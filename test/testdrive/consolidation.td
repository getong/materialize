# Copyright Materialize, Inc. and contributors. All rights reserved.
#
# Use of this software is governed by the Business Source License
# included in the LICENSE file at the root of this repository.
#
# As of the Change Date specified in that file, in accordance with
# the Business Source License, use of this software will be governed
# by the Apache License, Version 2.0.

$ set-arg-default single-replica-cluster=quickstart

$ postgres-execute connection=postgres://mz_system:materialize@${testdrive.materialize-internal-sql-addr}
ALTER SYSTEM SET enable_envelope_materialize = true
ALTER SYSTEM SET enable_index_options = true
ALTER SYSTEM SET enable_logical_compaction_window = true
ALTER SYSTEM SET enable_unlimited_retain_history = true

# Test consolidation and compaction behavior.
#
# The various tests in this file use the following Debezium-formatted Kafka
# topics. The first topic, `nums`, is a basic data topic that contains one
# bigint field. The second topic, `tx`, mimics a Debezium transactional
# metadata topic that groups updates from `nums` into transactions.
#
# Using a transactional metadata topic like this allows us to tightly control
# the timestamp at which data is ingested into Materialize. Data from the first
# transaction is assigned timestamp 1, data from the second is assigned
# timestamp 2, and so on.

$ set nums-schema=[
  {
    "type": "array",
    "items": {
      "type": "record",
      "name": "update",
      "namespace": "com.materialize.cdc",
      "fields": [
        {
          "name": "data",
          "type": {
            "type": "record",
            "name": "data",
            "fields": [{"name": "num", "type": "long"}]
          }
        },
        {
          "name": "time",
          "type": "long"
        },
        {
          "name": "diff",
          "type": "long"
        }
      ]
    }
  },
  {
    "type": "record",
    "name": "progress",
    "namespace": "com.materialize.cdc",
    "fields": [
      {
        "name": "lower",
        "type": {
          "type": "array",
          "items": "long"
        }
      },
      {
        "name": "upper",
        "type": {
          "type": "array",
          "items": "long"
        }
      },
      {
        "name": "counts",
        "type": {
          "type": "array",
          "items": {
            "type": "record",
            "name": "counts",
            "fields": [
              {
                "name": "time",
                "type": "long"
              },
              {
                "name": "count",
                "type": "long"
              }
            ]
          }
        }
      }
    ]
  }
  ]

$ kafka-create-topic topic=nums

> CREATE CONNECTION kafka_conn
  TO KAFKA (BROKER '${testdrive.kafka-addr}', SECURITY PROTOCOL PLAINTEXT);

> CREATE SOURCE nums
  IN CLUSTER ${arg.single-replica-cluster}
  FROM KAFKA CONNECTION kafka_conn (TOPIC 'testdrive-nums-${testdrive.seed}')

> CREATE TABLE nums_tbl FROM SOURCE nums (REFERENCE "testdrive-nums-${testdrive.seed}")
  FORMAT AVRO USING SCHEMA '${nums-schema}'
  ENVELOPE MATERIALIZE

> CREATE DEFAULT INDEX ON nums_tbl

# Disable logical compaction, to ensure we can view historical detail.
> ALTER INDEX materialize.public.nums_tbl_primary_idx
  SET (RETAIN HISTORY = FOR 0)

> CREATE CONNECTION IF NOT EXISTS csr_conn TO CONFLUENT SCHEMA REGISTRY (
    URL '${testdrive.schema-registry-url}'
  );

# Create a sink before we ingest any data, to ensure the sink starts AS OF 0
> CREATE SINK nums_sink
  IN CLUSTER ${arg.single-replica-cluster}
  FROM nums_tbl
  INTO KAFKA CONNECTION kafka_conn (TOPIC 'nums-sink-${testdrive.seed}')
  FORMAT AVRO USING CONFLUENT SCHEMA REGISTRY CONNECTION csr_conn
  ENVELOPE DEBEZIUM

# ==> Test consolidation.

# Ingest several updates that consolidate

$ kafka-ingest format=avro topic=nums schema=${nums-schema}
{"array":[{"data":{"num":3},"time":1,"diff":1}]}
{"array":[{"data":{"num":3},"time":2,"diff":-1}]}
{"array":[{"data":{"num":4},"time":2,"diff":1}]}
{"array":[{"data":{"num":4},"time":3,"diff":-1}]}
{"array":[{"data":{"num":5},"time":3,"diff":1}]}
{"com.materialize.cdc.progress":{"lower":[0],"upper":[4],"counts":[{"time":1,"count":1},{"time":2,"count":2}, {"time": 3, "count": 2}]}}

# Test that by updates that occurred at at distinct times are not consolidated

