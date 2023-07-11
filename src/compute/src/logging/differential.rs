// Copyright Materialize, Inc. and contributors. All rights reserved.
//
// Use of this software is governed by the Business Source License
// included in the LICENSE file.
//
// As of the Change Date specified in that file, in accordance with
// the Business Source License, use of this software will be governed
// by the Apache License, Version 2.0.

//! Logging dataflows for events generated by differential dataflow.

use std::any::Any;
use std::cell::RefCell;
use std::collections::BTreeMap;
use std::rc::Rc;
use std::time::Duration;

use differential_dataflow::collection::AsCollection;
use differential_dataflow::logging::{
    BatchEvent, DifferentialEvent, DropEvent, MergeEvent, TraceShare,
};
use mz_expr::{permutation_for_arrangement, MirScalarExpr};
use mz_ore::cast::CastFrom;
use mz_repr::{Datum, DatumVec, Diff, Row, Timestamp};
use mz_timely_util::buffer::ConsolidateBuffer;
use mz_timely_util::replay::MzReplay;
use timely::communication::Allocate;
use timely::dataflow::channels::pact::{Exchange, Pipeline};
use timely::dataflow::channels::pushers::Tee;
use timely::dataflow::operators::generic::builder_rc::OperatorBuilder;
use timely::dataflow::operators::{Filter, InputCapability};

use crate::extensions::arrange::MzArrange;
use crate::logging::compute::ComputeEvent;
use crate::logging::{DifferentialLog, EventQueue, LogVariant, SharedLoggingState};
use crate::typedefs::{KeysValsHandle, RowSpine};

/// Constructs the logging dataflow for differential logs.
///
/// Params
/// * `worker`: The Timely worker hosting the log analysis dataflow.
/// * `config`: Logging configuration
/// * `event_queue`: The source to read log events from.
///
/// Returns a map from log variant to a tuple of a trace handle and a dataflow drop token.
pub(super) fn construct<A: Allocate>(
    worker: &mut timely::worker::Worker<A>,
    config: &mz_compute_client::logging::LoggingConfig,
    event_queue: EventQueue<DifferentialEvent>,
    shared_state: Rc<RefCell<SharedLoggingState>>,
) -> BTreeMap<LogVariant, (KeysValsHandle, Rc<dyn Any>)> {
    let logging_interval_ms = std::cmp::max(1, config.interval.as_millis());
    let worker_id = worker.index();

    worker.dataflow_named("Dataflow: differential logging", move |scope| {
        let (mut logs, token) = Some(event_queue.link).mz_replay(
            scope,
            "differential logs",
            config.interval,
            event_queue.activator,
        );

        // If logging is disabled, we still need to install the indexes, but we can leave them
        // empty. We do so by immediately filtering all logs events.
        if !config.enable_logging {
            logs = logs.filter(|_| false);
        }

        // Build a demux operator that splits the replayed event stream up into the separate
        // logging streams.
        let mut demux =
            OperatorBuilder::new("Differential Logging Demux".to_string(), scope.clone());
        let mut input = demux.new_input(&logs, Pipeline);
        let (mut batches_out, batches) = demux.new_output();
        let (mut records_out, records) = demux.new_output();
        let (mut sharing_out, sharing) = demux.new_output();

        let mut demux_buffer = Vec::new();
        let mut demux_state = Default::default();
        demux.build(move |_capability| {
            move |_frontiers| {
                let mut batches = batches_out.activate();
                let mut records = records_out.activate();
                let mut sharing = sharing_out.activate();

                let mut output_buffers = DemuxOutput {
                    batches: ConsolidateBuffer::new(&mut batches, 0),
                    records: ConsolidateBuffer::new(&mut records, 1),
                    sharing: ConsolidateBuffer::new(&mut sharing, 2),
                };

                input.for_each(|cap, data| {
                    data.swap(&mut demux_buffer);

                    for (time, logger_id, event) in demux_buffer.drain(..) {
                        // We expect the logging infrastructure to not shuffle events between
                        // workers and this code relies on the assumption that each worker handles
                        // its own events.
                        assert_eq!(logger_id, worker_id);

                        DemuxHandler {
                            state: &mut demux_state,
                            output: &mut output_buffers,
                            logging_interval_ms,
                            time,
                            cap: &cap,
                            shared_state: &mut shared_state.borrow_mut(),
                        }
                        .handle(event);
                    }
                });
            }
        });

        // Encode the contents of each logging stream into its expected `Row` format.
        let arrangement_batches = batches.as_collection().map(move |op| {
            Row::pack_slice(&[
                Datum::UInt64(u64::cast_from(op)),
                Datum::UInt64(u64::cast_from(worker_id)),
            ])
        });
        let arrangement_records = records.as_collection().map(move |op| {
            Row::pack_slice(&[
                Datum::UInt64(u64::cast_from(op)),
                Datum::UInt64(u64::cast_from(worker_id)),
            ])
        });

        let sharing = sharing
            .as_collection()
            .mz_arrange_core::<_, RowSpine<_, _, _, _>>(
                Exchange::new(move |_| u64::cast_from(worker_id)),
                "PreArrange Differential sharing",
            );

        let sharing = sharing.as_collection(move |op, ()| {
            Row::pack_slice(&[
                Datum::UInt64(u64::cast_from(*op)),
                Datum::UInt64(u64::cast_from(worker_id)),
            ])
        });

        use DifferentialLog::*;
        let logs = [
            (ArrangementBatches, arrangement_batches),
            (ArrangementRecords, arrangement_records),
            (Sharing, sharing),
        ];

        // Build the output arrangements.
        let mut traces = BTreeMap::new();
        for (variant, collection) in logs {
            let variant = LogVariant::Differential(variant);
            if config.index_logs.contains_key(&variant) {
                let key = variant.index_by();
                let (_, value) = permutation_for_arrangement(
                    &key.iter()
                        .cloned()
                        .map(MirScalarExpr::Column)
                        .collect::<Vec<_>>(),
                    variant.desc().arity(),
                );
                let trace = collection
                    .map({
                        let mut row_buf = Row::default();
                        let mut datums = DatumVec::new();
                        move |row| {
                            let datums = datums.borrow_with(&row);
                            row_buf.packer().extend(key.iter().map(|k| datums[*k]));
                            let row_key = row_buf.clone();
                            row_buf.packer().extend(value.iter().map(|c| datums[*c]));
                            let row_val = row_buf.clone();
                            (row_key, row_val)
                        }
                    })
                    .mz_arrange::<RowSpine<_, _, _, _>>(&format!("ArrangeByKey {:?}", variant))
                    .trace();
                traces.insert(variant.clone(), (trace, Rc::clone(&token)));
            }
        }

        traces
    })
}

