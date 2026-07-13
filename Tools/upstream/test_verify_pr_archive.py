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

"""Unit tests for the immutable upstream PR archive ledger."""

from __future__ import annotations

import importlib.util
import json
import sys
import tempfile
import unittest
from pathlib import Path


def load_module():
    path = Path(__file__).with_name("verify-pr-archive.py")
    spec = importlib.util.spec_from_file_location("verify_pr_archive", path)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"could not load {path}")
    module = importlib.util.module_from_spec(spec)
    sys.modules["verify_pr_archive"] = module
    spec.loader.exec_module(module)
    return module


class UpstreamArchiveLedgerTests(unittest.TestCase):
    """Archive entries are immutable, full-SHA, Stephen-owned references."""

    def test_committed_ledger_is_valid(self) -> None:
        module = load_module()
        entries = module.load_ledger(
            Path(__file__).parents[2] / "docs" / "upstream" / "PR-ARCHIVE.json"
        )
        self.assertGreaterEqual(len(entries), 6)

    def test_rejects_mutable_or_non_stephen_entry(self) -> None:
        module = load_module()
        with tempfile.TemporaryDirectory() as directory:
            ledger = Path(directory) / "ledger.json"
            ledger.write_text(
                json.dumps(
                    {
                        "schemaVersion": 1,
                        "pullRequests": [
                            {
                                "upstream": "apple/container#1",
                                "repository": "apple/container",
                                "archiveRef": "refs/heads/main",
                                "commit": "a" * 40,
                            }
                        ],
                    }
                ),
                encoding="utf-8",
            )
            with self.assertRaisesRegex(ValueError, "Stephen-owned"):
                module.load_ledger(ledger)


if __name__ == "__main__":
    unittest.main()
