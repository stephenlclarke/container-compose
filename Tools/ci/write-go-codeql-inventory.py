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

"""Record the tracked Go production files selected by the current Go build scope."""

import argparse
import json
import os
from pathlib import Path
import subprocess


def packages_from_json(payload: str) -> list[dict]:
    decoder = json.JSONDecoder()
    packages = []
    offset = 0
    while payload[offset:].strip():
        package, consumed = decoder.raw_decode(payload, offset + len(payload[offset:]) - len(payload[offset:].lstrip()))
        packages.append(package)
        offset = consumed
    return packages


def selected_sources(packages: list[dict], root: Path) -> set[str]:
    selected = set()
    for package in packages:
        directory = Path(package["Dir"]).resolve()
        if not directory.is_relative_to(root):
            raise ValueError(f"package outside checkout: {directory}")
        for filename in package.get("GoFiles", []) + package.get("CgoFiles", []):
            path = directory / filename
            relative = path.relative_to(root).as_posix()
            if not relative.startswith("Tools/compose-normalizer/") or not relative.endswith(".go"):
                raise ValueError(f"unexpected Go source: {relative}")
            selected.add(relative)
    return selected


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--scope", type=Path, required=True)
    arguments = parser.parse_args()
    root = Path(__file__).resolve().parents[2]
    tracked = set(subprocess.check_output(
        ["git", "ls-files", "Tools/compose-normalizer"], cwd=root, text=True
    ).splitlines())
    tracked = {path for path in tracked if path.endswith(".go") and not path.endswith("_test.go")}
    listing = subprocess.check_output(
        ["go", "list", "-json", "./..."], cwd=root / "Tools/compose-normalizer", text=True
    )
    packages = packages_from_json(listing)
    selected = selected_sources(packages, root)
    expected = sorted(tracked & selected)
    if not expected or selected - tracked:
        raise ValueError(f"empty Go scope or untracked selected source: {sorted(selected - tracked)}")
    arguments.output.parent.mkdir(parents=True, exist_ok=True)
    arguments.scope.parent.mkdir(parents=True, exist_ok=True)
    arguments.output.write_text("\n".join(expected) + "\n", encoding="utf-8")
    arguments.scope.write_text(json.dumps({
        "goos": os.environ.get("GOOS", ""),
        "goarch": os.environ.get("GOARCH", ""),
        "cgo_enabled": os.environ.get("CGO_ENABLED", ""),
        "package_count": len(packages),
        "tracked_production_count": len(tracked),
        "selected_tracked_count": len(expected),
        "not_selected_by_go_list": sorted(tracked - selected),
    }, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    print(f"Go build scope selected {len(expected)} of {len(tracked)} tracked production files")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
