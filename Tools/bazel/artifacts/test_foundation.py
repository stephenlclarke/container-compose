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

"""Focused sealing and no-source-fallback checks for the foundation layer."""

import json
from pathlib import Path
import tempfile
import unittest
from unittest import mock

import foundation
from foundation import (archive_bytes, compiled_c_header_sources, digest, group_pins,
                        header_only_c_targets, inspect, package_overlay,
                        recipe_identity, transformed_build)


BUILD = '''load("@build_bazel_rules_swift//swift:swift.bzl", "swift_library", "swift_library_group")
load("@rules_cc//cc:defs.bzl", "cc_library")
swift_library(
    name = "Logging.rspm.__impl",
    module_name = "Logging",
    srcs = ["Sources/Logging.swift"],
)
cc_library(
    name = "CThing.rspm_c",
    srcs = ["Sources/thing.c", "Sources/thing.h"],
    textual_hdrs = ["Sources/Shims.c"],
)
cc_library(
    name = "HeaderOnly",
    hdrs = ["Sources/thing.h"],
)
cc_library(
    name = "InactiveC",
    srcs = ["Sources/thing.c"],
)
'''


class FoundationTests(unittest.TestCase):
    def q_only_documents(self, original: Path) -> tuple[bytes, bytes]:
        pins = foundation.source_pins(original)
        q = pins['container'].encode()
        containerization = pins['containerization'].encode()
        old_containerization = b'5ed9bc7490aa30c76337bd5b3d8ff251b63c678f'
        self.assertIn(containerization, (old_containerization,
                                         b'6db16197bbad8196a78132f86529daa89125aafb'))
        documents = []
        for name in ('Package.swift', 'Package.resolved'):
            document = (original / name).read_bytes()
            self.assertEqual(document.count(q), 1)
            self.assertEqual(document.count(containerization), 1)
            documents.append(document.replace(q, b'a' * 40).replace(containerization,
                                                                    old_containerization))
        return documents[0], documents[1]

    def test_published_lower_layers_accept_only_the_exact_container_pin_substitution(self) -> None:
        original = Path(__file__).resolve().parents[3]
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            producer = root / 'Tools/bazel/artifacts/foundation.py'
            producer.parent.mkdir(parents=True)
            producer.write_bytes(Path(foundation.__file__).read_bytes())
            manifest, resolved = self.q_only_documents(original)
            (root / 'Package.swift').write_bytes(manifest)
            (root / 'Package.resolved').write_bytes(resolved)
            locks = original / 'Tools/bazel/artifacts/layer-locks'
            old_c = json.loads((locks / 'engine-api-enhanced.json').read_text())
            old_c['recipeSHA256']['containerizationPatch'] = foundation.file_digest(
                original / 'Tools/bazel/containerization-ext4-unaligned.patch')
            for profile, groups in (('enhanced', ('foundation', 'engine-api')),
                                    ('stock', ('foundation', 'containerization', 'engine-api', 'container-sdk'))):
                for group in groups:
                    lock = json.loads((locks / f'{group}-{profile}.json').read_text())
                    current = dict(lock['recipeSHA256'], producer=foundation.file_digest(producer),
                                   swiftPackageManifest=foundation.file_digest(root / 'Package.swift'))
                    self.assertTrue(foundation._legacy_recipe_compatible(lock, root, profile, group, current),
                                    f'{group}-{profile}')
                    drifted = dict(current, rootBuild='0' * 64)
                    self.assertFalse(foundation._legacy_recipe_compatible(lock, root, profile, group, drifted))

            current_c = dict(old_c['recipeSHA256'], producer=foundation.file_digest(producer),
                             swiftPackageManifest=foundation.file_digest(root / 'Package.swift'))
            self.assertTrue(foundation._legacy_recipe_compatible(
                old_c, root, 'enhanced', 'containerization', current_c))

            current = dict(old_c['recipeSHA256'],
                           producer=foundation.file_digest(producer),
                           swiftPackageManifest=foundation.file_digest(root / 'Package.swift'))
            self.assertFalse(foundation._legacy_recipe_compatible(
                old_c, root, 'enhanced', 'container-sdk', current))
            foundation_lock = json.loads((locks / 'foundation-enhanced.json').read_text())
            foundation_current = dict(foundation_lock['recipeSHA256'],
                                      producer=foundation.file_digest(producer),
                                      swiftPackageManifest=foundation.file_digest(root / 'Package.swift'))
            foundation_lock['recipeSHA256']['producer'] = '0' * 64
            self.assertFalse(foundation._legacy_recipe_compatible(
                foundation_lock, root, 'enhanced', 'foundation', foundation_current))
            foundation_lock['recipeSHA256']['producer'] = \
                'fc84c316dc42f7c978cadf8a89208bcf5f1984aeb270eab5276442cb494bb678'
            (root / 'Package.swift').write_bytes((root / 'Package.swift').read_bytes() + b'// drift\n')
            self.assertFalse(foundation._legacy_recipe_compatible(
                foundation_lock, root, 'enhanced', 'foundation', foundation_current))

    def test_published_lower_compatibility_rejects_producer_ast_drift(self) -> None:
        original = Path(__file__).resolve().parents[3]
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            producer = root / 'Tools/bazel/artifacts/foundation.py'
            producer.parent.mkdir(parents=True)
            producer.write_bytes(Path(foundation.__file__).read_bytes())
            manifest, resolved = self.q_only_documents(original)
            (root / 'Package.swift').write_bytes(manifest)
            (root / 'Package.resolved').write_bytes(resolved)
            lock = json.loads((original / 'Tools/bazel/artifacts/layer-locks/foundation-enhanced.json').read_text())
            current = dict(lock['recipeSHA256'], producer=foundation.file_digest(producer),
                           swiftPackageManifest=foundation.file_digest(root / 'Package.swift'))
            self.assertTrue(foundation._legacy_recipe_compatible(
                lock, root, 'enhanced', 'foundation', current))
            producer.write_text(producer.read_text().replace(
                'def produce(root: Path, output: Path,', 'def produce_changed(root: Path, output: Path,'))
            self.assertFalse(foundation._legacy_recipe_compatible(
                lock, root, 'enhanced', 'foundation', current))
            producer.write_text(Path(foundation.__file__).read_text().replace(
                'def produce(root: Path, output: Path,',
                '@unexpected_decorator\ndef produce(root: Path, output: Path,'))
            self.assertFalse(foundation._legacy_recipe_compatible(
                lock, root, 'enhanced', 'foundation', current))

    def test_published_lower_layers_accept_only_the_exact_two_pin_transition(self) -> None:
        original = Path(__file__).resolve().parents[3]
        new_q = b'4d82da2c571d0924bd97569249a5d200ca764a13'
        old_containerization = b'5ed9bc7490aa30c76337bd5b3d8ff251b63c678f'
        new_containerization = b'6db16197bbad8196a78132f86529daa89125aafb'
        selected_pins = foundation.source_pins(original)
        selected_q = selected_pins['container'].encode()
        selected_containerization = selected_pins['containerization'].encode()
        self.assertIn(selected_q, (b'6fe80db1bad6abff5dfa22f02bdf8bc403ad48bc', new_q))
        self.assertIn(selected_containerization, (old_containerization, new_containerization))
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            producer = root / 'Tools/bazel/artifacts/foundation.py'
            producer.parent.mkdir(parents=True)
            producer.write_bytes(Path(foundation.__file__).read_bytes())
            manifest = (original / 'Package.swift').read_bytes().replace(selected_q, new_q).replace(
                selected_containerization, new_containerization)
            resolved = (original / 'Package.resolved').read_bytes().replace(selected_q, new_q).replace(
                selected_containerization, new_containerization)
            self.assertEqual(manifest.count(new_q), 1)
            self.assertEqual(manifest.count(new_containerization), 1)
            self.assertEqual(resolved.count(new_q), 1)
            self.assertEqual(resolved.count(new_containerization), 1)
            (root / 'Package.swift').write_bytes(manifest)
            (root / 'Package.resolved').write_bytes(resolved)
            locks = original / 'Tools/bazel/artifacts/layer-locks'

            def compatible(profile: str, group: str) -> bool:
                lock = json.loads((locks / f'{group}-{profile}.json').read_text())
                current = dict(lock['recipeSHA256'], producer=foundation.file_digest(producer),
                               swiftPackageManifest=foundation.file_digest(root / 'Package.swift'))
                return foundation._legacy_recipe_compatible(lock, root, profile, group, current)

            for profile, groups in (('enhanced', ('foundation', 'engine-api')),
                                    ('stock', foundation.GROUPS)):
                for group in groups:
                    self.assertTrue(compatible(profile, group), f'{group}-{profile}')
            historical = json.loads((locks / 'engine-api-enhanced.json').read_text())
            current = dict(historical['recipeSHA256'], producer=foundation.file_digest(producer),
                           swiftPackageManifest=foundation.file_digest(root / 'Package.swift'))
            for group in ('containerization', 'container-sdk'):
                self.assertFalse(foundation._legacy_recipe_compatible(
                    historical, root, 'enhanced', group, current), group)

            for other_q, other_containerization in ((b'a' * 40, new_containerization),
                                                       (new_q, b'b' * 40)):
                (root / 'Package.swift').write_bytes(manifest.replace(new_q, other_q).replace(
                    new_containerization, other_containerization))
                (root / 'Package.resolved').write_bytes(resolved.replace(new_q, other_q).replace(
                    new_containerization, other_containerization))
                self.assertFalse(compatible('enhanced', 'foundation'))
            (root / 'Package.swift').write_bytes(manifest)
            (root / 'Package.resolved').write_bytes(resolved)

            for changed_manifest, changed_resolved in (
                    (manifest + b'// unrelated recipe change\n', resolved),
                    (manifest.replace(b'https://github.com/', b'https://example.com/', 1), resolved),
                    (manifest, resolved.replace(b'https://github.com/', b'https://example.com/', 1)),
                    (manifest, resolved + b'\n'),
                    (manifest + new_q, resolved)):
                (root / 'Package.swift').write_bytes(changed_manifest)
                (root / 'Package.resolved').write_bytes(changed_resolved)
                self.assertFalse(compatible('enhanced', 'foundation'))

            (root / 'Package.swift').write_bytes(manifest)
            duplicated = json.loads(resolved)
            reordered = dict(duplicated, pins=list(reversed(duplicated['pins'])))
            (root / 'Package.resolved').write_text(json.dumps(reordered))
            self.assertFalse(compatible('enhanced', 'foundation'))
            duplicated['pins'].append(duplicated['pins'][0])
            (root / 'Package.resolved').write_text(json.dumps(duplicated))
            with self.assertRaisesRegex(ValueError, 'pins are incomplete'):
                compatible('enhanced', 'foundation')
            (root / 'Package.resolved').write_bytes(resolved.replace(new_containerization,
                                                                      old_containerization))
            self.assertFalse(compatible('enhanced', 'foundation'))

    def test_outer_consumer_keeps_source_and_lower_guards_before_recipe_compatibility(self) -> None:
        original = Path(__file__).resolve().parents[3]
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / 'Package.resolved').write_bytes((original / 'Package.resolved').read_bytes())
            source = original / 'Tools/bazel/artifacts/layer-locks/foundation-enhanced.json'
            lock = json.loads(source.read_text())
            target = root / 'lock.json'
            with mock.patch.object(foundation, 'lower_records', return_value=lock['lower']), \
                    mock.patch.object(foundation, 'recipe_identity', side_effect=AssertionError('recipe reached')):
                changed = json.loads(source.read_text())
                changed['sourcePins']['swift-log'] = '0' * 40
                target.write_text(json.dumps(changed))
                with self.assertRaisesRegex(ValueError, 'source pins or lower layer'):
                    foundation.verify_consumer(target, root, None, {})
                changed = json.loads(source.read_text())
                changed['lower'] = {}
                target.write_text(json.dumps(changed))
                with self.assertRaisesRegex(ValueError, 'source pins or lower layer'):
                    foundation.verify_consumer(target, root, None, {})

    def test_generated_build_replaces_compilers_and_keeps_other_rules(self) -> None:
        result = transformed_build(BUILD)
        self.assertIn('swift_library = "foundation_swift_library"', result)
        self.assertIn('cc_library = "foundation_cc_library"', result)
        self.assertIn('"swift_library_group"', result)
        self.assertNotIn('load("@rules_cc//cc:defs.bzl")', result)

    def test_overlay_contains_binaries_headers_and_metadata_without_source(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            source = Path(directory)
            (source / "BUILD.bazel").write_text(BUILD)
            (source / "Sources").mkdir()
            (source / "Sources/Logging.swift").write_text("print(0)\n")
            (source / "Sources/thing.c").write_text("int x;\n")
            (source / "Sources/thing.h").write_text("extern int x;\n")
            (source / "Sources/Shims.c").write_text("#define SHIM 1\n")
            (source / "LICENSE").write_text("license\n")
            outputs = {"binary/Logging.swiftmodule": b"module",
                       "binary/Logging.swiftdoc": b"docs",
                       "binary/libLogging.rspm.__impl.a": b"swift archive",
                       "binary/libCThing.rspm_c.lo": b"c archive"}
            identity = {"swift": {"Logging.rspm.__impl": {
                "swiftmodule": "binary/Logging.swiftmodule", "swiftdoc": "binary/Logging.swiftdoc",
                "archive": "binary/libLogging.rspm.__impl.a"}},
                "cc": {"CThing.rspm_c": "binary/libCThing.rspm_c.lo"}}
            files = package_overlay("swiftpkg_example", source, outputs, identity)
            self.assertIn("Sources/thing.h", files)
            self.assertIn("Sources/Shims.c", files)
            self.assertNotIn("Sources/thing.c", files)
            self.assertNotIn("Sources/Logging.swift", files)
            self.assertIn(b"CThing.rspm_c", files["prebuilt.bzl"])
            self.assertIn(b'C_HEADER_ONLY = ["HeaderOnly"]', files["prebuilt.bzl"])
            self.assertIn(b'"CThing.rspm_c": ["Sources/thing.h"]', files["prebuilt.bzl"])
            self.assertNotIn(b'"CThing.rspm_c": ["Sources/thing.c"', files["prebuilt.bzl"])

    def test_unknown_c_sources_never_become_header_only(self) -> None:
        build = '''cc_library(
    name = "Generated",
    srcs = GENERATED_SOURCES,
)
cc_library(
    name = "Headers",
    srcs = ["include/public.h"],
)
'''
        self.assertEqual(header_only_c_targets(build), {"Headers"})
        with self.assertRaisesRegex(ValueError, "unsupported source expression"):
            compiled_c_header_sources(build, {"Generated"})

    def test_group_pins_do_not_mix_sdk_and_foundation(self) -> None:
        pins = {"swift-log": "a" * 40, "containerization": "b" * 40,
                "container-engine-api": "c" * 40, "container": "d" * 40,
                "swift-argument-parser": "e" * 40}
        self.assertEqual(group_pins(pins, "foundation"), {"swift-log": "a" * 40})
        self.assertEqual(group_pins(pins, "container-sdk"), {"container": "d" * 40})

    def test_archive_is_deterministic_and_rejects_member_change(self) -> None:
        files = {"foundation/swiftpkg_example/BUILD.bazel": b"filegroup(name = 'x')\n"}
        manifest = {"schema": 1, "group": "foundation", "profile": "enhanced",
                    "files": {name: digest(data) for name, data in files.items()}}
        sealed = archive_bytes(files, manifest)
        self.assertEqual(sealed, archive_bytes(files, manifest))
        with tempfile.TemporaryDirectory() as directory:
            archive = Path(directory) / "layer.tar.gz"
            archive.write_bytes(sealed)
            self.assertEqual(inspect(archive)["archiveSHA256"], digest(sealed))
            archive.write_bytes(archive_bytes({"foundation/swiftpkg_example/BUILD.bazel": b"changed"}, manifest))
            with self.assertRaises(ValueError):
                inspect(archive)

    def test_recipe_identity_changes_with_applied_source_patch(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "Tools/bazel/artifacts").mkdir(parents=True)
            for name in ("foundation.py", "foundation_import.bzl", "compiled_outputs.bzl"):
                (root / "Tools/bazel/artifacts" / name).write_text("recipe\n")
            for name in ("run.py", "input_identity.py", "dependencies.bzl"):
                (root / "Tools/bazel" / name).write_text("recipe\n")
            (root / "BUILD.bazel").write_text("binary\n")
            (root / "Package.swift").write_text("package\n")
            (root / ".bazelrc").write_text("common --enable_bzlmod\nbuild --macos_minimum_os=15.0\n"
                                           "build:release --compilation_mode=opt\n")
            (root / "MODULE.bazel").write_text("rules\n")
            (root / "MODULE.bazel.lock").write_text(json.dumps({
                "lockFileVersion": 21, "registryFileHashes": {},
                "selectedYankedVersions": {}, "moduleExtensions": {}}))
            patch = root / "Tools/bazel/zstd-public-module.patch"
            patch.write_text("before\n")
            first = recipe_identity(root)
            patch.write_text("after\n")
            self.assertNotEqual(first, recipe_identity(root))
            patch.write_text("before\n")
            (root / "Tools/bazel/artifacts/compiled_outputs.bzl").write_text("changed aspect\n")
            self.assertNotEqual(first, recipe_identity(root))
            (root / "Tools/bazel/artifacts/compiled_outputs.bzl").write_text("recipe\n")
            (root / ".bazelrc").write_text("common --enable_bzlmod\nbuild --macos_minimum_os=16.0\n"
                                           "build:release --compilation_mode=opt\n")
            self.assertNotEqual(first, recipe_identity(root))


if __name__ == "__main__":
    unittest.main()
