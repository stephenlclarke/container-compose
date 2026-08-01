#!/usr/bin/python3 -I
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

"""Enter one CodeQL Make goal without inherited Make or interpreter source."""

from __future__ import annotations

import os
from pathlib import Path
import pwd
import sys


MAKE = "/usr/bin/make"
FIXED_PATH = "/usr/bin:/bin:/usr/sbin:/sbin"
CLEAN_ENTRY = "CONTAINER_COMPOSE_CODEQL_CLEAN_MAKE_ENTRY"
PROCESS_ENTRY = "CONTAINER_COMPOSE_CODEQL_CLEAN_PROCESS_ENTRY"
ALLOWED_GOALS = {
    "codeql-local",
    "codeql-sarif-upload",
    "codeql-sarif-upload-dry-run",
}
BASE_ENVIRONMENT = (
    "CODEQL_CACHE_ROOT",
    "CODEQL_ARTIFACT_ROOT",
    "LANG",
    "LC_ALL",
    "LC_CTYPE",
    "SSL_CERT_FILE",
    "SSL_CERT_DIR",
    "HTTP_PROXY",
    "HTTPS_PROXY",
    "NO_PROXY",
    "http_proxy",
    "https_proxy",
    "no_proxy",
)
UPLOAD_ENVIRONMENT = (
    "CODEQL_UPLOAD_REPOSITORY",
    "CODEQL_UPLOAD_REF",
    "CODEQL_UPLOAD_COMMIT",
)
NATIVE_LOADER_PREFIXES = ("LD_", "DYLD_", "__XPC_DYLD_")


def native_loader_environment() -> list[str]:
    """Identify an unsafe direct invocation without exposing its values."""

    return sorted(
        name
        for name, value in os.environ.items()
        if value and name.startswith(NATIVE_LOADER_PREFIXES)
    )


def clean_environment(goal: str) -> dict[str, str]:
    """Allowlist reviewed data after the caller-shell process boundary."""

    allowed = list(BASE_ENVIRONMENT)
    if goal != "codeql-local":
        allowed.extend(UPLOAD_ENVIRONMENT)
    environment = {
        name: value
        for name in allowed
        if (value := os.environ.get(name)) is not None
    }
    environment["HOME"] = pwd.getpwuid(os.getuid()).pw_dir
    environment["PATH"] = FIXED_PATH
    environment[CLEAN_ENTRY] = "1"
    return environment


def main() -> int:
    if len(sys.argv) != 2 or sys.argv[1] not in ALLOWED_GOALS:
        goals = "|".join(sorted(ALLOWED_GOALS))
        print(f"usage: {Path(sys.argv[0]).name} {goals}", file=sys.stderr)
        return 2

    if os.environ.get(PROCESS_ENTRY) != "1":
        print(
            "unsafe direct invocation; source Tools/ci/codeql-entry.sh and use "
            "container_compose_codeql <goal>",
            file=sys.stderr,
        )
        return 2
    if loader_environment := native_loader_environment():
        print(
            "unsafe native-loader environment reached the Python launcher: "
            + ", ".join(loader_environment),
            file=sys.stderr,
        )
        return 2

    repository = Path(__file__).resolve().parents[2]
    makefile = repository / "Makefile"
    arguments = [
        MAKE,
        "-rR",
        "-C",
        str(repository),
        "-f",
        str(makefile),
        sys.argv[1],
    ]
    try:
        os.execve(MAKE, arguments, clean_environment(sys.argv[1]))
    except OSError as error:
        print(f"could not enter the controlled CodeQL Make goal: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
