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

"""Verify and materialize a recovered Compose package artifact."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import shutil
import subprocess
import sys
import tarfile
import tempfile
import uuid


EXPECTED_ARTIFACTS = (
    "dist/compose/bin/compose",
    "dist/compose/config.toml",
    "dist/compose/resources/compose-normalizer",
    "dist/compose/resources/container-compose-icon.png",
    "dist/compose/resources/build-info.json",
    "container-compose-plugin-release-arm64.tar.gz",
    "container-compose-plugin-release-arm64.tar.gz.sha256",
)
OUTPUT_ROOTS = (
    "dist",
    "container-compose-plugin-release-arm64.tar.gz",
    "container-compose-plugin-release-arm64.tar.gz.sha256",
)
JOURNAL_NAME = ".pipeline-package-materialization.json"


class MaterializationError(RuntimeError):
    """Recovered package evidence is missing, corrupt or unsafe."""


def sha256(path: Path) -> str:
    """Return one regular file's SHA-256 digest."""
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def read_tsv(path: Path) -> list[list[str]]:
    """Read a bounded tab-separated receipt without accepting controls."""
    if path.is_symlink() or not path.is_file() or path.stat().st_size > 1024 * 1024:
        raise MaterializationError(f"package evidence is indirect or invalid: {path}")
    rows = []
    for line in path.read_text(encoding="utf-8").splitlines():
        fields = line.split("\t")
        if not fields or any("\n" in field or "\r" in field for field in fields):
            raise MaterializationError(f"package evidence contains controls: {path}")
        rows.append(fields)
    return rows


def one(rows: list[list[str]], key: str) -> str:
    """Return an exactly-once two-column receipt value."""
    matches = [row[1] for row in rows if len(row) == 2 and row[0] == key]
    if len(matches) != 1:
        raise MaterializationError(f"package evidence field is not unique: {key}")
    return matches[0]


def require_sha256(value: str, field: str) -> str:
    """Validate a lowercase SHA-256 value."""
    if len(value) != 64 or any(character not in "0123456789abcdef" for character in value):
        raise MaterializationError(f"package evidence has an invalid {field}")
    return value


def verify_evidence(
    receipt: Path, manifest: Path, archive: Path
) -> tuple[dict[str, str], str]:
    """Verify the complete package receipt, manifest and archive closure."""
    receipt_rows = read_tsv(receipt)
    manifest_rows = read_tsv(manifest)
    if one(receipt_rows, "schema") != "4":
        raise MaterializationError("package receipt has the wrong schema")
    if one(receipt_rows, "stage") != "compose-package":
        raise MaterializationError("package receipt has the wrong stage")
    if one(receipt_rows, "repository") != "container-compose":
        raise MaterializationError("package receipt has the wrong repository")
    if one(receipt_rows, "source-format") != "git-tree-archive":
        raise MaterializationError("package receipt has the wrong source format")
    source_commit = one(receipt_rows, "source-commit")
    if len(source_commit) != 40 or any(
        character not in "0123456789abcdef" for character in source_commit
    ):
        raise MaterializationError("package receipt has an invalid source commit")
    source_execution_head = one(receipt_rows, "source-execution-head")
    if len(source_execution_head) != 40 or any(
        character not in "0123456789abcdef"
        for character in source_execution_head
    ):
        raise MaterializationError("package receipt has an invalid execution head")
    if one(receipt_rows, "source-tracked-clean") != "true":
        raise MaterializationError("package receipt source was not clean")
    for key, label in (
        ("source-payload-sha256", "source payload digest"),
        ("source-metadata-sha256", "source metadata digest"),
        ("command-sha256", "command digest"),
        ("stage-tools-sha256", "stage tools digest"),
        ("stage-inputs-sha256", "stage input digest"),
    ):
        require_sha256(one(receipt_rows, key), label)
    if one(receipt_rows, "artifact-count") != str(len(EXPECTED_ARTIFACTS)):
        raise MaterializationError("package receipt has the wrong artifact count")
    if one(receipt_rows, "exit") != "0":
        raise MaterializationError("package receipt did not record success")
    archive_digest = require_sha256(
        one(receipt_rows, "artifact-archive-sha256"), "archive digest"
    )
    manifest_digest = require_sha256(
        one(receipt_rows, "artifact-manifest-sha256"), "manifest digest"
    )
    if archive.is_symlink() or not archive.is_file() or sha256(archive) != archive_digest:
        raise MaterializationError("package artifact archive digest does not match")
    if sha256(manifest) != manifest_digest:
        raise MaterializationError("package artifact manifest digest does not match")
    if one(manifest_rows, "schema") != "1":
        raise MaterializationError("package manifest has the wrong schema")
    if one(manifest_rows, "stage") != "compose-package":
        raise MaterializationError("package manifest has the wrong stage")
    if one(manifest_rows, "repository") != "container-compose":
        raise MaterializationError("package manifest has the wrong repository")
    if one(manifest_rows, "archive-sha256") != archive_digest:
        raise MaterializationError("package manifest does not bind its archive")
    if one(manifest_rows, "artifact-count") != str(len(EXPECTED_ARTIFACTS)):
        raise MaterializationError("package manifest has the wrong artifact count")

    artifacts: dict[str, str] = {}
    for row in manifest_rows:
        if not row or row[0] != "artifact":
            continue
        if len(row) != 4:
            raise MaterializationError("package artifact row is malformed")
        name, digest, size = row[1:]
        require_sha256(digest, f"digest for {name}")
        if not size.isdigit() or name in artifacts:
            raise MaterializationError(f"package artifact row is invalid: {name}")
        artifacts[name] = digest
    if tuple(artifacts) != EXPECTED_ARTIFACTS:
        raise MaterializationError("package manifest does not declare the exact outputs")

    with tarfile.open(archive, "r:") as package:
        members = package.getmembers()
        names = tuple(member.name for member in members)
        if names != EXPECTED_ARTIFACTS:
            raise MaterializationError("package archive does not contain the exact outputs")
        for member in members:
            path = PurePosixPath(member.name)
            if path.is_absolute() or ".." in path.parts or not member.isfile():
                raise MaterializationError(f"unsafe package archive member: {member.name}")
    return artifacts, source_commit


