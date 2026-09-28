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
