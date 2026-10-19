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

"""No-runtime checks for bounded DNS/Links fixtures and failed timing retention."""

from pathlib import Path
import re
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parent
SCRIPTS = {
    "network-service-discovery": ("api", "worker", "fixed", "client", "isolated", "job"),
    "links": ("pool", "linked", "peer", "external-client", "moving", "watcher"),
}


class NetworkParityFixtureTests(unittest.TestCase):
    def shell(self, name, code, *arguments):
        return subprocess.run(
            ["/bin/bash", "-c", 'source "$1"; shift; ' + code,
             "fixture-test", str(ROOT / f"check-compose-{name}.sh"), *map(str, arguments)],
            env={"PATH": "/usr/bin:/bin", "CONTAINER_COMPOSE_LIVE": "0"},
            text=True, capture_output=True, timeout=10,
        )

    def test_generated_lane_fixtures_bound_every_service(self):
        with tempfile.TemporaryDirectory() as temporary:
            for name, expected in SCRIPTS.items():
                for lane, subnet in (("docker", "10.241.50"), ("candidate", "10.242.50")):
                    with self.subTest(script=name, lane=lane):
                        fixture = Path(temporary) / f"{name}-{lane}.yml"
                        result = self.shell(name, 'write_fixture "$1" "$2" "$3"',
                                            fixture, subnet, "owned-external")
                        self.assertEqual(result.returncode, 0, result.stderr)
                        services = fixture.read_text().split("\nnetworks:", 1)[0]
                        records = re.findall(r"^  ([a-z-]+):\n(.*?)(?=^  [a-z-]+:|\Z)",
                                             services, re.M | re.S)
                        self.assertEqual(tuple(service for service, _ in records), expected)
                        for service, body in records:
                            self.assertEqual(re.findall(r"^    mem_limit: (.+)$", body, re.M),
                                             ["256m"], service)

    def cleanup_case(self, name, directory, report, status):
        fixture = directory / "fixture"
        fixture.mkdir()
        timing = fixture / "timings.tsv"
        timing.write_text("candidate\tstartup\t1\t0.125\n")
        result = self.shell(name, r'''FIXTURE_DIR="$1"; TIMING_FILE="$1/timings.tsv";
PARITY_TIMING_OUTPUT="$2"; docker() { return 0; };
trap cleanup EXIT; exit "$3"''', fixture, report, status)
        return result, fixture, timing

    def test_failure_retains_partial_samples_and_original_exit(self):
        for name in SCRIPTS:
            with self.subTest(script=name), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                report = root / "retained/timing.tsv"
                result, fixture, _ = self.cleanup_case(name, root, report, 42)
                self.assertEqual(result.returncode, 42, result.stderr)
                self.assertEqual(report.read_text(), "candidate\tstartup\t1\t0.125\n")
                self.assertFalse(fixture.exists())

    def test_different_report_is_preserved_with_raw_source(self):
        for name in SCRIPTS:
            for status in (0, 42):
                with self.subTest(script=name, status=status), tempfile.TemporaryDirectory() as temporary:
                    root = Path(temporary)
                    report = root / "timing.tsv"
                    report.write_text("earlier retained report\n")
                    result, _, timing = self.cleanup_case(name, root, report, status)
                    self.assertEqual(result.returncode, status or 1, result.stderr)
                    self.assertEqual(report.read_text(), "earlier retained report\n")
                    self.assertEqual(timing.read_text(), "candidate\tstartup\t1\t0.125\n")

    def test_matching_completed_report_allows_normal_cleanup(self):
        for name in SCRIPTS:
            with self.subTest(script=name), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                report = root / "timing.tsv"
                report.write_text("candidate\tstartup\t1\t0.125\n")
                result, fixture, _ = self.cleanup_case(name, root, report, 0)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertFalse(fixture.exists())

    def test_symlink_report_is_never_followed_or_overwritten(self):
        for name in SCRIPTS:
            with self.subTest(script=name), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                report = root / "timing.tsv"
                other = root / "other.tsv"
                other.write_text("unrelated report\n")
                report.symlink_to(other)
                result, _, timing = self.cleanup_case(name, root, report, 42)
                self.assertEqual(result.returncode, 42, result.stderr)
                self.assertEqual(other.read_text(), "unrelated report\n")
                self.assertTrue(report.is_symlink())
                self.assertTrue(timing.exists())


if __name__ == "__main__":
    unittest.main()
