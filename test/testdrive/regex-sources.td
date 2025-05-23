# Copyright Materialize, Inc. and contributors. All rights reserved.
#
# Use of this software is governed by the Business Source License
# included in the LICENSE file at the root of this repository.
#
# As of the Change Date specified in that file, in accordance with
# the Business Source License, use of this software will be governed
# by the Apache License, Version 2.0.

$ set-arg-default default-storage-size=1

$ kafka-create-topic topic=request-log
$ kafka-ingest topic=request-log format=bytes
123.17.127.5 - - [22/Jan/2020 18:59:52] "GET / HTTP/1.1" 200 -
8.15.119.56 - - [22/Jan/2020 18:59:52] "GET /detail/nNZpqxzR HTTP/1.1" 200 -
96.12.83.72 - - [22/Jan/2020 18:59:52] "GET /search/?kw=helper+ins+hennaed HTTP/1.1" 200 -

# Regex explained here: https://www.debuggex.com/r/k48kBEt-lTMUZbaw
> CREATE CONNECTION kafka_conn
  TO KAFKA (BROKER '${testdrive.kafka-addr}', SECURITY PROTOCOL PLAINTEXT);

> CREATE CLUSTER regex_source_cluster SIZE '${arg.default-storage-size}';
> CREATE SOURCE regex_source
  IN CLUSTER regex_source_cluster
  FROM KAFKA CONNECTION kafka_conn (TOPIC 'testdrive-request-log-${testdrive.seed}')
> CREATE TABLE regex_source_tbl
  FROM SOURCE regex_source (REFERENCE "testdrive-request-log-${testdrive.seed}")
  FORMAT REGEX '(?P<ip>\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}) - - \[(?P<ts>[^]]+)\] "(?P<path>(?:GET /search/\?kw=(?P<search_kw>[^ ]*) HTTP/\d\.\d)|(?:GET /detail/(?P<product_detail_id>[a-zA-Z0-9]+) HTTP/\d\.\d)|(?:[^"]+))" (?P<code>\d{3}) -'

> SHOW COLUMNS FROM regex_source_tbl
name               nullable  type  comment
------------------------------------------
ip                 true      text  ""
ts                 true      text  ""
path               true      text  ""
search_kw          true      text  ""
product_detail_id  true      text  ""
code               true      text  ""

> SELECT * FROM regex_source_tbl
ip            ts                      path                                           search_kw           product_detail_id  code
---------------------------------------------------------------------------------------------------------------------------------
123.17.127.5  "22/Jan/2020 18:59:52"  "GET / HTTP/1.1"                               <null>              <null>             200
8.15.119.56   "22/Jan/2020 18:59:52"  "GET /detail/nNZpqxzR HTTP/1.1"                <null>              nNZpqxzR           200
96.12.83.72   "22/Jan/2020 18:59:52"  "GET /search/?kw=helper+ins+hennaed HTTP/1.1"  helper+ins+hennaed  <null>             200

> SELECT search_kw FROM regex_source_tbl WHERE search_kw IS NOT NULL
search_kw
------------------
helper+ins+hennaed

> CREATE CLUSTER regex_source_named_cols_cluster SIZE '${arg.default-storage-size}';
> CREATE SOURCE regex_source_named_cols
  IN CLUSTER regex_source_named_cols_cluster
  FROM KAFKA CONNECTION kafka_conn (TOPIC 'testdrive-request-log-${testdrive.seed}')
> CREATE TABLE regex_source_named_cols_tbl (ip, ts, path, search_kw, product_detail_id, code)
  FROM SOURCE regex_source_named_cols (REFERENCE "testdrive-request-log-${testdrive.seed}")
  FORMAT REGEX '(?P<foo1>\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}) - - \[(?P<foo2>[^]]+)\] "(?P<foo3>(?:GET /search/\?kw=(?P<foo4>[^ ]*) HTTP/\d\.\d)|(?:GET /detail/(?P<foo5>[a-zA-Z0-9]+) HTTP/\d\.\d)|(?:[^"]+))" (?P<foo6>\d{3}) -'

