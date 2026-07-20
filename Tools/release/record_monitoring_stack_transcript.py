#!/usr/bin/env python3
##===----------------------------------------------------------------------===##
## Copyright © 2026 container-compose project authors.
##
## Licensed under the Apache License, Version 2.0 (the "License");
## you may not use this file except in compliance with the License.
## You may obtain a copy of the License at
## https://www.apache.org/licenses/LICENSE-2.0
##===----------------------------------------------------------------------===##

"""Execute and persist the monitoring-stack demo transcript for VHS replay."""

from __future__ import annotations

import argparse
import os
import shutil
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Sequence


@dataclass(frozen=True)
class TranscriptStep:
    filename: str
    marker: str
    commands: tuple[tuple[str, ...], ...]


class TranscriptFailure(RuntimeError):
    """A command in the verified demo cycle failed."""


def parse_args(argv: Sequence[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Run the monitoring-stack reuse cycle and write VHS replay logs."
    )
    parser.add_argument("--container", type=Path, required=True)
    parser.add_argument("--compose-file", type=Path, required=True)
    parser.add_argument("--working-directory", type=Path, required=True)
    parser.add_argument("--output-directory", type=Path, required=True)
    return parser.parse_args(argv)


def compose_command(container: Path, compose_file: Path, *arguments: str) -> tuple[str, ...]:
    return (str(container), "compose", "-f", str(compose_file), *arguments)


def display_command(compose_file: Path, command: Sequence[str]) -> str:
    command_tail = command[4:]
    return "container compose -f {} {}".format(
        compose_file.as_posix(),
        " ".join(command_tail),
    ).rstrip()


def curl_command(url: str) -> tuple[str, ...]:
    curl = shutil.which("curl")
    if curl is None:
        raise TranscriptFailure("curl is required to verify the monitoring demo endpoints")
    return (
        curl,
        "-4fsS",
        "--retry",
        "30",
        "--retry-all-errors",
        "--retry-connrefused",
        "--retry-delay",
        "1",
        url,
    )


def runtime_environment(container: Path) -> dict[str, str]:
    environment = os.environ.copy()
    environment["CONTAINER_COMPOSE_CONTAINER"] = str(container)
    return environment


def display_curl_command(command: Sequence[str]) -> str:
    return "curl " + " ".join(command[1:])


def steps(container: Path, compose_file: Path) -> tuple[TranscriptStep, ...]:
    compose = lambda *arguments: compose_command(container, compose_file, *arguments)
    nginx_health = curl_command("http://127.0.0.1:8080/healthz")
    alertmanager_health = curl_command("http://127.0.0.1:9093/alertmanager/-/ready")
    return (
        TranscriptStep(
            "00-system-status.log",
            "TAPE_TRANSCRIPT_SYSTEM_OK",
            ((str(container), "system", "status"),),
        ),
        TranscriptStep(
            "01-compose-version.log",
            "TAPE_TRANSCRIPT_VERSION_OK",
            ((str(container), "compose", "version"),),
        ),
        TranscriptStep(
            "02-first-up.log",
            "TAPE_TRANSCRIPT_FIRST_UP_OK",
            (compose("up", "--detach", "--wait", "--wait-timeout", "300"),),
        ),
        TranscriptStep(
            "03-first-stats.log",
            "TAPE_TRANSCRIPT_FIRST_STATS_OK",
            (compose("stats", "--no-stream"),),
        ),
        TranscriptStep(
            "04-first-ps.log",
            "TAPE_TRANSCRIPT_FIRST_PS_OK",
            (compose("ps"),),
        ),
        TranscriptStep(
            "05-first-health.log",
            "TAPE_TRANSCRIPT_FIRST_HEALTH_OK",
            (nginx_health, alertmanager_health),
        ),
        TranscriptStep(
            "06-retained-down.log",
            "TAPE_TRANSCRIPT_RETAINED_DOWN_OK",
            (compose("down", "--remove-orphans"),),
        ),
        TranscriptStep(
            "07-retained-volumes.log",
            "TAPE_TRANSCRIPT_VOLUMES_RETAINED_OK",
            (compose("volumes"),),
        ),
        TranscriptStep(
            "08-second-up.log",
            "TAPE_TRANSCRIPT_SECOND_UP_OK",
            (compose("up", "--detach", "--wait", "--wait-timeout", "300"),),
        ),
        TranscriptStep(
            "09-second-stats.log",
            "TAPE_TRANSCRIPT_SECOND_STATS_OK",
            (compose("stats", "--no-stream"),),
        ),
        TranscriptStep(
            "10-second-ps.log",
            "TAPE_TRANSCRIPT_SECOND_PS_OK",
            (compose("ps"),),
        ),
        TranscriptStep(
            "11-second-health.log",
            "TAPE_TRANSCRIPT_SECOND_HEALTH_OK",
            (nginx_health, alertmanager_health),
        ),
        TranscriptStep(
            "12-final-down.log",
            "TAPE_TRANSCRIPT_FINAL_DOWN_OK",
            (
                compose("down", "--volumes", "--remove-orphans"),
                compose("ps", "--all"),
            ),
        ),
    )


def rendered_command(compose_file: Path, command: Sequence[str]) -> str:
    if len(command) >= 3 and command[1:3] == ("system", "status"):
        return "container system status"
    if len(command) >= 3 and command[1:3] == ("compose", "version"):
        return "container compose version"
    if len(command) >= 2 and command[1] == "compose":
        return display_command(compose_file, command)
    if Path(command[0]).name == "curl":
        return display_curl_command(command)
    return " ".join(command)


def run_step(
    step: TranscriptStep,
    *,
    container: Path,
    compose_file: Path,
    working_directory: Path,
    output_directory: Path,
) -> None:
    transcript: list[str] = []
    environment = runtime_environment(container)
    for command in step.commands:
        completed = subprocess.run(
            command,
            cwd=working_directory,
            env=environment,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            check=False,
        )
        output = completed.stdout.rstrip()
        transcript.append(f"$ {rendered_command(compose_file, command)}")
        if output:
            transcript.append(output)
        if completed.returncode != 0:
            output_directory.joinpath(step.filename).write_text(
                "\n".join(transcript) + "\n",
                encoding="utf-8",
            )
            raise TranscriptFailure(
                f"{rendered_command(compose_file, command)} failed with exit {completed.returncode}"
            )
    transcript.append(step.marker)
    output_directory.joinpath(step.filename).write_text(
        "\n".join(transcript) + "\n",
        encoding="utf-8",
    )


def cleanup(container: Path, compose_file: Path, working_directory: Path) -> None:
    subprocess.run(
        compose_command(container, compose_file, "down", "--volumes", "--remove-orphans"),
        cwd=working_directory,
        env=runtime_environment(container),
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        check=False,
    )


def record(args: argparse.Namespace) -> None:
    container = args.container.resolve()
    compose_file = args.compose_file
    working_directory = args.working_directory.resolve()
    output_directory = args.output_directory.resolve()
    if not container.is_file():
        raise TranscriptFailure(f"container binary does not exist: {container}")
    compose_file_path = compose_file if compose_file.is_absolute() else working_directory / compose_file
    if not compose_file_path.is_file():
        raise TranscriptFailure(f"Compose file does not exist: {compose_file}")
    if not working_directory.is_dir():
        raise TranscriptFailure(f"working directory does not exist: {working_directory}")

    output_directory.mkdir(parents=True, exist_ok=True)
    try:
        # A Current-build recording must begin from an empty project so the
        # first `up` visibly creates and starts services. The recorded first
        # `down` deliberately keeps volumes, so the second `up` proves reuse.
        cleanup(container, compose_file, working_directory)
        for step in steps(container, compose_file):
            run_step(
                step,
                container=container,
                compose_file=compose_file,
                working_directory=working_directory,
                output_directory=output_directory,
            )
    except Exception:
        cleanup(container, compose_file, working_directory)
        raise


def main(argv: Sequence[str] | None = None) -> int:
    try:
        record(parse_args(argv))
    except TranscriptFailure as error:
        print(f"monitoring demo transcript failed: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
