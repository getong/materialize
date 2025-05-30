# Copyright Materialize, Inc. and contributors. All rights reserved.
#
# Use of this software is governed by the Business Source License
# included in the LICENSE file at the root of this repository.
#
# As of the Change Date specified in that file, in accordance with
# the Business Source License, use of this software will be governed
# by the Apache License, Version 2.0.

#
# Concurrent deletes over the same table
#

$ postgres-execute connection=postgres://postgres:postgres@postgres
CREATE TABLE concurrent_delete (f1 INTEGER, PRIMARY KEY (f1));
ALTER TABLE concurrent_delete REPLICA IDENTITY FULL;
INSERT INTO concurrent_delete VALUES (1);
INSERT INTO concurrent_delete VALUES (2);
INSERT INTO concurrent_delete VALUES (3);
INSERT INTO concurrent_delete VALUES (4);
INSERT INTO concurrent_delete VALUES (5);
INSERT INTO concurrent_delete VALUES (6);

$ schema-registry-wait topic=postgres.public.concurrent_delete

> CREATE CONNECTION IF NOT EXISTS csr_conn TO CONFLUENT SCHEMA REGISTRY (
    URL '${testdrive.schema-registry-url}'
  );

> CREATE CONNECTION IF NOT EXISTS kafka_conn TO KAFKA (BROKER '${testdrive.kafka-addr}', SECURITY PROTOCOL PLAINTEXT);

> CREATE SOURCE concurrent_delete
  FROM KAFKA CONNECTION kafka_conn (TOPIC 'postgres.public.concurrent_delete');

> CREATE TABLE concurrent_delete_tbl FROM SOURCE concurrent_delete (REFERENCE "postgres.public.concurrent_delete")
  FORMAT AVRO USING CONFLUENT SCHEMA REGISTRY CONNECTION csr_conn
  ENVELOPE DEBEZIUM;

$ postgres-connect name=conn1 url=postgres://postgres:postgres@postgres

$ postgres-connect name=conn2 url=postgres://postgres:postgres@postgres

$ postgres-execute connection=conn1
BEGIN;
DELETE FROM concurrent_delete WHERE f1 = 2;

$ postgres-execute connection=conn2
BEGIN;
DELETE FROM concurrent_delete WHERE f1 = 3;

$ postgres-execute connection=conn1
DELETE FROM concurrent_delete WHERE f1 = 4;
COMMIT;

$ postgres-execute connection=conn2
DELETE FROM concurrent_delete WHERE f1 = 5;
COMMIT;

> SELECT * FROM concurrent_delete_tbl;
1
6
