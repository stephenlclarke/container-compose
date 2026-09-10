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

"""Initialize and validate retained/internal and transient/external roots."""

from __future__ import annotations

import argparse
import os
import stat
import sys
import tempfile
from pathlib import Path


class StorageError(RuntimeError):
    """A storage role or path cannot be proved safe."""


def normalized(path: Path) -> Path:
    if not path.is_absolute():
        raise StorageError(f"stack storage path must be absolute: {path}")
    value = Path(os.path.abspath(path))
    if value == Path("/"):
        raise StorageError("stack storage path must not be /")
    current = Path(value.anchor)
    for component in value.parts[1:]:
        current /= component
        try:
            status = current.lstat()
        except FileNotFoundError:
            continue
        if stat.S_ISLNK(status.st_mode):
            raise StorageError(f"stack storage path contains a symbolic link: {current}")
    return value


def inside(path: Path, root: Path) -> bool:
    return path == root or root in path.parents


def existing_device(path: Path) -> int:
    current = path
    while not current.exists():
        current = current.parent
    return current.stat().st_dev


def preflight_root(path: Path, marker_name: str, marker_value: str) -> None:
    normalized(path)
    if path.exists() and not path.is_dir():
        raise StorageError(f"stack storage root is not a directory: {path}")
    if path.exists():
        marker = path / marker_name
        entries = list(path.iterdir())
        if entries and not marker.is_file():
            raise StorageError(f"refusing to claim non-empty unmarked stack storage root: {path}")
        if marker.exists() and marker.read_text(encoding="utf-8") != marker_value + "\n":
            raise StorageError(f"stack storage root has an unexpected ownership marker: {path}")


def initialize_root(path: Path, marker_name: str, marker_value: str) -> Path:
    path.mkdir(parents=True, exist_ok=True, mode=0o700)
    if path.resolve(strict=True) != normalized(path):
        raise StorageError(f"stack storage root changed while initializing: {path}")
    marker = path / marker_name
    if not marker.exists():
        descriptor, name = tempfile.mkstemp(dir=path, prefix=f".{marker_name}.")
        temporary = Path(name)
        try:
            with os.fdopen(descriptor, "w", encoding="utf-8") as stream:
                stream.write(marker_value + "\n")
                stream.flush()
                os.fsync(stream.fileno())
            os.chmod(temporary, 0o600)
            os.replace(temporary, marker)
        finally:
            temporary.unlink(missing_ok=True)
    return path.resolve(strict=True)


def initialize(options: argparse.Namespace) -> None:
    retained = normalized(options.retained_root)
    transient = normalized(options.transient_root)
    required_volume = (
        Path(os.path.abspath(options.transient_volume))
        if options.transient_volume
        else None
    )
    if required_volume is not None:
        if not required_volume.is_dir() or not os.path.ismount(required_volume):
            raise StorageError(f"required transient volume is not mounted: {required_volume}")
        if not inside(transient, required_volume):
            raise StorageError(
                f"transient root is outside required volume {required_volume}: {transient}"
            )
        if inside(retained, required_volume):
            raise StorageError(f"retained root is on the transient volume: {retained}")
    if inside(retained, transient) or inside(transient, retained):
        raise StorageError("retained and transient roots overlap")
    if options.require_separate_filesystems and existing_device(retained) == existing_device(transient):
        raise StorageError("retained and transient roots must be on separate filesystems")

    managed: list[tuple[str, Path, Path]] = []
    for role, values, root in (
        ("retained", options.retained_path, retained),
        ("transient", options.transient_path, transient),
    ):
        for raw in values:
            path = normalized(raw)
            if not inside(path, root):
                raise StorageError(f"{role} state path escaped its root: {path}")
            managed.append((role, path, root))

    preflight_root(retained, options.retained_marker, options.retained_marker_value)
    preflight_root(transient, options.transient_marker, options.transient_marker_value)
    retained = initialize_root(
        retained, options.retained_marker, options.retained_marker_value
    )
    transient = initialize_root(
        transient, options.transient_marker, options.transient_marker_value
    )
    for role, path, _ in managed:
        path.mkdir(parents=True, exist_ok=True, mode=0o700)
        if path.resolve(strict=True) != path:
            raise StorageError(f"{role} state path contains a symbolic link: {path}")


def main(arguments: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--retained-root", type=Path, required=True)
    parser.add_argument("--transient-root", type=Path, required=True)
    parser.add_argument("--transient-volume", default="")
    parser.add_argument("--retained-marker", required=True)
    parser.add_argument("--retained-marker-value", required=True)
    parser.add_argument("--transient-marker", required=True)
    parser.add_argument("--transient-marker-value", required=True)
    parser.add_argument("--retained-path", type=Path, action="append", default=[])
    parser.add_argument("--transient-path", type=Path, action="append", default=[])
    parser.add_argument("--require-separate-filesystems", action="store_true")
    options = parser.parse_args(arguments)
    try:
        initialize(options)
    except (StorageError, OSError, UnicodeError) as error:
        print(f"stack-storage: {error}", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
