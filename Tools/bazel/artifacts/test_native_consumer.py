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

"""Offline admission regressions; no native build or release qualification."""

import copy
import hashlib
import json
import os
from pathlib import Path
import re
import sys
import tempfile
from types import SimpleNamespace
import unittest
from unittest import mock

from Tools.bazel.artifacts import native_consumer as consumer


class NativeConsumerTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.native = self.root / "native"
        self.native.mkdir()
        for root in (self.root, self.native):
            (root / ".bazelrc").write_text("build --macos_minimum_os=15.0\n")
            (root / ".bazelversion").write_text("8.8.0\n")
        self.commit = consumer.VERIFIER_COMMIT
        self.layers = SimpleNamespace(
            SHA=re.compile(r"[0-9a-f]{64}\Z"),
            lower_identity=lambda row: row,
            digest=lambda path: hashlib.sha256(path.read_bytes()).hexdigest())
        self.selected = {"container": {"identity": "container", "kind": "remoteSourceControl",
            "location": "https://github.com/stephenlclarke/container.git", "state": {"revision": self.commit}}}
        self.producer = SimpleNamespace(_group_source_pins=lambda *args: self.selected)
        self.admission = {"source": self.commit, "layers": {name: {"archiveSHA256": name} for name in
                          ("argument-parser", "foundation", "containerization", "engine-api")},
                          "toolchain": {"swift": "actual"}, "recipeSHA256": {"producer": "exact"}}
        binary = "container-sdk/swiftpkg_container/binary/"
        files = {binary + name + ".swiftmodule": "a" * 64 for name in ("ContainerAPIClient", "ContainerXPC")}
        self.manifest = {"group": "container-sdk", "graph": "container-native", "profile": "native",
            "configuration": "opt", "platform": "darwin-arm64", "developmentProof": False,
            "producerCommit": self.commit, "sourcePins": self.selected,
            "lower": copy.deepcopy(self.admission["layers"]), "recipeSHA256": self.admission["recipeSHA256"],
            "toolchain": self.admission["toolchain"], "files": files,
            "payloadOutputs": {name: "configured/" + name for name in files},
            "packages": {"container": {"sourceCommit": self.commit,
                "sourceLocation": self.selected["container"]["location"], "repository": "swiftpkg_container",
                "generatedBuildSHA256": "b" * 64}}}
        self.pair = {"archive": {"repository": "stephenlclarke/container",
            "asset": "container-sdk-native-darwin-arm64-opt.tar.gz", "targetCommit": self.commit,
            "sha256": "c" * 64}, "evidence": {"asset": "container-sdk-native-evidence.json"},
            "proof": {"asset": "container-sdk-native-proof.tar.gz", "sha256": "d" * 64}}
        self.sidecar = {key: copy.deepcopy(self.manifest[key]) for key in
                        ("group", "sourcePins", "lower", "recipeSHA256", "toolchain", "developmentProof")}
        self.sidecar.update(schema=1, source=self.commit, archiveSHA256="c" * 64, passed=True,
            manifestSHA256=hashlib.sha256((json.dumps(self.manifest, sort_keys=True,
                separators=(",", ":")) + "\n").encode()).hexdigest(),
            proofBundle=copy.deepcopy(self.pair["proof"]),
            qualification={"passed": True, "group": "container-sdk", "source": self.commit,
                           "requiredTargets": sorted(consumer.CLIENT_TESTS),
                           "invocations": [{"targets": sorted(consumer.CLIENT_TESTS),
                             "reports": [{"label": label, "executed": 1, "skipped": 0,
                                          "reportSHA256": {"test.xml": "e" * 64, "test.log": "f" * 64}}
                                         for label in sorted(consumer.CLIENT_TESTS)]}]},
            tests={label: "e" * 64 for label in consumer.CLIENT_TESTS},
            producerBuild={"files": {"configured/" + name: {"sha256": digest}
                                      for name, digest in files.items()}})

    def verify(self):
        consumer.verify_client(self.layers, self.producer, self.sidecar,
            self.manifest, self.pair, self.admission, {})

    def test_published_qualification_schema_has_authenticated_client_xpc_reports(self):
        observed = json.loads((Path(__file__).parent / "testdata/native-client-qualification.json").read_text())
        self.sidecar.update(observed)
        self.verify()
        label = "@swiftpkg_container//:ContainerXPCTests.rspm"
        report = next(row for invocation in self.sidecar["qualification"]["invocations"]
                      for row in invocation["reports"] if row["label"] == label)
        report["skipped"] = 1
        with self.assertRaisesRegex(ValueError, "authenticated client/XPC"):
            self.verify()
        report["skipped"] = 0
        self.sidecar["tests"][label] = "0" * 64
        with self.assertRaisesRegex(ValueError, "authenticated client/XPC"):
            self.verify()

    def test_native_python_guard_rejects_system_python_before_importing_verifier(self):
        with mock.patch.object(consumer.sys, "version_info", (3, 9, 6)), \
             mock.patch.object(consumer, "load_verifier") as imported:
            with self.assertRaisesRegex(ValueError, "Python >= 3.10"):
                consumer.admit(self.root, self.native, self.root, self.root, [], "enhanced")
            imported.assert_not_called()

    def test_explicit_options_require_complete_absolute_unique_paths_and_default_is_unchanged(self):
        selected, rest = consumer.options(["//:compose", "--config=release"])
        self.assertEqual(selected, {})
        self.assertEqual(rest, ["//:compose", "--config=release"])
        selected, rest = consumer.options(["--native-container-source=/source", "//:compose",
                                          "--native-layer-locks=/locks"])
        self.assertEqual(selected["--native-container-source"], Path("/source"))
        self.assertEqual(rest, ["//:compose"])
        for args in (["--native-container-source=relative", "--native-layer-locks=/locks"],
                     ["--native-container-source=/a/../b", "--native-layer-locks=/locks"],
                     ["--native-container-source=/a"], ["--native-container-source"],
                     ["--native-container-source=/a", "--native-container-source=/b",
                      "--native-layer-locks=/locks"]):
            with self.subTest(args=args), self.assertRaises(ValueError):
                consumer.options(args)

    def test_native_identity_remains_native_and_exact(self):
        self.verify()
        self.assertEqual(self.manifest["profile"], "native")

    def test_rejects_wrong_own_source_recipe_lower_toolchain_profile_and_configuration(self):
        for field, bad in (("producerCommit", "f" * 40), ("recipeSHA256", {}), ("lower", {}),
                           ("toolchain", {}), ("profile", "enhanced"), ("graph", "legacy"),
                           ("configuration", "dbg"), ("developmentProof", True), ("sourcePins", {})):
            with self.subTest(field=field):
                original = self.manifest[field]
                self.manifest[field] = bad
                with self.assertRaises(ValueError):
                    self.verify()
                self.manifest[field] = original

    def test_rejects_sidecar_or_proof_replacement(self):
        for field, bad in (("passed", False), ("source", "e" * 40), ("manifestSHA256", "f" * 64),
                           ("proofBundle", {}), ("archiveSHA256", "e" * 64)):
            with self.subTest(field=field):
                original = self.sidecar[field]
                self.sidecar[field] = bad
                with self.assertRaises(ValueError):
                    self.verify()
                self.sidecar[field] = original

    def test_rejects_missing_client_xpc_qualification_and_output_evidence(self):
        for field, bad in (("qualification", {"passed": True, "source": self.commit,
                                               "group": "container-sdk", "invocations": []}),
                           ("producerBuild", {"files": {}})):
            with self.subTest(field=field):
                original = self.sidecar[field]
                self.sidecar[field] = bad
                with self.assertRaises(ValueError):
                    self.verify()
                self.sidecar[field] = original

    def test_configuration_rejects_stock_nonrelease_minos_toolchain_and_override_flags(self):
        consumer.configuration(self.root, self.native, ["--config=release"], "enhanced")
        for flags, profile in (([], "enhanced"), (["--config=release"], "stock"),
                               (["--config=release", "--swiftcopt=-Ounchecked"], "enhanced"),
                               (["--config=release", "--config=prebuilt-container-sdk"], "enhanced")):
            with self.subTest(flags=flags, profile=profile), self.assertRaises(ValueError):
                consumer.configuration(self.root, self.native, flags, profile)
        (self.native / ".bazelrc").write_text("build --macos_minimum_os=16.0\n")
        with self.assertRaises(ValueError):
            consumer.configuration(self.root, self.native, ["--config=release"], "enhanced")
        (self.native / ".bazelrc").write_text("build --macos_minimum_os=15.0\n")
        (self.native / ".bazelversion").write_text("8.9.0\n")
        with self.assertRaises(ValueError):
            consumer.configuration(self.root, self.native, ["--config=release"], "enhanced")

    def test_verifier_rejects_dirty_or_wrong_commit_before_import(self):
        for state in ({"commit": self.commit, "dirty": True}, {"commit": "f" * 40, "dirty": False}):
            with mock.patch("Tools.bazel.input_identity.source_identity", return_value=state), \
                 mock.patch.object(consumer.importlib, "import_module") as imported:
                with self.assertRaises(ValueError):
                    consumer.load_verifier(self.native)
                imported.assert_not_called()

    def test_clean_reviewed_verifier_imports_only_its_bound_module_namespace(self):
        state = {"commit": self.commit, "dirty": False}
        original_cache = sys.pycache_prefix
        caches = []
        def imported_module(name):
            self.assertNotEqual(sys.pycache_prefix, original_cache)
            self.assertTrue(Path(sys.pycache_prefix).is_dir())
            caches.append(Path(sys.pycache_prefix))
            return "layers" if name.endswith("native_layers") else "producer"
        with mock.patch("Tools.bazel.input_identity.source_identity", return_value=state), \
             mock.patch.object(consumer.importlib, "import_module", side_effect=imported_module) as imported:
            self.assertEqual(consumer.load_verifier(self.native), ("layers", "producer", state))
            self.assertEqual(sys.pycache_prefix, original_cache)
            self.assertTrue(all(not path.exists() for path in caches))
            self.assertEqual(imported.call_args_list, [
                mock.call("_compose_native_" + self.commit + ".native_layers"),
                mock.call("_compose_native_" + self.commit + ".native_producer")])

    def test_configuration_rejects_ambiguous_minimum_os(self):
        (self.native / ".bazelrc").write_text("build --macos_minimum_os=15.0\nbuild --macos_minimum_os=16.0\n")
        with self.assertRaisesRegex(ValueError, "ambiguous"):
            consumer.configuration(self.root, self.native, ["--config=release"], "enhanced")

    def test_missing_compiled_client_and_wrong_package_owner_are_rejected(self):
        del self.manifest["files"]["container-sdk/swiftpkg_container/binary/ContainerXPC.swiftmodule"]
        # Authenticate the mutated fixture to exercise the subsequent inventory admission.
        self.manifest["payloadOutputs"] = {name: "configured/" + name for name in self.manifest["files"]}
        self.sidecar["manifestSHA256"] = hashlib.sha256((json.dumps(self.manifest, sort_keys=True,
            separators=(",", ":")) + "\n").encode()).hexdigest()
        with self.assertRaisesRegex(ValueError, "compiled client/XPC"):
            self.verify()
        self.manifest["files"]["container-sdk/swiftpkg_container/binary/ContainerXPC.swiftmodule"] = "a" * 64
        self.manifest["payloadOutputs"] = {name: "configured/" + name for name in self.manifest["files"]}
        self.manifest["packages"]["container"]["sourceLocation"] = "https://wrong-owner/container.git"
        self.sidecar["manifestSHA256"] = hashlib.sha256((json.dumps(self.manifest, sort_keys=True,
            separators=(",", ":")) + "\n").encode()).hexdigest()
        with self.assertRaisesRegex(ValueError, "package source identity"):
            self.verify()

    def test_client_extraction_must_materialize_exact_authenticated_inventory(self):
        def extract(archive, manifest, group, destination):
            package = destination / "swiftpkg_container"
            package.mkdir(parents=True)
            build = package / "BUILD.bazel"
            build.write_bytes(b"authentic")
            build.chmod(0o644)
        self.layers._safe_extract = mock.Mock(side_effect=extract)
        self.layers._private_cache = lambda path: None
        manifest = {"files": {"container-sdk/swiftpkg_container/BUILD.bazel": hashlib.sha256(b"authentic").hexdigest()}}
        package = consumer.cached_client(self.layers, self.root / "archive", manifest, self.root / "cache", "a" * 64)
        self.assertEqual((package / "BUILD.bazel").read_bytes(), b"authentic")
        self.layers._safe_extract.assert_called_once()
        os.mkfifo(package / "not-an-artifact")
        with self.assertRaisesRegex(ValueError, "unexpected file type"):
            consumer.cached_client(self.layers, self.root / "archive", manifest, self.root / "cache", "a" * 64)

    def test_coherent_vector_replaces_all_shared_pins_adds_native_dependencies_preserves_compose_only(self):
        def pin(name, revision):
            return {"identity": name, "kind": "remoteSourceControl", "location": "https://example/" + name,
                    "state": {"revision": revision}}
        original = {"pins": [pin("swift-nio-ssl", "a" * 40), pin("compose-only", "b" * 40)]}
        path = self.root / "Package.resolved"
        path.write_text(json.dumps(original))
        native = {name: pin(name, "c" * 40) for name in ("swift-nio-ssl", "new-transitive")}
        result = consumer.coherent_pins(self.root, native, self.commit)
        rows = {row["identity"]: row for row in result["pins"]}
        self.assertEqual(rows["swift-nio-ssl"], native["swift-nio-ssl"])
        self.assertEqual(rows["new-transitive"], native["new-transitive"])
        self.assertEqual(rows["compose-only"], original["pins"][1])
        self.assertEqual(rows["container"]["state"]["revision"], self.commit)
        self.assertEqual(json.loads(path.read_text()), original)
        native["swift-nio-ssl"]["state"]["revision"] = "main"
        with self.assertRaises(ValueError):
            consumer.coherent_pins(self.root, native, self.commit)

    def test_cached_client_rehashes_exact_inventory_permissions_and_rejects_symlinks(self):
        destination = self.root / "cache/container-sdk" / ("a" * 64) / "packages"
        package = destination / "swiftpkg_container"
        package.mkdir(parents=True)
        build = package / "BUILD.bazel"
        build.write_bytes(b"authentic")
        build.chmod(0o644)
        self.layers._private_cache = lambda path: None
        manifest = {"files": {"container-sdk/swiftpkg_container/BUILD.bazel": self.layers.digest(build)}}
        result = consumer.cached_client(self.layers, self.root / "unused", manifest, self.root / "cache", "a" * 64)
        self.assertEqual(result, package)
        build.write_bytes(b"tampered")
        with self.assertRaises(ValueError):
            consumer.cached_client(self.layers, self.root / "unused", manifest, self.root / "cache", "a" * 64)
        build.write_bytes(b"authentic")
        build.chmod(0o755)
        with self.assertRaises(ValueError):
            consumer.cached_client(self.layers, self.root / "unused", manifest, self.root / "cache", "a" * 64)
        build.chmod(0o644)
        (package / "extra").symlink_to(build)
        with self.assertRaises(ValueError):
            consumer.cached_client(self.layers, self.root / "unused", manifest, self.root / "cache", "a" * 64)

    def test_admission_requires_portable_replay_before_exposing_override_paths(self):
        (self.root / "Package.resolved").write_text(json.dumps({"pins": []}))
        evidence = self.root / "evidence.json"
        evidence.write_text(json.dumps(self.sidecar))
        client = self.root / "verified-client"
        client.mkdir()
        self.admission["overrides"] = {}
        self.admission["expectedUnimportedPins"] = []
        self.layers.import_layers = mock.Mock(return_value=self.admission)
        self.layers.toolchain = lambda root: self.admission["toolchain"]
        self.layers.pin_records = lambda root: {}
        self.layers.repo_name = lambda name: "swiftpkg_" + name.replace("-", "_")
        self.layers._release_pair = lambda *args: (
            {"asset": str(self.root / "archive")}, {"asset": str(evidence)},
            {"asset": str(self.root / "proof")}, self.pair)
        self.layers.__package__ = "pinned_verifier"
        self.producer.verify_proof_bundle = mock.Mock(return_value={"passed": True, "authenticatedCacheReuse": True})
        state = {"commit": self.commit, "dirty": False}
        with mock.patch.object(consumer, "load_verifier", return_value=(self.layers, self.producer, state)), \
             mock.patch.object(consumer.importlib, "import_module", return_value=SimpleNamespace(
                 inspect=lambda *args: {"manifest": self.manifest})), \
             mock.patch.object(consumer, "cached_client", return_value=client) as cached:
            record = consumer.admit(self.root, self.native, self.root, self.root, ["--config=release"], "enhanced")
            self.producer.verify_proof_bundle.assert_called_once_with(self.root / "proof", self.sidecar)
            self.assertFalse(record["compiledConsumerVerified"])
            self.assertEqual(record["graph"], "container-native")
            self.assertEqual(record["consumerProfile"], "enhanced")
            self.assertEqual(record["overrides"]["+dependencies+swiftpkg_container"], str(client.resolve()))
            cached.reset_mock()
            resolved = Path(record["resolved"])
            resolved_bytes = resolved.read_bytes()
            resolved.write_bytes(b"changed")
            with self.assertRaisesRegex(ValueError, "resolved vector cache changed"):
                consumer.admit(self.root, self.native, self.root, self.root, ["--config=release"], "enhanced")
            resolved.write_bytes(resolved_bytes)
            (self.root / "Package.resolved").write_text(json.dumps({"pins": [{"identity": "unlisted"}]}))
            with self.assertRaisesRegex(ValueError, "lacks compiled packages"):
                consumer.admit(self.root, self.native, self.root, self.root, ["--config=release"], "enhanced")
            (self.root / "Package.resolved").write_text(json.dumps({"pins": []}))
            self.layers.toolchain = lambda root: {"swift": "wrong"}
            with self.assertRaisesRegex(ValueError, "toolchain differs"):
                consumer.admit(self.root, self.native, self.root, self.root, ["--config=release"], "enhanced")
            self.layers.toolchain = lambda root: self.admission["toolchain"]
            cached.reset_mock()
            self.producer.verify_proof_bundle.side_effect = ValueError("unauthenticated cached/skipped test proof")
            with self.assertRaisesRegex(ValueError, "unauthenticated cached/skipped"):
                consumer.admit(self.root, self.native, self.root, self.root, ["--config=release"], "enhanced")
            cached.assert_not_called()

    def test_readmission_refuses_changed_cached_or_source_proof(self):
        record = {"verifierRoot": str(self.native), "locksRoot": str(self.root), "layers": "before"}
        with mock.patch.object(consumer, "admit", return_value={**record, "layers": "after"}):
            with self.assertRaises(ValueError):
                consumer.readmit(self.root, record, self.root, [], "enhanced")


if __name__ == "__main__":
    unittest.main()
