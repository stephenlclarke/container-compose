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

"""Evaluate whether the weekly stable-release scheduler may start a promotion."""

from __future__ import annotations

import argparse
import json
from dataclasses import asdict, dataclass
from datetime import datetime, timedelta, timezone


CURRENT_SOAK = timedelta(days=7)


@dataclass(frozen=True)
class StableReleaseDecision:
    """A transparent, non-mutating decision for a scheduled stable release."""

    should_release: bool
    reason: str
    current_age_seconds: int


def parse_timestamp(value: str) -> datetime:
    """Parse a GitHub timestamp into an aware UTC datetime."""

    timestamp = datetime.fromisoformat(value.replace("Z", "+00:00"))
    if timestamp.tzinfo is None:
        raise ValueError("timestamp must include a timezone")
    return timestamp.astimezone(timezone.utc)


def decide(
    *,
    main_sha: str,
    current_sha: str,
    current_built_at: datetime,
    latest_stable_sha: str,
    now: datetime,
) -> StableReleaseDecision:
    """Require a soaked Current build and source newer than the stable tag."""

    if not main_sha or not current_sha:
        raise ValueError("main and current SHAs are required")
    if now.tzinfo is None:
        raise ValueError("now must include a timezone")

    age_seconds = int((now.astimezone(timezone.utc) - current_built_at).total_seconds())
    if current_sha != main_sha:
        return StableReleaseDecision(
            False,
            "Current build does not point at the main head.",
            age_seconds,
        )
    if age_seconds < 0:
        return StableReleaseDecision(
            False,
            "Current build publication time is in the future.",
            age_seconds,
        )
    if age_seconds < int(CURRENT_SOAK.total_seconds()):
        remaining = int(CURRENT_SOAK.total_seconds()) - age_seconds
        return StableReleaseDecision(
            False,
            f"Current build has not completed its seven-day soak ({remaining}s remaining).",
            age_seconds,
        )
    if latest_stable_sha and latest_stable_sha == main_sha:
        return StableReleaseDecision(
            False,
            "Main has no source changes since the latest stable release.",
            age_seconds,
        )
    return StableReleaseDecision(
        True,
        "Current build is soaked and contains source newer than the latest stable release.",
        age_seconds,
    )


def parse_arguments() -> argparse.Namespace:
    """Parse a scheduler preflight invocation."""

    parser = argparse.ArgumentParser(
        description="Decide whether a scheduled stable release may start."
    )
    parser.add_argument("--main-sha", required=True)
    parser.add_argument("--current-sha", required=True)
    parser.add_argument("--current-built-at", required=True)
    parser.add_argument(
        "--latest-stable-sha",
        default="",
        help="Commit SHA for the latest stable tag, if a stable tag exists.",
    )
    parser.add_argument(
        "--now",
        default=datetime.now(timezone.utc).isoformat(),
        help="UTC clock override for deterministic tests.",
    )
    return parser.parse_args()


def main() -> None:
    """Render the scheduler decision as machine-readable JSON."""

    arguments = parse_arguments()
    try:
        decision = decide(
            main_sha=arguments.main_sha,
            current_sha=arguments.current_sha,
            current_built_at=parse_timestamp(arguments.current_built_at),
            latest_stable_sha=arguments.latest_stable_sha,
            now=parse_timestamp(arguments.now),
        )
    except ValueError as error:
        raise SystemExit(f"invalid stable release preflight input: {error}") from error
    print(json.dumps(asdict(decision), sort_keys=True))


if __name__ == "__main__":
    main()