def path_exists(path: Path) -> bool:
    """Return whether a path or symbolic link occupies a destination."""
    return os.path.lexists(path)


def remove_output(path: Path) -> None:
    """Remove one exact generated output without following symbolic links."""
    if path.is_symlink() or path.is_file():
        path.unlink()
    elif path.is_dir():
        shutil.rmtree(path)


def write_journal(path: Path, payload: dict[str, object]) -> None:
    """Atomically persist a materialization transaction before mutation."""
    descriptor, temporary_name = tempfile.mkstemp(
        prefix=f".{path.name}.", dir=path.parent
    )
    try:
        stream_descriptor = descriptor
        descriptor = -1
        with os.fdopen(stream_descriptor, "w", encoding="utf-8") as output:
            json.dump(payload, output, sort_keys=True)
            output.write("\n")
            output.flush()
            os.fsync(output.fileno())
        os.replace(temporary_name, path)
        descriptor = -1
        directory = os.open(path.parent, os.O_RDONLY)
        try:
            os.fsync(directory)
        finally:
            os.close(directory)
    finally:
        if descriptor >= 0:
            os.close(descriptor)
        Path(temporary_name).unlink(missing_ok=True)


def recover_interrupted_transaction(destination: Path) -> None:
    """Roll back a previously interrupted materialization transaction."""
    journal = destination / JOURNAL_NAME
    if not path_exists(journal):
        return
    if journal.is_symlink() or not journal.is_file() or journal.stat().st_size > 65536:
        raise MaterializationError(f"package materialization journal is invalid: {journal}")
    payload = json.loads(journal.read_text(encoding="utf-8"))
    if not isinstance(payload, dict) or payload.get("schema") != 1:
        raise MaterializationError("package materialization journal has the wrong schema")
    transaction = payload.get("transaction")
    phase = payload.get("phase")
    outputs = payload.get("outputs")
    if (
        not isinstance(transaction, str)
        or len(transaction) != 32
        or any(character not in "0123456789abcdef" for character in transaction)
        or phase not in ("prepared", "committed")
        or not isinstance(outputs, dict)
        or set(outputs) != set(OUTPUT_ROOTS)
        or any(not isinstance(value, bool) for value in outputs.values())
    ):
        raise MaterializationError("package materialization journal is malformed")
    backup = destination / f".pipeline-package-previous.{transaction}"
    if backup.is_symlink() or (path_exists(backup) and not backup.is_dir()):
        raise MaterializationError(f"package materialization backup is invalid: {backup}")

    if phase == "committed":
        if backup.exists():
            shutil.rmtree(backup)
        journal.unlink()
        return

    for name in OUTPUT_ROOTS:
        current = destination / name
        previous = backup / name
        if outputs[name]:
            if path_exists(previous):
                remove_output(current)
                os.replace(previous, current)
            elif not path_exists(current):
                raise MaterializationError(
                    f"package materialization cannot restore prior output: {name}"
                )
        else:
            remove_output(current)
    journal.unlink()
    fsync_directory = os.open(destination, os.O_RDONLY)
    try:
        os.fsync(fsync_directory)
    finally:
        os.close(fsync_directory)
    if backup.exists():
        shutil.rmtree(backup)


def checkout_destination(path: Path) -> Path:
    """Return one physical Git checkout that may receive generated outputs."""
    if not path.is_absolute() or not path.is_dir():
        raise MaterializationError(f"package destination is invalid: {path}")
    destination = path.resolve(strict=True)
    if not (destination / ".git").exists():
        raise MaterializationError(f"package destination is not a Git checkout: {destination}")
    return destination


