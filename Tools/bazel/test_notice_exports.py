#!/usr/bin/env python3
# Copyright 2026 container-compose project authors. SPDX-License-Identifier: Apache-2.0
"""Offline repository-template regressions; no Bazel or runtime execution."""

import json
from pathlib import Path
import tempfile
from types import SimpleNamespace
import unittest

from Tools.bazel.package import EXPLICIT_SWIFT_NOTICES, source_notices

ROOT = Path(__file__).resolve().parents[2]


class RepositoryPath:
    def __init__(self, path):
        self.path = path

    @property
    def dirname(self):
        return RepositoryPath(self.path.parent)

    @property
    def realpath(self):
        return self.path.resolve()

    @property
    def exists(self):
        return self.path.exists()

    def get_child(self, relative):
        return RepositoryPath(self.path / relative)


class NoticeExportsTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.calls = []
        def rule(**kwargs):
            return lambda **attrs: self.calls.append(attrs)
        def fail(message):
            raise ValueError(message)
        self.namespace = {"repository_rule": rule, "fail": fail,
                          "attr": SimpleNamespace(label_keyed_string_dict=lambda **kwargs: None),
                          "json": SimpleNamespace(encode=json.dumps)}
        exec(compile((ROOT / "Tools/bazel/notice_exports.bzl").read_text(),
                     "notice_exports.bzl", "exec"), self.namespace)
        self.namespace["compose_notice_exports"]("compose_notice_exports")
        self.packages = self.calls[0]["packages"]
        self.selected = {}
        self.before = {}
        for label, repository in self.packages.items():
            root = self.root / repository
            root.mkdir()
            (root / "pkg_info.json").write_text('{}\n')
            (root / "BUILD.bazel").write_text('exports_files(["pkg_info.json"])\n')
            self.selected[label] = root / "pkg_info.json"
            for relative in self.namespace["NOTICE_FILES"][repository]:
                source = root / relative
                source.parent.mkdir(parents=True, exist_ok=True)
                source.write_text(repository + "/" + relative + " notice\n")
            self.before.update({path: path.read_bytes() for path in root.rglob('*') if path.is_file()})
        self.output = self.root / "exported"
        self.output.mkdir()
        def write(name, content, executable):
            self.assertFalse(executable)
            path = self.output / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(content)
        self.context = SimpleNamespace(attr=SimpleNamespace(packages=self.packages),
            path=lambda label: RepositoryPath(self.selected[label]),
            read=lambda source: source.path.read_text(), file=write)

    def test_exact_seven_public_labels_and_metadata_inputs_without_lower_build_changes(self):
        self.namespace["_notice_exports_impl"](self.context)
        exports = []
        groups = []
        exec((self.output / "BUILD.bazel").read_text(), {
            "exports_files": lambda files: exports.extend(files),
            "filegroup": lambda **kwargs: groups.append(kwargs)})
        expected = {"swiftpkg_" + label.removeprefix("Swift/") for label in EXPLICIT_SWIFT_NOTICES}
        self.assertEqual(set(exports), expected)
        self.assertEqual(len(exports), 7)
        self.assertEqual(groups, [{"name": "notices", "srcs": sorted(expected),
                                  "visibility": ["//visibility:public"]}])
        for source, data in self.before.items():
            self.assertEqual(source.read_bytes(), data)
        self.assertEqual(set(self.packages), {
            "@" + repository + "//:pkg_info.json" for repository in self.namespace["NOTICE_FILES"]})
        licenses = self.root / "licenses.json"
        licenses.write_text("[]")
        texts, _, _ = source_notices({"licenses": str(licenses), "source_swift_notices": [
            str(self.output / relative) for relative in exports]}, {})
        self.assertEqual(set(texts), EXPLICIT_SWIFT_NOTICES)
        for relative in expected:
            self.assertEqual((self.output / relative).read_bytes(), (self.root / relative).read_bytes())

    def test_missing_empty_or_escaping_notice_fails(self):
        source = self.root / "swiftpkg_swift_crypto/NOTICE.txt"
        original = source.read_bytes()
        for kind in ("missing", "empty", "escaping"):
            with self.subTest(kind=kind):
                source.unlink()
                if kind == "empty":
                    source.write_text("")
                elif kind == "escaping":
                    external = self.root / "outside-notice"
                    external.write_text("unowned")
                    source.symlink_to(external)
                with self.assertRaisesRegex(ValueError, "notice is"):
                    self.namespace["_notice_exports_impl"](self.context)
                if source.exists():
                    source.unlink()
                source.write_bytes(original)

    def test_incomplete_or_duplicate_package_roots_fail(self):
        for invalid in ({}, {**self.packages, "@extra//:pkg_info.json": "swiftpkg_swift_crypto"}):
            with self.subTest(invalid=invalid), self.assertRaisesRegex(ValueError, "exact selected"):
                self.namespace["_notice_exports_impl"](SimpleNamespace(attr=SimpleNamespace(packages=invalid)))

    def test_extension_and_package_are_wired_to_closed_export_repository(self):
        dependency = (ROOT / "Tools/bazel/dependencies.bzl").read_text()
        self.assertIn('compose_notice_exports(name = "compose_notice_exports")', dependency)
        self.assertIn('"compose_notice_exports",', (ROOT / "MODULE.bazel").read_text())
        self.assertIn('source_swift_notices = ["@compose_notice_exports//:notices"]',
                      (ROOT / "Tools/bazel/package.bzl").read_text())


if __name__ == "__main__":
    unittest.main()
