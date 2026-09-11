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

"""Run actionlint while validating GitHub's newer concurrency queue extension."""

from __future__ import annotations

import argparse
import subprocess
import sys
import tempfile
from pathlib import Path


class WorkflowError(RuntimeError):
    """A workflow uses an invalid queue extension."""


def compatible_source(path: Path) -> str:
    lines = path.read_text(encoding="utf-8").splitlines(keepends=True)
    output: list[str] = []
    for index, line in enumerate(lines):
        stripped = line.lstrip(" ")
        if not stripped.startswith("queue:"):
            output.append(line)
            continue
        indentation = len(line) - len(stripped)
        if stripped.strip() != "queue: max":
            raise WorkflowError(f"{path}:{index + 1}: concurrency queue must be max")
        parent_found = False
        for previous in reversed(lines[:index]):
            previous_stripped = previous.lstrip(" ")
            if not previous_stripped.strip() or previous_stripped.startswith("#"):
                continue
            previous_indentation = len(previous) - len(previous_stripped)
            if previous_indentation < indentation:
                parent_found = previous_stripped.strip() == "concurrency:"
                break
        if not parent_found:
            raise WorkflowError(
                f"{path}:{index + 1}: queue is not directly inside concurrency"
            )
        # actionlint 1.7.12 predates GitHub's queue extension. Validate the
        # extension narrowly above and lint every remaining byte normally.
    return "".join(output)


def main(arguments: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--actionlint", default="actionlint")
    parser.add_argument("--config", type=Path, default=Path(".github/actionlint.yaml"))
    parser.add_argument("workflow", type=Path, nargs="+")
    options = parser.parse_args(arguments)
    try:
        with tempfile.TemporaryDirectory() as directory:
            temporary = Path(directory)
            lint_paths: list[str] = []
            for index, workflow in enumerate(options.workflow):
                destination = temporary / f"{index}-{workflow.name}"
                destination.write_text(compatible_source(workflow), encoding="utf-8")
                lint_paths.append(str(destination))
            command = [options.actionlint]
            if options.config.is_file():
                command.extend(("-config-file", str(options.config.resolve())))
            result = subprocess.run([*command, *lint_paths], check=False)
            return result.returncode
    except (OSError, UnicodeError, WorkflowError) as error:
        print(f"validate-actions-workflows: {error}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
