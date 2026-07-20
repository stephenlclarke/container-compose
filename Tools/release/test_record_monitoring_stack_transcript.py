#!/usr/bin/env python3
##===----------------------------------------------------------------------===##
## Copyright © 2026 container-compose project authors.
##
## Licensed under the Apache License, Version 2.0 (the "License");
## you may not use this file except in compliance with the License.
## You may obtain a copy of the License at
## https://www.apache.org/licenses/LICENSE-2.0
##===----------------------------------------------------------------------===##

from __future__ import annotations

import importlib.util
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch


SCRIPT = Path(__file__).with_name("record_monitoring_stack_transcript.py")
SPEC = importlib.util.spec_from_file_location("record_monitoring_stack_transcript", SCRIPT)
assert SPEC is not None and SPEC.loader is not None
MODULE = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = MODULE
SPEC.loader.exec_module(MODULE)


class MonitoringStackTranscriptTests(unittest.TestCase):
    def test_successful_cycle_writes_all_marked_transcripts(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            container = root / "container"
            compose_file = root / "docker-compose.yaml"
            output = root / "transcript"
            container.touch()
            compose_file.write_text("services: {}\n", encoding="utf-8")
            args = MODULE.parse_args(
                [
                    "--container",
                    str(container),
                    "--compose-file",
                    str(compose_file),
                    "--working-directory",
                    str(root),
                    "--output-directory",
                    str(output),
                ]
            )
            completed = subprocess.CompletedProcess([], 0, "verified output\n")
            with patch.object(MODULE.shutil, "which", return_value="/usr/bin/curl"), patch.object(
                MODULE.subprocess, "run", return_value=completed
            ) as run:
                MODULE.record(args)

            transcript_files = sorted(output.glob("*.log"))
            self.assertEqual(len(transcript_files), 13)
            first_up = output / "02-first-up.log"
            self.assertIn("$ container compose -f", first_up.read_text(encoding="utf-8"))
            self.assertIn("TAPE_TRANSCRIPT_FIRST_UP_OK", first_up.read_text(encoding="utf-8"))
            self.assertIn(
                "$ container compose version",
                (output / "01-compose-version.log").read_text(encoding="utf-8"),
            )
            self.assertIn(
                "TAPE_TRANSCRIPT_FINAL_DOWN_OK",
                (output / "12-final-down.log").read_text(encoding="utf-8"),
            )
            self.assertEqual(run.call_count, 17)
            self.assertIn("down", run.call_args_list[0].args[0])
            self.assertEqual(
                run.call_args_list[0].kwargs["env"]["CONTAINER_COMPOSE_CONTAINER"],
                str(container.resolve()),
            )

    def test_failed_step_writes_output_and_cleans_up(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            container = root / "container"
            compose_file = root / "docker-compose.yaml"
            output = root / "transcript"
            container.touch()
            compose_file.write_text("services: {}\n", encoding="utf-8")
            args = MODULE.parse_args(
                [
                    "--container",
                    str(container),
                    "--compose-file",
                    str(compose_file),
                    "--working-directory",
                    str(root),
                    "--output-directory",
                    str(output),
                ]
            )
            failed = subprocess.CompletedProcess([], 17, "broken output\n")
            cleanup = subprocess.CompletedProcess([], 0, "")
            with patch.object(MODULE.shutil, "which", return_value="/usr/bin/curl"), patch.object(
                MODULE.subprocess, "run", side_effect=[cleanup, failed, cleanup]
            ) as run:
                with self.assertRaises(MODULE.TranscriptFailure):
                    MODULE.record(args)

            self.assertIn("broken output", (output / "00-system-status.log").read_text(encoding="utf-8"))
            self.assertEqual(run.call_count, 3)
            self.assertIn("down", run.call_args_list[0].args[0])
            self.assertIn("down", run.call_args_list[-1].args[0])

    def test_relative_compose_file_is_resolved_from_the_working_directory(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            container = root / "container"
            compose_file = root / "docker-compose.yaml"
            output = root / "transcript"
            container.touch()
            compose_file.write_text("services: {}\n", encoding="utf-8")
            args = MODULE.parse_args(
                [
                    "--container",
                    str(container),
                    "--compose-file",
                    compose_file.name,
                    "--working-directory",
                    str(root),
                    "--output-directory",
                    str(output),
                ]
            )
            completed = subprocess.CompletedProcess([], 0, "verified output\n")
            with patch.object(MODULE.shutil, "which", return_value="/usr/bin/curl"), patch.object(
                MODULE.subprocess, "run", return_value=completed
            ):
                MODULE.record(args)

            self.assertTrue((output / "12-final-down.log").is_file())

    def test_missing_curl_is_reported(self) -> None:
        with patch.object(MODULE.shutil, "which", return_value=None):
            with self.assertRaises(MODULE.TranscriptFailure):
                MODULE.steps(Path("/tmp/container"), Path("compose.yaml"))


if __name__ == "__main__":
    unittest.main()
