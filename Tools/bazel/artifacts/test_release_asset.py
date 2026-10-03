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

"""Focused exact-tag and asset-byte admission tests for release downloads."""

import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest
from unittest.mock import patch

from release_asset import (cached_fetch, fetch, publication_journal_path, publish_assets,
                           read_lock, tag_commit)


class ReleaseAssetTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name).resolve()
        self.content = b"released binary, not source"
        self.lock = self.root / "lock.json"
        self.data = {"schema": 1, "repository": "stephenlclarke/container",
                     "tag": "layer-example-1", "targetCommit": "a" * 40,
                     "asset": "example.tar.gz",
                     "sha256": hashlib.sha256(self.content).hexdigest()}
        self.lock.write_text(json.dumps(self.data))

    def api(self, *args: str) -> str:
        endpoint = args[-1]
        if "/git/ref/tags/" in endpoint:
            return json.dumps({"object": {"type": "tag", "sha": "b" * 40}})
        if "/git/tags/" in endpoint:
            return json.dumps({"object": {"type": "commit", "sha": "a" * 40}})
        return json.dumps({"id": 10, "tag_name": self.data["tag"], "draft": False,
                           "prerelease": True,
                           "immutable": False,
                           "assets": [{"id": 20, "name": self.data["asset"],
                                       "size": len(self.content)}]})

    def download(self, args: list[str], **_kwargs: object) -> None:
        (Path(args[-1]) / self.data["asset"]).write_bytes(self.content)

    def resumable_transport(self, *, fail_upload: str | None = None,
                            fail_before_upload: str | None = None,
                            starter_after_upload_error: str | None = None,
                            fail_create: bool = False, fail_expose: bool = False,
                            corrupt_download: str | None = None) -> tuple[dict, list[list[str]]]:
        state: dict = {"release": None, "uploaded": {}, "next_id": 30}
        calls: list[list[str]] = []
        fail_upload_once = [fail_upload]
        fail_before_upload_once = [fail_before_upload]
        fail_create_once = [fail_create]
        fail_expose_once = [fail_expose]

        def api(*args: str) -> str:
            if args[:2] == ("release", "view"):
                release = state["release"]
                if release is None:
                    raise AssertionError("release view before creation")
                return json.dumps({"databaseId": release["databaseId"]})
            endpoint = args[-1]
            if "/git/commits/" in endpoint:
                return json.dumps({"sha": "a" * 40})
            if "/git/ref/tags/" in endpoint:
                return json.dumps({"object": {"type": "commit", "sha": "a" * 40}})
            if "releases/tags/" in endpoint:
                release = state["release"]
                if release is None:
                    raise AssertionError("release API read before draft creation")
                if release["isDraft"]:
                    raise AssertionError("REST tag lookup does not reliably return draft releases")
                return json.dumps({"id": release["databaseId"], "tag_name": release["tagName"],
                                   "target_commitish": release["targetCommitish"],
                                   "draft": release["isDraft"],
                                   "prerelease": release["isPrerelease"],
                                   "name": release["title"], "body": release["body"],
                                   "assets": release["assets"], "immutable": False})
            if "/releases/" in endpoint:
                release = state["release"]
                if release is None or endpoint.rsplit("/", 1)[-1] != str(release["databaseId"]):
                    raise AssertionError("release lookup used the wrong database ID")
                return json.dumps({"id": release["databaseId"], "tag_name": release["tagName"],
                                   "target_commitish": release["targetCommitish"],
                                   "draft": release["isDraft"],
                                   "prerelease": release["isPrerelease"],
                                   "name": release["title"], "body": release["body"],
                                   "assets": release["assets"], "immutable": False})
            raise AssertionError(f"unexpected API endpoint: {endpoint}")

        def gh_run(args: list[str], **_kwargs: object) -> subprocess.CompletedProcess[str]:
            calls.append(args)
            if args[:3] == ["gh", "api", "--hostname"]:
                if "-X" in args and "DELETE" in args:
                    asset_id = int(args[-1].rsplit("/", 1)[-1])
                    state["release"]["assets"] = [item for item in state["release"]["assets"]
                                                   if item["id"] != asset_id]
                    return subprocess.CompletedProcess(args, 0, "", "")
                return subprocess.CompletedProcess(args, 1, "", "HTTP 404")
            if args[:3] == ["gh", "release", "view"]:
                return subprocess.CompletedProcess(args, 1, "", "release not found") \
                    if state["release"] is None else subprocess.CompletedProcess(args, 0, "", "")
            if args[:3] == ["gh", "release", "create"]:
                notes = args[args.index("--notes") + 1]
                state["release"] = {"databaseId": 10, "tagName": self.data["tag"],
                                    "targetCommitish": "a" * 40, "isDraft": True,
                                    "isPrerelease": True, "title": "Compiled dependency",
                                    "body": notes, "assets": []}
                if fail_create_once[0]:
                    fail_create_once[0] = False
                    raise subprocess.CalledProcessError(1, args, stderr="response lost")
                return subprocess.CompletedProcess(args, 0, "", "")
            if args[:3] == ["gh", "release", "upload"]:
                source = Path(args[4])
                if fail_before_upload_once[0] == source.name:
                    fail_before_upload_once[0] = None
                    raise subprocess.CalledProcessError(1, args, stderr="interrupted before upload")
                content = source.read_bytes()
                state["next_id"] += 1
                item = {"id": state["next_id"], "name": source.name,
                        "size": len(content), "state": "uploaded"}
                state["release"]["assets"].append(item)
                state["uploaded"][source.name] = content
                if fail_upload_once[0] == source.name:
                    fail_upload_once[0] = None
                    if starter_after_upload_error == source.name:
                        item["size"] = 0
                        item["state"] = "starter"
                    raise subprocess.CalledProcessError(1, args, stderr="response lost")
                return subprocess.CompletedProcess(args, 0, "", "")
            if args[:3] == ["gh", "release", "download"]:
                name = args[args.index("--pattern") + 1]
                content = state["uploaded"][name]
                if corrupt_download == name:
                    content = b"tampered remote content"
                (Path(args[args.index("--dir") + 1]) / name).write_bytes(content)
                return subprocess.CompletedProcess(args, 0, "", "")
            if args[:3] == ["gh", "release", "edit"]:
                state["release"]["isDraft"] = False
                if fail_expose_once[0]:
                    fail_expose_once[0] = False
                    raise subprocess.CalledProcessError(1, args, stderr="response lost")
                return subprocess.CompletedProcess(args, 0, "", "")
            raise AssertionError(f"unexpected gh command: {args}")

        return {"api": api, "run": gh_run, "state": state}, calls

    def publish_resumable(self, scratch: Path, assets: tuple[Path, ...], **kwargs: object) -> dict:
        journal_root = kwargs.pop("journal_root", self.root)
        return publish_assets(self.data["repository"], self.data["tag"], "a" * 40,
                              "Compiled dependency", "Proof", assets, resume=True,
                              scratch=scratch, journal_root=journal_root,
                              owner="q-runtime-layer-test", **kwargs)

    def test_annotated_tag_and_exact_download(self) -> None:
        with patch("release_asset.gh", side_effect=self.api), patch(
                "release_asset.subprocess.run", side_effect=self.download):
            self.assertEqual(tag_commit(self.data["repository"], self.data["tag"]), "a" * 40)
            receipt = fetch(self.lock, self.root / "download")
        self.assertEqual(receipt["sha256"], self.data["sha256"])
        self.assertFalse(receipt["githubImmutable"])
        self.assertTrue((self.root / "download/fetch-receipt.json").is_file())

    def test_wrong_hash_and_receipt_collision_fail(self) -> None:
        self.data["sha256"] = "0" * 64
        self.lock.write_text(json.dumps(self.data))
        with patch("release_asset.gh", side_effect=self.api), patch(
                "release_asset.subprocess.run", side_effect=self.download):
            with self.assertRaisesRegex(ValueError, "pinned SHA"):
                fetch(self.lock, self.root / "download")
        self.data["asset"] = "fetch-receipt.json"
        self.lock.write_text(json.dumps(self.data))
        with self.assertRaisesRegex(ValueError, "exact repository"):
            read_lock(self.lock)

    def test_verified_cache_reuse_is_offline_and_rechecks_bytes(self) -> None:
        cache = self.root / "cache"
        with patch("release_asset.gh", side_effect=self.api), patch(
                "release_asset.subprocess.run", side_effect=self.download):
            first = cached_fetch(self.lock, cache)
        self.assertFalse(first["offlineCacheReuse"])
        with patch("release_asset.gh", side_effect=AssertionError("unexpected network")):
            second = cached_fetch(self.lock, cache)
        self.assertTrue(second["offlineCacheReuse"])
        Path(second["asset"]).write_bytes(b"changed")
        with self.assertRaisesRegex(ValueError, "offline release cache"):
            cached_fetch(self.lock, cache)

    def test_publish_verifies_draft_bytes_and_exact_target(self) -> None:
        source = self.root / "example.tar.gz"
        source.write_bytes(self.content)
        def api(*args: str) -> str:
            if args[:2] == ("release", "view"):
                return json.dumps({"databaseId": 10, "tagName": self.data["tag"],
                                   "targetCommitish": "a" * 40, "isDraft": True,
                                   "isPrerelease": True,
                                   "assets": [{"name": source.name, "size": source.stat().st_size}]})
            if "/git/commits/" in args[-1]:
                return json.dumps({"sha": "a" * 40})
            return self.api(*args)
        calls = []
        def run(args: list[str], **_kwargs: object) -> subprocess.CompletedProcess[str]:
            calls.append(args)
            if args[:3] == ["gh", "release", "view"]:
                return subprocess.CompletedProcess(args, 1, "", "release not found")
            if args[:2] == ["gh", "api"]:
                return subprocess.CompletedProcess(args, 1, "", "HTTP 404")
            if args[:3] == ["gh", "release", "download"]:
                (Path(args[-1]) / source.name).write_bytes(self.content)
            return subprocess.CompletedProcess(args, 0, "", "")
        with patch("release_asset.gh", side_effect=api), patch(
                "release_asset.subprocess.run", side_effect=run):
            result = publish_assets(self.data["repository"], self.data["tag"], "a" * 40,
                                    "Compiled dependency", "Proof", (source,))
        self.assertEqual(result["assets"][source.name]["sha256"], self.data["sha256"])
        create = next(args for args in calls if args[:3] == ["gh", "release", "create"])
        self.assertIn("--latest=false", create)
        self.assertIn("--prerelease", create)

    def test_prepushed_tag_must_resolve_to_exact_target(self) -> None:
        source = self.root / "example.tar.gz"
        source.write_bytes(self.content)
        with patch("release_asset.gh", side_effect=lambda *args: json.dumps(
                {"sha": "a" * 40} if "/git/commits/" in args[-1] else
                {"object": {"type": "commit", "sha": "b" * 40}})), patch(
                "release_asset.subprocess.run", side_effect=lambda args, **kwargs:
                subprocess.CompletedProcess(args, 1, "", "release not found")
                if args[:3] == ["gh", "release", "view"] else
                subprocess.CompletedProcess(args, 0, "", "")):
            with self.assertRaisesRegex(ValueError, "different commit"):
                publish_assets(self.data["repository"], self.data["tag"], "a" * 40,
                               "Compiled dependency", "Proof", (source,))

    def test_resumable_publication_requires_explicit_scratch_journal_root_and_owner(self) -> None:
        source = self.root / "example.tar.gz"
        source.write_bytes(self.content)
        with self.assertRaisesRegex(ValueError, "explicit scratch, journal root and owner"):
            publish_assets(self.data["repository"], self.data["tag"], "a" * 40,
                           "Compiled dependency", "Proof", (source,), resume=True)
        path = publication_journal_path(self.root, self.data["repository"], self.data["tag"],
                                        "q-runtime-layer-test")
        self.assertEqual(path.parent, self.root)
        self.assertTrue(path.name.startswith("release-publication-"))

    def test_resumable_publication_recovers_after_draft_creation_and_partial_upload(self) -> None:
        alpha = self.root / "a-layer.tar.gz"
        beta = self.root / "b-layer.tar.gz"
        alpha.write_bytes(b"first verified asset")
        beta.write_bytes(b"second verified asset")
        transport, calls = self.resumable_transport(fail_create=True, fail_upload=beta.name)
        journal_path = publication_journal_path(self.root, self.data["repository"],
                                                self.data["tag"], "q-runtime-layer-test")
        with patch("release_asset.gh", side_effect=transport["api"]), \
             patch("release_asset.subprocess.run", side_effect=transport["run"]):
            with self.assertRaises(subprocess.CalledProcessError):
                self.publish_resumable(self.root, (alpha, beta))
            self.assertTrue(journal_path.is_file())
            journal = json.loads(journal_path.read_text())
            self.assertEqual(journal["state"], "intent")
            self.assertEqual({row["name"] for row in journal["intent"]["assets"]},
                             {alpha.name, beta.name})
            with self.assertRaises(subprocess.CalledProcessError):
                self.publish_resumable(self.root, (alpha, beta))
            result = self.publish_resumable(self.root, (alpha, beta))
        self.assertEqual(set(result["assets"]), {alpha.name, beta.name})
        uploads = [Path(call[4]).name for call in calls if call[:3] == ["gh", "release", "upload"]]
        self.assertEqual(uploads, [alpha.name, beta.name])

    def test_resumable_journal_survives_verification_scratch_cleanup(self) -> None:
        source = self.root / "asset.tar.gz"
        source.write_bytes(self.content)
        scratch = self.root / "ssd-scratch"
        journal_root = self.root / "retained-output"
        scratch.mkdir(mode=0o700)
        journal_root.mkdir(mode=0o700)
        transport, _calls = self.resumable_transport(fail_create=True)
        journal_path = publication_journal_path(journal_root, self.data["repository"],
                                                self.data["tag"], "q-runtime-layer-test")
        with patch("release_asset.gh", side_effect=transport["api"]), \
             patch("release_asset.subprocess.run", side_effect=transport["run"]):
            with self.assertRaises(subprocess.CalledProcessError):
                self.publish_resumable(scratch, (source,), journal_root=journal_root)
        self.assertTrue(journal_path.is_file())
        for child in scratch.iterdir():
            if child.is_dir():
                shutil.rmtree(child)
            else:
                child.unlink()
        scratch.rmdir()
        self.assertTrue(journal_path.is_file())
        self.assertEqual(journal_path.parent, journal_root)

    def test_resumable_publication_repairs_only_unacknowledged_starter_asset(self) -> None:
        acknowledged = self.root / "a-layer.tar.gz"
        interrupted = self.root / "b-layer.tar.gz"
        acknowledged.write_bytes(b"acknowledged producer bytes")
        interrupted.write_bytes(self.content)
        transport, _calls = self.resumable_transport(
            fail_upload=interrupted.name, starter_after_upload_error=interrupted.name)
        with patch("release_asset.gh", side_effect=transport["api"]), \
             patch("release_asset.subprocess.run", side_effect=transport["run"]):
            with self.assertRaises(subprocess.CalledProcessError):
                self.publish_resumable(self.root, (acknowledged, interrupted))
            self.assertEqual(transport["state"]["release"]["assets"][1]["state"], "starter")
            result = self.publish_resumable(self.root, (acknowledged, interrupted))
        journal_path = publication_journal_path(self.root, self.data["repository"],
                                                self.data["tag"], "q-runtime-layer-test")
        journal = json.loads(journal_path.read_text())
        self.assertEqual(journal["repairs"][0]["state"], "removed")
        self.assertEqual(journal["repairs"][0]["assetName"], interrupted.name)
        remote_assets = {item["name"]: item for item in transport["state"]["release"]["assets"]}
        self.assertEqual(set(remote_assets), {acknowledged.name, interrupted.name})
        self.assertEqual(remote_assets[acknowledged.name]["state"], "uploaded")
        self.assertEqual(remote_assets[interrupted.name]["state"], "uploaded")
        self.assertEqual(result["assets"][interrupted.name]["sha256"], self.data["sha256"])

    def test_resumable_publication_resumes_partial_upload_without_reuploading_verified_assets(self) -> None:
        alpha = self.root / "a-layer.tar.gz"
        beta = self.root / "b-layer.tar.gz"
        alpha.write_bytes(b"first verified asset")
        beta.write_bytes(b"second verified asset")
        transport, calls = self.resumable_transport(fail_before_upload=beta.name)
        with patch("release_asset.gh", side_effect=transport["api"]), \
             patch("release_asset.subprocess.run", side_effect=transport["run"]):
            with self.assertRaises(subprocess.CalledProcessError):
                self.publish_resumable(self.root, (alpha, beta))
            self.assertEqual([item["name"] for item in transport["state"]["release"]["assets"]],
                             [alpha.name])
            result = self.publish_resumable(self.root, (alpha, beta))
        uploads = [Path(call[4]).name for call in calls if call[:3] == ["gh", "release", "upload"]]
        self.assertEqual(uploads.count(alpha.name), 1)
        self.assertEqual(uploads.count(beta.name), 2)  # one failed before remote creation
        self.assertEqual(set(result["assets"]), {alpha.name, beta.name})

    def test_resumable_publication_rejects_owned_draft_asset_id_tampering(self) -> None:
        source = self.root / "example.tar.gz"
        source.write_bytes(self.content)
        transport, _ = self.resumable_transport(fail_expose=True)
        with patch("release_asset.gh", side_effect=transport["api"]), \
             patch("release_asset.subprocess.run", side_effect=transport["run"]):
            with self.assertRaises(subprocess.CalledProcessError):
                self.publish_resumable(self.root, (source,))
            transport["state"]["release"]["assets"][0]["id"] += 1
            with self.assertRaisesRegex(ValueError, "asset identity changed"):
                self.publish_resumable(self.root, (source,))

    def test_resumable_publication_recovers_after_exposure_and_verifies_downloads_first(self) -> None:
        source = self.root / "example.tar.gz"
        source.write_bytes(self.content)
        transport, calls = self.resumable_transport(fail_expose=True)
        with patch("release_asset.gh", side_effect=transport["api"]), \
             patch("release_asset.subprocess.run", side_effect=transport["run"]):
            with self.assertRaises(subprocess.CalledProcessError):
                self.publish_resumable(self.root, (source,))
            result = self.publish_resumable(self.root, (source,))
        edits = [call for call in calls if call[:3] == ["gh", "release", "edit"]]
        downloads = [call for call in calls if call[:3] == ["gh", "release", "download"]]
        self.assertEqual(len(edits), 1)
        self.assertTrue(downloads)
        self.assertEqual(result["assets"][source.name]["sha256"], self.data["sha256"])

    def test_resumable_publication_rejects_unrelated_identity_changed_intent_and_bad_bytes(self) -> None:
        source = self.root / "example.tar.gz"
        source.write_bytes(self.content)
        transport, _calls = self.resumable_transport()
        transport["state"]["release"] = {"databaseId": 99, "tagName": self.data["tag"],
                                          "targetCommitish": "a" * 40, "isDraft": True,
                                          "isPrerelease": True, "title": "Other",
                                          "body": "Unrelated release", "assets": []}
        with patch("release_asset.gh", side_effect=transport["api"]), \
             patch("release_asset.subprocess.run", side_effect=transport["run"]):
            with self.assertRaisesRegex(ValueError, "not this exact owned"):
                self.publish_resumable(self.root, (source,))

        scratch = self.root / "second-scratch"
        scratch.mkdir()
        bad_transport, _ = self.resumable_transport(corrupt_download=source.name)
        with patch("release_asset.gh", side_effect=bad_transport["api"]), \
             patch("release_asset.subprocess.run", side_effect=bad_transport["run"]):
            with self.assertRaisesRegex(ValueError, "downloaded draft asset"):
                self.publish_resumable(scratch, (source,))
        self.assertTrue(bad_transport["state"]["release"]["isDraft"])

        source.write_bytes(b"changed qualified bytes")
        with patch("release_asset.gh", side_effect=bad_transport["api"]), \
             patch("release_asset.subprocess.run", side_effect=bad_transport["run"]):
            with self.assertRaisesRegex(ValueError, "differ from the durable intent"):
                self.publish_resumable(scratch, (source,))

    def test_resumable_publication_refuses_to_replace_a_missing_owned_release(self) -> None:
        source = self.root / "example.tar.gz"
        source.write_bytes(self.content)
        transport, _calls = self.resumable_transport(fail_expose=True)
        with patch("release_asset.gh", side_effect=transport["api"]), \
             patch("release_asset.subprocess.run", side_effect=transport["run"]):
            with self.assertRaises(subprocess.CalledProcessError):
                self.publish_resumable(self.root, (source,))
        transport["state"]["release"] = None
        with patch("release_asset.gh", side_effect=transport["api"]), \
             patch("release_asset.subprocess.run", side_effect=transport["run"]):
            with self.assertRaisesRegex(ValueError, "previously owned release is missing"):
                self.publish_resumable(self.root, (source,))


if __name__ == "__main__":
    unittest.main()
