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

"""Render a monotonically increasing Homebrew version for a Current build."""

from __future__ import annotations

import argparse
import re
from collections.abc import Sequence

RUN_NUMBER_PATTERN = re.compile(r"[0-9]+")
COMMIT_PATTERN = re.compile(r"[0-9a-f]{40}")


def current_formula_version(run_number: str, commit: str) -> str:
    """Return a Current version ordered by workflow run before source identity."""
    if RUN_NUMBER_PATTERN.fullmatch(run_number) is None or int(run_number) < 1:
        raise ValueError("run number must be a positive decimal integer")
    if COMMIT_PATTERN.fullmatch(commit) is None:
        raise ValueError("commit must be a lowercase 40-character hexadecimal SHA")

    return f"current.{int(run_number)}.{commit[:12]}"


def parse_arguments(arguments: Sequence[str] | None = None) -> argparse.Namespace:
    """Parse command-line arguments."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--run-number", required=True)
    parser.add_argument("--commit", required=True)
    return parser.parse_args(arguments)


def main(arguments: Sequence[str] | None = None) -> int:
    """Render the validated version to standard output."""
    options = parse_arguments(arguments)
    try:
        version = current_formula_version(options.run_number, options.commit)
    except ValueError as error:
        raise SystemExit(str(error)) from error
    print(version)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
