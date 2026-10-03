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

"""Focused archive and lock admission checks for compiled ArgumentParser."""

import json
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

from argument_parser import (FILES, LOWER, PRODUCER_BUILD_SHA256, accepted_qualification, archive_bytes,
                             cached_release, digest, inspect, publish, release_tag, selected_output, write_lock)


class ArgumentParserLayerTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.files = {name: name.encode() for name in FILES}
        self.manifest = {
            "schema": 1, "package": "swift-argument-parser", "modules": LOWER,
            "sourceCommit": "a" * 40, "producerCommit": "b" * 40,
            "platform": "darwin-arm64", "configuration": "opt",
            "toolchain": {"generatedBuildSHA256": PRODUCER_BUILD_SHA256},
            "files": {name: digest(data) for name, data in self.files.items()},
        }
        self.archive = self.root / "swift-argument-parser-darwin-arm64-opt.tar.gz"
        self.archive.write_bytes(archive_bytes(self.files, self.manifest))

    def test_real_binary_members_are_deterministic_and_verified(self) -> None:
        self.assertEqual(self.archive.read_bytes(), archive_bytes(self.files, self.manifest))
        result = inspect(self.archive)
        self.assertEqual(result["manifest"]["modules"]["ArgumentParser"], ["ArgumentParserToolInfo"])
        self.assertEqual(len(result["archiveSHA256"]), 64)

    def test_missing_or_changed_compiled_member_is_rejected(self) -> None:
        missing = dict(self.files)
        missing.pop("ArgumentParser.swiftmodule")
        self.archive.write_bytes(archive_bytes(missing, self.manifest))
        with self.assertRaisesRegex(ValueError, "missing or extra"):
            inspect(self.archive)
        self.archive.write_bytes(archive_bytes(self.files, self.manifest))
        with self.assertRaisesRegex(ValueError, "checksum"):
            inspect(self.archive, "0" * 64)

    def test_lock_binds_source_and_does_not_overwrite(self) -> None:
        source = self.root / "source"
        source.mkdir()
        (source / "Package.resolved").write_text(json.dumps({"pins": [{
            "identity": "swift-argument-parser", "kind": "remoteSourceControl",
            "state": {"revision": "a" * 40},
        }]}))
        subprocess.run(["git", "init", "-q", str(source)], check=True)
        subprocess.run(["git", "-C", str(source), "add", "Package.resolved"], check=True)
        subprocess.run(["git", "-C", str(source), "-c", "user.name=Test",
                        "-c", "user.email=test@example.invalid", "commit", "-qm", "pin"], check=True)
        commit = subprocess.check_output(["git", "-C", str(source), "rev-parse", "HEAD"], text=True).strip()
        self.manifest["producerCommit"] = commit
        self.archive.write_bytes(archive_bytes(self.files, self.manifest))
        receipt = self.root / "receipt.json"
        qualification = self.root / "qualification"
        (qualification / "runtime-smoke").mkdir(parents=True)
        (qualification / "qualification.json").write_text(json.dumps({"source": commit, "passed": True}))
        (qualification / "acceptance.json").write_text(json.dumps({"passed": True}))
        (qualification / "runtime-smoke/source-inputs.json").write_text(json.dumps({"fork": commit}))
        test_events = []
        for target in ("ArgumentParserToolInfoTests.rspm", "ArgumentParserUnitTests.rspm"):
            stem = self.root / target
            event = stem.with_name(stem.name + ".events.json")
            event.write_text("\n".join(json.dumps(row) for row in [
                {"unstructuredCommandLine": {"args": ["test"]}},
                {"optionsParsed": {"cmdLine": ["--compilation_mode=dbg"]}},
                {"id": {"testSummary": {"label": "//:" + target}},
                 "testSummary": {"overallStatus": "PASSED"}},
                {"finished": {"overallSuccess": True, "exitCode": {"name": "SUCCESS"}}},
            ]) + "\n")
            stem.with_name(stem.name + ".source.txt").write_text(f"source={source}\nhead={commit}\n")
            stem.with_name(stem.name + ".diff").write_bytes(b"")
            stem.with_name(stem.name + ".inputs.sha256").write_text(
                f"{digest((source / 'Package.resolved').read_bytes())}  Package.resolved\n")
            test_events.append(event)
        evidence = self.root / "release-evidence.json"
        evidence.write_text(json.dumps({"archiveSHA256": digest(self.archive.read_bytes()),
                                        "producerCommit": commit,
                                        "qualification": accepted_qualification(
                                            qualification, commit, tuple(test_events))}))
        receipt.write_text(json.dumps({"archive": str(self.archive),
                                       "archiveSHA256": digest(self.archive.read_bytes()),
                                       "manifest": self.manifest,
                                       "releaseEvidence": str(evidence),
                                       "releaseEvidenceSHA256": digest(evidence.read_bytes()),
                                       "qualificationDirectory": str(qualification),
                                       "targetedTestEvents": [str(path) for path in test_events]}))
        lock_file = self.root / "lock.json"
        lock = write_lock(receipt, source, lock_file)
        self.assertEqual(lock["tag"], release_tag(self.manifest))
        with self.assertRaisesRegex(ValueError, "already exists"):
            write_lock(receipt, source, lock_file)
        test_events[0].with_name("ArgumentParserToolInfoTests.rspm.source.txt").write_text(
            f"source={source}\nhead={'0' * 40}\n")
        with self.assertRaisesRegex(ValueError, "source snapshot"):
            accepted_qualification(qualification, commit, tuple(test_events))

    def test_output_selection_rejects_ambiguous_or_escaping_paths(self) -> None:
        execution = self.root / "execroot"
        output = self.root / "output"
        execution.mkdir()
        output.mkdir()
        plain = execution / "bazel-out/darwin_arm64-opt/bin/Module.swiftmodule"
        selected = execution / "bazel-out/darwin_arm64-opt-ST-abc/bin/Module.swiftmodule"
        plain.parent.mkdir(parents=True)
        selected.parent.mkdir(parents=True)
        plain.write_bytes(b"different")
        selected.write_bytes(b"module")
        paths = f"{plain.relative_to(execution)}\n{selected.relative_to(execution)}"
        self.assertEqual(selected_output(paths, "Module.swiftmodule", execution, self.root), selected.resolve())
        with self.assertRaisesRegex(ValueError, "expected one"):
            selected_output(str(plain.relative_to(execution)), "Module.swiftmodule", execution, self.root)

    def test_verified_release_cache_reuses_offline_and_rejects_mutation(self) -> None:
        evidence = b'{"archiveSHA256":"' + digest(self.archive.read_bytes()).encode() + b'"}\n'
        lock = self.root / "lock.json"
        lock.write_text(json.dumps({"asset": self.archive.name,
                                    "archiveSHA256": digest(self.archive.read_bytes()),
                                    "evidenceAsset": "release-evidence.json",
                                    "evidenceSHA256": digest(evidence),
                                    "manifest": self.manifest}))

        def stage(_lock: Path, destination: Path) -> Path:
            destination.mkdir()
            (destination / self.archive.name).write_bytes(self.archive.read_bytes())
            (destination / "release-evidence.json").write_bytes(evidence)
            (destination / "verified-release.json").write_text(json.dumps({
                "lockSHA256": digest(lock.read_bytes()),
                "archiveSHA256": digest(self.archive.read_bytes()),
                "evidenceSHA256": digest(evidence),
                "tagCommit": self.manifest["producerCommit"],
                "releaseId": 1, "assetIds": [2, 3],
            }))
            return destination / self.archive.name

        with patch("argument_parser.fetch", side_effect=stage) as download:
            first = cached_release(lock, self.root / "cache")
            self.assertEqual(first, cached_release(lock, self.root / "cache"))
            download.assert_called_once()
        first.write_bytes(b"changed")
        with self.assertRaisesRegex(ValueError, "checksum"):
            cached_release(lock, self.root / "cache")

    def test_publish_checks_draft_before_tag_exists_then_published_ref(self) -> None:
        import subprocess as process

        build_log = self.root / "build.log"
        build_events = self.root / "build.events.json"
        build_log.write_bytes(b"build succeeded")
        build_events.write_bytes(b"events")
        qualification = {"qualifiedSource": self.manifest["producerCommit"]}
        evidence = self.root / "release-evidence.json"
        evidence.write_text(json.dumps({
            "archiveSHA256": digest(self.archive.read_bytes()),
            "producerCommit": self.manifest["producerCommit"],
            "qualification": qualification,
            "optimizedBuild": {"logSHA256": digest(build_log.read_bytes()),
                               "eventsSHA256": digest(build_events.read_bytes())},
        }))
        receipt = self.root / "receipt.json"
        receipt.write_text(json.dumps({
            "archive": str(self.archive), "archiveSHA256": digest(self.archive.read_bytes()),
            "manifest": self.manifest, "sourceCheckout": str(self.root),
            "qualificationDirectory": str(self.root), "targetedTestEvents": [],
            "releaseEvidence": str(evidence), "releaseEvidenceSHA256": digest(evidence.read_bytes()),
            "producerBuildLog": str(build_log), "producerBuildEvents": str(build_events),
        }))
        staged = {self.archive.name: self.archive, evidence.name: evidence}
        published = False

        def run(args: list[str], **_kwargs: object) -> process.CompletedProcess[str]:
            nonlocal published
            if args[1:3] == ["release", "view"]:
                return process.CompletedProcess(args, 1, "", "release not found\n")
            if args[1:3] == ["api", "--hostname"]:
                return process.CompletedProcess(args, 1, "", "gh: Not Found (HTTP 404)\n")
            if args[1:3] == ["release", "download"]:
                (Path(args[-1]) / args[args.index("--pattern") + 1]).write_bytes(
                    staged[args[args.index("--pattern") + 1]].read_bytes())
            if args[1:3] == ["release", "edit"]:
                published = True
            return process.CompletedProcess(args, 0, "", "")

        def api(*args: str) -> str:
            assets = [{"name": name, "size": path.stat().st_size} for name, path in staged.items()]
            if args[0] == "release":
                self.assertFalse(published)
                return json.dumps({"databaseId": 7, "isDraft": True, "isPrerelease": True,
                                   "tagName": release_tag(self.manifest),
                                   "targetCommitish": self.manifest["producerCommit"], "assets": assets})
            self.assertTrue(published)
            return json.dumps({"id": 7, "draft": False, "prerelease": True, "assets": assets})

        def remote_tag(_repository: str, _tag: str) -> str:
            self.assertTrue(published, "draft must not require a Git ref")
            return self.manifest["producerCommit"]

        with patch("argument_parser.clean_source"), patch(
                "argument_parser.accepted_qualification", return_value=qualification), patch(
                "argument_parser.subprocess.run", side_effect=run), patch(
                "argument_parser.gh", side_effect=api), patch(
                "argument_parser.tag_commit", side_effect=remote_tag):
            publish(receipt)
        self.assertTrue(published)


if __name__ == "__main__":
    unittest.main()
