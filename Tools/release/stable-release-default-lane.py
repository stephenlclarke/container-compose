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

"""Classify whether a stable release may advance mutable consumer pointers."""

from __future__ import annotations

import argparse
import re


SEMVER = re.compile(r"[0-9]+[.][0-9]+[.][0-9]+")


def version_key(value: str) -> tuple[int, int, int]:
    """Parse the project's deliberately narrow stable-version format."""
    if not SEMVER.fullmatch(value):
        raise ValueError(f"invalid stable release version: {value}")
    major, minor, patch = value.split(".")
    return int(major), int(minor), int(patch)


def promotes_default_lane(candidate: str, latest: str) -> bool:
    """Return whether candidate can become GitHub latest and update the tap."""
    candidate_key = version_key(candidate)
    return not latest or candidate_key >= version_key(latest)


def main() -> int:
    """Print a shell-compatible Boolean classification."""
    parser = argparse.ArgumentParser()
    parser.add_argument("candidate")
    parser.add_argument("latest", nargs="?", default="")
    arguments = parser.parse_args()
    try:
        promotes = promotes_default_lane(arguments.candidate, arguments.latest)
    except ValueError as error:
        parser.error(str(error))
    print("true" if promotes else "false")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
