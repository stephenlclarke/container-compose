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

"""Focused tests for durable release host-state restoration authority."""

import importlib.util
import json
import sys
import tempfile
import unittest
from pathlib import Path


MODULE_PATH = Path(__file__).with_name("release-host-state.py")
SPEC = importlib.util.spec_from_file_location("release_host_state", MODULE_PATH)
assert SPEC is not None and SPEC.loader is not None
HOST_STATE = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = HOST_STATE
SPEC.loader.exec_module(HOST_STATE)


class ReleaseHostStateTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name) / "host-state"
        self.label = "actions.runner.owner-container-compose.release-host"
        self.plist = f"/tmp/{self.label}.plist"
        self.entry = HOST_STATE.validate_launch_agent(self.label, self.plist)

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def test_record_list_and_remove_are_idempotent(self) -> None:
        HOST_STATE.record_launch_agent(self.root, self.entry)
        HOST_STATE.record_launch_agent(self.root, self.entry)

        self.assertEqual(HOST_STATE.load_launch_agents(self.root), [self.entry])
        journal = self.root / HOST_STATE.JOURNAL
        self.assertEqual(journal.stat().st_mode & 0o077, 0)

        HOST_STATE.remove_launch_agent(self.root, self.entry)
        HOST_STATE.remove_launch_agent(self.root, self.entry)

        self.assertEqual(HOST_STATE.load_launch_agents(self.root), [])
        self.assertFalse(journal.exists())

    def test_conflicting_plist_is_rejected_without_replacing_authority(self) -> None:
        HOST_STATE.record_launch_agent(self.root, self.entry)
        conflicting = HOST_STATE.LaunchAgent(
            label=self.label,
            plist=f"/private/tmp/{self.label}.plist",
        )

        with self.assertRaisesRegex(HOST_STATE.HostStateError, "already maps"):
            HOST_STATE.record_launch_agent(self.root, conflicting)

        self.assertEqual(HOST_STATE.load_launch_agents(self.root), [self.entry])

    def test_insertion_order_is_preserved_for_reverse_restoration(self) -> None:
        second_label = "homebrew.mxcl.devcontainer"
        second = HOST_STATE.validate_launch_agent(
            second_label,
            f"/tmp/{second_label}.plist",
        )

        HOST_STATE.record_launch_agent(self.root, self.entry)
        HOST_STATE.record_launch_agent(self.root, second)

        self.assertEqual(
            HOST_STATE.load_launch_agents(self.root),
            [self.entry, second],
        )

    def test_malformed_journal_fails_closed(self) -> None:
        HOST_STATE.require_state_root(self.root)
        journal = self.root / HOST_STATE.JOURNAL
        journal.write_text('{"schema":1}\n', encoding="utf-8")
        journal.chmod(0o600)

        with self.assertRaisesRegex(HOST_STATE.HostStateError, "structure"):
            HOST_STATE.load_launch_agents(self.root)

    def test_insecure_or_linked_state_is_rejected(self) -> None:
        HOST_STATE.record_launch_agent(self.root, self.entry)
        journal = self.root / HOST_STATE.JOURNAL
        payload = json.loads(journal.read_text(encoding="utf-8"))
        journal.unlink()
        target = self.root / "target.json"
        target.write_text(json.dumps(payload), encoding="utf-8")
        target.chmod(0o600)
        journal.symlink_to(target)

        with self.assertRaisesRegex(HOST_STATE.HostStateError, "untrusted"):
            HOST_STATE.load_launch_agents(self.root)

        journal.unlink()
        target.rename(journal)
        journal.chmod(0o644)
        with self.assertRaisesRegex(HOST_STATE.HostStateError, "permissions"):
            HOST_STATE.load_launch_agents(self.root)

    def test_dangling_marker_and_journal_links_are_rejected(self) -> None:
        HOST_STATE.require_state_root(self.root)
        marker = self.root / HOST_STATE.ROOT_MARKER
        marker.unlink()
        marker.symlink_to(self.root / "missing-marker")
        with self.assertRaisesRegex(HOST_STATE.HostStateError, "untrusted"):
            HOST_STATE.load_launch_agents(self.root)

        marker.unlink()
        marker.write_text(HOST_STATE.ROOT_MARKER_VALUE, encoding="utf-8")
        marker.chmod(0o600)
        journal = self.root / HOST_STATE.JOURNAL
        journal.symlink_to(self.root / "missing-journal")
        with self.assertRaisesRegex(HOST_STATE.HostStateError, "untrusted"):
            HOST_STATE.load_launch_agents(self.root)

    def test_label_and_plist_identity_are_validated(self) -> None:
        with self.assertRaisesRegex(HOST_STATE.HostStateError, "label"):
            HOST_STATE.validate_launch_agent("bad\tlabel", self.plist)
        with self.assertRaisesRegex(HOST_STATE.HostStateError, "does not match"):
            HOST_STATE.validate_launch_agent(self.label, "/tmp/other.plist")


if __name__ == "__main__":
    unittest.main()
