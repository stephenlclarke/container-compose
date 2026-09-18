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

"""Native package input validation; no compiler, runtime, network or signing."""

import copy
import hashlib
import json
import os
from pathlib import Path
import struct
import subprocess
import sys
import tarfile
import tempfile
import unittest
import xml.etree.ElementTree as ET

from package import PRODUCTS, dependency, dependency_notices, metadata, receipt, sha256, validate_binary, write_json

WRITER = Path(sys.argv[1])
if len(sys.argv) == 3 and sys.argv[2] == "unit":
    ARCHIVE = None
elif len(sys.argv) == 4 and sys.argv[2] == "archive":
    ARCHIVE = Path(sys.argv[3])
else:
    raise SystemExit("Expected BUILD_INFO_HELPER unit|archive [ARCHIVE]")


class PackageTests(unittest.TestCase):
    def setUp(self) -> None:
        temporary = tempfile.TemporaryDirectory(dir=os.environ["TEST_TMPDIR"])
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.manifest = {"commit": "a" * 40, "profile": "stock", "binaries": {}}
        for name, platform in PRODUCTS.items():
            path = self.root / name
            if platform == "darwin-arm64":
                data = struct.pack("<II", 0xFEEDFACF, 0x0100000C) + bytes(56)
            else:
                data = bytearray(120)
                data[:7] = b"\x7fELF\x02\x01\x01"
                struct.pack_into("<HH", data, 16, 2, 183 if platform == "linux-arm64" else 62)
                struct.pack_into("<Q", data, 32, 64)
                struct.pack_into("<HH", data, 54, 56, 1)
                struct.pack_into("<I", data, 64, 1)
            path.write_bytes(data)
            self.manifest["binaries"][name] = str(path)
        pins = [{"identity": name, "location": "https://github.com/apple/" + name + ".git",
                 "state": {"revision": "b" * 40}} for name in ("container", "containerization")]
        contents = {
            "makefile": "COMPOSE_VERSION ?= 1.2.3\n",
            "resolved": json.dumps({"pins": pins}),
            "go_mod": "go 1.26.3\nrequire (\n github.com/compose-spec/compose-go/v2 v2.14.0\n)\n",
            "go_sum": "fixture",
            "capabilities": json.dumps({"schemaVersion": 2, "capabilities": ["one", "two"]}),
        }
        for key, value in contents.items():
            path = self.root / key
            path.write_text(value)
            self.manifest[key] = str(path)

    def test_stock_metadata_preserves_version_pins_and_all_products(self) -> None:
        info, identity = metadata(self.manifest, WRITER)
        self.assertEqual(info["version"], "1.2.3")
        self.assertEqual(info["containerSource"], "apple/container")
        self.assertEqual(info["containerRef"], "b" * 40)
        self.assertEqual(info["composeGoVersion"], "v2.14.0")
        self.assertEqual(info["runtimeCapabilities"], [])
        self.assertEqual(set(identity["products"]), set(PRODUCTS))
        self.assertFalse(identity["distributionReady"])
        self.assertFalse(identity["licenseClosureComplete"])
        self.assertEqual(identity["dependencyLockSHA256"], sha256(Path(self.manifest["resolved"])))

    def test_enhanced_metadata_reuses_capability_manifest_validation(self) -> None:
        self.manifest["profile"] = "enhanced"
        info, _ = metadata(self.manifest, WRITER)
        self.assertEqual(info["runtimeCapabilities"], ["one", "two"])
        self.assertEqual(info["runtimeCapabilitySchemaVersion"], 2)
        Path(self.manifest["capabilities"]).write_text('{"schemaVersion":1,"capabilities":["two","one"]}')
        with self.assertRaises(SystemExit):
            metadata(self.manifest, WRITER)

    def test_missing_products_and_unbound_identity_fail(self) -> None:
        for key, value in [("binaries", {}), ("commit", "HEAD"), ("profile", "invalid")]:
            changed = {**self.manifest, key: value}
            with self.subTest(key=key), self.assertRaises(ValueError):
                metadata(changed, WRITER)

    def test_missing_and_duplicate_versions_fail(self) -> None:
        for key in ("makefile", "go_mod"):
            path = Path(self.manifest[key])
            content = path.read_text()
            for invalid in ("", content * 2):
                path.write_text(invalid)
                with self.subTest(key=key, value=invalid), self.assertRaises(ValueError):
                    metadata(self.manifest, WRITER)
            path.write_text(content)

    def test_mutable_duplicate_and_nonapple_stock_dependencies_fail(self) -> None:
        pins = json.loads(Path(self.manifest["resolved"]).read_text())["pins"]
        for invalid in ([], pins + [pins[0]]):
            with self.assertRaises(ValueError):
                dependency(invalid, "container", "stock")
        for key, value in [("location", "https://github.com/another/container.git"),
                           ("location", "https://example.com/container.git"), ("state", {"revision": "main"})]:
            changed = copy.deepcopy(pins)
            changed[0][key] = value
            with self.assertRaises(ValueError):
                dependency(changed, "container", "stock")

    def test_wrong_binary_architecture_and_dynamic_guest_fail(self) -> None:
        for name, platform in PRODUCTS.items():
            path = Path(self.manifest["binaries"][name])
            original = path.read_bytes()
            path.write_bytes(b"not-executable")
            with self.subTest(name=name), self.assertRaises(ValueError):
                validate_binary(path, platform)
            path.write_bytes(original)
        path = Path(self.manifest["binaries"]["compose-volume-initializer-linux-arm64"])
        original = path.read_bytes()
        for field_offset, fmt, value in [(18, "<H", 62), (54, "<H", 1), (56, "<H", 0), (32, "<Q", 0), (64, "<I", 2), (64, "<I", 3)]:
            data = bytearray(original)
            struct.pack_into(fmt, data, field_offset, value)
            path.write_bytes(data)
            with self.assertRaises(ValueError):
                validate_binary(path, "linux-arm64")
        path.write_bytes(original[:70])
        with self.assertRaises(ValueError):
            validate_binary(path, "linux-arm64")

    def test_receipt_is_bound_to_exact_archive_bytes(self) -> None:
        _, identity = metadata(self.manifest, WRITER)
        archive = self.root / "candidate.tar.gz"
        archive.write_bytes(b"fixture-archive")
        first = receipt(archive, identity)
        self.assertEqual(first["archiveSHA256"], sha256(archive))
        self.assertEqual(first["archiveSize"], 15)
        self.assertFalse(first["distributionReady"])
        output = self.root / "nested/candidate.json"
        write_json(output, first)
        self.assertEqual(json.loads(output.read_text()), first)
        archive.write_bytes(b"changed")
        self.assertNotEqual(first["archiveSHA256"], receipt(archive, identity)["archiveSHA256"])

    def notice_fixture(self) -> list[dict]:
        inventory = self.root / "inventory.json"
        inventory.write_text(json.dumps({"schemaVersion": 1, "modules": [
            {"module": "github.com/compose-spec/compose-go/v2", "version": "v2.14.0", "notices": ["LICENSE", "NOTICE"]}]}))
        self.manifest["go_inventory"] = str(inventory)
        entries = []
        for name, version, directory, files in [
            ("github.com/compose-spec/compose-go/v2", "v2.14.0", "go_module", ["LICENSE", "NOTICE"]),
            ("", "", "swiftpkg_container", ["LICENSE"]),
            ("", "", "swiftpkg_containerization", ["LICENSE"]),
        ]:
            folder = self.root / directory
            folder.mkdir(exist_ok=True)
            for file in files:
                path = folder / file
                path.write_text(directory + " " + file + " source notice\n")
                entries.append({"package_name": name, "package_version": version, "license_text": str(path)})
        licenses = self.root / "licenses.json"
        licenses.write_text(json.dumps([{"licenses": entries}]))
        self.manifest["licenses"] = str(licenses)
        self.vendor_fixture()
        sdk = self.root / "sdk"
        sdk.mkdir(exist_ok=True)
        self.manifest["sdk_notices"] = []
        for name in ("LICENSE", "PATENTS"):
            path = sdk / name
            path.write_text("Go SDK " + name + "\n")
            self.manifest["sdk_notices"].append(str(path))
        return entries

    def vendor_fixture(self) -> None:
        rows = {}
        resolved = Path(self.manifest["resolved"])
        lock = json.loads(resolved.read_text())
        lock["pins"] = [pin for pin in lock["pins"] if pin["identity"] not in {"swift-crypto", "swift-nio-ssl"}]
        self.manifest["vendor_notices"] = []
        for identity, package_revision, revision in (("swift-crypto", "e" * 40, "1" * 40),
                                                       ("swift-nio-ssl", "f" * 40, "2" * 40)):
            repository = f"https://github.com/apple/{identity}.git"
            path = self.root / f"boringssl-{revision}.txt"
            path.write_text(identity + " vendored notice\n")
            self.manifest["vendor_notices"].append(str(path))
            rows[identity] = {"repository": repository, "packageRevisions": [package_revision],
                              "vendor": "BoringSSL", "revision": revision, "license": path.name,
                              "sourceURL": f"https://raw.githubusercontent.com/google/boringssl/{revision}/LICENSE",
                              "sha256": sha256(path)}
            lock["pins"].append({"identity": identity, "kind": "remoteSourceControl", "location": repository,
                                 "state": {"revision": package_revision}})
        resolved.write_text(json.dumps(lock))
        inventory = self.root / "vendor.json"
        inventory.write_text(json.dumps({"schemaVersion": 1, "packages": rows}))
        self.manifest["vendor_inventory"] = str(inventory)

    def test_notices_cover_locked_modules_and_sdk_deterministically(self) -> None:
        entries = self.notice_fixture()
        text, evidence = dependency_notices(self.manifest)
        self.assertIn("github.com/compose-spec/compose-go/v2@v2.14.0/NOTICE", text)
        self.assertIn("Swift/container/LICENSE", text)
        self.assertIn("Go SDK 1.26.3/PATENTS", text)
        self.assertNotIn(str(self.root), text)
        self.assertEqual(evidence["dependencyNoticesSHA256"], hashlib.sha256(text.encode()).hexdigest())
        self.assertEqual((evidence["goNoticeModules"], evidence["swiftNoticePackages"], evidence["noticeTexts"]), (1, 2, 8))
        self.assertEqual([row["package"] for row in evidence["vendoredNotices"]], ["swift-crypto", "swift-nio-ssl"])
        self.assertEqual(evidence["vendoredNotices"][0]["packageRevision"], "e" * 40)
        self.assertIn("Swift/swift_crypto/BoringSSL@" + "1" * 40 + "/LICENSE", text)
        Path(self.manifest["licenses"]).write_text(json.dumps([{"licenses": list(reversed(entries)) + entries}]))
        self.assertEqual(dependency_notices(self.manifest), (text, evidence))

    def test_notices_reject_missing_mismatched_and_unknown_inputs(self) -> None:
        original = self.notice_fixture()
        for entries in (original[1:], original[:-1], [{**original[0], "package_version": "v1.0.0"}] + original[1:],
                        [{**original[0], "package_name": "unrecognized"}] + original[1:]):
            Path(self.manifest["licenses"]).write_text(json.dumps([{"licenses": entries}]))
            with self.assertRaises(ValueError):
                dependency_notices(self.manifest)
        self.notice_fixture()
        Path(original[0]["license_text"]).write_text("")
        with self.assertRaises(ValueError):
            dependency_notices(self.manifest)
        self.notice_fixture()
        self.manifest["sdk_notices"].pop()
        with self.assertRaises(ValueError):
            dependency_notices(self.manifest)

    def test_notices_reject_inventory_drift_and_empty_sdk(self) -> None:
        self.notice_fixture()
        inventory = Path(self.manifest["go_inventory"])
        original = json.loads(inventory.read_text())
        for invalid in ({**original, "schemaVersion": 0}, {**original, "modules": []},
                        {**original, "modules": original["modules"] * 2},
                        {"schemaVersion": 1, "modules": [{**original["modules"][0], "notices": ["LICENSE"]}]}):
            inventory.write_text(json.dumps(invalid))
            with self.assertRaises(ValueError):
                dependency_notices(self.manifest)
        self.notice_fixture()
        Path(self.manifest["sdk_notices"][0]).write_text("")
        with self.assertRaises(ValueError):
            dependency_notices(self.manifest)

    def test_vendor_notices_reject_changed_missing_or_ambiguous_package(self) -> None:
        self.notice_fixture()
        resolved = Path(self.manifest["resolved"])
        original = json.loads(resolved.read_text())
        pin = original["pins"][-1]
        alternatives = [original["pins"][:-1], original["pins"] + [pin],
                        original["pins"][:-1] + [{**pin, "location": "https://example.invalid/other.git"}],
                        original["pins"][:-1] + [{**pin, "state": {"revision": "0" * 40}}]]
        for pins in alternatives:
            resolved.write_text(json.dumps({**original, "pins": pins}))
            with self.subTest(pins=pins), self.assertRaisesRegex(ValueError, "revision requires review"):
                dependency_notices(self.manifest)

    def test_vendor_notices_reject_missing_duplicate_or_modified_text(self) -> None:
        self.notice_fixture()
        files = self.manifest["vendor_notices"]
        for invalid in (files[:1], files + files[:1]):
            self.manifest["vendor_notices"] = invalid
            with self.assertRaisesRegex(ValueError, "notice inputs"):
                dependency_notices(self.manifest)
        self.manifest["vendor_notices"] = files
        for invalid in ("", "altered licence\n"):
            Path(files[0]).write_text(invalid)
            with self.assertRaisesRegex(ValueError, "reviewed upstream text"):
                dependency_notices(self.manifest)

    def test_vendor_notices_reject_stale_provenance_and_inventory(self) -> None:
        self.notice_fixture()
        path = Path(self.manifest["vendor_inventory"])
        original = json.loads(path.read_text())
        invalid_rows = [dict(original, schemaVersion=0), {**original, "packages": {}},
                        *[{**original, "packages": {**original["packages"], "swift-crypto":
                           {**original["packages"]["swift-crypto"], key: value}}}
                          for key, value in (("vendor", "other"), ("revision", "latest"),
                                             ("packageRevisions", "e" * 40), ("packageRevisions", []),
                                             ("packageRevisions", ["e" * 40, "e" * 40]),
                                             ("packageRevisions", ["latest"]), ("packageRevisions", [None]),
                                             ("sourceURL", "https://example.invalid/LICENSE"))]]
        for invalid in invalid_rows:
            path.write_text(json.dumps(invalid))
            with self.subTest(invalid=invalid), self.assertRaisesRegex(ValueError, "vendored notice"):
                dependency_notices(self.manifest)


