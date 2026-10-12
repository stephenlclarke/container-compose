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

"""Offline configured-graph integrity tests; these do not qualify a native build."""

import copy
import hashlib
import json
from pathlib import Path
import tempfile
from types import SimpleNamespace
import unittest
from unittest import mock

from Tools.bazel.artifacts import native_graph as verifier


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


class GraphTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name).resolve()
        self.output = self.root / "output"
        (self.output / "external").mkdir(parents=True)
        self.inventory = {}
        self.graph = {key: [] for key in ("actions", "targets", "artifacts", "depSetOfFiles", "pathFragments")}
        self.graph["configuration"] = [{"id": "1", "checksum": "a" * 64, "mnemonic": "darwin_arm64-opt"}]
        self.graph["targets"].append({"id": "1", "label": "//:compose"})
        self.admission = {"expectedUnimportedPins": ["swift-http-types", "swift-http-structured-headers",
                                                  "swift-docc-plugin", "swift-docc-symbolkit"]}
        inputs = []
        for repository in sorted(verifier.REQUIRED_LINK_REPOSITORIES):
            selected = self.root / repository
            (selected / "binary").mkdir(parents=True)
            (selected / "BUILD.bazel").write_text("authenticated import macro\n")
            archive = selected / "binary/module.a"
            archive.write_bytes(repository.encode())
            self.inventory[repository] = {"root": str(selected), "files": {
                "BUILD.bazel": digest(selected / "BUILD.bazel"), "binary/module.a": digest(archive)}}
            (self.output / "external" / repository).symlink_to(selected, target_is_directory=True)
            inputs.append(self.artifact("external/" + repository + "/binary/module.a"))
        self.graph["depSetOfFiles"].append({"id": "1", "directArtifactIds": inputs})
        output = self.artifact("bazel-out/darwin_arm64-opt/bin/compose")
        self.graph["actions"].append({"targetId": "1", "mnemonic": "CppLink", "configurationId": "1",
                                      "inputDepSetIds": ["1"], "outputIds": [output]})
        self.path = self.root / "aquery.log"
        self.source = {"commit": "a" * 40, "dirty": False}
        patch = mock.patch.object(verifier, "source_identity", return_value=self.source)
        self.source_probe = patch.start()
        self.addCleanup(patch.stop)

    def artifact(self, path):
        parent = None
        for part in path.split("/"):
            identity = str(len(self.graph["pathFragments"]) + 1)
            row = {"id": identity, "label": part}
            if parent:
                row["parentId"] = parent
            self.graph["pathFragments"].append(row)
            parent = identity
        identity = str(len(self.graph["artifacts"]) + 1)
        self.graph["artifacts"].append({"id": identity, "pathFragmentId": parent})
        return identity

    def write(self, suffix="\nINFO: Build completed successfully, 0 total actions\n"):
        self.path.write_text(json.dumps(self.graph) + suffix)

    def verify(self):
        self.write()
        with mock.patch.object(verifier, "authenticated_packages", return_value=self.inventory):
            return verifier.verify_action_graph(self.path, self.admission, self.output, self.root, self.root)

    def test_authenticates_real_linked_files_without_claiming_build_equivalence(self):
        result = self.verify()
        self.assertEqual(len(result["archiveInputs"]), 3)
        self.assertEqual(set(result["loadedBUILD"]), verifier.REQUIRED_LINK_REPOSITORIES)
        self.assertEqual(result["aquerySHA256"], digest(self.path))
        self.assertEqual(result["links"][0]["configuration"], self.graph["configuration"][0])
        self.assertFalse(result["qualified"])
        self.assertFalse(result["buildConfigurationVerified"])

    def test_rejects_all_lower_implementation_actions_including_container(self):
        for repository in self.inventory:
            for mnemonic in ("SwiftCompile", "CppCompile", "SwiftCompileModule", "SwiftArchive"):
                with self.subTest(repository=repository, mnemonic=mnemonic):
                    self.graph["targets"] = [self.graph["targets"][0], {"id": "2", "label": "@@" + repository + "//:Module"}]
                    self.graph["actions"] = [self.graph["actions"][0], {"targetId": "2", "mnemonic": mnemonic}]
                    with self.assertRaisesRegex(ValueError, "implementation action"):
                        self.verify()
        self.graph["actions"][-1]["mnemonic"] = "FileWrite"
        self.assertEqual(len(self.verify()["links"]), 1)

    def test_rejects_unadmitted_package_and_alias_actions(self):
        for repository in ("+dependencies+swiftpkg_unknown", "+alternate+swiftpkg_container"):
            self.graph["targets"].append({"id": "2", "label": "@@" + repository + "//:Module"})
            self.graph["actions"].append({"targetId": "2", "mnemonic": "FileWrite"})
            with self.assertRaises(ValueError):
                self.verify()
            self.graph["targets"].pop()
            self.graph["actions"].pop()

    def test_unused_http_targets_or_artifacts_are_rejected(self):
        for package in verifier.UNUSED_HTTP:
            repository = "+dependencies+swiftpkg_" + package.replace("-", "_")
            with self.subTest(package=package):
                self.graph["targets"].append({"id": "2", "label": "@@" + repository + "//:Module"})
                with self.assertRaisesRegex(ValueError, "unused HTTP"):
                    self.verify()
                self.graph["targets"].pop()
                self.artifact("external/" + repository + "/metadata")
                with self.assertRaisesRegex(ValueError, "unused HTTP"):
                    self.verify()
                self.graph["artifacts"].pop()
        self.admission["expectedUnimportedPins"].append("another-package")
        with self.assertRaisesRegex(ValueError, "explicit review"):
            self.verify()

    def test_redirected_repository_or_modified_build_is_rejected(self):
        repository = next(iter(self.inventory))
        loaded = self.output / "external" / repository
        loaded.unlink()
        loaded.symlink_to(self.root)
        with self.assertRaisesRegex(ValueError, "redirected"):
            self.verify()
        loaded.unlink()
        loaded.symlink_to(self.inventory[repository]["root"])
        build = loaded / "BUILD.bazel"
        build.write_text("source fallback")
        with self.assertRaisesRegex(ValueError, "BUILD differs"):
            self.verify()

    def test_changed_missing_or_symlinked_archive_is_rejected(self):
        repository = next(iter(self.inventory))
        archive = Path(self.inventory[repository]["root"]) / "binary/module.a"
        archive.write_bytes(b"changed")
        with self.assertRaisesRegex(ValueError, "archive differs"):
            self.verify()
        archive.unlink()
        with self.assertRaisesRegex(ValueError, "archive differs"):
            self.verify()
        archive.symlink_to(self.path)
        with self.assertRaisesRegex(ValueError, "archive differs"):
            self.verify()

    def test_link_requires_published_archives_for_all_three_required_layers(self):
        for path in ("external/+alternate+swiftpkg_container/binary/module.a",
                     "bazel-out/darwin_arm64-opt/bin/external/+dependencies+swiftpkg_container/module.a",
                     "external/+dependencies+swiftpkg_unknown/binary/module.a"):
            with self.subTest(path=path):
                identity = self.artifact(path)
                self.graph["depSetOfFiles"][0]["directArtifactIds"].append(identity)
                with self.assertRaises(ValueError):
                    self.verify()
                self.graph["depSetOfFiles"][0]["directArtifactIds"].pop()
        self.graph["depSetOfFiles"][0]["directArtifactIds"].pop()
        with self.assertRaisesRegex(ValueError, "omits a required"):
            self.verify()

    def test_duplicate_or_missing_product_link_and_nonoptimized_output_fail(self):
        self.graph["actions"].append(copy.deepcopy(self.graph["actions"][0]))
        with self.assertRaisesRegex(ValueError, "exactly one"):
            self.verify()
        self.graph["actions"].pop()
        original = self.graph["actions"][0]["outputIds"]
        self.graph["actions"][0]["outputIds"] = [self.artifact("bazel-out/darwin_arm64-fastbuild/bin/compose")]
        with self.assertRaisesRegex(ValueError, "optimized"):
            self.verify()
        self.graph["actions"][0]["outputIds"] = original
        self.graph["actions"] = []
        with self.assertRaisesRegex(ValueError, "exactly one"):
            self.verify()

    def test_owned_absolute_output_and_confined_link_output_required(self):
        output = self.output
        self.output = Path("relative")
        with self.assertRaisesRegex(ValueError, "owned absolute"):
            self.verify()
        self.output = self.root / "link"
        self.output.symlink_to(output)
        with self.assertRaisesRegex(ValueError, "owned absolute"):
            self.verify()
        self.output = output
        (output / "execroot").mkdir()
        (output / "execroot/_main").symlink_to(self.root)
        with self.assertRaisesRegex(ValueError, "escapes"):
            self.verify()

    def test_dirty_or_changed_source_and_changed_graph_are_rejected(self):
        self.source["dirty"] = True
        with self.assertRaisesRegex(ValueError, "clean immutable"):
            self.verify()
        self.source["dirty"] = False
        self.source_probe.side_effect = [self.source, {**self.source, "commit": "b" * 40}]
        with self.assertRaisesRegex(ValueError, "changed during"):
            self.verify()
        self.source_probe.side_effect = None
        original = verifier._loaded
        def mutate(*args):
            self.path.write_text("changed graph")
            return original(*args)
        with mock.patch.object(verifier, "_loaded", side_effect=mutate):
            with self.assertRaisesRegex(ValueError, "changed during"):
                self.verify()

    def test_graph_parser_requires_actual_success_and_inventory(self):
        for text in ("not a graph", json.dumps(self.graph), json.dumps(self.graph) +
                     "\nINFO: Aquery did NOT complete successfully\n"):
            self.path.write_text(text)
            with self.assertRaises(ValueError):
                verifier._graph(self.path)
        self.path.write_text("INFO: metadata\n" + json.dumps(self.graph) + "\nINFO: Build completed successfully\n")
        self.assertEqual(verifier._graph(self.path), self.graph)
        del self.graph["configuration"]
        self.write()
        with self.assertRaisesRegex(ValueError, "inventory"):
            verifier._graph(self.path)

    def test_artifact_cycles_escapes_and_depset_cycles_rejected(self):
        for label in ("..", ".", "", "a/b"):
            self.graph["pathFragments"][0]["label"] = label
            with self.assertRaisesRegex(ValueError, "escapes"):
                self.verify()
        self.graph["pathFragments"][0]["label"] = "external"
        self.graph["pathFragments"][0]["parentId"] = "1"
        with self.assertRaisesRegex(ValueError, "cyclic"):
            self.verify()
        del self.graph["pathFragments"][0]["parentId"]
        self.graph["depSetOfFiles"][0]["transitiveDepSetIds"] = ["1"]
        with self.assertRaisesRegex(ValueError, "cyclic"):
            self.verify()
        self.graph["depSetOfFiles"][0]["transitiveDepSetIds"] = ["2"]
        self.graph["depSetOfFiles"].append({"id": "2", "transitiveDepSetIds": []})
        self.assertEqual(len(self.verify()["archiveInputs"]), 3)
        self.graph["depSetOfFiles"][0]["transitiveDepSetIds"] = ["2", "2"]
        self.assertEqual(len(self.verify()["archiveInputs"]), 3)
        self.graph["targets"].append(copy.deepcopy(self.graph["targets"][0]))
        with self.assertRaisesRegex(ValueError, "duplicate"):
            self.verify()


