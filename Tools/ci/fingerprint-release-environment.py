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

"""Fingerprint every inherited input that can cross the release-gate boundary."""

from __future__ import annotations

import hashlib
import json
import os
import re
import shlex
import shutil
import stat
from collections.abc import Mapping
from pathlib import Path

SCHEMA_VERSION = 2

# These values select isolated execution locations or evidence destinations;
# they cannot change the code, policy, tools, fixtures, or runtime candidate
# being proved. Everything else is included by default so a newly introduced
# environment or make-command-line override fails closed without updating this
# tool first.
NON_RESULT_VARIABLES = frozenset(
    {
        "COMPOSE_CLI_SURFACE_REPORT",
        "CONTAINER_RUNTIME_APP_ROOT",
        "CONTAINER_RUNTIME_RUN_ID",
        "CONTAINER_RUNTIME_SERVICE_NAMESPACE",
        "CONTAINER_STACK_VALIDATION_CHECKPOINT_DIR",
        "CONTAINER_STACK_VALIDATION_RUNTIME_ROOT",
        "CONTAINER_STACK_VALIDATION_SCRATCH_ROOT",
        "LLVM_PROFILE_FILE",
        "LOG_COMPLETION_FILE",
        "PARITY_EVIDENCE_DIR",
        "PARITY_TIMING_OUTPUT",
    }
)

# Interactive shell and task-runner session identities change when the same
# immutable release is resumed in a new terminal or Codex task. They do not
# reach the build, test, parity, packaging, or publication contracts.
NON_RESULT_PREFIXES = (
    "ATUIN_",
    "CODEX_",
    "STARSHIP_",
    "ZSH_TMUX_",
)
NON_RESULT_SESSION_VARIABLES = frozenset(
    {
        "COMMAND_MODE",
        "OLDPWD",
        "SHLVL",
        "XPC_FLAGS",
        "XPC_SERVICE_NAME",
        "_",
        "__CF_USER_TEXT_ENCODING",
    }
)

# GNU Make serializes command-line variable assignments into MAKEFLAGS for
# recursive invocations, including on the system GNU Make 3.81 shipped by
# macOS. MAKEOVERRIDES may contain only Make's internal expansion placeholder,
# so both variables are represented by parse_make_inputs() instead of being
# hashed as opaque environment values.
MAKE_INTERNAL_VARIABLES = frozenset({"MAKEFLAGS", "MAKEOVERRIDES"})
MAKE_ASSIGNMENT = re.compile(
    r"^(?P<name>[A-Za-z_][A-Za-z0-9_.-]*)"
    r"(?P<operator>:::=|::=|:=|\+=|\?=|=)(?P<value>.*)$"
)

# These roots are freshly allocated for each release attempt, but their
# contents can affect the result. Bind the proof to the directory tree rather
# than its random absolute location.
CONTENT_ROOT_VARIABLES = frozenset({"XDG_CONFIG_HOME"})

# The release helper extracts the same immutable Container candidate below a
# fresh mktemp root on every retry. These selectors establish which PATH entry
# can be normalized to the selected executable's content identity.
RELOCATABLE_EXECUTABLE_VARIABLES = frozenset(
    {
        "CONTAINER_BIN",
        "CONTAINER_COMPOSE_CONTAINER",
        "CONTAINER_RUNTIME_CLI",
    }
)


def sha256_bytes(value: bytes) -> str:
    return hashlib.sha256(value).hexdigest()


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def sha256_directory(path: Path) -> str:
    digest = hashlib.sha256()
    for candidate in sorted(
        path.rglob("*"), key=lambda item: item.relative_to(path).as_posix()
    ):
        relative = candidate.relative_to(path).as_posix()
        metadata = candidate.lstat()
        digest.update(relative.encode("utf-8"))
        digest.update(b"\0")
        digest.update(f"{stat.S_IMODE(metadata.st_mode):04o}".encode("ascii"))
        digest.update(b"\0")
        if candidate.is_symlink():
            digest.update(b"symlink\0")
            digest.update(os.readlink(candidate).encode("utf-8"))
        elif candidate.is_file():
            digest.update(b"file\0")
            digest.update(sha256_file(candidate).encode("ascii"))
        elif candidate.is_dir():
            digest.update(b"directory\0")
        else:
            digest.update(b"other\0")
        digest.update(b"\0")
    return digest.hexdigest()


