# Copyright Materialize, Inc. and contributors. All rights reserved.
#
# Use of this software is governed by the Business Source License
# included in the LICENSE file at the root of this repository.
#
# As of the Change Date specified in that file, in accordance with
# the Business Source License, use of this software will be governed
# by the Apache License, Version 2.0.

$ set-arg-default default-storage-size=1
$ set-arg-default single-replica-cluster=quickstart

# Test Avro UPSERT sinks.

$ postgres-execute connection=postgres://mz_system:materialize@${testdrive.materialize-internal-sql-addr}
ALTER SYSTEM SET enable_envelope_materialize = true
ALTER SYSTEM SET max_clusters = 20


# sinking directly from an UPSERT source with multi-part key

$ set upsert-keyschema={
    "type": "record",
    "name": "Key",
    "fields": [
        {"name": "key1", "type": "string"},
        {"name": "key2", "type": "long"}
    ]
  }

$ set upsert-schema={
        "type" : "record",
        "name" : "test",
        "fields" : [
            {"name":"f1", "type":"string"},
            {"name":"f2", "type":"long"}
        ]
    }

$ kafka-create-topic topic=upsert-avro

$ kafka-ingest format=avro topic=upsert-avro key-format=avro key-schema=${upsert-keyschema} schema=${upsert-schema}
{"key1": "fish", "key2": 2} {"f1": "fish", "f2": 1000}
{"key1": "fisch", "key2": 42} {"f1": "fish", "f2": 1000}

> CREATE CONNECTION kafka_conn
  TO KAFKA (BROKER '${testdrive.kafka-addr}', SECURITY PROTOCOL PLAINTEXT);

> CREATE CONNECTION IF NOT EXISTS csr_conn TO CONFLUENT SCHEMA REGISTRY (
    URL '${testdrive.schema-registry-url}'
  );

> CREATE CLUSTER upsert_input_cluster SIZE '${arg.default-storage-size}';
> CREATE SOURCE upsert_input
  IN CLUSTER upsert_input_cluster
  FROM KAFKA CONNECTION kafka_conn (TOPIC 'testdrive-upsert-avro-${testdrive.seed}')

> CREATE TABLE upsert_input_tbl FROM SOURCE upsert_input (REFERENCE "testdrive-upsert-avro-${testdrive.seed}")
  FORMAT AVRO USING CONFLUENT SCHEMA REGISTRY CONNECTION csr_conn
  ENVELOPE UPSERT

> CREATE CLUSTER upsert_input_sink_cluster SIZE '${arg.default-storage-size}';
> CREATE SINK upsert_input_sink
  IN CLUSTER upsert_input_sink_cluster
  FROM upsert_input_tbl
  INTO KAFKA CONNECTION kafka_conn (TOPIC 'testdrive-upsert-input-sink-${testdrive.seed}')
  KEY (key1, key2)
  FORMAT AVRO USING CONFLUENT SCHEMA REGISTRY CONNECTION csr_conn ENVELOPE UPSERT

$ kafka-verify-data format=avro sink=materialize.public.upsert_input_sink sort-messages=true
{"key1": "fisch", "key2": 42} {"key1": "fisch", "key2": 42, "f1": "fish", "f2": 1000}
{"key1": "fish", "key2": 2} {"key1": "fish", "key2": 2, "f1": "fish", "f2": 1000}

$ kafka-ingest format=avro topic=upsert-avro key-format=avro key-schema=${upsert-keyschema} schema=${upsert-schema}
{"key1": "fisch", "key2": 42} {"f1": "richtig, fisch", "f2": 2000}

$ kafka-verify-data format=avro sink=materialize.public.upsert_input_sink
{"key1": "fisch", "key2": 42} {"key1": "fisch", "key2": 42, "f1": "richtig, fisch", "f2": 2000}