class PackageAuthenticationTests(unittest.TestCase):
    def setUp(self):
        self.groups = ("argument-parser", "foundation", "containerization", "engine-api", "container-sdk")
        self.admission = {"verifierRoot": "/verifier", "locksRoot": "/locks", "layers": {}, "overrides": {}}
        self.pairs = {}
        self.manifests = {}
        for group in self.groups:
            product = {"asset": "/" + group, "assetId": 1, "releaseId": 2}
            evidence, proof = {"assetId": 3}, {"assetId": 4}
            pair = {key: {"sha256": key * 8} for key in ("archive", "evidence", "proof")}
            pair["lockSHA256"] = "lock"
            self.pairs[group] = product, evidence, proof, pair
            self.admission["layers"][group] = {"archiveSHA256": pair["archive"]["sha256"],
                "evidenceSHA256": pair["evidence"]["sha256"], "proofSHA256": pair["proof"]["sha256"],
                "assetId": 1, "releaseId": 2, "evidenceAssetId": 3, "proofAssetId": 4, "lockSHA256": "lock"}
            repository = "swiftpkg_" + group.replace("-", "_")
            self.admission["overrides"]["+dependencies+" + repository] = "/selected/" + repository
            self.manifests["/" + group] = {"packages": {group: {"repository": repository}},
                                         "files": {group + "/" + repository + "/BUILD.bazel": "sha"}}
        self.admission["client"] = self.pairs["container-sdk"][3]
        self.layers = SimpleNamespace(__package__="pinned", _release_pair=lambda group, *args: self.pairs[group])
        self.format = SimpleNamespace(inspect=lambda path, sha: {"manifest": self.manifests[str(path)]})
        self.readmit = self.enter_context(mock.patch.object(verifier.native_consumer, "readmit"))
        self.enter_context(mock.patch.object(verifier.native_consumer, "load_verifier", return_value=(self.layers, None, None)))
        self.enter_context(mock.patch.object(verifier.importlib, "import_module", return_value=self.format))

    def enter_context(self, context):
        value = context.__enter__()
        self.addCleanup(context.__exit__, None, None, None)
        return value

    def authenticate(self):
        return verifier.authenticated_packages(self.admission, Path("/cache"), Path("/root"))

    def test_full_readmission_precedes_original_archive_manifest_inventory(self):
        inventory = self.authenticate()
        self.assertEqual(set(inventory), set(self.admission["overrides"]))
        self.assertEqual(inventory["+dependencies+swiftpkg_foundation"]["files"], {"BUILD.bazel": "sha"})
        self.readmit.assert_called_once_with(Path("/root"), self.admission, Path("/cache"), ["--config=release"], "enhanced")
        self.readmit.side_effect = ValueError("source or proof changed")
        with self.assertRaisesRegex(ValueError, "source or proof"):
            self.authenticate()

    def test_client_or_lower_release_drift_is_rejected(self):
        self.admission["client"] = {}
        with self.assertRaisesRegex(ValueError, "client release identity"):
            self.authenticate()
        self.admission["client"] = self.pairs["container-sdk"][3]
        self.admission["layers"]["foundation"]["lockSHA256"] = "changed"
        with self.assertRaisesRegex(ValueError, "lower release identity"):
            self.authenticate()

    def test_duplicate_unlisted_and_omitted_package_ownership_is_rejected(self):
        manifest = self.manifests["/foundation"]
        original = copy.deepcopy(manifest)
        manifest["packages"]["foundation"]["repository"] = "swiftpkg_argument_parser"
        with self.assertRaisesRegex(ValueError, "ownership"):
            self.authenticate()
        manifest["packages"]["foundation"]["repository"] = "swiftpkg_unknown"
        with self.assertRaisesRegex(ValueError, "ownership"):
            self.authenticate()
        self.manifests["/foundation"] = original
        self.admission["overrides"]["+dependencies+swiftpkg_missing"] = "/missing"
        with self.assertRaisesRegex(ValueError, "omits"):
            self.authenticate()


if __name__ == "__main__":
    unittest.main()