def is_non_result_variable(name: str) -> bool:
    return (
        name in NON_RESULT_VARIABLES
        or name in NON_RESULT_SESSION_VARIABLES
        or name.startswith(NON_RESULT_PREFIXES)
    )


def selected_file(
    value: str, environment: Mapping[str, str], working_directory: Path
) -> tuple[Path, tuple[str, ...]] | None:
    selectors = [value.strip()]
    try:
        arguments = shlex.split(value)
    except ValueError:
        arguments = []
    if arguments and arguments[0] not in selectors:
        selectors.append(arguments[0])
    if not selectors[0]:
        return None

    for selector in selectors:
        try:
            direct = Path(selector).expanduser()
        except (OSError, RuntimeError):
            direct = Path(selector)
        if not direct.is_absolute():
            direct = working_directory / direct
        try:
            if direct.is_file():
                arguments_after_selector: tuple[str, ...] = ()
                if selector != selectors[0] and arguments:
                    arguments_after_selector = tuple(arguments[1:])
                return direct.resolve(), arguments_after_selector
        except OSError:
            pass

    executable = arguments[0] if arguments else selectors[0]
    try:
        resolved = shutil.which(executable, path=environment.get("PATH"))
    except OSError:
        resolved = None
    if resolved is None:
        return None
    path = Path(resolved)
    if not path.is_file():
        return None
    return path.resolve(), tuple(arguments[1:])


def parse_make_inputs(
    environment: Mapping[str, str],
) -> tuple[tuple[str, ...], tuple[tuple[str, str, str], ...]]:
    makeflags = environment.get("MAKEFLAGS", "")
    # GNU Make separates MAKEFLAGS words with unescaped whitespace and uses a
    # backslash to preserve the following character. Quotes have no special
    # meaning: they are literal variable data, not POSIX shell syntax.
    tokens: list[str] = []
    current: list[str] = []
    escaped = False
    for character in makeflags:
        if escaped:
            current.append(character)
            escaped = False
        elif character == "\\":
            escaped = True
        elif character.isspace():
            if current:
                tokens.append("".join(current))
                current = []
        else:
            current.append(character)
    if escaped:
        current.append("\\")
    if current:
        tokens.append("".join(current))

    flags: list[str] = []
    overrides: list[tuple[str, str, str]] = []
    for token in tokens:
        if token == "--":
            continue
        assignment = MAKE_ASSIGNMENT.match(token)
        if assignment is None:
            flags.append(token)
            continue
        overrides.append(
            (
                assignment.group("name"),
                assignment.group("operator"),
                assignment.group("value"),
            )
        )
    return tuple(flags), tuple(overrides)


def selected_file_entry(
    selection: tuple[Path, tuple[str, ...]],
) -> dict[str, str]:
    artifact, arguments = selection
    mode = stat.S_IMODE(artifact.stat().st_mode)
    return {
        "arguments_sha256": sha256_bytes(
            json.dumps(arguments, separators=(",", ":")).encode("utf-8")
        ),
        "selected_file_mode": f"{mode:04o}",
        "selected_file_name_sha256": sha256_bytes(artifact.name.encode("utf-8")),
        "selected_file_sha256": sha256_file(artifact),
    }


def relocatable_path_directories(
    environment: Mapping[str, str], working_directory: Path
) -> dict[Path, str]:
    candidate_sha256 = environment.get("CONTAINER_RUNTIME_CANDIDATE_SHA256", "")
    runtime_cli_sha256 = environment.get("CONTAINER_RUNTIME_CLI_SHA256", "")
    runtime_cli = environment.get("CONTAINER_RUNTIME_CLI", "")
    if not re.fullmatch(r"[0-9a-f]{64}", candidate_sha256):
        return {}
    if not re.fullmatch(r"[0-9a-f]{64}", runtime_cli_sha256):
        return {}
    runtime_selection = selected_file(runtime_cli, environment, working_directory)
    if runtime_selection is None:
        return {}
    runtime_artifact, _runtime_arguments = runtime_selection
    if sha256_file(runtime_artifact) != runtime_cli_sha256:
        return {}

    runtime_directory = runtime_artifact.parent
    directories: dict[Path, list[dict[str, str]]] = {}
    for name in RELOCATABLE_EXECUTABLE_VARIABLES:
        value = environment.get(name)
        if value is None:
            continue
        selection = selected_file(value, environment, working_directory)
        if selection is None:
            continue
        artifact, _arguments = selection
        if artifact.parent != runtime_directory:
            continue
        directories.setdefault(artifact.parent, []).append(
            selected_file_entry(selection)
        )
    return {
        directory: sha256_bytes(
            json.dumps(entries, sort_keys=True, separators=(",", ":")).encode(
                "utf-8"
            )
        )
        for directory, entries in directories.items()
    }