# More complicated scenarios: super keys, consistency input/output
$ set schema=[
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
            "fields": [
              {"name": "a", "type": "long"},
              {"name": "b", "type": "long"}
            ]
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

$ kafka-create-topic topic=input

# (PRIMARY KEY (id) NOT ENFORCED)
> CREATE CLUSTER input_cluster SIZE '${arg.default-storage-size}';
> CREATE SOURCE input
  IN CLUSTER input_cluster
  FROM KAFKA CONNECTION kafka_conn (TOPIC 'testdrive-input-${testdrive.seed}')

> CREATE TABLE input_tbl FROM SOURCE input (REFERENCE "testdrive-input-${testdrive.seed}")
  FORMAT AVRO USING SCHEMA '${schema}' ENVELOPE MATERIALIZE

> CREATE MATERIALIZED VIEW input_keyed AS SELECT a, max(b) as b FROM input_tbl GROUP BY a

> CREATE CLUSTER input_sink_cluster SIZE '${arg.default-storage-size}';
> CREATE SINK input_sink
  IN CLUSTER input_sink_cluster
  FROM input_keyed
  INTO KAFKA CONNECTION kafka_conn (TOPIC 'input-sink-${testdrive.seed}') KEY (a)
  FORMAT AVRO
  USING CONFLUENT SCHEMA REGISTRY CONNECTION csr_conn ENVELOPE UPSERT

# requesting to key by (a, b) is fine when (a) is a unique key

> CREATE CLUSTER input_sink_multiple_keys_cluster SIZE '${arg.default-storage-size}';
> CREATE SINK input_sink_multiple_keys
  IN CLUSTER input_sink_multiple_keys_cluster
  FROM input_keyed
  INTO KAFKA CONNECTION kafka_conn (TOPIC 'input-sink-multikey-${testdrive.seed}') KEY (b, a)
  FORMAT AVRO
  USING CONFLUENT SCHEMA REGISTRY CONNECTION csr_conn ENVELOPE UPSERT

$ kafka-ingest format=avro topic=input schema=${schema}
{"array":[{"data":{"a":1,"b":1},"time":1,"diff":1}]}
{"array":[{"data":{"a":2,"b":2},"time":1,"diff":1}]}
{"array":[{"data":{"a":3,"b":1},"time":2,"diff":1}]}
{"array":[{"data":{"a":4,"b":2},"time":2,"diff":1}]}
{"array":[{"data":{"a":1,"b":7},"time":3,"diff":1}]}
{"com.materialize.cdc.progress":{"lower":[0],"upper":[4],"counts":[{"time":1,"count":2},{"time":2,"count":2}, {"time": 3, "count": 1}]}}

> SELECT * FROM input_tbl;
a  b
------
1  1
2  2
3  1
4  2
1  7

# Compare sorted messages within each transaction. We know that messages of one
# transaction appear together as one "bundle" in the output. But there is no
# guarantee on the order within a transaction.

$ kafka-verify-data headers=materialize-timestamp format=avro sink=materialize.public.input_sink sort-messages=true
1	{"a": 1} {"a": 1, "b": 1}
1	{"a": 2} {"a": 2, "b": 2}

$ kafka-verify-data headers=materialize-timestamp format=avro sink=materialize.public.input_sink sort-messages=true
2	{"a": 3} {"a": 3, "b": 1}
2	{"a": 4} {"a": 4, "b": 2}

$ kafka-verify-data headers=materialize-timestamp format=avro sink=materialize.public.input_sink sort-messages=true
3	{"a": 1} {"a": 1, "b": 7}

# Again, compare split by transaction. See comment just above.

$ kafka-verify-data headers=materialize-timestamp format=avro sink=materialize.public.input_sink_multiple_keys sort-messages=true
1	{"a": 1, "b": 1} {"a": 1, "b": 1}
1	{"a": 2, "b": 2} {"a": 2, "b": 2}

$ kafka-verify-data headers=materialize-timestamp format=avro sink=materialize.public.input_sink_multiple_keys sort-messages=true
2	{"a": 3, "b": 1} {"a": 3, "b": 1}
2	{"a": 4, "b": 2} {"a": 4, "b": 2}

# missing value denotes DELETE

$ kafka-verify-data headers=materialize-timestamp format=avro sink=materialize.public.input_sink_multiple_keys sort-messages=true
3 {"a": 1, "b": 1}
3	{"a": 1, "b": 7} {"a": 1, "b": 7}

# verify if/when input deletions are emitted to an UPSERT sink

$ kafka-create-topic topic=input-with-deletions

> CREATE CLUSTER input_with_deletions_cluster SIZE '${arg.default-storage-size}';
> CREATE SOURCE input_with_deletions
  IN CLUSTER input_with_deletions_cluster
  FROM KAFKA CONNECTION kafka_conn (TOPIC 'testdrive-input-with-deletions-${testdrive.seed}')

> CREATE TABLE input_with_deletions_tbl FROM SOURCE input_with_deletions (REFERENCE "testdrive-input-with-deletions-${testdrive.seed}")
  FORMAT AVRO USING SCHEMA '${schema}' ENVELOPE MATERIALIZE

> CREATE MATERIALIZED VIEW input_with_deletions_keyed AS SELECT a, max(b) as b FROM input_with_deletions_tbl GROUP BY a

> CREATE CLUSTER input_with_deletions_sink_cluster SIZE '${arg.default-storage-size}';
> CREATE SINK input_with_deletions_sink
  IN CLUSTER input_with_deletions_sink_cluster
  FROM input_with_deletions_keyed
  INTO KAFKA CONNECTION kafka_conn (TOPIC 'input-sink-with-deletions-${testdrive.seed}') KEY (a)
  FORMAT AVRO USING CONFLUENT SCHEMA REGISTRY CONNECTION csr_conn ENVELOPE UPSERT

$ kafka-ingest format=avro topic=input-with-deletions schema=${schema}
{"array":[{"data":{"a":1,"b":1},"time":1,"diff":1}]}
{"com.materialize.cdc.progress":{"lower":[0],"upper":[2],"counts":[{"time":1,"count":1}]}}

$ kafka-verify-data headers=materialize-timestamp format=avro sink=materialize.public.input_with_deletions_sink sort-messages=true
1	{"a": 1} {"a": 1, "b": 1}

$ kafka-ingest format=avro topic=input-with-deletions schema=${schema}
{"array":[{"data":{"a":1,"b":2},"time":2,"diff":1}]}
{"com.materialize.cdc.progress":{"lower":[2],"upper":[3],"counts":[{"time":2,"count":1}]}}

$ kafka-verify-data headers=materialize-timestamp format=avro sink=materialize.public.input_with_deletions_sink sort-messages=true
2	{"a": 1} {"a": 1, "b": 2}

# deletion of the "shadowed" input should not cause downstream updates

$ kafka-ingest format=avro topic=input-with-deletions schema=${schema}
{"array":[{"data":{"a":1,"b":1},"time":3,"diff":-1}]}
{"com.materialize.cdc.progress":{"lower":[3],"upper":[4],"counts":[{"time":3,"count":1}]}}

$ kafka-ingest format=avro topic=input-with-deletions schema=${schema}
{"array":[{"data":{"a":1,"b":2},"time":4,"diff":-1}]}
{"com.materialize.cdc.progress":{"lower":[4],"upper":[5],"counts":[{"time":4,"count":1}]}}

# now we should see a NULL update on the key, which means a DELETE

$ kafka-verify-data format=avro sink=materialize.public.input_with_deletions_sink sort-messages=true
{"a": 1}

$ kafka-ingest format=avro topic=input-with-deletions schema=${schema}
{"array":[{"data":{"a":1,"b":1},"time":5,"diff":1}]}
{"array":[{"data":{"a":1,"b":2},"time":5,"diff":1}]}
{"com.materialize.cdc.progress":{"lower":[5],"upper":[6],"counts":[{"time":5,"count":2}]}}

$ kafka-verify-data headers=materialize-timestamp format=avro sink=materialize.public.input_with_deletions_sink sort-messages=true
5	{"a": 1} {"a": 1, "b": 2}

$ kafka-ingest format=avro topic=input-with-deletions schema=${schema}
{"array":[{"data":{"a":1,"b":2},"time":6,"diff":-1}]}
{"com.materialize.cdc.progress":{"lower":[6],"upper":[7],"counts":[{"time":6,"count":1}]}}

# removing the occluding input should "reveal" the previous input again
#
$ kafka-verify-data headers=materialize-timestamp format=avro sink=materialize.public.input_with_deletions_sink sort-messages=true
6	{"a": 1} {"a": 1, "b": 1}

# NOT ENFORCED Keys

$ kafka-create-topic topic=non-keyed-input

> CREATE CLUSTER non_keyed_input_cluster SIZE '${arg.default-storage-size}';
> CREATE SOURCE non_keyed_input
  IN CLUSTER non_keyed_input_cluster
  FROM KAFKA CONNECTION kafka_conn (TOPIC 'testdrive-non-keyed-input-${testdrive.seed}')

> CREATE TABLE non_keyed_input_tbl FROM SOURCE non_keyed_input (REFERENCE "testdrive-non-keyed-input-${testdrive.seed}")
  FORMAT AVRO USING SCHEMA '${schema}' ENVELOPE MATERIALIZE

> CREATE CLUSTER not_enforced_key_cluster SIZE '${arg.default-storage-size}';
> CREATE SINK not_enforced_key
  IN CLUSTER not_enforced_key_cluster
  FROM non_keyed_input_tbl
  INTO KAFKA CONNECTION kafka_conn (TOPIC 'not-enforced-sink-${testdrive.seed}') KEY (a) NOT ENFORCED
  FORMAT AVRO USING CONFLUENT SCHEMA REGISTRY CONNECTION csr_conn ENVELOPE UPSERT

# Send a create, an update, and a delete for two separate keys.
$ kafka-ingest format=avro topic=non-keyed-input schema=${schema}
{"array":[{"data":{"a":1,"b":1},"time":1,"diff":1}]}
{"array":[{"data":{"a":2,"b":1},"time":1,"diff":1}]}
{"array":[{"data":{"a":1,"b":1},"time":2,"diff":-1}]}
{"array":[{"data":{"a":2,"b":1},"time":2,"diff":-1}]}
{"array":[{"data":{"a":1,"b":2},"time":2,"diff":1}]}
{"array":[{"data":{"a":2,"b":2},"time":2,"diff":1}]}
{"array":[{"data":{"a":1,"b":2},"time":3,"diff":-1}]}
{"array":[{"data":{"a":2,"b":2},"time":3,"diff":-1}]}
{"com.materialize.cdc.progress":{"lower":[0],"upper":[10],"counts":[{"time":1,"count":2}, {"time":2,"count":4}, {"time":3,"count":2}]}}

# Verify that the update appears as an upsert instead of a create + delete, even when keys are not enforced.
$ kafka-verify-data headers=materialize-timestamp format=avro topic=not-enforced-sink-${testdrive.seed} sort-messages=true
1	{"a": 1} {"a": 1, "b": 1}
1	{"a": 2} {"a": 2, "b": 1}

$ kafka-verify-data headers=materialize-timestamp format=avro topic=not-enforced-sink-${testdrive.seed} sort-messages=true
2	{"a": 1} {"a": 1, "b": 2}
2	{"a": 2} {"a": 2, "b": 2}

$ kafka-verify-data headers=materialize-timestamp format=avro topic=not-enforced-sink-${testdrive.seed} sort-messages=true
3	{"a": 1}
3	{"a": 2}

# Bad upsert keys

! CREATE SINK invalid_key
  IN CLUSTER ${arg.single-replica-cluster}
  FROM input_tbl
  INTO KAFKA CONNECTION kafka_conn (TOPIC 'input-sink-${testdrive.seed}') KEY (a)
  FORMAT AVRO
  USING CONFLUENT SCHEMA REGISTRY CONNECTION csr_conn ENVELOPE UPSERT
contains:upsert key could not be validated as unique

! CREATE SINK another_invalid_key
  IN CLUSTER ${arg.single-replica-cluster}
  FROM input_keyed
  INTO KAFKA CONNECTION kafka_conn (TOPIC 'input-sink-${testdrive.seed}') KEY (b)
  FORMAT AVRO
  USING CONFLUENT SCHEMA REGISTRY CONNECTION csr_conn ENVELOPE UPSERT
contains:upsert key could not be validated as unique

> CREATE MATERIALIZED VIEW input_keyed_ab AS SELECT a, b FROM input_tbl GROUP BY a, b

! CREATE SINK invalid_sub_key
  IN CLUSTER ${arg.single-replica-cluster}
  FROM input_keyed_ab
  INTO KAFKA CONNECTION kafka_conn (TOPIC 'input-sink-${testdrive.seed}') KEY (a)
  FORMAT AVRO
  USING CONFLUENT SCHEMA REGISTRY CONNECTION csr_conn ENVELOPE UPSERT
contains:upsert key could not be validated as unique

! CREATE SINK another_invalid_sub_key
  IN CLUSTER ${arg.single-replica-cluster}
  FROM input_keyed_ab
  INTO KAFKA CONNECTION kafka_conn (TOPIC 'input-sink-${testdrive.seed}') KEY (b)
  FORMAT AVRO
  USING CONFLUENT SCHEMA REGISTRY CONNECTION csr_conn ENVELOPE UPSERT
contains:upsert key could not be validated as unique

! CREATE SINK invalid_key_from_upsert_input
  IN CLUSTER ${arg.single-replica-cluster}
  FROM upsert_input_tbl
  INTO KAFKA CONNECTION kafka_conn (TOPIC 'data-sink-${testdrive.seed}')
  KEY (key1)
  FORMAT AVRO USING CONFLUENT SCHEMA REGISTRY CONNECTION csr_conn ENVELOPE UPSERT
contains:upsert key could not be validated as unique

! CREATE SINK invalid_key_from_upsert_input
  IN CLUSTER ${arg.single-replica-cluster}
  FROM upsert_input_tbl
  INTO KAFKA CONNECTION kafka_conn (TOPIC 'data-sink-${testdrive.seed}')
  KEY (key2)
  FORMAT AVRO USING CONFLUENT SCHEMA REGISTRY CONNECTION csr_conn ENVELOPE UPSERT
contains:upsert key could not be validated as unique

# Check arrangements, seeing new arrangements can mean a significant increase
# in memory consumptions and should be understood before adapting the values.
> SET cluster_replica = r1

> SELECT mdod.dataflow_name, mdod.name
  FROM mz_introspection.mz_arrangement_sharing mash
  JOIN mz_introspection.mz_dataflow_operator_dataflows mdod ON mash.operator_id = mdod.id
  JOIN mz_introspection.mz_compute_exports USING (dataflow_id)
  WHERE export_id LIKE 'u%'
"Dataflow: materialize.public.input_keyed" "Arrange ReduceMinsMaxes"
"Dataflow: materialize.public.input_keyed" "Arranged MinsMaxesHierarchical input"
"Dataflow: materialize.public.input_keyed" "Arranged MinsMaxesHierarchical input"
"Dataflow: materialize.public.input_keyed" "Arranged MinsMaxesHierarchical input"
"Dataflow: materialize.public.input_keyed" "Arranged MinsMaxesHierarchical input"
"Dataflow: materialize.public.input_keyed" "Arranged MinsMaxesHierarchical input"
"Dataflow: materialize.public.input_keyed" "Arranged MinsMaxesHierarchical input"
"Dataflow: materialize.public.input_keyed" "Arranged MinsMaxesHierarchical input"
"Dataflow: materialize.public.input_keyed" ReduceMinsMaxes
"Dataflow: materialize.public.input_keyed" "Reduced Fallibly MinsMaxesHierarchical"
"Dataflow: materialize.public.input_keyed" "Reduced Fallibly MinsMaxesHierarchical"
"Dataflow: materialize.public.input_keyed" "Reduced Fallibly MinsMaxesHierarchical"
"Dataflow: materialize.public.input_keyed" "Reduced Fallibly MinsMaxesHierarchical"
"Dataflow: materialize.public.input_keyed" "Reduced Fallibly MinsMaxesHierarchical"
"Dataflow: materialize.public.input_keyed" "Reduced Fallibly MinsMaxesHierarchical"
"Dataflow: materialize.public.input_keyed" "Reduced Fallibly MinsMaxesHierarchical"
"Dataflow: materialize.public.input_keyed_ab" "Arranged DistinctBy"
"Dataflow: materialize.public.input_keyed_ab" DistinctBy
"Dataflow: materialize.public.input_keyed_ab" DistinctByErrorCheck
"Dataflow: materialize.public.input_with_deletions_keyed" "Arrange ReduceMinsMaxes"
"Dataflow: materialize.public.input_with_deletions_keyed" "Arranged MinsMaxesHierarchical input"
"Dataflow: materialize.public.input_with_deletions_keyed" "Arranged MinsMaxesHierarchical input"
"Dataflow: materialize.public.input_with_deletions_keyed" "Arranged MinsMaxesHierarchical input"
"Dataflow: materialize.public.input_with_deletions_keyed" "Arranged MinsMaxesHierarchical input"
"Dataflow: materialize.public.input_with_deletions_keyed" "Arranged MinsMaxesHierarchical input"
"Dataflow: materialize.public.input_with_deletions_keyed" "Arranged MinsMaxesHierarchical input"
"Dataflow: materialize.public.input_with_deletions_keyed" "Arranged MinsMaxesHierarchical input"
"Dataflow: materialize.public.input_with_deletions_keyed" ReduceMinsMaxes
"Dataflow: materialize.public.input_with_deletions_keyed" "Reduced Fallibly MinsMaxesHierarchical"
"Dataflow: materialize.public.input_with_deletions_keyed" "Reduced Fallibly MinsMaxesHierarchical"
"Dataflow: materialize.public.input_with_deletions_keyed" "Reduced Fallibly MinsMaxesHierarchical"
"Dataflow: materialize.public.input_with_deletions_keyed" "Reduced Fallibly MinsMaxesHierarchical"
"Dataflow: materialize.public.input_with_deletions_keyed" "Reduced Fallibly MinsMaxesHierarchical"
"Dataflow: materialize.public.input_with_deletions_keyed" "Reduced Fallibly MinsMaxesHierarchical"
"Dataflow: materialize.public.input_with_deletions_keyed" "Reduced Fallibly MinsMaxesHierarchical"
