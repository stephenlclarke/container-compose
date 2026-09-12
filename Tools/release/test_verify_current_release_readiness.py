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

from __future__ import annotations

import importlib.util
import unittest
from pathlib import Path


TOOL = Path(__file__).with_name("verify-current-release-readiness.py")


def load_module():
    spec = importlib.util.spec_from_file_location("current_release_readiness", TOOL)
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class VerifyCurrentReleaseReadinessTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.module = load_module()
        cls.sha = "a" * 40
        cls.tag = f"current-{cls.sha}"
        cls.repository = "owner/repository"

    def payload(self):
        digest = "b" * 64
        assets = [
            {"name": name, "digest": f"sha256:{digest}", "updated_at": "2026-09-11T20:00:00Z"}
            for name in self.module.expected_assets(self.sha)
        ]
        short = self.sha[:12]
        compose = f"container-compose-plugin-current-{short}-arm64.tar.gz"
        runtime = f"container-current-{short}-arm64.tar.gz"
        base = f"https://github.com/{self.repository}/releases/download/{self.tag}"
        return {
            "release": {
                "draft": False,
                "immutable": True,
                "prerelease": True,
                "tag_name": self.tag,
                "target_commitish": self.sha,
                "published_at": "2026-09-11T20:05:00Z",
                "assets": assets,
            },
            "runs": {
                "workflow_runs": [
                    {
                        "head_sha": self.sha,
                        "run_number": 42,
                        "status": "completed",
                        "conclusion": "success",
                        "updated_at": "2026-09-11T20:10:00Z",
                    }
                ]
            },
            "compose_formula": (
                f'  url "{base}/{compose}"\n  sha256 "{digest}"\n'
                f'  version "current.42.{self.sha[:12]}"\n'
            ),
            "container_formula": (
                f'  url "{base}/{runtime}"\n  sha256 "{digest}"\n'
                f'  version "current.42.{self.sha[:12]}"\n'
            ),
        }

    def verify(self, payload):
        return self.module.verify(
            payload,
            repository=self.repository,
            tag=self.tag,
            sha=self.sha,
        )

    def test_accepts_the_complete_exact_authority(self) -> None:
        self.assertEqual(self.verify(self.payload()), "2026-09-11T20:10:00Z")

    def test_soak_uses_selected_package_run_not_old_draft_asset_or_later_noop(self) -> None:
        payload = self.payload()
        for asset in payload["release"]["assets"]:
            asset["updated_at"] = "2026-09-01T00:00:00Z"
        payload["runs"]["workflow_runs"].append(
            {
                "head_sha": self.sha,
                "run_number": 43,
                "status": "completed",
                "conclusion": "success",
                "updated_at": "2026-09-11T20:15:00Z",
            }
        )
        self.assertEqual(self.verify(payload), "2026-09-11T20:10:00Z")

    def test_rejects_draft_mutable_and_wrong_target_releases(self) -> None:
        for field, value in (("draft", True), ("immutable", False), ("target_commitish", "c" * 40)):
            with self.subTest(field=field):
                payload = self.payload()
                payload["release"][field] = value
                with self.assertRaises(self.module.ReadinessError):
                    self.verify(payload)

    def test_rejects_incomplete_or_digestless_asset_closure(self) -> None:
        incomplete = self.payload()
        incomplete["release"]["assets"].pop()
        with self.assertRaises(self.module.ReadinessError):
            self.verify(incomplete)
        digestless = self.payload()
        digestless["release"]["assets"][0]["digest"] = None
        with self.assertRaises(self.module.ReadinessError):
            self.verify(digestless)

    def test_rejects_untapped_or_wrong_digest_formulae(self) -> None:
        for field in ("compose_formula", "container_formula"):
            with self.subTest(field=field):
                payload = self.payload()
                payload[field] = payload[field].replace("b" * 64, "c" * 64)
                with self.assertRaises(self.module.ReadinessError):
                    self.verify(payload)

    def test_rejects_expected_authority_only_in_comments_or_caveats(self) -> None:
        payload = self.payload()
        expected_url = payload["compose_formula"].splitlines()[0]
        payload["compose_formula"] = payload["compose_formula"].replace(
            expected_url,
            '  url "https://example.invalid/foreign.tar.gz"\n'
            f"  # {expected_url.strip()}\n"
            "\n  def caveats\n"
            "    <<~EOS\n"
            f"      {expected_url.strip()}\n"
            "    EOS\n"
            "  end",
        )
        with self.assertRaises(self.module.ReadinessError):
            self.verify(payload)

        payload = self.payload()
        expected_digest = f'  sha256 "{"b" * 64}"'
        payload["container_formula"] = payload["container_formula"].replace(
            expected_digest,
            f'  sha256 "{"c" * 64}"\n'
            f"  # {expected_digest.strip()}\n"
            "\n  def caveats\n"
            "    <<~EOS\n"
            f"      {expected_digest.strip()}\n"
            "    EOS\n"
            "  end",
        )
        with self.assertRaises(self.module.ReadinessError):
            self.verify(payload)

    def test_rejects_duplicate_active_formula_declarations(self) -> None:
        for declaration in ("url", "sha256", "version"):
            with self.subTest(declaration=declaration):
                payload = self.payload()
                lines = payload["compose_formula"].splitlines()
                line = next(item for item in lines if item.strip().startswith(declaration))
                payload["compose_formula"] += f"{line}\n"
                with self.assertRaises(self.module.ReadinessError):
                    self.verify(payload)

    def test_rejects_mismatched_or_wrong_current_formula_run_versions(self) -> None:
        replacements = (
            ("container_formula", "current.42.", "current.43."),
            ("compose_formula", f"current.42.{self.sha[:12]}", "current.42.cccccccccccc"),
            ("compose_formula", 'version "current.42.', 'version "current.042.'),
        )
        for field, old, new in replacements:
            with self.subTest(field=field, new=new):
                payload = self.payload()
                payload[field] = payload[field].replace(old, new)
                with self.assertRaises(self.module.ReadinessError):
                    self.verify(payload)

    def test_rejects_missing_exact_head_package_authority(self) -> None:
        payload = self.payload()
        payload["runs"]["workflow_runs"][0]["conclusion"] = "failure"
        with self.assertRaises(self.module.ReadinessError):
            self.verify(payload)

    def test_rejects_missing_or_malformed_authority_timestamps(self) -> None:
        for owner, field in (("release", "published_at"), ("run", "updated_at")):
            for value in (None, "", "2026-09-11 20:10:00", "2026-13-11T20:10:00Z"):
                with self.subTest(owner=owner, value=value):
                    payload = self.payload()
                    target = (
                        payload["release"]
                        if owner == "release"
                        else payload["runs"]["workflow_runs"][0]
                    )
                    target[field] = value
                    with self.assertRaises(self.module.ReadinessError):
                        self.verify(payload)

    def test_rejects_a_package_run_completed_before_publication(self) -> None:
        payload = self.payload()
        payload["runs"]["workflow_runs"][0]["updated_at"] = "2026-09-11T20:04:59Z"
        with self.assertRaises(self.module.ReadinessError):
            self.verify(payload)


if __name__ == "__main__":
    unittest.main()
