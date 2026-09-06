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

"""Run one Swift command in a recoverable local dependency session."""

from __future__ import annotations

import argparse
import base64
import fcntl
import hashlib
import json
import os
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path


OVERRIDE_ENVIRONMENT = (
    "CONTAINER_PACKAGE_PATH",
    "CONTAINERIZATION_PACKAGE_PATH",
    "CONTAINER_ENGINE_API_PACKAGE_PATH",
)


@dataclass(frozen=True)
class Dependency:
    identity: str
    path: Path


def clean_environment() -> dict[str, str]:
    environment = os.environ.copy()
    for name in OVERRIDE_ENVIRONMENT:
        environment.pop(name, None)
    return environment


def sha256(contents: bytes) -> str:
    return hashlib.sha256(contents).hexdigest()


def restore_lockfile(lockfile: Path, contents: bytes) -> bool:
    if lockfile.read_bytes() == contents:
        return False
    lockfile.write_bytes(contents)
    return True


def active_edit_paths(workspace_state: Path) -> dict[str, Path]:
    if not workspace_state.exists():
        return {}
    try:
        state = json.loads(workspace_state.read_text(encoding="utf-8"))
        dependencies = state.get("object", {}).get("dependencies", [])
        return {
            dependency.get("packageRef", {}).get("identity", ""): Path(
                dependency.get("state", {}).get("path", "")
            ).resolve()
            for dependency in dependencies
            if dependency.get("state", {}).get("name") == "edited"
        }
    except (json.JSONDecodeError, OSError, TypeError, AttributeError) as error:
        raise SystemExit(f"could not inspect SwiftPM workspace state: {error}") from error


def validate_dependency(identity: str, value: str | None) -> Dependency | None:
    if not value:
        return None
    path = Path(value)
    if not path.is_absolute():
        raise SystemExit(f"{identity} package path must be absolute: {path}")
    if path.is_symlink() or not (path / "Package.swift").is_file():
        raise SystemExit(f"{identity} package path is invalid: {path}")
    return Dependency(identity=identity, path=path.resolve())


def git_output(path: Path, *arguments: str) -> str:
    result = subprocess.run(
        ["/usr/bin/git", "-C", str(path), *arguments],
        check=False,
        stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )
    if result.returncode != 0:
        diagnostic = result.stderr.strip() or f"exit {result.returncode}"
        raise SystemExit(f"could not inspect local package {path}: {diagnostic}")
    return result.stdout


def dependency_record(dependency: Dependency) -> dict[str, str]:
    if git_output(dependency.path, "status", "--porcelain"):
        raise SystemExit(
            f"{dependency.identity} package must be clean: {dependency.path}"
        )
    tree = git_output(dependency.path, "rev-parse", "HEAD^{tree}").strip()
    if len(tree) != 40 or any(character not in "0123456789abcdef" for character in tree):
        raise SystemExit(
            f"{dependency.identity} package has an invalid Git tree: {tree}"
        )
    return {
        "identity": dependency.identity,
        "path": str(dependency.path),
        "tree": tree,
    }


def dependency_records(
    dependencies: tuple[Dependency, ...],
) -> tuple[dict[str, str], ...]:
    return tuple(dependency_record(dependency) for dependency in dependencies)


def recovery_paths(root: Path) -> tuple[Path, Path]:
    recovery_root = root / ".build" / "local-swift-stack"
    return recovery_root / "journal.json", recovery_root / "Package.resolved.backup"


def ensure_recovery_root(root: Path) -> Path:
    recovery_root = root / ".build" / "local-swift-stack"
    recovery_root.mkdir(parents=True, exist_ok=True)
    if recovery_root.is_symlink() or not recovery_root.is_dir():
        raise SystemExit(
            f"local Swift stack recovery root is indirect or invalid: {recovery_root}"
        )
    return recovery_root


def read_recovery_state(root: Path) -> tuple[dict[str, object], bytes] | None:
    journal, backup = recovery_paths(root)
    if not journal.exists() and not backup.exists():
        return None
    if journal.is_symlink() or not journal.is_file():
        raise SystemExit("local Swift stack recovery state is incomplete or indirect")
    try:
        state = json.loads(journal.read_text(encoding="utf-8"))
        expected_sha256 = state["package_resolved_sha256"]
    except (json.JSONDecodeError, KeyError, TypeError, OSError) as error:
        raise SystemExit(f"local Swift stack recovery journal is invalid: {error}") from error
    schema = state.get("schema")
    if schema == 3:
        if backup.exists():
            raise SystemExit("local Swift stack recovery state mixes journal schemas")
        try:
            encoded_lock = state["package_resolved_base64"]
            if not isinstance(encoded_lock, str):
                raise TypeError("package_resolved_base64 is not text")
            original_lock = base64.b64decode(encoded_lock, validate=True)
        except (KeyError, TypeError, ValueError) as error:
            raise SystemExit(
                f"local Swift stack recovery journal has an invalid lock: {error}"
            ) from error
    elif schema in (1, 2):
        if backup.is_symlink() or not backup.is_file():
            raise SystemExit(
                "local Swift stack legacy recovery backup is incomplete or indirect"
            )
        original_lock = backup.read_bytes()
    else:
        raise SystemExit("local Swift stack recovery journal has an unknown schema")
    if sha256(original_lock) != expected_sha256:
        raise SystemExit("local Swift stack recovery journal does not match its lock backup")
    return state, original_lock


