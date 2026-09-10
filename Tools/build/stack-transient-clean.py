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

"""Plan or remove only marker-owned transient Container-family build data."""

from __future__ import annotations

import argparse
import os
import stat
import sys
from pathlib import Path


MARKER = ".container-family-transient-root"
MARKER_VALUE = "container-compose transient build v2\n"
REMOVABLE = ("attempts", "builds", "downloads", "scratch", "tmp")


class CleanupError(RuntimeError):
    """Transient cleanup could not prove a target is safe."""


def validate_root(root: Path) -> Path:
    if not root.is_absolute() or root == Path("/") or root.is_symlink():
        raise CleanupError(f"unsafe transient root: {root}")
    resolved = root.resolve(strict=True)
    marker = resolved / MARKER
    if marker.is_symlink() or not marker.is_file():
        raise CleanupError(f"transient root has no regular ownership marker: {resolved}")
    if marker.read_text(encoding="utf-8") != MARKER_VALUE:
        raise CleanupError(f"transient root has an unexpected ownership marker: {resolved}")
    return resolved


def remove_tree(path: Path) -> None:
    status = path.lstat()
    if stat.S_ISLNK(status.st_mode) or not stat.S_ISDIR(status.st_mode):
        path.unlink()
        return
    with os.scandir(path) as entries:
        for entry in entries:
            child = path / entry.name
            if entry.is_dir(follow_symlinks=False):
                remove_tree(child)
            else:
                child.unlink()
    path.rmdir()


def targets(root: Path) -> list[Path]:
    resolved = validate_root(root)
    return [resolved / name for name in REMOVABLE if (resolved / name).exists()]


def main(arguments: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, required=True)
    parser.add_argument("--execute", action="store_true")
    options = parser.parse_args(arguments)
    try:
        selected = targets(options.root)
        for target in selected:
            print(target)
            if options.execute:
                remove_tree(target)
    except (CleanupError, OSError, UnicodeError) as error:
        print(f"stack-transient-clean: {error}", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