type Pusher<D> = Tee<Timestamp, (D, Timestamp, Diff)>;
type OutputBuffer<'a, 'b, D> = ConsolidateBuffer<'a, 'b, Timestamp, D, Diff, Pusher<D>>;

/// Bundled output buffers used by the demux operator.
struct DemuxOutput<'a, 'b> {
    batches: OutputBuffer<'a, 'b, usize>,
    records: OutputBuffer<'a, 'b, usize>,
    sharing: OutputBuffer<'a, 'b, (usize, ())>,
}

/// State maintained by the demux operator.
#[derive(Default)]
struct DemuxState {
    /// Arrangement trace sharing
    sharing: BTreeMap<usize, usize>,
}

/// Event handler of the demux operator.
struct DemuxHandler<'a, 'b, 'c> {
    /// State kept by the demux operator
    state: &'a mut DemuxState,
    /// Demux output buffers.
    output: &'a mut DemuxOutput<'b, 'c>,
    /// The logging interval specifying the time granularity for the updates.
    logging_interval_ms: u128,
    /// The current event time.
    time: Duration,
    /// A capability usable for emitting outputs.
    cap: &'a InputCapability<Timestamp>,
    /// State shared across log receivers.
    shared_state: &'a mut SharedLoggingState,
}

impl DemuxHandler<'_, '_, '_> {
    /// Return the timestamp associated with the current event, based on the event time and the
    /// logging interval.
    fn ts(&self) -> Timestamp {
        let time_ms = self.time.as_millis();
        let interval = self.logging_interval_ms;
        let rounded = (time_ms / interval + 1) * interval;
        rounded.try_into().expect("must fit")
    }

    /// Handle the given differential event.
    fn handle(&mut self, event: DifferentialEvent) {
        use DifferentialEvent::*;

        match event {
            Batch(e) => self.handle_batch(e),
            Merge(e) => self.handle_merge(e),
            Drop(e) => self.handle_drop(e),
            TraceShare(e) => self.handle_trace_share(e),
            _ => (),
        }
    }

    fn handle_batch(&mut self, event: BatchEvent) {
        let ts = self.ts();
        let op = event.operator;
        self.output.batches.give(self.cap, (op, ts, 1));

        let diff = Diff::try_from(event.length).expect("must fit");
        self.output.records.give(self.cap, (op, ts, diff));
        self.notify_arrangement_size(op);
    }

    fn handle_merge(&mut self, event: MergeEvent) {
        let Some(done) = event.complete else { return };

        let ts = self.ts();
        let op = event.operator;
        self.output.batches.give(self.cap, (op, ts, -1));

        let diff = Diff::try_from(done).expect("must fit")
            - Diff::try_from(event.length1 + event.length2).expect("must fit");
        if diff != 0 {
            self.output.records.give(self.cap, (op, ts, diff));
        }
        self.notify_arrangement_size(op);
    }

    fn handle_drop(&mut self, event: DropEvent) {
        let ts = self.ts();
        let op = event.operator;
        self.output.batches.give(self.cap, (op, ts, -1));

        let diff = -Diff::try_from(event.length).expect("must fit");
        if diff != 0 {
            self.output.records.give(self.cap, (op, ts, diff));
        }
        self.notify_arrangement_size(op);
    }

    fn handle_trace_share(&mut self, event: TraceShare) {
        let ts = self.ts();
        let op = event.operator;
        let diff = Diff::cast_from(event.diff);
        debug_assert_ne!(diff, 0);
        self.output.sharing.give(self.cap, ((op, ()), ts, diff));

        if let Some(logger) = &mut self.shared_state.compute_logger {
            let sharing = self.state.sharing.entry(op).or_default();
            *sharing = (i64::try_from(*sharing).expect("must fit") + diff)
                .try_into()
                .expect("under/overflow");
            if *sharing == 0 {
                self.state.sharing.remove(&op);
                logger.log(ComputeEvent::ArrangementHeapSizeOperatorDrop { operator: op });
            }
        }
    }

    fn notify_arrangement_size(&self, operator: usize) {
        // While every arrangement should have a corresponding arrangement size operator,
        // we have no guarantee that it already/still exists. Otherwise we could print a warning
        // here, but it's difficult to implement without maintaining state for a longer period than
        // while the arrangement actually exists.
        if let Some(activator) = self.shared_state.arrangement_size_activators.get(&operator) {
            activator.activate();
        }
    }
}