# we know that transactions (timestamps) are emitted in order, but the order
# of emitted records with the same timestamp is not deterministic. We therefore
# verify each transaction separately and sort within each transaction to get
# deterministic results.

$ kafka-verify-data headers=materialize-timestamp format=avro sink=materialize.public.nums_sink
1	{"before": null, "after": {"row": {"num": 3}}}

$ kafka-verify-data headers=materialize-timestamp format=avro sink=materialize.public.nums_sink sort-messages=true
2	{"before": null, "after": {"row": {"num": 4}}}
2	{"before": {"row": {"num": 3}}, "after": null}

$ kafka-verify-data headers=materialize-timestamp format=avro sink=materialize.public.nums_sink sort-messages=true
3	{"before": null, "after": {"row": {"num": 5}}}
3	{"before": {"row": {"num": 4}}, "after": null}

# TODO(benesch): re-enable when we support `CREATE SINK ... AS OF`.
# # Test that a Debezium sink created `AS OF 3` (the latest completed timestamp)
# # is fully consolidated.
# > CREATE SINK nums_sink
#   IN CLUSTER ${arg.single-replica-cluster}
#   FROM nums_tbl
#   INTO KAFKA CONNECTION kafka_conn (TOPIC 'testdrive-nums-sink-${testdrive.seed}')
#   FORMAT AVRO USING CONFLUENT SCHEMA REGISTRY CONNECTION csr_conn
#   AS OF 3
#
# $ kafka-verify-data headers=materialize-timestamp format=avro sink=materialize.public.nums_sink
# 6 {"before": null, "after": {"row": {"num": 5}}}

# Validate that `SUBSCRIBE` is similarly consolidated.
# This protects against regression of database-issues#1675.

> BEGIN
> DECLARE cur CURSOR FOR SUBSCRIBE nums_tbl AS OF 3
> FETCH ALL cur
mz_timestamp  mz_diff  num
--------------------------
3             1        5
> COMMIT

# ==> Test compaction.

# Each transaction that has been updated so far should be separately visible
# (i.e., not compacted away).

> SELECT * FROM nums_tbl AS OF 1
3
> SELECT * FROM nums_tbl AS OF 2
4
> SELECT * FROM nums_tbl AS OF 3
5

# Decrease the compaction window and ingest some new data in transaction 4.

> ALTER INDEX materialize.public.nums_tbl_primary_idx
  SET (RETAIN HISTORY = FOR '1ms')

$ kafka-ingest format=avro topic=nums schema=${nums-schema}
{"array":[{"data":{"num":5},"time":4,"diff":-1}]}
{"array":[{"data":{"num":6},"time":4,"diff":1}]}
{"com.materialize.cdc.progress":{"lower":[4],"upper":[5],"counts":[{"time":4,"count":2}]}}

# Data from older transactions should be immediately compacted to the timestamp
# of the latest transaction (i.e., 4).

! SELECT * FROM nums_tbl AS OF 2
contains:Timestamp (2) is not valid for all inputs
! SELECT * FROM nums_tbl AS OF 3
contains:Timestamp (3) is not valid for all inputs
> SELECT * FROM nums_tbl AS OF 4
6

# Set the compaction window back to off and advance the number in transactions 5 and 6.

> ALTER INDEX materialize.public.nums_tbl_primary_idx
  SET (RETAIN HISTORY = FOR 0)

# But also create an index that compacts frequently.
> CREATE VIEW nums_compacted AS SELECT * FROM nums_tbl
> CREATE DEFAULT INDEX ON nums_compacted WITH (RETAIN HISTORY = FOR '1ms')

$ kafka-ingest format=avro topic=nums schema=${nums-schema}
{"array":[{"data":{"num":6},"time":5,"diff":-1}]}
{"array":[{"data":{"num":7},"time":5,"diff":1}]}
{"array":[{"data":{"num":7},"time":6,"diff":-1}]}
{"array":[{"data":{"num":8},"time":6,"diff":1}]}
{"com.materialize.cdc.progress":{"lower":[5],"upper":[7],"counts":[{"time":5,"count":2},{"time":6,"count":2}]}}

# Timestamps 4, 5, and 6 should all be available due to the longer compaction
# window.

> SELECT * FROM nums_tbl AS OF 4
6
> SELECT * FROM nums_tbl AS OF 5
7
> SELECT * FROM nums_tbl AS OF 6
8

! SELECT * FROM nums_compacted AS OF 4
contains:Timestamp (4) is not valid for all inputs
! SELECT * FROM nums_compacted AS OF 5
contains:Timestamp (5) is not valid for all inputs
> SELECT * FROM nums_compacted AS OF 6
8