def can_resume(
    root: Path,
    lockfile: Path,
    dependencies: tuple[Dependency, ...],
    records: tuple[dict[str, str], ...],
) -> bool:
    recovery = read_recovery_state(root)
    if recovery is None:
        return False
    state, original_lock = recovery
    if state.get("schema") != 3 or state.get("dependencies") != list(records):
        return False
    active_edits = active_edit_paths(root / ".build" / "workspace-state.json")
    if any(active_edits.get(item.identity) != item.path for item in dependencies):
        return False
    restore_lockfile(lockfile, original_lock)
    return True


def swift_package(swift: str, environment: dict[str, str], *arguments: str) -> int:
    result = subprocess.run(
        [swift, "package", *arguments],
        check=False,
        env=environment,
        stdin=subprocess.DEVNULL,
    )
    return result.returncode


def edit_dependencies(
    swift: str, dependencies: tuple[Dependency, ...], environment: dict[str, str]
) -> tuple[bool, tuple[str, ...]]:
    edited: list[str] = []
    for dependency in dependencies:
        status = swift_package(
            swift,
            environment,
            "edit",
            dependency.identity,
            "--path",
            str(dependency.path),
        )
        if status != 0:
            return False, tuple(edited)
        edited.append(dependency.identity)
    return True, tuple(edited)


def unedit_dependencies(
    swift: str, identities: tuple[str, ...], environment: dict[str, str]
) -> int:
    status = 0
    for identity in reversed(identities):
        current = swift_package(swift, environment, "unedit", identity, "--force")
        if current != 0:
            status = current
    return status


def recover(
    root: Path,
    lockfile: Path,
    swift: str,
    environment: dict[str, str],
) -> None:
    recovery = read_recovery_state(root)
    if recovery is None:
        return
    state, original_lock = recovery
    try:
        identities = tuple(state["identities"])
    except (KeyError, TypeError) as error:
        raise SystemExit(f"local Swift stack recovery journal is invalid: {error}") from error
    if any(not isinstance(identity, str) or not identity for identity in identities):
        raise SystemExit("local Swift stack recovery journal has invalid dependency identities")
    active_edits = active_edit_paths(root / ".build" / "workspace-state.json")
    active_identities = tuple(
        identity for identity in identities if identity in active_edits
    )
    if unedit_dependencies(swift, active_identities, environment) != 0:
        raise SystemExit(
            "could not recover interrupted SwiftPM edits; recovery state retained"
        )
    restore_lockfile(lockfile, original_lock)
    journal, backup = recovery_paths(root)
    journal.unlink()
    if backup.exists():
        backup.unlink()
    print("Recovered an interrupted local Swift stack transaction.")


def write_recovery_journal(
    root: Path,
    lock_contents: bytes,
    managed_dependencies: tuple[Dependency, ...],
    records: tuple[dict[str, str], ...],
) -> Path:
    recovery_root = ensure_recovery_root(root)
    journal = recovery_root / "journal.json"
    _, legacy_backup = recovery_paths(root)
    if legacy_backup.exists() or journal.exists():
        raise SystemExit("local Swift stack recovery state was not cleared")
    journal_temporary = recovery_root / "journal.json.pending"
    if journal_temporary.exists() or journal_temporary.is_symlink():
        if journal_temporary.is_symlink() or not journal_temporary.is_file():
            raise SystemExit("local Swift stack pending journal is indirect or invalid")
        journal_temporary.unlink()
    journal_contents = (
        json.dumps(
            {
                "schema": 3,
                "dependencies": records,
                "identities": [
                    dependency.identity for dependency in managed_dependencies
                ],
                "package_resolved_base64": base64.b64encode(lock_contents).decode(
                    "ascii"
                ),
                "package_resolved_sha256": sha256(lock_contents),
            },
            sort_keys=True,
        )
        + "\n"
    ).encode("utf-8")
    flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    descriptor = os.open(journal_temporary, flags, 0o600)
    try:
        offset = 0
        while offset < len(journal_contents):
            offset += os.write(descriptor, journal_contents[offset:])
        os.fsync(descriptor)
    finally:
        os.close(descriptor)
    os.replace(journal_temporary, journal)
    directory_descriptor = os.open(recovery_root, os.O_RDONLY)
    try:
        os.fsync(directory_descriptor)
    finally:
        os.close(directory_descriptor)
    return journal


