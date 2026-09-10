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

import argparse
from collections.abc import Sequence
import importlib.util
from pathlib import Path
import unittest
from unittest import mock

MODULE_PATH = Path(__file__).with_name("documentation-authority.py")
SPEC = importlib.util.spec_from_file_location("documentation_authority", MODULE_PATH)
assert SPEC is not None and SPEC.loader is not None
AUTHORITY = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(AUTHORITY)


class DocumentationAuthorityTests(unittest.TestCase):
    def options(self) -> argparse.Namespace:
        return AUTHORITY.parse_arguments(
            (
                "--compose-repository",
                "owner/compose",
                "--compose-tag",
                "1.2.3",
                "--compose-release-id",
                "12",
                "--compose-ref",
                "a" * 40,
                "--component",
                f"owner/container={'b' * 40}",
                "--k8s-repository",
                "owner/k8s",
                "--k8s-tag",
                "4.5.6",
                "--k8s-release-id",
                "34",
                "--k8s-ref",
                "c" * 40,
            )
        )

    @staticmethod
    def command_result(arguments: Sequence[str]) -> str:
        joined = " ".join(arguments)
        if "releases/tags/1.2.3" in joined:
            return (
                '{"id":12,"tag_name":"1.2.3",'
                '"draft":false,"prerelease":false}'
            )
        if "releases/tags/4.5.6" in joined:
            return (
                '{"id":34,"tag_name":"4.5.6",'
                '"draft":false,"prerelease":true}'
            )
        if "commits/" in joined:
            return "b" * 40
        if "owner/compose.git" in joined:
            return f"{'a' * 40}\trefs/tags/1.2.3"
        if "owner/k8s.git" in joined:
            return f"{'c' * 40}\trefs/tags/4.5.6"
        raise AssertionError(arguments)

    def test_unchanged_authority_has_a_stable_digest(self) -> None:
        with mock.patch.object(
            AUTHORITY, "run_command", side_effect=self.command_result
        ):
            first = AUTHORITY.authority_digest(self.options())
            second = AUTHORITY.authority_digest(self.options())

        self.assertRegex(first, r"^[0-9a-f]{64}$")
        self.assertEqual(first, second)

    def test_changed_release_identity_is_rejected(self) -> None:
        def changed(arguments):
            if "releases/tags/1.2.3" in " ".join(arguments):
                return (
                    '{"id":99,"tag_name":"1.2.3",'
                    '"draft":false,"prerelease":false}'
                )
            return self.command_result(arguments)

        with mock.patch.object(AUTHORITY, "run_command", side_effect=changed):
            with self.assertRaisesRegex(ValueError, "release authority changed"):
                AUTHORITY.authority_digest(self.options())

    def test_moved_tag_is_rejected(self) -> None:
        def moved(arguments):
            if "owner/compose.git" in " ".join(arguments):
                return f"{'d' * 40}\trefs/tags/1.2.3"
            return self.command_result(arguments)

        with mock.patch.object(AUTHORITY, "run_command", side_effect=moved):
            with self.assertRaisesRegex(ValueError, "published tag moved"):
                AUTHORITY.authority_digest(self.options())

    def test_compose_prerelease_is_rejected(self) -> None:
        def prerelease(arguments):
            if "releases/tags/1.2.3" in " ".join(arguments):
                return (
                    '{"id":12,"tag_name":"1.2.3",'
                    '"draft":false,"prerelease":true}'
                )
            return self.command_result(arguments)

        with mock.patch.object(
            AUTHORITY, "run_command", side_effect=prerelease
        ):
            with self.assertRaisesRegex(ValueError, "release authority changed"):
                AUTHORITY.authority_digest(self.options())

    def test_k8s_prerelease_state_is_bound_into_authority(self) -> None:
        with mock.patch.object(
            AUTHORITY, "run_command", side_effect=self.command_result
        ):
            prerelease = AUTHORITY.authority_digest(self.options())

        def stable(arguments):
            if "releases/tags/4.5.6" in " ".join(arguments):
                return (
                    '{"id":34,"tag_name":"4.5.6",'
                    '"draft":false,"prerelease":false}'
                )
            return self.command_result(arguments)

        with mock.patch.object(AUTHORITY, "run_command", side_effect=stable):
            release = AUTHORITY.authority_digest(self.options())

        self.assertNotEqual(prerelease, release)

    def test_k8s_draft_is_rejected(self) -> None:
        def draft(arguments):
            if "releases/tags/4.5.6" in " ".join(arguments):
                return (
                    '{"id":34,"tag_name":"4.5.6",'
                    '"draft":true,"prerelease":true}'
                )
            return self.command_result(arguments)

        with mock.patch.object(AUTHORITY, "run_command", side_effect=draft):
            with self.assertRaisesRegex(ValueError, "release authority changed"):
                AUTHORITY.authority_digest(self.options())


if __name__ == "__main__":
    unittest.main()
