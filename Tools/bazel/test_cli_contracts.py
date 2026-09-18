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
import shlex
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
        self.coverage = None
        if os.environ.get("COVERAGE") == "1":
            self.coverage = Path(os.environ["COVERAGE_DIR"]).resolve(strict=True)
            self.assertIn(Path("/Volumes/SSD/cf/bazel"), self.coverage.parents,
                          "CLI coverage must remain within the enrolled SSD")

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
        environment = dict(self.environment)
        profile_prefix = f"{self.root.name}-{self.command_index}-"
        if self.coverage is not None:
            # Only the native profiling destination crosses the clean child
            # environment. Every invocation must emit its own nonempty profile;
            # a prior successful command cannot mask missing instrumentation.
            environment["LLVM_PROFILE_FILE"] = str(self.coverage / (profile_prefix + "%p-%m.profraw"))
        with stdout_path.open("x+b") as stdout, stderr_path.open("x+b") as stderr:
            self.cleanup_verified = False
            status = run(command, cwd=self.root, env=environment, stdout=stdout, stderr=stderr, timeout=30)
            self.cleanup_verified = True
            output = []
            for stream in (stdout, stderr):
                stream.seek(0)
                data = stream.read(1024**2 + 1)
                self.assertLessEqual(len(data), 1024**2, "CLI diagnostic output exceeds fixture bound")
                output.append(data.decode("utf-8"))
        if self.coverage is not None:
            profiles = list(self.coverage.glob(profile_prefix + "*.profraw"))
            self.assertTrue(profiles, "Native CLI emitted no coverage profile")
            self.assertTrue(all(path.is_file() and path.stat().st_size > 0 for path in profiles),
                            "Native CLI emitted an empty coverage profile")
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

    def plan(self, *arguments):
        output, _ = self.invoke("--dry-run", *arguments)
        return [shlex.split(line[2:]) for line in output.splitlines() if line.startswith("+ ")]

    def runtime_plan(self, *arguments):
        return [line[1:] for line in self.plan(*arguments) if line[0] == str(self.runtime)]

    def test_run_options_and_guest_payload_reach_distinct_plan_positions(self):
        payload = ["printf", "--help", "--dry-run", "--user", "guest", "two words", "--"]
        commands = self.runtime_plan("run", "--no-deps", "--rm", "-T", "--name", "contract-job",
                                     "--user", "1001:1002", "--workdir", "/work dir",
                                     "--env", "GREETING=hello world", "--label", "purpose=contract",
                                     "api", *payload)
        runs = [line for line in commands if line[0] == "run"]
        self.assertEqual(len(runs), 1, commands)
        run = runs[0]
        image_index = run.index("alpine:3.22")
        self.assertEqual(run[image_index + 1:], payload)
        options = run[:image_index]
        for flag, value in (("--name", "contract-job"), ("--user", "1001:1002"),
                            ("--workdir", "/work dir"), ("--env", "GREETING=hello world"),
                            ("--label", "purpose=contract")):
            self.assertTrue(any(options[index:index + 2] == [flag, value] for index in range(len(options))), options)
        self.assertIn("--rm", options)
        self.assertNotIn("--tty", options)
        self.assertFalse(any(line[0] in ("create", "start") for line in commands), commands)

    def test_exec_index_detach_and_guest_flags_reach_exact_plan(self):
        payload = ["printf", "--help", "--dry-run", "--env", "GUEST=value", "two words", "--"]
        commands = self.runtime_plan("exec", "--index", "2", "--detach", "-T", "--privileged",
                                     "--env", "OUTER=hello world", "--user", "1001", "--workdir", "/work dir",
                                     "api", *payload)
        self.assertEqual(commands, [["exec", "--detach", "--env", "OUTER=hello world", "--user", "1001",
                                     "--workdir", "/work dir", "--privileged", PROJECT + "-api-2", *payload]])

    def test_create_scale_includes_dependencies_without_starting(self):
        commands = self.runtime_plan("create", "--no-build", "--pull", "never", "--scale", "api=2", "api")
        creates = [line for line in commands if line[0] == "create"]
        names = [line[line.index("--name") + 1] for line in creates]
        self.assertEqual(names, [PROJECT + "-db-1", PROJECT + "-api-1", PROJECT + "-api-2"])
        self.assertFalse(any(line[0] in ("start", "run", "build") for line in commands), commands)

    def test_start_wait_plan_preserves_service_and_deadline(self):
        self.assertEqual(self.plan("start", "--wait", "--wait-timeout", "7", "api"), [
            [str(self.runtime), "start", PROJECT + "-api-1"],
            ["compose-runtime", "wait-ready", "--timeout", "7", PROJECT + "-api-1"],
        ])

    def test_stop_plan_uses_reverse_dependency_order_and_timeout(self):
        self.assertEqual(self.runtime_plan("stop", "--timeout", "7"), [
            ["stop", "--time", "7", PROJECT + "-api-1"],
            ["stop", "--time", "7", PROJECT + "-db-1"],
        ])

    def test_restart_no_deps_plan_is_limited_to_selected_service(self):
        self.assertEqual(self.runtime_plan("restart", "--no-deps", "--timeout", "4", "api"), [
            ["restart", "--time", "4", PROJECT + "-api-1"],
        ])

    def test_rm_stop_force_plan_stops_before_deleting_only_selected_service(self):
        self.assertEqual(self.runtime_plan("rm", "--stop", "--force", "api"), [
            ["stop", PROJECT + "-api-1"],
            ["delete", "--force", PROJECT + "-api-1"],
        ])

    def test_down_selected_service_does_not_remove_project_network(self):
        self.assertEqual(self.runtime_plan("down", "--timeout", "6", "api"), [
            ["stop", "--time", "6", PROJECT + "-api-1"],
            ["delete", PROJECT + "-api-1"],
        ])

    def test_logs_plan_preserves_replica_tail_and_time_bounds(self):
        self.assertEqual(self.plan("logs", "--follow", "--index", "2", "--tail", "5", "--timestamps",
                                   "--since", "2026-01-01T00:00:00Z", "--until", "2026-01-02T00:00:00Z", "api"), [
            ["compose-runtime", "logs", "--follow", "-n", "5", "--since", "2026-01-01T00:00:00Z",
             "--until", "2026-01-02T00:00:00Z", "--timestamps", PROJECT + "-api-2"],
        ])

    def test_kill_plan_limits_signal_to_selected_service(self):
        operations = self.plan("kill", "--signal", "TERM", "api")
        self.assertEqual([line for line in operations if line[0] == "compose-runtime"], [
            ["compose-runtime", "kill", "--signal", "TERM", PROJECT + "-api-1"],
        ])
        self.assertFalse(any("delete" in line or "stop" in line for line in operations), operations)

    def test_pause_plan_is_limited_to_selected_service(self):
        self.assertEqual(self.plan("pause", "api"), [["compose-runtime", "pause", PROJECT + "-api-1"]])

    def test_unpause_plan_is_limited_to_selected_service(self):
        self.assertEqual(self.plan("unpause", "api"), [["compose-runtime", "unpause", PROJECT + "-api-1"]])

    def test_wait_plan_does_not_implicitly_remove_project(self):
        self.assertEqual(self.plan("wait", "api"), [["compose-runtime", "wait", PROJECT + "-api-1"]])

    def test_copy_plan_preserves_path_spaces_and_replica_options(self):
        source = self.root / "input file"
        source.write_text("fixture\n")
        self.assertEqual(self.plan("cp", "--archive", "--follow-link", "--index", "2",
                                   str(source), "api:/target file"), [
            ["compose-runtime", "cp", "--archive", "--follow-link", str(source), PROJECT + "-api-2:/target file"],
        ])

    def test_port_dry_run_selects_protocol_and_static_host_binding(self):
        self.fixture.write_text("""services:
  api:
    image: alpine:3.22
    ports:
      - '127.0.0.1:8080:80/tcp'
      - '127.0.0.1:8081:80/udp'
""")
        output, _ = self.invoke("--dry-run", "port", "--protocol", "udp", "api", "80")
        self.assertEqual(output.strip(), "127.0.0.1:8081")

    def test_invalid_stop_timeout_fails_before_emitting_operations(self):
        output, error = self.invoke("--dry-run", "stop", "--timeout=-1", "api", expected_status=1)
        self.assertIn("stop --timeout must be between 0 and", error)
        self.assertFalse(any(line.startswith("+ ") for line in output.splitlines()), output)

    def test_build_plan_preserves_paths_and_cli_overrides(self):
        context = self.root / "build context"
        context.mkdir()
        (context / "Dockerfile.test").write_text("FROM scratch\n")
        self.fixture.write_text("""services:
  api:
    image: example.invalid/contract:local
    build:
      context: ./build context
      dockerfile: Dockerfile.test
      target: final
      args:
        BASE: configured
""")
        self.assertEqual(self.runtime_plan("build", "--no-cache", "--pull", "--quiet",
                                           "--build-arg", "OVERRIDE=two words", "api"), [[
            "build", "--tag", "example.invalid/contract:local", "--file", str(context / "Dockerfile.test"),
            "--target", "final", "--no-cache", "--pull", "--quiet", "--build-arg", "BASE=configured",
            "--build-arg", "OVERRIDE=two words", str(context),
        ]])

    def set_distinct_dependency_images(self):
        self.fixture.write_text("""services:
  api:
    image: example.invalid/api:local
    depends_on: [db]
  db:
    image: example.invalid/db:local
""")

    def test_pull_plan_includes_dependency_images_with_quiet_policy(self):
        self.set_distinct_dependency_images()
        self.assertEqual(self.runtime_plan("pull", "--include-deps", "--policy", "always", "--quiet", "api"), [
            ["image", "pull", "--progress", "none", "example.invalid/db:local"],
            ["image", "pull", "--progress", "none", "example.invalid/api:local"],
        ])

    def test_push_plan_includes_dependency_images(self):
        self.set_distinct_dependency_images()
        self.assertEqual(self.runtime_plan("push", "--include-deps", "--quiet", "api"), [
            ["image", "push", "example.invalid/db:local"],
            ["image", "push", "example.invalid/api:local"],
        ])

    def test_config_failure_is_not_silently_accepted(self):
        del self.environment["CONTRACT_VALUE"]
        _, error = self.invoke("config", "--format", "json", expected_status=1)
        self.assertIn("CONTRACT_VALUE", error)
        self.assertIn("required", error)

    def assert_payload_help_reaches_project_validation(self, command, help_flag):
        self.fixture.unlink()
        output, error = self.invoke("--dry-run", command, "api", "echo", help_flag, expected_status=1)
        self.assertIn(str(self.fixture), error)
        self.assertIn("no such file or directory", error.lower())
        self.assertNotIn("Usage:", output)

    def test_run_payload_long_help_reaches_project_validation(self):
        self.assert_payload_help_reaches_project_validation("run", "--help")

    def test_run_payload_short_help_reaches_project_validation(self):
        self.assert_payload_help_reaches_project_validation("run", "-h")

    def test_exec_payload_long_help_reaches_project_validation(self):
        self.assert_payload_help_reaches_project_validation("exec", "--help")

    def test_exec_payload_short_help_reaches_project_validation(self):
        self.assert_payload_help_reaches_project_validation("exec", "-h")

    def assert_command_help_does_not_load_project(self, command):
        self.fixture.unlink()
        output, _ = self.invoke(command, "--help")
        self.assertIn("Usage:", output)
        self.assertIn("compose " + command, output)

    def test_run_command_help_does_not_load_project(self):
        self.assert_command_help_does_not_load_project("run")

    def test_exec_command_help_does_not_load_project(self):
        self.assert_command_help_does_not_load_project("exec")

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
    raise SystemExit(0 if result.wasSuccessful() and result.testsRun == 31 else 1)
