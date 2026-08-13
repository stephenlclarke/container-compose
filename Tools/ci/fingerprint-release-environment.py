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
import shlex
import shutil
from collections.abc import Mapping
from pathlib import Path

SCHEMA_VERSION = 1

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


def sha256_bytes(value: bytes) -> str:
    return hashlib.sha256(value).hexdigest()


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def is_non_result_variable(name: str) -> bool:
    return (
        name in NON_RESULT_VARIABLES
        or name in NON_RESULT_SESSION_VARIABLES
        or name.startswith(NON_RESULT_PREFIXES)
    )


def selected_file(
    value: str, environment: Mapping[str, str], working_directory: Path
) -> Path | None:
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
                return direct.resolve()
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
    return path.resolve() if path.is_file() else None


def environment_manifest(
    environment: Mapping[str, str], working_directory: Path
) -> dict[str, object]:
    entries: dict[str, dict[str, str]] = {}
    for name in sorted(environment):
        if is_non_result_variable(name):
            continue
        value = environment[name]
        entry = {"value_sha256": sha256_bytes(value.encode("utf-8"))}
        artifact = selected_file(value, environment, working_directory)
        if artifact is not None:
            entry["selected_file_sha256"] = sha256_file(artifact)
        entries[name] = entry
    return {
        "entries": entries,
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