class ArchiveTests(unittest.TestCase):
    def test_layout_modes_and_product_hashes(self) -> None:
        expected = {"compose/LICENSE", "compose/config.toml", "compose/resources/build-info.json",
                    "compose/resources/candidate.json", "compose/resources/container-compose-icon.png",
                    "compose/resources/THIRD-PARTY-NOTICES.txt",
                    "compose/bin/compose", "compose/resources/compose-normalizer",
                    "compose/resources/volume-initializer/compose-volume-initializer-linux-arm64",
                    "compose/resources/volume-initializer/compose-volume-initializer-linux-amd64"}
        with tarfile.open(ARCHIVE) as archive:
            files = [entry for entry in archive if not entry.isdir()]
            self.assertEqual(len(files), len(expected))
            self.assertEqual({entry.name for entry in files}, expected)
            identity = json.load(archive.extractfile("compose/resources/candidate.json"))
            info = json.load(archive.extractfile("compose/resources/build-info.json"))
            self.assertEqual(identity["commit"], info["commit"])
            self.assertEqual(identity["version"], info["version"])
            self.assertFalse(identity["distributionReady"])
            notices = archive.extractfile("compose/resources/THIRD-PARTY-NOTICES.txt").read()
            self.assertEqual(hashlib.sha256(notices).hexdigest(), identity["dependencyNoticesSHA256"])
            self.assertGreater(identity["goNoticeModules"], 0)
            self.assertIn(b"Swift/swift_crypto/NOTICE.txt", notices)
            self.assertIn(b"Swift/swift_nio_ssl/NOTICE.txt", notices)
            self.assertIn(b"Go SDK 1.26.3/PATENTS", notices)
            self.assertEqual({row["package"] for row in identity["vendoredNotices"]}, {"swift-crypto", "swift-nio-ssl"})
            for row in identity["vendoredNotices"]:
                label = "Swift/" + row["package"].replace("-", "_") + "/BoringSSL@" + row["vendorRevision"] + "/LICENSE"
                self.assertIn(label.encode(), notices)
                self.assertEqual(len(row["licenseSHA256"]), 64)
            self.assertFalse(identity["licenseClosureComplete"])
            for entry in files:
                self.assertTrue(entry.isfile())
                self.assertEqual((entry.uid, entry.gid, entry.mtime), (0, 0, 946684800))
                name = Path(entry.name).name
                self.assertEqual(entry.mode, 0o755 if name in PRODUCTS else 0o644)
                if name in PRODUCTS:
                    self.assertEqual(hashlib.sha256(archive.extractfile(entry).read()).hexdigest(), identity["products"][name])

    def test_installed_layout_version_and_bundled_parser_without_runtime(self) -> None:
        with tempfile.TemporaryDirectory(dir=os.environ["TEST_TMPDIR"]) as directory:
            root = Path(directory)
            with tarfile.open(ARCHIVE) as archive:
                # Only regular files/directories under the one declared root;
                # never let an archive supply links or an escaping path.
                for entry in archive:
                    parts = Path(entry.name).parts
                    self.assertTrue(parts and parts[0] == "compose" and ".." not in parts)
                    self.assertTrue(entry.isfile() or entry.isdir())
                    output = root / entry.name
                    if entry.isdir():
                        output.mkdir(parents=True, exist_ok=True)
                    else:
                        output.parent.mkdir(parents=True, exist_ok=True)
                        output.write_bytes(archive.extractfile(entry).read())
                        output.chmod(entry.mode)
            info = json.loads((root / "compose/resources/build-info.json").read_text())
            cli = root / "compose/bin/compose"
            # An installed package must not discover a developer checkout or
            # build a missing helper via the host's Go installation.
            environment = {"PATH": "/usr/bin:/bin", "HOME": str(root), "TMPDIR": str(root), "LANG": "en_US.UTF-8"}
            result = subprocess.run([str(cli), "version", "--short"], env=environment, cwd=root,
                                    capture_output=True, text=True, timeout=20, check=True)
            self.assertEqual(result.stdout.strip(), info["version"])
            fixture = root / "compose.yaml"
            fixture.write_text("name: native-package\nservices:\n  web:\n    image: alpine:3.22\n    command: ['echo', 'native-package']\n")
            result = subprocess.run([str(cli), "-f", str(fixture), "config", "--format", "json"],
                                    env=environment, cwd=root, capture_output=True, text=True, timeout=20, check=True)
            self.assertEqual(json.loads(result.stdout)["services"]["web"]["image"], "alpine:3.22")
            (root / "compose/resources/compose-normalizer").chmod(0o600)
            missing = subprocess.run([str(cli), "-f", str(fixture), "config", "--format", "json"],
                                     env=environment, cwd=root, capture_output=True, text=True, timeout=20)
            self.assertNotEqual(missing.returncode, 0, "A package must not silently bypass its missing native helper")


if __name__ == "__main__":
    suite = unittest.defaultTestLoader.loadTestsFromTestCase(ArchiveTests if ARCHIVE else PackageTests)
    cases = list(suite)
    result = unittest.TextTestRunner(verbosity=2).run(suite)
    root = ET.Element("testsuite", tests=str(result.testsRun), failures=str(len(result.failures)), errors=str(len(result.errors)))
    failures = {test.id(): trace for test, trace in result.failures + result.errors}
    for test in cases:
        element = ET.SubElement(root, "testcase", name=test.id())
        if test.id() in failures:
            ET.SubElement(element, "failure").text = failures.pop(test.id())
    for name, trace in failures.items():
        ET.SubElement(ET.SubElement(root, "testcase", name=name), "failure").text = trace
    ET.ElementTree(root).write(os.environ["XML_OUTPUT_FILE"], encoding="utf-8", xml_declaration=True)
    raise SystemExit(not result.wasSuccessful())