> SHOW COLUMNS FROM regex_source_named_cols_tbl
name               nullable  type  comment
------------------------------------------
ip                 true      text  ""
ts                 true      text  ""
path               true      text  ""
search_kw          true      text  ""
product_detail_id  true      text  ""
code               true      text  ""

# verify metadata column renaming
> CREATE CLUSTER regex_source_renamed_cols_cluster SIZE '${arg.default-storage-size}';
> CREATE SOURCE regex_source_renamed_cols
  IN CLUSTER regex_source_renamed_cols_cluster
  FROM KAFKA CONNECTION kafka_conn (TOPIC 'testdrive-request-log-${testdrive.seed}')
> CREATE TABLE regex_source_renamed_cols_tbl (ip, ts, path, search_kw, product_detail_id, code)
  FROM SOURCE regex_source_renamed_cols (REFERENCE "testdrive-request-log-${testdrive.seed}")
  FORMAT REGEX '(?P<foo1>\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}) - - \[(?P<foo2>[^]]+)\] "(?P<foo3>(?:GET /search/\?kw=(?P<foo4>[^ ]*) HTTP/\d\.\d)|(?:GET /detail/(?P<foo5>[a-zA-Z0-9]+) HTTP/\d\.\d)|(?:[^"]+))" (?P<foo6>\d{3}) -'

> SHOW COLUMNS FROM regex_source_renamed_cols_tbl
name               nullable  type  comment
------------------------------------------
ip                 true      text  ""
ts                 true      text  ""
path               true      text  ""
search_kw          true      text  ""
product_detail_id  true      text  ""
code               true      text  ""

> SELECT * FROM regex_source_named_cols_tbl
ip            ts                      path                                           search_kw           product_detail_id  code
---------------------------------------------------------------------------------------------------------------------------------
123.17.127.5  "22/Jan/2020 18:59:52"  "GET / HTTP/1.1"                               <null>              <null>             200
8.15.119.56   "22/Jan/2020 18:59:52"  "GET /detail/nNZpqxzR HTTP/1.1"                <null>              nNZpqxzR           200
96.12.83.72   "22/Jan/2020 18:59:52"  "GET /search/?kw=helper+ins+hennaed HTTP/1.1"  helper+ins+hennaed  <null>             200

# Malformed regex with non-utf-8 characters
$ kafka-create-topic topic=malformed-request-log
$ kafka-ingest topic=malformed-request-log format=bytes
123.17.127.5 - - [22/Jan/2020 18:59:52] "GET / HTTP/1.1" 200 -
8.15.119.56 - - [22/Jan/2020 18:59:52] "GET /detail/nNZpqxzR HTTP/1.1" 200 -
this line has invalid UTF-8 and will be cause dataflow errors --> \x80 <--
96.12.83.72 - - [22/Jan/2020 18:59:52] "GET /search/?kw=helper+ins+hennaed HTTP/1.1" 200 -

> CREATE CLUSTER bad_regex_source_cluster SIZE '${arg.default-storage-size}';
> CREATE SOURCE bad_regex_source
  IN CLUSTER bad_regex_source_cluster
  FROM KAFKA CONNECTION kafka_conn (TOPIC 'testdrive-malformed-request-log-${testdrive.seed}')
> CREATE TABLE bad_regex_source_tbl
  FROM SOURCE bad_regex_source (REFERENCE "testdrive-malformed-request-log-${testdrive.seed}")
  FORMAT REGEX '(?P<ip>\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}) - - \[(?P<ts>[^]]+)\] "(?P<path>(?:GET /search/\?kw=(?P<search_kw>[^ ]*) HTTP/\d\.\d)|(?:GET /detail/(?P<product_detail_id>[a-zA-Z0-9]+) HTTP/\d\.\d)|(?:[^"]+))" (?P<code>\d{3}) -'

! SELECT * FROM bad_regex_source_tbl
contains:UTF-8