def normalized_path_identity(
    value: str, relocatable_directories: Mapping[Path, str]
) -> str:
    normalized_entries: list[str] = []
    for entry in value.split(os.pathsep):
        resolved: Path | None = None
        try:
            path = Path(entry).expanduser()
            if path.is_dir():
                resolved = path.resolve()
        except (OSError, RuntimeError):
            pass
        content_identity = (
            relocatable_directories.get(resolved) if resolved is not None else None
        )
        normalized_entries.append(
            f"selected-directory:{content_identity}"
            if content_identity is not None
            else entry
        )
    return sha256_bytes(os.pathsep.join(normalized_entries).encode("utf-8"))


def value_entry(
    name: str,
    value: str,
    environment: Mapping[str, str],
    working_directory: Path,
    relocatable_directories: Mapping[Path, str],
) -> dict[str, str]:
    if name == "PATH":
        return {
            "normalized_path_sha256": normalized_path_identity(
                value, relocatable_directories
            )
        }
    if name in CONTENT_ROOT_VARIABLES:
        try:
            content_root = Path(value).expanduser()
            if not content_root.is_absolute():
                content_root = working_directory / content_root
            if content_root.is_dir():
                entry = {
                    "selected_directory_sha256": sha256_directory(content_root)
                }
                if not relocatable_directories:
                    entry["value_sha256"] = sha256_bytes(value.encode("utf-8"))
                return entry
        except (OSError, RuntimeError):
            pass
        entry = {"selected_directory_state": "missing"}
        if not relocatable_directories:
            entry["value_sha256"] = sha256_bytes(value.encode("utf-8"))
        return entry

    selection = selected_file(value, environment, working_directory)
    if selection is not None:
        entry = selected_file_entry(selection)
        artifact, _arguments = selection
        is_relocated_candidate = (
            name in RELOCATABLE_EXECUTABLE_VARIABLES
            and artifact.parent in relocatable_directories
        )
        if not is_relocated_candidate:
            entry["value_sha256"] = sha256_bytes(value.encode("utf-8"))
        return entry
    return {"value_sha256": sha256_bytes(value.encode("utf-8"))}


def environment_manifest(
    environment: Mapping[str, str], working_directory: Path
) -> dict[str, object]:
    make_flags, make_overrides = parse_make_inputs(environment)
    effective_environment = dict(environment)
    for name, operator, value in make_overrides:
        if operator in {"=", ":=", "::=", ":::="}:
            effective_environment[name] = value
    relocatable_directories = relocatable_path_directories(
        effective_environment, working_directory
    )

    entries: dict[str, dict[str, str]] = {}
    for name in sorted(environment):
        if is_non_result_variable(name) or name in MAKE_INTERNAL_VARIABLES:
            continue
        value = environment[name]
        entries[name] = value_entry(
            name,
            value,
            effective_environment,
            working_directory,
            relocatable_directories,
        )

    override_entries = []
    for name, operator, value in make_overrides:
        override_entries.append(
            {
                "identity": value_entry(
                    name,
                    value,
                    effective_environment,
                    working_directory,
                    relocatable_directories,
                ),
                "name": name,
                "operator": operator,
            }
        )
    return {
        "entries": entries,
        "make_flags_sha256": sha256_bytes(
            json.dumps(make_flags, separators=(",", ":")).encode("utf-8")
        ),
        "make_overrides": override_entries,
        "schema": SCHEMA_VERSION,
    }


def fingerprint_environment(
    environment: Mapping[str, str], working_directory: Path
) -> str:
    encoded = json.dumps(
        environment_manifest(environment, working_directory),
        sort_keys=True,
        separators=(",", ":"),
    ).encode("utf-8")
    return sha256_bytes(encoded)


def main() -> int:
    print(fingerprint_environment(os.environ, Path.cwd()))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
