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

import json
from pathlib import Path
import tempfile
import unittest

from verify_swiftpm_overrides import OVERRIDES, verify


class SwiftPMOverrideTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        self.paths = {name: self.root / name for name in OVERRIDES}
        for path in self.paths.values():
            path.mkdir()
        self.environment = {variable: str(self.paths[name])
                            for name, variable in OVERRIDES.items()}
        self.original = [self.pin(name) for name in
                         ("container", "containerization", "zstd", "swift-nio")]
        self.graph = {"name": "container-compose", "dependencies": [
            self.node(name) for name in OVERRIDES] +
            [{"name": "indirect", "dependencies": [self.node("containerization")]}]}

    @staticmethod
    def pin(name):
        return {"identity": name, "kind": "remoteSourceControl",
                "location": "https://example.invalid/" + name + ".git",
                "state": {"revision": "a" * 40}}

    def node(self, name):
        path = str(self.paths[name])
        return {"identity": name, "name": name, "url": path,
                "path": path, "version": "unspecified", "dependencies": []}

    def check(self, after=None, graph=None, profile="enhanced", before=None):
        before_path = self.root / "before.json"
        after_path = self.root / "after.json"
        graph_path = self.root / "graph.json"
        before_path.write_text(json.dumps({"pins": self.original if before is None else before}))
        after_path.write_text(json.dumps({"pins": self.original if after is None else after}))
        graph_path.write_text(json.dumps(self.graph if graph is None else graph))
        return verify(before_path, after_path, profile, graph_path,
                      self.environment)

    def test_local_sources_with_retained_remote_rows(self):
        result = self.check()
        self.assertEqual(result["retainedOverridePins"], sorted(OVERRIDES))
        self.assertEqual(result["localGraphOccurrences"]["containerization"], 2)

    def test_local_sources_with_removed_remote_rows(self):
        result = self.check(after=[self.pin("swift-nio")])
        self.assertEqual(result["removedOverridePins"], sorted(OVERRIDES))

    def test_stock_requires_every_original_pin(self):
        self.assertEqual(self.check(profile="stock")["retainedOverridePins"], [])
        with self.assertRaisesRegex(ValueError, "inventory"):
            self.check(after=[self.pin("swift-nio")], profile="stock")

    def test_duplicate_pin_identity_rejected(self):
        with self.assertRaisesRegex(ValueError, "Duplicate"):
            self.check(after=self.original + [self.pin("container")])
        with self.assertRaisesRegex(ValueError, "Duplicate"):
            self.check(before=self.original + [self.pin("container")])

    def test_retained_override_pin_mutation_rejected(self):
        changed = [dict(entry) for entry in self.original]
        changed[0] = {**changed[0], "state": {"revision": "b" * 40}}
        with self.assertRaisesRegex(ValueError, "changed a remote pin"):
            self.check(after=changed)

    def test_unrelated_pin_mutation_or_inventory_change_rejected(self):
        changed = [dict(entry) for entry in self.original]
        changed[-1] = {**changed[-1], "state": {"revision": "b" * 40}}
        with self.assertRaisesRegex(ValueError, "changed a remote pin"):
            self.check(after=changed)
        with self.assertRaisesRegex(ValueError, "inventory"):
            self.check(after=self.original[:-1])
        with self.assertRaisesRegex(ValueError, "inventory"):
            self.check(after=self.original + [self.pin("unexpected")])

    def test_wrong_local_path_or_identity_rejected(self):
        graph = json.loads(json.dumps(self.graph))
        graph["dependencies"][0]["path"] = "/tmp/wrong-container"
        with self.assertRaisesRegex(ValueError, "reviewed local container"):
            self.check(graph=graph)
        graph = json.loads(json.dumps(self.graph))
        graph["dependencies"][0]["identity"] = "different"
        with self.assertRaisesRegex(ValueError, "reviewed local container"):
            self.check(graph=graph)

    def test_remote_duplicate_or_missing_local_graph_rejected(self):
        graph = json.loads(json.dumps(self.graph))
        graph["dependencies"].append({"name": "container", "identity": "container",
                                     "url": "https://example.invalid/container.git",
                                     "path": "/tmp/remote", "version": "1.0"})
        with self.assertRaisesRegex(ValueError, "reviewed local container"):
            self.check(graph=graph)
        graph = json.loads(json.dumps(self.graph))
        graph["dependencies"].append({"name": "renamed", "identity": "container",
                                     "url": "https://example.invalid/container.git",
                                     "path": "/tmp/remote", "version": "1.0"})
        with self.assertRaisesRegex(ValueError, "reviewed local container"):
            self.check(graph=graph)
        graph = json.loads(json.dumps(self.graph))
        graph["dependencies"] = [node for node in graph["dependencies"]
                                 if node["name"] != "container"]
        with self.assertRaisesRegex(ValueError, "omitted"):
            self.check(graph=graph)

    def test_missing_override_path_rejected(self):
        self.environment["CONTAINER_PACKAGE_PATH"] = ""
        with self.assertRaisesRegex(ValueError, "Missing reviewed"):
            self.check()


if __name__ == "__main__":
    unittest.main()
