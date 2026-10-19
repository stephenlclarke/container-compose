#!/usr/bin/env python3
# Copyright 2026 container-compose project authors. SPDX-License-Identifier: Apache-2.0
"""Offline tests for the Compose source companion inventory builder."""
from __future__ import annotations

import hashlib
import importlib.util
import io
import json
from pathlib import Path
import tarfile
import tempfile
import unittest

SCRIPT = Path(__file__).with_name("build_source_companion.py")
SPEC = importlib.util.spec_from_file_location("build_source_companion", SCRIPT)
assert SPEC is not None and SPEC.loader is not None
module = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(module)


def digest(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


class SourceCompanionTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.repo = self.root / "repo"
        self.repo.mkdir()
        self.execroot = self.root / "execroot" / "_main"
        self.external = self.execroot / "external"
        self.external.mkdir(parents=True)
        self.bin_dir = self.execroot / "bazel-out/darwin_arm64-opt/bin"
        self.bin_dir.mkdir(parents=True)
        self.output = self.root / "out"

        self.go_mod = self.repo / "Tools/compose-normalizer/go.mod"
        self.go_mod.parent.mkdir(parents=True)
        self.go_mod.write_text("module example.com/main\n\ngo 1.24.0\n\nrequire (\n\texample.com/go v1.0.0\n)\n")
        self.go_sum = self.repo / "Tools/compose-normalizer/go.sum"
        self.go_sum.write_text("example.com/go v1.0.0 h1:fixture\n")
        self.go_inventory_path = self.repo / "Tools/bazel/licenses/inventory.json"
        self.go_inventory_path.parent.mkdir(parents=True)
        self.go_inventory_path.write_text(json.dumps({"schemaVersion": 1, "modules": [
            {"module": "example.com/go", "version": "v1.0.0", "repo": "go_example",
             "notices": ["LICENSE"]}]}))
        self.vendor_inventory_path = self.repo / "Tools/bazel/licenses/vendored.json"
        self.vendor_inventory_path.write_text("{\"schemaVersion\":1,\"packages\":[]}\n")
        self.vendor_notice_path = self.repo / "Tools/bazel/licenses/sample.txt"
        self.vendor_notice_path.write_text("Vendor source notice fixture\n")
        (self.repo / "MODULE.bazel.lock").write_text("{\"lockFileVersion\":1}\n")

        self.swift_root = self.external / "+dependencies+swiftpkg_tldextractswift"
        self.go_root = self.external / "gazelle++go_deps+go_example"
        self.bazel_root = self.external / "protobuf+"
        for root in (self.swift_root, self.go_root, self.bazel_root):
            root.mkdir()
        self.swift_license = self.swift_root / "LICENSE"
        self.swift_license.write_text("MIT fixture license\n")
        self.psl_source = self.swift_root / "Sources/SPMPSL.swift"
        self.psl_source.parent.mkdir()
        self.psl_source.write_text("// exact pinned source fixture\n")
        self.psl_data = self.swift_root / "Resources/public_suffix_list_frozen.dat"
        self.psl_data.parent.mkdir()
        self.psl_data.write_text("fixture.example\n")
        (self.go_root / "LICENSE").write_text("Go license fixture\n")
        (self.go_root / "go.mod").write_text("module example.com/go\n")
        (self.bazel_root / "LICENSE").write_text("protobuf license fixture\n")

        source_sha = digest(self.psl_source.read_bytes())
        data_sha = digest(self.psl_data.read_bytes())
        license_sha = "a" * 64
        module.PSL_SOURCE_SHA = source_sha
        module.PSL_DATA_SHA = data_sha
        module.PSL_LICENSE_SHA = license_sha
        self.commit = "5a60352febdbd2db04216c65b9b60443b1bf5d39"
        self.lock = self.execroot / "Package.resolved"
        self.lock.write_text(json.dumps({"version": 3, "pins": [{
            "identity": "tldextractswift", "kind": "remoteSourceControl",
            "location": "https://example.invalid/tldextractswift.git",
            "state": {"revision": "5fb29b13f99b24401cd93c6c0c83faf7c23e9918"}}]}))

        self.license_inventory_path = self.bin_dir / "candidate_archive_metadata.licenses.json"
        self.license_inventory_path.write_text(json.dumps([{
            "dependencies": [
                {"license_text": "external/+dependencies+swiftpkg_tldextractswift/LICENSE"},
                {"license_text": "external/gazelle++go_deps+go_example/LICENSE",
                 "package_name": "example.com/go", "package_version": "v1.0.0"},
                {"license_text": "external/protobuf+/LICENSE"},
            ]}]))
        self.notice = b"MPL notice fixture\n"
        self.build_info = {"commit": self.commit, "lane": "candidate",
                           "containerSource": "example/container", "containerRef": "a" * 40,
                           "containerizationSource": "example/containerization",
                           "containerizationRef": "b" * 40}
        self.archive_path = self.bin_dir / "candidate_archive.tar.gz"
        with self.archive_path.open("wb") as raw:
            with __import__("gzip").GzipFile(fileobj=raw, filename="", mode="wb", mtime=0) as zipped:
                with tarfile.open(fileobj=zipped, mode="w") as tar:
                    for name, body in (("compose/resources/THIRD-PARTY-NOTICES.txt", self.notice),
                                       ("compose/resources/build-info.json", json.dumps(self.build_info).encode())):
                        info = tarfile.TarInfo(name)
                        info.size = len(body)
                        tar.addfile(info, io.BytesIO(body))
        archive_sha = digest(self.archive_path.read_bytes())
        self.identity = {
            "runtimeProfile": "enhanced", "commit": self.commit,
            "archiveSHA256": archive_sha,
            "dependencyLockSHA256": digest(self.lock.read_bytes()),
            "dependencyNoticesSHA256": digest(self.notice),
            "goModSHA256": digest(self.go_mod.read_bytes()),
            "goSumSHA256": digest(self.go_sum.read_bytes()),
            "goNoticeModules": 1, "swiftNoticePackages": 1,
            "sourceNoticeFragments": [{"component": "tldextractswift-psl",
                "packageRevision": "5fb29b13f99b24401cd93c6c0c83faf7c23e9918",
                "sourceRevision": "5fb29b13f99b24401cd93c6c0c83faf7c23e9918",
                "sourceFileSHA256": source_sha, "dataSHA256": data_sha,
                "licenseSHA256": license_sha}],
        }
        (self.bin_dir / "candidate_archive.json").write_text(json.dumps(self.identity))
        inputs = {"commit": self.commit, "profile": "enhanced",
                  "licenses": "bazel-out/darwin_arm64-opt/bin/candidate_archive_metadata.licenses.json",
                  "go_inventory": "Tools/bazel/licenses/inventory.json",
                  "vendor_inventory": "Tools/bazel/licenses/vendored.json",
                  "vendor_notices": ["Tools/bazel/licenses/sample.txt"],
                  "go_mod": "Tools/compose-normalizer/go.mod", "go_sum": "Tools/compose-normalizer/go.sum"}
        (self.bin_dir / "candidate_archive_metadata.inputs.json").write_text(json.dumps(inputs))

    def tearDown(self):
        self.temp.cleanup()

    def build(self, output=None):
        return module.build_companion(source_repo=self.repo, execroot=self.execroot,
                                      bin_dir=self.bin_dir, output=output or self.output)

    def test_full_pinned_roots_and_mpl_source_are_in_deterministic_companion(self):
        first = self.build()
        second_output = self.root / "second"
        second = self.build(second_output)
        self.assertEqual(first["sourceRoots"]["swift"], ["+dependencies+swiftpkg_tldextractswift"])
        self.assertEqual(first["sourceRoots"]["go"], ["gazelle++go_deps+go_example"])
        self.assertEqual(first["sourceRoots"]["bazel"], ["protobuf+"])
        self.assertEqual(first["companionSHA256"], second["companionSHA256"])
        with tarfile.open(self.output / "source-companion.tar.gz", "r:gz") as archive:
            names = set(archive.getnames())
        self.assertIn("sources/+dependencies+swiftpkg_tldextractswift/Sources/SPMPSL.swift", names)
        self.assertIn("sources/+dependencies+swiftpkg_tldextractswift/Resources/public_suffix_list_frozen.dat", names)
        self.assertIn("sources/gazelle++go_deps+go_example/LICENSE", names)
        self.assertIn("sources/protobuf+/LICENSE", names)
        evidence = json.loads((self.output / "technical-review-evidence.json").read_text())
        self.assertFalse(evidence["legalSufficiencyDetermined"])
        notice = (self.output / "SOURCE-LICENSES-AND-SOURCE-AVAILABILITY.md").read_text()
        self.assertIn("MPL-covered transformed Public Suffix List", notice)
        self.assertIn("Sources/SPMPSL.swift", notice)
        self.assertIn("public_suffix_list_frozen.dat", notice)
        self.assertIn(module.COMPOSE_SOURCE_URL, notice)
        self.assertIn(first["companionSHA256"], notice)
        self.assertIn(str(first["companionBytes"]), notice)
        nested = json.loads((self.output / "nested-legal-candidate-review.json").read_text())
        self.assertEqual(len(nested["candidates"]), evidence["unreviewedNestedLegalFileCandidateCount"])
        self.assertTrue(all("rawTextUTF8" in row and "sourceRootBinding" in row for row in nested["candidates"]))
        template = json.loads((self.output / "closure-review-template.json").read_text())
        self.assertIs(template["closureComplete"], False)
        self.assertEqual(template["bindings"]["runtimeProfile"], "enhanced")
        self.assertIsNone(template["bindings"]["compiledSdkChain"])

    def test_rejects_changed_mpl_source_even_when_notice_metadata_is_unchanged(self):
        self.psl_source.write_text("changed source\n")
        with self.assertRaisesRegex(module.CompanionError, "MPL-covered PSL source"):
            self.build()

    def test_rejects_missing_root_license_file_referenced_by_graph(self):
        (self.go_root / "LICENSE").unlink()
        with self.assertRaisesRegex(module.CompanionError, "license source is missing"):
            self.build()

    def test_rejects_profile_mismatch_and_go_inventory_drift(self):
        inputs_path = self.bin_dir / "candidate_archive_metadata.inputs.json"
        inputs = json.loads(inputs_path.read_text())
        inputs["profile"] = "stock"
        inputs_path.write_text(json.dumps(inputs))
        with self.assertRaisesRegex(module.CompanionError, "not the enhanced profile"):
            self.build()
        inputs["profile"] = "enhanced"
        inputs_path.write_text(json.dumps(inputs))
        self.go_mod.write_text("module example.com/main\n\ngo 1.24.0\n\nrequire (\n\texample.com/go v2.0.0\n)\n")
        with self.assertRaisesRegex(module.CompanionError, "Go notice inventory differs"):
            self.build()

    def test_rejects_swift_pin_substitution(self):
        pins = json.loads(self.lock.read_text())
        pins["pins"][0]["state"]["revision"] = "0" * 40
        self.lock.write_text(json.dumps(pins))
        with self.assertRaisesRegex(module.CompanionError, "Swift dependency lock differs"):
            self.build()


if __name__ == "__main__":
    unittest.main()
