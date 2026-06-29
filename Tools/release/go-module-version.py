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

"""Print a required module version from a go.mod file."""

from __future__ import annotations

import argparse
from pathlib import Path


def module_version(go_mod: Path, module: str) -> str:
    """Return the version for a single-line or block-style require entry."""
    for line in go_mod.read_text(encoding="utf-8").splitlines():
        fields = line.split()
        if len(fields) >= 3 and fields[0] == "require" and fields[1] == module:
            return fields[2]
        if len(fields) >= 2 and fields[0] == module:
            return fields[1]
    return "unspecified"


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("module")
    parser.add_argument("--go-mod", type=Path, default=Path("go.mod"))
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    print(module_version(args.go_mod, args.module))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
