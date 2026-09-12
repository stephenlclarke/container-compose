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

"""Atomically promote completed build products into retained local storage."""

from __future__ import annotations

import argparse
import hashlib
import os
import shutil
import stat
import sys
import tempfile
from pathlib import Path
from typing import BinaryIO


class ArtifactError(RuntimeError):
    """A candidate artifact or retained-store operation is unsafe."""


def parse_arguments(arguments: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path, required=True)
    parser.add_argument("--root", type=Path, required=True)
    parser.add_argument("--name", required=True)
    return parser.parse_args(arguments)


def copy_and_digest(source: BinaryIO, destination: BinaryIO) -> str:
    digest = hashlib.sha256()
    for chunk in iter(lambda: source.read(1024 * 1024), b""):
        digest.update(chunk)
        destination.write(chunk)
    return digest.hexdigest()


def digest_file(path: Path) -> str:
    flags = os.O_RDONLY
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    descriptor = os.open(path, flags)
    digest = hashlib.sha256()
    try:
        if not stat.S_ISREG(os.fstat(descriptor).st_mode):
            raise ArtifactError(f"artifact is not a regular file: {path}")
        with os.fdopen(descriptor, "rb") as stream:
            descriptor = -1
            for chunk in iter(lambda: stream.read(1024 * 1024), b""):
                digest.update(chunk)
    finally:
        if descriptor >= 0:
            os.close(descriptor)
    return digest.hexdigest()


def validate_name(name: str) -> None:
    if (
        not name
        or name in {".", ".."}
        or "/" in name
        or "\0" in name
        or Path(name).name != name
    ):
        raise ArtifactError(f"artifact name must be one safe path component: {name!r}")


def reject_symlink_components(path: Path) -> None:
    """Reject every existing symbolic-link component in an absolute path."""
    current = Path(path.anchor)
    for component in path.parts[1:]:
        current /= component
        try:
            status = current.lstat()
        except FileNotFoundError:
            continue
        if stat.S_ISLNK(status.st_mode):
            raise ArtifactError(f"artifact path contains a symbolic link: {current}")


def resolve_root(root: Path) -> Path:
    if not root.is_absolute():
        raise ArtifactError(f"retained artifact root must be absolute: {root}")
    normalized = Path(os.path.abspath(root))
    reject_symlink_components(normalized)
    root.mkdir(parents=True, exist_ok=True, mode=0o700)
    reject_symlink_components(normalized)
    resolved = root.resolve(strict=True)
    if resolved == Path("/") or resolved != normalized:
        raise ArtifactError("retained artifact root must not be /")
    return resolved


def promote(source: Path, root: Path, name: str) -> Path:
    validate_name(name)
    if not source.is_absolute():
        raise ArtifactError(f"source artifact must be an absolute regular file: {source}")
    source_flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0)
    try:
        source_descriptor = os.open(source, source_flags)
    except OSError as error:
        raise ArtifactError(
            f"source artifact must be an absolute regular file: {source}"
        ) from error
    source_status = os.fstat(source_descriptor)
    if not stat.S_ISREG(source_status.st_mode):
        os.close(source_descriptor)
        raise ArtifactError(f"source artifact is not a regular file: {source}")

    resolved_root = resolve_root(root)
    incoming = resolved_root / "incoming"
    objects = resolved_root / "objects" / "sha256"
    reject_symlink_components(incoming)
    reject_symlink_components(objects)
    incoming.mkdir(mode=0o700, exist_ok=True)
    objects.mkdir(mode=0o700, parents=True, exist_ok=True)
    reject_symlink_components(incoming)
    reject_symlink_components(objects)
    descriptor, temporary_name = tempfile.mkstemp(prefix=".promote-", dir=incoming)
    temporary = Path(temporary_name)
    try:
        with (
            os.fdopen(source_descriptor, "rb") as source_stream,
            os.fdopen(descriptor, "wb") as destination_stream,
        ):
            source_descriptor = -1
            descriptor = -1
            digest = copy_and_digest(source_stream, destination_stream)
            destination_stream.flush()
            os.fsync(destination_stream.fileno())
        retained_mode = stat.S_IMODE(source_status.st_mode) & ~0o222
        temporary.chmod(retained_mode)
        destination_directory = objects / digest[:2] / digest
        destination_directory.mkdir(mode=0o700, parents=True, exist_ok=True)
        reject_symlink_components(destination_directory)
        destination = destination_directory / name
        if destination.exists():
            if destination.is_symlink() or digest_file(destination) != digest:
                raise ArtifactError(f"retained artifact conflicts with {destination}")
            if stat.S_IMODE(destination.lstat().st_mode) != retained_mode:
                raise ArtifactError(f"retained artifact mode conflicts with {destination}")
        else:
            try:
                # A hard-link install is an atomic no-clobber operation. Two
                # publishers may race, but neither can replace retained bytes.
                os.link(temporary, destination, follow_symlinks=False)
            except FileExistsError:
                if destination.is_symlink() or digest_file(destination) != digest:
                    raise ArtifactError(
                        f"retained artifact conflicts with {destination}"
                    )
                if (
                    stat.S_IMODE(destination.lstat().st_mode)
                    != retained_mode
                ):
                    raise ArtifactError(
                        f"retained artifact mode conflicts with {destination}"
                    )
            else:
                directory = os.open(destination_directory, os.O_RDONLY)
                try:
                    os.fsync(directory)
                finally:
                    os.close(directory)
        return destination
    finally:
        if source_descriptor >= 0:
            os.close(source_descriptor)
        if descriptor >= 0:
            os.close(descriptor)
        temporary.unlink(missing_ok=True)


def main(arguments: list[str] | None = None) -> int:
    options = parse_arguments(arguments if arguments is not None else sys.argv[1:])
    try:
        destination = promote(options.source, options.root, options.name)
    except (ArtifactError, OSError, shutil.Error) as error:
        print(f"stack-artifact: {error}", file=sys.stderr)
        return 2
    print(destination)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
