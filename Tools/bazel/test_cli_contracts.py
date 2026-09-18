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

"""Native CLI/parser contracts: declared artifacts, no runtime or Go compiler."""

import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import time
import unittest
import xml.etree.ElementTree as ET

from cli_process import run, terminate_session


COMPOSE, NORMALIZER = (Path(item).resolve(strict=True) for item in sys.argv[1:])
PROJECT = "native-contract"


class CLIContracts(unittest.TestCase):
    def setUp(self):
        self.root = Path(tempfile.mkdtemp(dir=os.environ["TEST_TMPDIR"]))
        self.cleanup_verified = True
        self.command_index = 0
        self.addCleanup(self.remove_scratch)
        self.fixture = self.root / "compose.yaml"
        self.fixture.write_text("""services:
  api:
    image: alpine:3.22
    environment:
      CONTRACT_VALUE: ${CONTRACT_VALUE:?required}
    depends_on:
      db:
        condition: service_started
  db:
    image: alpine:3.22
""")
        self.marker = self.root / "runtime-invoked"
        self.runtime = self.root / "forbidden-runtime"
        self.runtime.write_text('#!/bin/sh\n: > "$HOME/runtime-invoked"\nexit 97\n')
        self.runtime.chmod(0o700)
        # A clean environment prevents source fallback, operator credentials,
        # runtime socket discovery and inherited test-enabling switches.
        self.environment = {"PATH": "/usr/bin:/bin", "HOME": str(self.root), "TMPDIR": str(self.root),
                            "LANG": "en_US.UTF-8", "CONTRACT_VALUE": "literal-value",
                            "CONTAINER_COMPOSE_NORMALIZER": str(NORMALIZER),
                            "CONTAINER_COMPOSE_CONTAINER": str(self.runtime), "CONTAINER_BIN": str(self.runtime)}

    def remove_scratch(self):
        if self.cleanup_verified:
            shutil.rmtree(self.root)

    def invoke(self, *arguments, expected_status=0):
        command = [str(COMPOSE), "--ansi", "never", "--project-name", PROJECT,
                   "--file", str(self.fixture), *arguments]
        self.command_index += 1
        # Named private logs survive exceptional returns with preserved scratch.
        # File-backed output keeps a broken child from exhausting host memory.
        stdout_path = self.root / f"command-{self.command_index}.stdout"
        stderr_path = self.root / f"command-{self.command_index}.stderr"
        with stdout_path.open("x+b") as stdout, stderr_path.open("x+b") as stderr:
            self.cleanup_verified = False
            status = run(command, cwd=self.root, env=self.environment, stdout=stdout, stderr=stderr, timeout=30)
            self.cleanup_verified = True
            output = []
            for stream in (stdout, stderr):
                stream.seek(0)
                data = stream.read(1024**2 + 1)
                self.assertLessEqual(len(data), 1024**2, "CLI diagnostic output exceeds fixture bound")
                output.append(data.decode("utf-8"))
        self.assertFalse(self.marker.exists(), "A no-runtime contract executed the container command")
        self.assertEqual(status, expected_status, output[1])
        return output[0], output[1]

    def test_foreground_dry_run_preserves_direct_attachment_contract(self):
        up, _ = self.invoke("--dry-run", "up", "--attach", "api", "--attach-dependencies", "api")
        attach, _ = self.invoke("--dry-run", "attach", "--no-stdin", "api")
        for service in ("db", "api"):
            name = PROJECT + "-" + service + "-1"
            self.assertIn(f"+ {self.runtime} create --name {name} ", up)
            self.assertIn(f"+ {self.runtime} start {name}", up)
            self.assertIn(f"+ compose-runtime attach --no-stdin {name}", up)
        self.assertNotIn("+ compose-runtime logs --follow", up)
        self.assertIn(f"+ compose-runtime attach --no-stdin {PROJECT}-api-1", attach)
        self.assertNotIn("+ compose-runtime logs --follow", attach)

    def test_config_uses_native_parser_and_interpolation(self):
        output, _ = self.invoke("config", "--format", "json")
        model = json.loads(output)
        self.assertEqual(model["name"], PROJECT)
        self.assertEqual(set(model["services"]), {"api", "db"})
        self.assertEqual(model["services"]["api"]["environment"]["CONTRACT_VALUE"], "literal-value")
        self.assertEqual(model["services"]["api"]["dependsOn"]["db"]["condition"], "service_started")

    def test_config_failure_is_not_silently_accepted(self):
        del self.environment["CONTRACT_VALUE"]
        _, error = self.invoke("config", "--format", "json", expected_status=1)
        self.assertIn("CONTRACT_VALUE", error)
        self.assertIn("required", error)

    def test_missing_declared_parser_cannot_fall_back_to_compilation(self):
        self.environment["CONTAINER_COMPOSE_NORMALIZER"] = str(self.root / "missing-parser")
        _, error = self.invoke("config", "--format", "json", expected_status=1)
        self.assertIn("No such file or directory", error)

    def test_timeout_removes_helper_in_separate_process_group(self):
        marker = self.root / "child-pid"
        script = ("import os,signal,sys; child=os.fork(); "
                  "os.setpgid(0,0) if child == 0 else None; "
                  "open(sys.argv[1],'w').write(str(os.getpid())) if child == 0 else None; "
                  "signal.pause()")
        unrelated = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(30)"], start_new_session=True)
        self.addCleanup(terminate_session, unrelated)
        self.cleanup_verified = False
        with self.assertRaises(subprocess.TimeoutExpired):
            run([sys.executable, "-c", script, str(marker)], cwd=self.root, env=self.environment,
                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=1)
        self.cleanup_verified = True
        self.assertTrue(marker.is_file(), "Fixture never established a distinct-group child")
        child_pid = int(marker.read_text())
        with self.assertRaises(ProcessLookupError):
            os.kill(child_pid, 0)
        self.assertIsNone(unrelated.poll(), "Cleanup touched an unrelated session")

    def test_nonzero_exit_reaps_its_isolated_session(self):
        status = run([sys.executable, "-c", "raise SystemExit(7)"], cwd=self.root, env=self.environment,
                     stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=5)
        self.assertEqual(status, 7)


class TimedResult(unittest.TextTestResult):
    def startTest(self, test):
        self.started = time.monotonic_ns()
        super().startTest(test)

    def stopTest(self, test):
        DURATIONS[test.id()] = (time.monotonic_ns() - self.started) / 1e9
        super().stopTest(test)


if __name__ == "__main__":
    DURATIONS = {}
    suite = unittest.defaultTestLoader.loadTestsFromTestCase(CLIContracts)
    cases = list(suite)
    result = unittest.TextTestRunner(verbosity=2, resultclass=TimedResult).run(suite)
    root = ET.Element("testsuite", name="native-cli-contracts", tests=str(result.testsRun),
                      failures=str(len(result.failures)), errors=str(len(result.errors)), skipped="0")
    failures = {test.id(): ("failure", trace) for test, trace in result.failures}
    failures.update({test.id(): ("error", trace) for test, trace in result.errors})
    for test in cases:
        element = ET.SubElement(root, "testcase", name=test.id(), time=str(DURATIONS.get(test.id(), 0)))
        if test.id() in failures:
            kind, trace = failures[test.id()]
            ET.SubElement(element, kind).text = trace
    ET.ElementTree(root).write(os.environ["XML_OUTPUT_FILE"], encoding="utf-8", xml_declaration=True)
    raise SystemExit(0 if result.wasSuccessful() and result.testsRun == 6 else 1)
