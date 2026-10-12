#!/usr/bin/env python3
# Copyright 2026 container-compose project authors. SPDX-License-Identifier: Apache-2.0
"""Offline raw-product metadata regressions; no build/runtime qualification."""
import copy
import json
from pathlib import Path
import struct
import tempfile
import unittest
from unittest.mock import patch

import native_build_info as helper
from package import sha256


class NativeBuildInfoTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        actual = Path(__file__).resolve().parents[2]
        paths = {"Makefile": "COMPOSE_VERSION ?= 0.15.1\n",
                 "Package.resolved": '{"pins":[]}', ".bazelrc": "release", ".bazelversion": "8.8.0",
                 "Tools/compose-normalizer/go.mod": "github.com/compose-spec/compose-go/v2 v2.14.0\n",
                 "Tools/compose-normalizer/go.sum": "sum", "Sources/ComposePlugin/test.swift": "source",
                 "Tools/release/runtime-capabilities.json": '{"schemaVersion":1,"capabilities":["required"]}',
                 "Tools/release/write-build-info.py": (actual / "Tools/release/write-build-info.py").read_text()}
        for name, data in paths.items():
            path = self.root / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(data)
        self.before = {"commit": "4" * 40, "dirty": False,
                       "files": {name: {"sha256": sha256(self.root / name), "mode": 0o644} for name in paths}}
        self.current = {**copy.deepcopy(self.before), "commit": "e" * 40}
        self.product = self.root / "compose"
        self.product.write_bytes(struct.pack("<II", 0xFEEDFACF, 0x0100000C) + bytes(56))
        self.resolved = self.root / "native.json"
        self.resolved.write_text(json.dumps({"pins": [{"identity": name,
            "location": "https://github.com/stephenlclarke/" + name + ".git", "state": {"revision": ref}}
            for name, ref in (("container", "f" * 40), ("containerization", "5" * 40))]}))
        self.record = {"graph": "container-native", "consumerProfile": "enhanced", "verifierCommit": "f" * 40,
                       "resolved": str(self.resolved), "resolvedSHA256": sha256(self.resolved)}
        self.directory = self.root / "invocation"
        self.directory.mkdir()
        values = {"inputs-before.json": self.before, "inputs-after.json": self.before,
                  "native-admission.json": self.record, "events.json": {},
                  "owner.json": {"profile": "enhanced"},
                  "outcome.json": {"bazel_exit_code": 0, "validation_exit_code": 0}}
        for name, data in values.items():
            (self.directory / name).write_text(json.dumps(data))
        self.acceptance = {"passed": True, "compiledConsumerVerified": True, "buildConfigurationVerified": True,
                           "hostRestored": True, "failures": [], "productSHA256": sha256(self.product),
                           "source": self.before["commit"], "invocations": [{"path": str(self.directory),
                           "filesSHA256": {name: sha256(self.directory / name) for name in values}}]}
        self.path = self.root / "acceptance.json"
        self.source_mock = patch.object(helper, "source_identity", return_value=self.current).start()
        self.readmit = patch.object(helper, "readmit").start()
        self.addCleanup(patch.stopall)

    def generate(self):
        self.path.write_text(json.dumps(self.acceptance))
        return helper.generate(self.root, self.path, sha256(self.path), self.product)

    def replace_evidence(self, name, value):
        path = self.directory / name
        path.write_text(json.dumps(value))
        self.acceptance["invocations"][0]["filesSHA256"][name] = sha256(path)

    def test_native_refs_and_original_compiled_commit_survive_test_only_source_change(self):
        info, proof = self.generate()
        self.assertEqual(info["containerRef"], "f" * 40)
        self.assertEqual(info["containerizationRef"], "5" * 40)
        self.assertEqual(info["commit"], self.before["commit"])
        self.assertEqual(info["runtimeCapabilities"], ["required"])
        self.assertEqual(proof["metadataSource"], self.current["commit"])
        self.assertFalse(proof["releaseAuthority"])
        self.assertFalse(proof["runtimeQualified"])
        self.readmit.assert_called_once_with(self.root, self.record, self.root, ["--config=release"], "enhanced")

    def test_receipt_product_and_success_controls_fail_closed(self):
        self.generate()
        with self.assertRaisesRegex(ValueError, "receipt hash"):
            helper.generate(self.root, self.path, "0" * 64, self.product)
        for key, wrong in (("passed", False), ("compiledConsumerVerified", False),
                           ("buildConfigurationVerified", False), ("hostRestored", False),
                           ("failures", ["failed"]), ("productSHA256", "0" * 64)):
            original = self.acceptance[key]
            self.acceptance[key] = wrong
            with self.subTest(key=key), self.assertRaisesRegex(ValueError, "compiled acceptance"):
                self.generate()
            self.acceptance[key] = original
        self.current["dirty"] = True
        with self.assertRaisesRegex(ValueError, "clean source"):
            self.generate()

    def test_changed_invocation_inputs_or_lower_admission_fail(self):
        for name in ("events.json", "native-admission.json"):
            original = (self.directory / name).read_bytes()
            (self.directory / name).write_text("tampered")
            with self.subTest(name=name), self.assertRaisesRegex(ValueError, "evidence changed"):
                self.generate()
            (self.directory / name).write_bytes(original)
        self.readmit.side_effect = ValueError("lower proof mismatch")
        with self.assertRaisesRegex(ValueError, "lower proof mismatch"):
            self.generate()

    def test_wrong_source_profile_outcome_and_source_drift_fail(self):
        for name, value in (("inputs-before.json", {**self.before, "dirty": True}),
                            ("inputs-before.json", {**self.before, "commit": "9" * 40}),
                            ("owner.json", {"profile": "stock"}),
                            ("outcome.json", {"bazel_exit_code": 1, "validation_exit_code": 0})):
            original = json.loads((self.directory / name).read_bytes())
            self.replace_evidence(name, value)
            with self.subTest(name=name), self.assertRaises(ValueError):
                self.generate()
            self.replace_evidence(name, original)
        self.current["files"]["Sources/ComposePlugin/test.swift"] = {"sha256": "changed"}
        with self.assertRaisesRegex(ValueError, "inputs changed"):
            self.generate()
        self.current = copy.deepcopy(self.before)
        self.source_mock.side_effect = [self.current, {**self.current, "commit": "c" * 40}]
        with self.assertRaisesRegex(ValueError, "Source changed while"):
            self.generate()

    def test_command_writes_fresh_metadata_and_proof_without_overwrite(self):
        output = self.root / "build-info.json"
        arguments = ["native_build_info.py", "--source", str(self.root), "--acceptance", str(self.path),
                     "--acceptance-sha256", "a" * 64, "--product", str(self.product), "--output", str(output)]
        with patch("sys.argv", arguments), patch.object(helper, "generate", return_value=({"commit": "4" * 40}, {"releaseAuthority": False})):
            helper.main()
        self.assertEqual(json.loads(output.read_bytes())["commit"], "4" * 40)
        proof = json.loads(output.with_suffix(".proof.json").read_bytes())
        self.assertEqual(proof["buildInfoSHA256"], sha256(output))
        with patch("sys.argv", arguments), self.assertRaisesRegex(ValueError, "overwrite"):
            helper.main()

    def test_empty_or_mixed_admissions_fail(self):
        original = self.acceptance["invocations"]
        self.acceptance["invocations"] = []
        with self.assertRaisesRegex(ValueError, "one coherent"):
            self.generate()
        self.acceptance["invocations"] = original
        second = self.root / "second"
        second.mkdir()
        for path in self.directory.iterdir():
            (second / path.name).write_bytes(path.read_bytes())
        (second / "native-admission.json").write_text(json.dumps({**self.record, "graph": "wrong"}))
        self.acceptance["invocations"].append({"path": str(second), "filesSHA256": {
            path.name: sha256(path) for path in second.iterdir()}})
        with self.assertRaisesRegex(ValueError, "one coherent"):
            self.generate()


if __name__ == "__main__":
    unittest.main()
