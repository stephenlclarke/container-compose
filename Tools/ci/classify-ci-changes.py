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

"""Classify repository changes into independent CI validation scopes."""

from __future__ import annotations

import argparse
from dataclasses import dataclass
from pathlib import Path, PurePosixPath


RUNTIME_DRIVER_PATHS = {
    "Tools/ci/run-swift-test.sh",
    "Tools/ci/run-with-local-swift-stack.py",
    "Tools/ci/summarize-swift-testing.py",
    "Tools/ci/use-stack-container.sh",
    "Tools/ci/use-stack-containerization.sh",
}


@dataclass(frozen=True)
class ValidationScope:
    """The CI work required for one changed-file set."""

    heavy: bool
    tools: bool
    runtime: bool
    handoff: bool


def _under(path: PurePosixPath, directory: str) -> bool:
    return path.parts[:1] == (directory,)


def classify(paths: list[str], *, full: bool = False) -> ValidationScope:
    """Return the smallest safe validation scope for ``paths``."""

    if full or not paths:
        return ValidationScope(heavy=True, tools=True, runtime=True, handoff=False)

    tools = False
    runtime = False
    handoff = False
    for value in paths:
        path = PurePosixPath(value)
        if path.is_absolute() or ".." in path.parts or not path.parts:
            tools = True
            runtime = True
            continue

        if value.startswith("docs/upstream/"):
            handoff = True
            continue
        if path.suffix == ".md" or _under(path, "docs") or _under(path, "Formula"):
            continue

        if value.startswith("Tests/BuildPipeline/"):
            tools = True
            continue

        if value in RUNTIME_DRIVER_PATHS:
            tools = True
            runtime = True
            continue

        if (
            _under(path, "Sources")
            or _under(path, "Tests")
            or _under(path, "examples")
            or value in {"Package.swift", "Package.resolved"}
            or value.startswith("Tools/compose-normalizer/")
        ):
            runtime = True
            continue

        if value == "Makefile":
            tools = True
            runtime = True
            continue

        if value == ".github/workflows/ci.yml":
            tools = True
            runtime = True
            continue

        if (
            _under(path, ".github")
            or _under(path, "Tools")
            or _under(path, "scripts")
            or _under(path, "build-pipeline")
            or value
            in {
                ".gitignore",
                ".markdownlint.json",
                ".swiftformat",
                ".swiftlint.yml",
                "LICENSE",
                "config.toml",
                "licenserc.toml",
                "main.nf",
                "nextflow.config",
                "sonar-project.properties",
            }
        ):
            tools = True
            continue

        # New top-level inputs must prove that they are safe before receiving a
        # narrower classification.
        tools = True
        runtime = True

    return ValidationScope(
        heavy=tools or runtime,
        tools=tools,
        runtime=runtime,
        handoff=handoff,
    )


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("changed_files", type=Path, nargs="?")
    parser.add_argument("--full", action="store_true")
    arguments = parser.parse_args()
    if arguments.full:
        paths: list[str] = []
    elif arguments.changed_files is None:
        parser.error("changed_files is required unless --full is used")
    else:
        paths = arguments.changed_files.read_text(encoding="utf-8").splitlines()

    scope = classify(paths, full=arguments.full)
    for name in ("heavy", "tools", "runtime", "handoff"):
        print(f"{name}={str(getattr(scope, name)).lower()}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
