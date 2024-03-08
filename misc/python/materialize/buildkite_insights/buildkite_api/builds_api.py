#!/usr/bin/env python3

# Copyright Materialize, Inc. and contributors. All rights reserved.
#
# Use of this software is governed by the Business Source License
# included in the LICENSE file at the root of this repository.
#
# As of the Change Date specified in that file, in accordance with
# the Business Source License, use of this software will be governed
# by the Apache License, Version 2.0.

from typing import Any

from materialize.buildkite_insights.buildkite_api.generic_api import get


def get_builds(
    pipeline_slug: str,
    max_fetches: int | None,
    branch: str | None,
    build_state: str | None,
    items_per_page: int = 100,
    include_retries: bool = True,
) -> list[Any]:
    request_path = f"organizations/materialize/pipelines/{pipeline_slug}/builds"
    params = {
        "include_retried_jobs": str(include_retries).lower(),
        "per_page": str(items_per_page),
    }

    if branch is not None:
        params["branch"] = branch

    if build_state is not None:
        params["state"] = build_state

    return get(request_path, params, max_fetches=max_fetches)


def get_builds_of_all_pipelines(
    max_fetches: int | None,
    items_per_page: int = 100,
    include_retries: bool = True,
) -> list[Any]:
    params = {
        "include_retried_jobs": str(include_retries).lower(),
        "per_page": str(items_per_page),
    }

    return get(
        "organizations/materialize/builds",
        params,
        max_fetches=max_fetches,
    )
