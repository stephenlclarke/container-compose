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

"""Regression tests for Developer ID release archive verification."""

import os
from pathlib import Path
import subprocess
import tarfile
import tempfile
import textwrap
import unittest


ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "Tools" / "release" / "verify-developer-id-archive.sh"


class VerifyDeveloperIDArchiveTests(unittest.TestCase):
    def make_archive(self, root: Path, names: list[str]) -> Path:
        payload = root / "payload"
        payload.mkdir()
        for name in names:
            path = payload / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(name, encoding="utf-8")
            path.chmod(0o755)

        archive = root / "package.tar.gz"
        with tarfile.open(archive, "w:gz") as output:
            for path in payload.rglob("*"):
                output.add(path, arcname=path.relative_to(payload))
        return archive

    def make_tools(
        self,
        root: Path,
        *,
        authority: bool = True,
        apple_chain: bool = True,
        runtime: bool = True,
        second_team: bool = False,
    ) -> dict[str, str]:
        file_command = root / "file"
        file_command.write_text(
            textwrap.dedent(
                """\
                #!/usr/bin/env bash
                case "$2" in
                  *.txt) printf 'ASCII text\\n' ;;
                  *) printf 'Mach-O 64-bit executable arm64\\n' ;;
                esac
                """
            ),
            encoding="utf-8",
        )
        file_command.chmod(0o755)

        authority_lines = (
            "\n".join(
                [
                    "Authority=Developer ID Application: Stephen Clarke (ABCDEFGHIJ)",
                    "Authority=Developer ID Certification Authority",
                    "Authority=Apple Root CA",
                ]
            )
            if authority and apple_chain
            else "Authority=Developer ID Application: Stephen Clarke (ABCDEFGHIJ)"
            if authority
            else "Signature=adhoc"
        )
        authority_lines = authority_lines.replace("\n", "\n                ")
        flags = "0x10000(runtime)" if runtime else "0x0(none)"
        flags_line = (
            f"CodeDirectory v=20500 size=128 flags={flags} "
            "hashes=2+2 location=embedded"
        )
        team_expression = (
            '[[ "$path" == *second ]] && team=ZZZZZZZZZZ'
            if second_team
            else ":"
        )
        codesign_command = root / "codesign"
        codesign_command.write_text(
            textwrap.dedent(
                f"""\
                #!/usr/bin/env bash
                if [[ "$1" == "--verify" ]]; then
                  exit 0
                fi
                path="${{@: -1}}"
                team=ABCDEFGHIJ
                {team_expression}
                cat >&2 <<'EOF'
                {flags_line}
                {authority_lines}
                Timestamp=29 Jul 2026 at 12:00:00
                EOF
                printf 'TeamIdentifier=%s\\n' "$team" >&2
                """
            ),
            encoding="utf-8",
        )
        codesign_command.chmod(0o755)
        return {
            **os.environ,
            "CODESIGN": str(codesign_command),
            "FILE_COMMAND": str(file_command),
        }

    def run_script(
        self, archive: Path, environment: dict[str, str]
    ) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            ["bash", str(SCRIPT), str(archive)],
            cwd=ROOT,
            env=environment,
            text=True,
            capture_output=True,
            check=False,
        )

    def test_accepts_one_team_and_ignores_non_macho_resources(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            archive = self.make_archive(
                root, ["bin/compose", "resources/normalizer", "resources/info.txt"]
            )

            result = self.run_script(archive, self.make_tools(root))

            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("Verified 2 Developer ID signed Mach-O binaries", result.stdout)

    def test_rejects_an_ad_hoc_signature(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            archive = self.make_archive(root, ["bin/compose"])

            result = self.run_script(
                archive, self.make_tools(root, authority=False)
            )

            self.assertNotEqual(result.returncode, 0)
            self.assertIn("not signed by a Developer ID Application", result.stderr)

    def test_rejects_a_signature_without_hardened_runtime(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            archive = self.make_archive(root, ["bin/compose"])

            result = self.run_script(archive, self.make_tools(root, runtime=False))

            self.assertNotEqual(result.returncode, 0)
            self.assertIn("missing the hardened runtime", result.stderr)

    def test_rejects_a_signature_without_the_apple_certificate_chain(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            archive = self.make_archive(root, ["bin/compose"])

            result = self.run_script(
                archive, self.make_tools(root, apple_chain=False)
            )

            self.assertNotEqual(result.returncode, 0)
            self.assertIn(
                "does not chain through the Developer ID certification authority",
                result.stderr,
            )

    def test_rejects_mixed_developer_teams(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            archive = self.make_archive(root, ["bin/first", "bin/second"])

            result = self.run_script(
                archive, self.make_tools(root, second_team=True)
            )

            self.assertNotEqual(result.returncode, 0)
            self.assertIn("archive mixes Developer ID teams", result.stderr)

    def test_rejects_an_archive_path_escape(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / "source"
            source.write_text("escape", encoding="utf-8")
            archive = root / "package.tar.gz"
            with tarfile.open(archive, "w:gz") as output:
                output.add(source, arcname="../escape")

            result = self.run_script(archive, self.make_tools(root))

            self.assertNotEqual(result.returncode, 0)
            self.assertIn("unsafe archive path", result.stderr)


if __name__ == "__main__":
    unittest.main()
