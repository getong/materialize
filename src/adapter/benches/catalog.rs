// Copyright Materialize, Inc. and contributors. All rights reserved.
//
// Use of this software is governed by the Business Source License
// included in the LICENSE file.
//
// As of the Change Date specified in that file, in accordance with
// the Business Source License, use of this software will be governed
// by the Apache License, Version 2.0.

use criterion::{Criterion, criterion_group, criterion_main};
use mz_adapter::catalog::{Catalog, Op};
use mz_catalog::durable::test_bootstrap_args;
use mz_persist_client::PersistClient;
use mz_sql::session::user::MZ_SYSTEM_ROLE_ID;
use tokio::runtime::Runtime;
use uuid::Uuid;

fn bench_transact(c: &mut Criterion) {
    c.bench_function("transact", |b| {
        let runtime = Runtime::new().unwrap();

        let bootstrap_args = test_bootstrap_args();
        let mut catalog = runtime.block_on(async {
            Catalog::open_debug_catalog(
                PersistClient::new_for_tests().await,
                Uuid::new_v4(),
                &bootstrap_args,
            )
            .await
            .unwrap()
        });
        let mut id = 0;
        b.iter(|| {
            runtime.block_on(async {
                id += 1;
                let ops = vec![Op::CreateDatabase {
                    name: id.to_string(),
                    owner_id: MZ_SYSTEM_ROLE_ID,
                }];
                let commit_ts = catalog.current_upper().await;
                catalog.transact(None, commit_ts, None, ops).await.unwrap();
            })
        });
        runtime.block_on(async {
            catalog.expire().await;
        });
    });
}

criterion_group!(benches, bench_transact);
criterion_main!(benches);
