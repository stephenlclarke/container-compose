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
import subprocess
import tempfile
import unittest
from unittest.mock import patch

from release_asset import cached_fetch, fetch, publish_assets, read_lock, tag_commit


class ReleaseAssetTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
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


if __name__ == "__main__":
    unittest.main()
