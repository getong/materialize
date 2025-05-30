# Copyright Materialize, Inc. and contributors. All rights reserved.
#
# Use of this software is governed by the Business Source License
# included in the LICENSE file at the root of this repository.
#
# As of the Change Date specified in that file, in accordance with
# the Business Source License, use of this software will be governed
# by the Apache License, Version 2.0.

from materialize.feature_benchmark.action import Action, TdAction
from materialize.feature_benchmark.measurement_source import MeasurementSource, Td
from materialize.feature_benchmark.scenario import Scenario
from materialize.feature_benchmark.scenario_version import ScenarioVersion


class Concurrency(Scenario):
    """Feature benchmarks related to testing concurrency aspects of the system"""


class ParallelIngestion(Concurrency):
    """Measure the time it takes to ingest multiple sources concurrently."""

    SOURCES = 10
    FIXED_SCALE = True  # Disk slowness in CRDB leading to CRDB going down

    def version(self) -> ScenarioVersion:
        return ScenarioVersion.create(1, 1, 0)

    def shared(self) -> Action:
        return TdAction(
            self.schema()
            + self.keyschema()
            + f"""
$ kafka-create-topic topic=kafka-parallel-ingestion partitions=4

$ kafka-ingest format=avro topic=kafka-parallel-ingestion key-format=avro key-schema=${{keyschema}} schema=${{schema}} repeat={self.n()}
{{"f1": ${{kafka-ingest.iteration}} }} {{"f2": ${{kafka-ingest.iteration}} }}
"""
        )

    def benchmark(self) -> MeasurementSource:
        sources = range(1, ParallelIngestion.SOURCES + 1)
        drop_sources = "\n".join(
            [
                f"""
> DROP SOURCE IF EXISTS s{s} CASCADE
> DROP CLUSTER IF EXISTS s{s}_cluster
"""
                for s in sources
            ]
        )

        create_sources = "\n".join(
            [
                f"""
> CREATE CONNECTION IF NOT EXISTS csr_conn
  FOR CONFLUENT SCHEMA REGISTRY
  URL '${{testdrive.schema-registry-url}}';

> CREATE CONNECTION IF NOT EXISTS kafka_conn TO KAFKA (BROKER '${{testdrive.kafka-addr}}', SECURITY PROTOCOL PLAINTEXT);

> CREATE CLUSTER s{s}_cluster SIZE '{self._default_size}', REPLICATION FACTOR 2;

> CREATE SOURCE s{s}
  IN CLUSTER s{s}_cluster
  FROM KAFKA CONNECTION kafka_conn (TOPIC 'testdrive-kafka-parallel-ingestion-${{testdrive.seed}}')

> CREATE TABLE s{s}_tbl FROM SOURCE s{s} (REFERENCE "testdrive-kafka-parallel-ingestion-${{testdrive.seed}}")
  FORMAT AVRO USING CONFLUENT SCHEMA REGISTRY CONNECTION csr_conn
"""
                for s in sources
            ]
        )

        create_indexes = "\n".join(
            [
                f"""
> CREATE DEFAULT INDEX ON s{s}_tbl
"""
                for s in sources
            ]
        )

        selects = "\n".join(
            [
                f"""
> SELECT * FROM s{s}_tbl WHERE f2 = {self.n()-1}
{self.n()-1}
"""
                for s in sources
            ]
        )

        return Td(
            self.schema()
            + f"""
{drop_sources}

{create_sources}

> SELECT 1
  /* A */
1

{create_indexes}

{selects}

> SELECT 1
  /* B */
1
"""
        )


class ParallelDataflows(Concurrency):
    """Measure the time it takes to compute multiple parallel dataflows."""

    SCALE = 6
    VIEWS = 25

    def benchmark(self) -> MeasurementSource:
        views = range(1, ParallelDataflows.VIEWS + 1)

        create_views = "\n".join(
            [
                f"""
> CREATE MATERIALIZED VIEW v{v} AS
  SELECT COUNT(DISTINCT generate_series) + {v} - {v} AS f1
  FROM generate_series(1,{self.n()})
"""
                for v in views
            ]
        )

        selects = "\n".join(
            [
                f"""
> SELECT * FROM v{v}
{self.n()}
"""
                for v in views
            ]
        )

        return Td(
            f"""
$ postgres-execute connection=postgres://mz_system@materialized:6877/materialize
DROP SCHEMA public CASCADE;

> CREATE SCHEMA public;

> SELECT 1
  /* A */
1

{create_views}

{selects}

> SELECT 1
  /* B */
1
"""
        )
