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

"""Focused release identity and source-mode qualification checks."""

import json
from pathlib import Path
import tempfile
import unittest

from layer_release import admitted_tests, release_target


class LayerReleaseTests(unittest.TestCase):
    def test_package_owned_release_targets_its_own_source(self) -> None:
        compose = "a" * 40
        package = "b" * 40
        manifest = {"group": "containerization", "packages": {
            "containerization": {"sourceCommit": package}}}
        self.assertEqual(release_target(manifest, compose), package)
        self.assertEqual(release_target({"group": "foundation"}, compose), compose)

    def test_qualification_rejects_wrong_profile_or_missing_opt(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory)
            before = {"commit": "a" * 40, "dirty": False, "files": {}}
            for name in ("inputs-before.json", "inputs-after.json"):
                (path / name).write_text(json.dumps(before))
            (path / "outcome.json").write_text(json.dumps({"bazel_exit_code": 0,
                                                            "validation_exit_code": 0}))
            commands = ["test", "--config=stock", "--config=release",
                        "--config=prebuilt-argument-parser"]
            events = [{"unstructuredCommandLine": {"args": commands}},
                      {"optionsParsed": {"cmdLine": ["--compilation_mode=opt"]}},
                      {"finished": {"overallSuccess": True, "exitCode": {"name": "SUCCESS"}}}]
            for label in ("//Tools/bazel:cli_smoke", "//Tools/bazel:cli_contracts"):
                events.append({"id": {"testSummary": {"label": label}},
                               "testSummary": {"overallStatus": "PASSED"}})
            (path / "events.json").write_text("\n".join(json.dumps(item) for item in events))
            with self.assertRaisesRegex(ValueError, "source-mode CLI"):
                admitted_tests(path, before, "foundation", "enhanced")
            commands[1] = "--config=enhanced"
            events[1]["optionsParsed"]["cmdLine"] = ["--compilation_mode=dbg"]
            (path / "events.json").write_text("\n".join(json.dumps(item) for item in events))
            with self.assertRaisesRegex(ValueError, "source-mode CLI"):
                admitted_tests(path, before, "foundation", "enhanced")
            events[1]["optionsParsed"]["cmdLine"] = ["--compilation_mode=opt"]
            (path / "events.json").write_text("\n".join(json.dumps(item) for item in events))
            self.assertEqual(len(admitted_tests(path, before, "foundation", "enhanced")["passedLabels"]), 2)


if __name__ == "__main__":
    unittest.main()
