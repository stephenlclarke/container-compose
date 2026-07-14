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

"""Render a container Homebrew formula for a matched Compose release."""

from __future__ import annotations

import argparse
import re
from pathlib import Path


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--formula", required=True, type=Path)
    parser.add_argument("--template", required=True, type=Path)
    parser.add_argument("--formula-class", required=True)
    parser.add_argument(
        "--compose-formula",
        required=True,
        help="Fully qualified tap formula name without the stephenlclarke/tap prefix.",
    )
    parser.add_argument("--url", required=True)
    parser.add_argument("--sha256", required=True)
    parser.add_argument("--version", required=True)
    parser.add_argument("--label", required=True)
    parser.add_argument("--asset", required=True)
    return parser.parse_args()


def replace_once(pattern: str, replacement: str, text: str) -> str:
    updated, count = re.subn(pattern, replacement, text, count=1, flags=re.MULTILINE)
    if count != 1:
        raise SystemExit(f"expected exactly one match for pattern: {pattern}")
    return updated


def main() -> None:
    args = parse_args()
    if re.fullmatch(r"container-compose(?:-current)?", args.compose_formula) is None:
        raise SystemExit(
            "compose formula must be one of: container-compose, container-compose-current"
        )

    text = args.template.read_text(encoding="utf-8")
    text = replace_once(r"^class \w+ < Formula$", f"class {args.formula_class} < Formula", text)
    text = replace_once(r'^  url ".+"$', f'  url "{args.url}"', text)
    text = replace_once(r"^  sha256 .+$", f'  sha256 "{args.sha256}"', text)
    text = replace_once(r'^  version ".+"$', f'  version "{args.version}"', text)
    text = re.sub(
        r"stephenlclarke/tap/container-compose(?:-current)?",
        f"stephenlclarke/tap/{args.compose_formula}",
        text,
    )
    text = re.sub(
        r"opt/container-compose(?:-current)?/",
        f"opt/{args.compose_formula}/",
        text,
    )
    text = replace_once(
        r"This formula installs the .+ prebuilt (?:release|package) asset:\n        .+\.tar\.gz",
        f"This formula installs the {args.label} prebuilt package asset:\n        {args.asset}",
        text,
    )
    args.formula.parent.mkdir(parents=True, exist_ok=True)
    args.formula.write_text(text, encoding="utf-8")


if __name__ == "__main__":
    main()