def materialize(
    *, receipt: Path, manifest: Path, archive: Path, destination: Path
) -> None:
    """Verify all bytes before replacing ignored generated outputs."""
    destination = checkout_destination(destination)
    recover_interrupted_transaction(destination)
    artifacts, source_commit = verify_evidence(receipt, manifest, archive)
    checkout_commit = subprocess.run(
        ["/usr/bin/git", "-C", str(destination), "rev-parse", "--verify", "HEAD"],
        check=True,
        capture_output=True,
        text=True,
        env={"PATH": "/usr/bin:/bin", "LANG": "C", "LC_ALL": "C"},
    ).stdout.strip()
    if checkout_commit != source_commit:
        raise MaterializationError(
            "package source commit does not match the destination checkout"
        )

    staging = Path(tempfile.mkdtemp(prefix=".pipeline-package.", dir=destination))
    transaction = uuid.uuid4().hex
    backup = destination / f".pipeline-package-previous.{transaction}"
    journal = destination / JOURNAL_NAME
    try:
        with tarfile.open(archive, "r:") as package:
            try:
                package.extractall(staging, filter="fully_trusted")
            except TypeError:
                package.extractall(staging)
        for relative, expected_digest in artifacts.items():
            staged = staging / relative
            if staged.is_symlink() or not staged.is_file():
                raise MaterializationError(f"staged package output is invalid: {relative}")
            if sha256(staged) != expected_digest:
                raise MaterializationError(f"staged package output digest changed: {relative}")
        build_info = json.loads(
            (staging / "dist/compose/resources/build-info.json").read_text(
                encoding="utf-8"
            )
        )
        if not isinstance(build_info, dict) or build_info.get("commit") != source_commit:
            raise MaterializationError("package build information has the wrong commit")
        plugin = staging / "container-compose-plugin-release-arm64.tar.gz"
        sidecar = staging / "container-compose-plugin-release-arm64.tar.gz.sha256"
        sidecar_lines = sidecar.read_text(encoding="utf-8").splitlines()
        sidecar_fields = sidecar_lines[0].split() if len(sidecar_lines) == 1 else []
        if (
            len(sidecar_fields) != 2
            or sidecar_fields[0] != sha256(plugin)
            or sidecar_fields[1] != plugin.name
        ):
            raise MaterializationError("package checksum sidecar does not match")

        for name in OUTPUT_ROOTS:
            output = destination / name
            if output.is_symlink():
                raise MaterializationError(f"package output destination is indirect: {output}")
            if not path_exists(output):
                continue
            if name == "dist" and not output.is_dir():
                raise MaterializationError(f"package output destination is invalid: {output}")
            if name != "dist" and not output.is_file():
                raise MaterializationError(f"package output destination is invalid: {output}")

        original_outputs = {
            name: path_exists(destination / name) for name in OUTPUT_ROOTS
        }
        backup.mkdir(mode=0o700)
        write_journal(
            journal,
            {
                "schema": 1,
                "transaction": transaction,
                "phase": "prepared",
                "outputs": original_outputs,
            },
        )
        for name in OUTPUT_ROOTS:
            if original_outputs[name]:
                os.replace(destination / name, backup / name)
        for name in OUTPUT_ROOTS:
            os.replace(staging / name, destination / name)
        write_journal(
            journal,
            {
                "schema": 1,
                "transaction": transaction,
                "phase": "committed",
                "outputs": original_outputs,
            },
        )
        shutil.rmtree(backup)
        journal.unlink()
        directory = os.open(destination, os.O_RDONLY)
        try:
            os.fsync(directory)
        finally:
            os.close(directory)
    except BaseException:
        if path_exists(journal):
            recover_interrupted_transaction(destination)
        raise
    finally:
        shutil.rmtree(staging, ignore_errors=True)


def main() -> int:
    """Parse the evidence paths and materialize one recovered package."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--receipt", type=Path)
    parser.add_argument("--manifest", type=Path)
    parser.add_argument("--archive", type=Path)
    parser.add_argument("--destination", type=Path, required=True)
    parser.add_argument("--recover-only", action="store_true")
    args = parser.parse_args()
    destination = checkout_destination(args.destination)
    if args.recover_only:
        recover_interrupted_transaction(destination)
        return 0
    if args.receipt is None or args.manifest is None or args.archive is None:
        parser.error("--receipt, --manifest and --archive are required")
    materialize(
        receipt=args.receipt,
        manifest=args.manifest,
        archive=args.archive,
        destination=destination,
    )
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (
        MaterializationError,
        OSError,
        subprocess.SubprocessError,
        tarfile.TarError,
        json.JSONDecodeError,
    ) as error:
        print(error, file=sys.stderr)
        raise SystemExit(2) from error