def run(arguments: argparse.Namespace) -> int:
    root = Path.cwd()
    lockfile = root / "Package.resolved"
    if not lockfile.is_file() or lockfile.is_symlink():
        raise SystemExit(f"tracked Package.resolved is unavailable: {lockfile}")
    dependencies = tuple(
        dependency
        for dependency in (
            validate_dependency("container", arguments.container),
            validate_dependency("containerization", arguments.containerization),
            validate_dependency("container-engine-api", arguments.engine_api),
        )
        if dependency is not None
    )
    environment = clean_environment()
    recovery_root = ensure_recovery_root(root)
    lock_path = recovery_root / "transaction.lock"
    if lock_path.is_symlink():
        raise SystemExit(f"local Swift stack lock must not be a symbolic link: {lock_path}")
    lock_descriptor = os.open(lock_path, os.O_CREAT | os.O_RDWR, 0o600)
    try:
        try:
            fcntl.flock(lock_descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError as error:
            raise SystemExit("another local Swift stack transaction is active") from error
        if arguments.cleanup:
            recover(root, lockfile, arguments.swift, environment)
            return 0

        records = dependency_records(dependencies)
        resuming = (
            arguments.retain_edits
            and bool(dependencies)
            and can_resume(root, lockfile, dependencies, records)
        )
        if not resuming:
            recover(root, lockfile, arguments.swift, environment)
        prior_edits = active_edit_paths(root / ".build" / "workspace-state.json")
        expected_edits = {
            dependency.identity: dependency.path for dependency in dependencies
        }
        incompatible_edits = {
            identity: path
            for identity, path in prior_edits.items()
            if expected_edits.get(identity) != path
        }
        if incompatible_edits:
            raise SystemExit(
                "refusing to replace incompatible SwiftPM edits: "
                + ", ".join(sorted(incompatible_edits))
            )
        managed_dependencies = tuple(
            dependency
            for dependency in dependencies
            if dependency.identity not in prior_edits
        )
        if resuming:
            recovery = read_recovery_state(root)
            assert recovery is not None
            _, original_lock = recovery
            try:
                return subprocess.run(
                    arguments.command,
                    check=False,
                    env=environment,
                    stdin=subprocess.DEVNULL,
                ).returncode
            finally:
                restore_lockfile(lockfile, original_lock)
        if not managed_dependencies:
            original_lock = lockfile.read_bytes()
            try:
                return subprocess.run(
                    arguments.command,
                    check=False,
                    env=environment,
                    stdin=subprocess.DEVNULL,
                ).returncode
            finally:
                restore_lockfile(lockfile, original_lock)

        original_lock = lockfile.read_bytes()
        journal = write_recovery_journal(
            root,
            original_lock,
            managed_dependencies,
            records,
        )
        edited: tuple[str, ...] = ()
        command_status = 0
        cleanup_status = 0
        lock_changed = False
        setup_failed = False
        try:
            edited_ok, edited = edit_dependencies(
                arguments.swift, managed_dependencies, environment
            )
            if not edited_ok:
                cleanup_status = unedit_dependencies(
                    arguments.swift, edited, environment
                )
                edited = ()
                if cleanup_status == 0 and swift_package(
                    arguments.swift, environment, "resolve"
                ) == 0:
                    edited_ok, edited = edit_dependencies(
                        arguments.swift, managed_dependencies, environment
                    )
                if not edited_ok:
                    command_status = 2
                    setup_failed = True
            if edited_ok:
                lock_changed = restore_lockfile(lockfile, original_lock)
                command_status = subprocess.run(
                    arguments.command,
                    check=False,
                    env=environment,
                    stdin=subprocess.DEVNULL,
                ).returncode
        finally:
            lock_changed = (
                restore_lockfile(lockfile, original_lock) or lock_changed
            )
            if not arguments.retain_edits or setup_failed:
                final_cleanup_status = unedit_dependencies(
                    arguments.swift, edited, environment
                )
                if final_cleanup_status != 0:
                    cleanup_status = final_cleanup_status
            if cleanup_status == 0 and (not arguments.retain_edits or setup_failed):
                journal.unlink()
        if lock_changed:
            print(
                "local Swift stack changed Package.resolved; the original lock was restored",
                file=sys.stderr,
            )
        if cleanup_status != 0:
            print(
                "could not restore SwiftPM editable dependencies; recovery state retained",
                file=sys.stderr,
            )
            return cleanup_status
        return command_status
    finally:
        try:
            fcntl.flock(lock_descriptor, fcntl.LOCK_UN)
        except OSError:
            pass
        os.close(lock_descriptor)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--swift", default="swift")
    parser.add_argument("--container")
    parser.add_argument("--containerization")
    parser.add_argument("--engine-api")
    parser.add_argument("--retain-edits", action="store_true")
    parser.add_argument("--cleanup", action="store_true")
    parser.add_argument("command", nargs=argparse.REMAINDER)
    arguments = parser.parse_args()
    if arguments.command and arguments.command[0] == "--":
        arguments.command = arguments.command[1:]
    if not arguments.command and not arguments.cleanup:
        parser.error("a command is required after --")
    raise SystemExit(run(arguments))


if __name__ == "__main__":
    main()
