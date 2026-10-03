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

"""Assertion-copy normalization preserves raw command captures and suffixes."""

from __future__ import annotations

import json
import os
from pathlib import Path
import shlex
import stat
import subprocess
import sys
import tempfile
import unittest


HELPER = Path(__file__).with_name("normalize-container-command-output.py")


class NormalizeContainerCommandOutputTests(unittest.TestCase):
    def setUp(self) -> None:
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)

    def invoke(self, raw: bytes, *, selected: str | None, arguments: list[str],
               evidence: bool = False) -> subprocess.CompletedProcess[bytes]:
        environment = dict(os.environ)
        environment.pop("CONTAINER_BIN", None)
        environment.pop("CONTAINER_COMPOSE_CONTAINER", None)
        environment.pop("PARITY_EVIDENCE_DIR", None)
        if selected is not None:
            environment["CONTAINER_BIN"] = selected
        if evidence:
            environment["PARITY_EVIDENCE_DIR"] = str(self.root)
        return subprocess.run([sys.executable, str(HELPER), *arguments], input=raw,
                              capture_output=True, env=environment, check=False)

    def test_stdin_preserves_suffix_bytes_and_unrelated_output(self) -> None:
        selected = "/private/run/can't stop/container"
        suffix = b'\t--name "two  spaces"  --label x=1\r\n'
        raw = (b"+ " + shlex.quote(selected).encode() + suffix +
               b'+ docker compose up\n' +
               b'{"command":"/private/run/container create"}\n' +
               b'prose mentions container create\n')
        result = self.invoke(raw, selected=selected, arguments=["--label", "command-capture"])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, b"+ container" + suffix + raw[len(b"+ ") +
                         len(shlex.quote(selected).encode()) + len(suffix):])

    def test_file_mode_keeps_raw_and_writes_private_assertion_copy_and_receipt(self) -> None:
        selected = "/private/signed/runtime/bin/container"
        source = self.root / "capture with spaces.log"
        raw = (b"+ " + selected.encode() + b" create --name 'a b'\n" +
               b"+ docker compose ps\n")
        source.write_bytes(raw)
        result = self.invoke(b"", selected=selected, arguments=["--file", str(source)],
                             evidence=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        output = Path(result.stdout.decode().strip())
        self.assertEqual(output, Path(str(source) + ".assertions"))
        self.assertEqual(source.read_bytes(), raw)
        self.assertEqual(output.read_bytes(), b"+ container create --name 'a b'\n"
                         b"+ docker compose ps\n")
        self.assertEqual(stat.S_IMODE(output.stat().st_mode), 0o600)
        directory = self.root / "command-assertions"
        self.assertEqual(stat.S_IMODE(directory.stat().st_mode), 0o700)
        raw_copy, = directory.glob("*.raw")
        receipt_path, = directory.glob("*.json")
        self.assertEqual(raw_copy.read_bytes(), raw)
        receipt = json.loads(receipt_path.read_text())
        self.assertEqual(receipt['selectedExecutable'], selected)
        self.assertEqual(receipt['rewrittenLines'], 1)
        self.assertEqual(len(receipt['rawSHA256']), 64)
        self.assertEqual(len(receipt['canonicalSHA256']), 64)

    def test_different_container_executable_fails_before_assertions(self) -> None:
        source = self.root / "capture.log"
        source.write_bytes(b"+ /wrong/runtime/bin/container create --name x\n")
        result = self.invoke(b"", selected="/signed/runtime/bin/container",
                             arguments=["--file", str(source)], evidence=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(Path(str(source) + ".assertions").exists())
        self.assertEqual(source.read_bytes(), b"+ /wrong/runtime/bin/container create --name x\n")
        failure_receipt, = (self.root / "command-assertions").glob("*.json")
        receipt = json.loads(failure_receipt.read_text())
        self.assertIsNone(receipt['canonicalSHA256'])
        self.assertIn('different Container executable', receipt['failure'])
        failure_raw, = (self.root / "command-assertions").glob("*.raw")
        self.assertEqual(failure_raw.read_bytes(), source.read_bytes())
        bare = self.invoke(b"+ container create\n", selected="/signed/runtime/bin/container",
                           arguments=["--label", "bare"])
        self.assertNotEqual(bare.returncode, 0)

    def test_malformed_first_token_fails_without_changing_raw_file(self) -> None:
        source = self.root / "bad.log"
        raw = b"+ '/unterminated/container create\n"
        source.write_bytes(raw)
        result = self.invoke(b"", selected="/signed/runtime/bin/container",
                             arguments=["--file", str(source)])
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(source.read_bytes(), raw)
        self.assertFalse(Path(str(source) + ".assertions").exists())

    def test_default_selected_executable_only_changes_command_token(self) -> None:
        raw = b"+ container inspect x\n+ echo container inspect x\n"
        result = self.invoke(raw, selected=None, arguments=["--label", "default"])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, raw)

    def test_explicit_empty_selected_executable_does_not_fall_back(self) -> None:
        result = self.invoke(b"+ container inspect x\n", selected="",
                             arguments=["--label", "empty"])
        self.assertNotEqual(result.returncode, 0)

    def test_repeated_label_retains_distinct_raw_capture_identities(self) -> None:
        first = self.invoke(b"+ container create one\n", selected="container",
                            arguments=["--label", "same"], evidence=True)
        second = self.invoke(b"+ container create two\n", selected="container",
                             arguments=["--label", "same"], evidence=True)
        self.assertEqual((first.returncode, second.returncode), (0, 0))
        directory = self.root / "command-assertions"
        self.assertEqual(len(list(directory.glob("same-*.raw"))), 2)
        self.assertEqual(len(list(directory.glob("same-*.json"))), 2)


if __name__ == "__main__":
    unittest.main()
