#!/usr/bin/env python3
##===----------------------------------------------------------------------===##
## Copyright © 2026 container-compose project authors.
##
## Licensed under the Apache License, Version 2.0 (the "License");
## you may not use this file except in compliance with the License.
## You may obtain a copy of the License at
##
##   https://www.apache.org/licenses/LICENSE-2.0
##
## Unless required by applicable law or agreed to in writing, software
## distributed under the License is distributed on an "AS IS" BASIS,
## WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
## See the License for the specific language governing permissions and
## limitations under the License.
##===----------------------------------------------------------------------===##

"""Verify the complete immutable Current authority used by stable promotion."""

from __future__ import annotations

import argparse
from datetime import datetime
import json
import re
import sys
from typing import Any


SHA256 = re.compile(r"sha256:([0-9a-f]{64})")
GITHUB_TIMESTAMP = re.compile(r"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?Z")
FORMULA_URL = re.compile(r'^  url\s+"([^"]+)"\s*$', re.MULTILINE)
FORMULA_SHA256 = re.compile(r'^  sha256\s+"([0-9a-f]{64})"\s*$', re.MULTILINE)
FORMULA_VERSION = re.compile(r'^  version\s+"([^"]+)"\s*$', re.MULTILINE)


class ReadinessError(ValueError):
    """The Current release is not a complete promotion authority."""


def expected_assets(sha: str) -> tuple[str, ...]:
    short = sha[:12]
    return tuple(
        sorted(
            (
                f"container-compose-plugin-current-{short}-arm64.tar.gz",
                f"container-compose-plugin-current-{short}-arm64.tar.gz.sha256",
                f"container-current-{short}-arm64.tar.gz",
                f"container-current-{short}-arm64.tar.gz.sha256",
                f"container-vminit-current-{short}-arm64.oci.tar",
                f"container-vminit-current-{short}-arm64.oci.tar.sha256",
                f"release-highlights-current-{short}.json",
                "quality-snapshot-current.svg",
            )
        )
    )


def require_mapping(value: Any, label: str) -> dict[str, Any]:
    if not isinstance(value, dict):
        raise ReadinessError(f"{label} is not an object")
    return value


def parse_github_timestamp(value: Any, label: str) -> tuple[str, datetime]:
    if not isinstance(value, str) or GITHUB_TIMESTAMP.fullmatch(value) is None:
        raise ReadinessError(f"{label} is not a GitHub UTC timestamp")
    try:
        parsed = datetime.fromisoformat(value.removesuffix("Z") + "+00:00")
    except ValueError as error:
        raise ReadinessError(f"{label} is not a valid timestamp") from error
    return value, parsed


def formula_declaration(formula: Any, pattern: re.Pattern[str], label: str) -> str:
    if not isinstance(formula, str):
        raise ReadinessError(f"formula for {label} is unavailable")
    values = pattern.findall(formula)
    if len(values) != 1:
        raise ReadinessError(f"Homebrew formula does not have one active {label} declaration")
    return values[0]


def verify_formula(formula: Any, *, repository: str, tag: str, asset: str, digest: str) -> None:
    expected_url = f"https://github.com/{repository}/releases/download/{tag}/{asset}"
    active_url = formula_declaration(formula, FORMULA_URL, "URL")
    active_digest = formula_declaration(formula, FORMULA_SHA256, "SHA-256")
    if active_url != expected_url or active_digest != digest:
        raise ReadinessError(f"Homebrew formula does not authenticate {asset}")


def formula_run_number(formula: Any, *, sha: str, label: str) -> int:
    version = formula_declaration(formula, FORMULA_VERSION, f"{label} version")
    match = re.fullmatch(rf"current\.([1-9][0-9]*)\.{re.escape(sha[:12])}", version)
    if match is None:
        raise ReadinessError(f"{label} formula version does not identify the Current package run")
    return int(match.group(1))


def verify(payload: dict[str, Any], *, repository: str, tag: str, sha: str) -> str:
    if re.fullmatch(r"[0-9a-f]{40}", sha) is None or tag != f"current-{sha}":
        raise ReadinessError("Current tag is not the exact source identity")
    release = require_mapping(payload.get("release"), "release")
    fields = {
        "draft": False,
        "immutable": True,
        "prerelease": True,
        "tag_name": tag,
        "target_commitish": sha,
    }
    for field, expected in fields.items():
        if release.get(field) != expected:
            raise ReadinessError(f"Current release {field} is not {expected!r}")

    raw_assets = release.get("assets")
    if not isinstance(raw_assets, list):
        raise ReadinessError("Current release assets are unavailable")
    assets: dict[str, dict[str, Any]] = {}
    for raw in raw_assets:
        asset = require_mapping(raw, "release asset")
        name = asset.get("name")
        if not isinstance(name, str) or name in assets:
            raise ReadinessError("Current release has an invalid or duplicate asset")
        assets[name] = asset
    expected = expected_assets(sha)
    if tuple(sorted(assets)) != expected:
        raise ReadinessError("Current release does not have the exact asset closure")
    digests: dict[str, str] = {}
    for name, asset in assets.items():
        match = SHA256.fullmatch(str(asset.get("digest", "")))
        if match is None:
            raise ReadinessError(f"Current release asset has no SHA-256 digest: {name}")
        digests[name] = match.group(1)

    short = sha[:12]
    compose_asset = f"container-compose-plugin-current-{short}-arm64.tar.gz"
    runtime_asset = f"container-current-{short}-arm64.tar.gz"
    compose_formula = payload.get("compose_formula")
    container_formula = payload.get("container_formula")
    verify_formula(
        compose_formula,
        repository=repository,
        tag=tag,
        asset=compose_asset,
        digest=digests[compose_asset],
    )
    verify_formula(
        container_formula,
        repository=repository,
        tag=tag,
        asset=runtime_asset,
        digest=digests[runtime_asset],
    )
    compose_run_number = formula_run_number(
        compose_formula, sha=sha, label="container-compose-current"
    )
    container_run_number = formula_run_number(
        container_formula, sha=sha, label="container-current"
    )
    if compose_run_number != container_run_number:
        raise ReadinessError("Current Homebrew formulae do not identify the same package run")

    _, publication_time = parse_github_timestamp(
        release.get("published_at"), "Current release publication timestamp"
    )
    runs = require_mapping(payload.get("runs"), "package runs").get("workflow_runs")
    if not isinstance(runs, list):
        raise ReadinessError("package runs are unavailable")
    successful_run_times: list[tuple[str, datetime]] = []
    for raw_run in runs:
        run = require_mapping(raw_run, "package run")
        if (
            run.get("run_number") == compose_run_number
            and run.get("head_sha") == sha
            and run.get("status") == "completed"
            and run.get("conclusion") == "success"
        ):
            successful_run_times.append(
                parse_github_timestamp(
                    run.get("updated_at"), "successful package run completion timestamp"
                )
            )
    if not successful_run_times:
        raise ReadinessError("no successful exact-head Prebuilt Binaries authority exists")
    soak_started_at, soak_start_time = max(successful_run_times, key=lambda item: item[1])
    if soak_start_time < publication_time:
        raise ReadinessError("successful package run completed before Current was published")
    return soak_started_at


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repository", required=True)
    parser.add_argument("--tag", required=True)
    parser.add_argument("--sha", required=True)
    options = parser.parse_args()
    try:
        payload = require_mapping(json.load(sys.stdin), "input")
        print(
            verify(
                payload,
                repository=options.repository,
                tag=options.tag,
                sha=options.sha,
            )
        )
    except (ReadinessError, json.JSONDecodeError) as error:
        print(f"current-release-readiness: {error}", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
