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

"""Verify and install one pipeline dependency archive into staged source."""

from __future__ import annotations

import argparse
import hashlib
import os
from pathlib import Path, PurePosixPath
import sys
import tarfile


class DependencyError(RuntimeError):
    """Dependency evidence is malformed, corrupt or unsafe."""


def sha256(path: Path) -> str:
    """Return one regular file's SHA-256 digest."""
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def read_manifest(path: Path) -> dict[str, tuple[str, int]]:
    """Read the exact artifact closure declared by one manifest."""
    if path.is_symlink() or not path.is_file() or path.stat().st_size > 1024 * 1024:
        raise DependencyError(f"dependency manifest is invalid: {path}")
    rows = [
        line.split("\t") for line in path.read_text(encoding="utf-8").splitlines()
    ]
    count_rows = [
        row[1] for row in rows if len(row) == 2 and row[0] == "artifact-count"
    ]
    if len(count_rows) != 1 or not count_rows[0].isdigit():
        raise DependencyError("dependency manifest artifact count is invalid")

    artifacts: dict[str, tuple[str, int]] = {}
    for row in rows:
        if not row or row[0] != "artifact":
            continue
        if len(row) != 4:
            raise DependencyError("dependency manifest artifact row is malformed")
        name, digest, size = row[1:]
        relative = PurePosixPath(name)
        if (
            relative.is_absolute()
            or ".." in relative.parts
            or not relative.parts
            or name in artifacts
            or len(digest) != 64
            or any(character not in "0123456789abcdef" for character in digest)
            or not size.isdigit()
        ):
            raise DependencyError(f"dependency manifest artifact is invalid: {name}")
        artifacts[name] = (digest, int(size))
    if len(artifacts) != int(count_rows[0]) or not artifacts:
        raise DependencyError("dependency manifest artifact count does not match")
    return artifacts


def require_direct_parents(destination: Path, relative: PurePosixPath) -> None:
    """Reject an existing parent that could redirect archive extraction."""
    parent = destination
    for component in relative.parts[:-1]:
        parent /= component
        if parent.is_symlink() or (
            os.path.lexists(parent) and not parent.is_dir()
        ):
            raise DependencyError(
                f"dependency archive member has an indirect or invalid parent: {relative}"
            )


def install(*, archive_path: Path, manifest_path: Path, destination: Path) -> None:
    """Verify, collision-check, extract and reverify one dependency closure."""
    if (
        archive_path.is_symlink()
        or not archive_path.is_file()
        or destination.is_symlink()
        or not destination.is_dir()
    ):
        raise DependencyError("dependency archive or destination is invalid")
    artifacts = read_manifest(manifest_path)
    with tarfile.open(archive_path, "r:") as archive:
        members = archive.getmembers()
        if tuple(member.name for member in members) != tuple(artifacts):
            raise DependencyError("dependency archive does not match its manifest")
        for member in members:
            relative = PurePosixPath(member.name)
            target = destination / relative
            require_direct_parents(destination, relative)
            if (
                relative.is_absolute()
                or ".." in relative.parts
                or not member.isfile()
                or os.path.lexists(target)
            ):
                raise DependencyError(
                    f"dependency archive member is unsafe or collides: {member.name}"
                )
        try:
            archive.extractall(destination, filter="fully_trusted")
        except TypeError:
            archive.extractall(destination)

    for name, (expected_digest, expected_size) in artifacts.items():
        extracted = destination / name
        if extracted.is_symlink() or not extracted.is_file():
            raise DependencyError(f"dependency extraction is invalid: {name}")
        if sha256(extracted) != expected_digest or extracted.stat().st_size != expected_size:
            raise DependencyError(f"dependency artifact changed during extraction: {name}")


def main() -> int:
    """Parse paths and install one dependency archive."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--archive", type=Path, required=True)
    parser.add_argument("--manifest", type=Path, required=True)
    parser.add_argument("--destination", type=Path, required=True)
    args = parser.parse_args()
    install(
        archive_path=args.archive,
        manifest_path=args.manifest,
        destination=args.destination,
    )
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (DependencyError, OSError, tarfile.TarError) as error:
        print(error, file=sys.stderr)
        raise SystemExit(2) from error
