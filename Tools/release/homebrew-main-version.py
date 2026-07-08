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

"""Print the Homebrew formula version for the main package lane."""

from __future__ import annotations

import argparse
import re


SEMVER_PATTERN = re.compile(r"^[0-9]+[.][0-9]+[.][0-9]+$")
SHA_PATTERN = re.compile(r"^[0-9a-fA-F]{12,}$")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--plugin-version", required=True)
    parser.add_argument("--run-number", required=True)
    parser.add_argument("--sha", required=True)
    return parser.parse_args()


def homebrew_main_version(plugin_version: str, run_number: str, sha: str) -> str:
    if not SEMVER_PATTERN.fullmatch(plugin_version):
        raise ValueError(f"plugin version must be MAJOR.MINOR.PATCH: {plugin_version}")
    if not run_number.isdecimal() or int(run_number) <= 0:
        raise ValueError(f"workflow run number must be a positive integer: {run_number}")
    if not SHA_PATTERN.fullmatch(sha):
        raise ValueError(f"git SHA must be at least 12 hex characters: {sha}")

    return f"{plugin_version}-main.{run_number}.{sha[:12].lower()}"


def main() -> None:
    args = parse_args()
    try:
        print(homebrew_main_version(args.plugin_version, args.run_number, args.sha))
    except ValueError as error:
        raise SystemExit(str(error)) from error


if __name__ == "__main__":
    main()
