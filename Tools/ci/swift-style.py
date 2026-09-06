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

"""Install and run the repository's deterministic Swift style toolchain."""

from __future__ import annotations

import argparse
import hashlib
import os
import shutil
import stat
import subprocess
import tempfile
import zipfile
from dataclasses import dataclass
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
LEGACY_EXCLUSIONS = frozenset(
    {
        "Sources/ComposePlugin/ComposeCLIHelp.swift",
        "Tests/ComposePluginTests/ComposeCLIHelpTests.swift",
        "Sources/ComposePlugin/ComposePlugin.swift",
        "Sources/ComposeCore/ComposeCommandOptions.swift",
        "Sources/ComposeCore/ComposeCommitImageArchive.swift",
        "Sources/ComposeCore/ComposeExecutionOptions.swift",
        "Sources/ComposeCore/ComposeOrchestratorBuildAndImages.swift",
        "Sources/ComposeCore/ComposeOrchestratorCreateAndLogs.swift",
        "Sources/ComposeCore/ComposeOrchestratorMountsContainersVolumes.swift",
        "Sources/ComposeCore/ComposeOrchestratorRunCopyStart.swift",
        "Sources/ComposeCore/ComposeOrchestratorUp.swift",
        "Sources/ComposeCore/ComposeOrchestratorWaitAndPorts.swift",
        "Sources/ComposeCore/ContainerDiscoveryAdapter.swift",
        "Tests/ComposeCoreTests/ComposeOrchestratorTests.swift",
        "Sources/ComposeContainerRuntime/ComposeCommitImageArchive.swift",
        "Tests/ComposeCoreTests/ComposeOrchestratorBuildAndImageTests.swift",
        "Tests/ComposeCoreTests/ComposeOrchestratorCopyExportCommitTests.swift",
        "Tests/ComposeCoreTests/ComposeOrchestratorInspectionAndConfigTests.swift",
        "Tests/ComposeCoreTests/ComposeOrchestratorLifecycleTests.swift",
        "Tests/ComposeCoreTests/ComposeOrchestratorLogsWatchAttachTests.swift",
        "Tests/ComposeCoreTests/ComposeOrchestratorResourceTests.swift",
        "Tests/ComposeCoreTests/ComposeOrchestratorRunTests.swift",
        "Tests/ComposeCoreTests/ComposeOrchestratorRuntimeAdapterTests.swift",
        "Tests/ComposeCoreTests/ComposeOrchestratorTestSupport.swift",
        "Tests/ComposeCoreTests/ComposeOrchestratorUpAndCreateTests.swift",
        "Tests/ComposeCoreTests/ComposeOrchestratorValidationTests.swift",
        "Sources/ComposePlugin/ContainerPackageCompatibility.swift",
        "Tests/ComposePluginTests/ContainerPackageCompatibilityTests.swift",
        "Tests/ComposeCoreTests/ComposeNormalizerTests.swift",
        "Tests/ComposeRuntimeTests/ComposeRuntimeSmokeTests.swift",
    }
)


@dataclass(frozen=True)
class Tool:
    name: str
    version: str
    url: str
    archive_sha256: str
    member: str
    executable_sha256: str


TOOLS = (
    Tool(
        name="swiftlint",
        version="0.65.1",
        url="https://github.com/realm/SwiftLint/releases/download/0.65.1/portable_swiftlint.zip",
        archive_sha256="c1e429b0599cf1b516f369a2d9ec04eaf0e436f3c12b637df8851fa52ff694d0",
        member="swiftlint",
        executable_sha256="52112ece2dfa99c2442a1367f9a365d43784714cf224c3675bf8bc2f18ebd7c8",
    ),
    Tool(
        name="swiftformat",
        version="0.63.0",
        url="https://github.com/nicklockwood/SwiftFormat/releases/download/0.63.0/swiftformat.zip",
        archive_sha256="28c7802e11fa5ae113d903066439c6bb1be20a8ac1ad9709c42616a7e273fb0f",
        member="swiftformat",
        executable_sha256="4cb54c31a889282e7f2473515d498f07c71f3aa0a66bbc056837c006149a8af1",
    ),
)


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def cache_root() -> Path:
    configured = os.environ.get("SWIFT_STYLE_CACHE_ROOT")
    root = Path(configured) if configured else ROOT / ".local" / "share" / "swift-style"
    if not root.is_absolute():
        raise SystemExit(f"SWIFT_STYLE_CACHE_ROOT must be absolute: {root}")
    return root


def download(url: str, destination: Path) -> None:
    subprocess.run(
        [
            "/usr/bin/curl",
            "--fail",
            "--location",
            "--silent",
            "--show-error",
            "--connect-timeout",
            "20",
            "--max-time",
            "600",
            "--max-filesize",
            "67108864",
            "--retry",
            "3",
            "--retry-all-errors",
            "--output",
            str(destination),
            url,
        ],
        check=True,
        stdin=subprocess.DEVNULL,
    )


def install_tool(tool: Tool, root: Path, downloader=download) -> Path:
    destination = root / f"{tool.name}-{tool.version}" / tool.name
    if destination.is_file() and not destination.is_symlink():
        if sha256(destination) == tool.executable_sha256:
            return destination

    destination.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix=f".{tool.name}-", dir=destination.parent) as temporary:
        temporary_root = Path(temporary)
        archive = temporary_root / "tool.zip"
        downloader(tool.url, archive)
        actual_archive_sha256 = sha256(archive)
        if actual_archive_sha256 != tool.archive_sha256:
            raise SystemExit(
                f"{tool.name} archive digest mismatch: expected {tool.archive_sha256}, "
                f"got {actual_archive_sha256}"
            )
        extracted = temporary_root / tool.name
        with zipfile.ZipFile(archive) as bundle:
            members = {member.filename: member for member in bundle.infolist()}
            if tool.member not in members or members[tool.member].is_dir():
                raise SystemExit(f"{tool.name} archive has no {tool.member} executable")
            with bundle.open(members[tool.member]) as source, extracted.open("wb") as target:
                shutil.copyfileobj(source, target)
        actual_executable_sha256 = sha256(extracted)
        if actual_executable_sha256 != tool.executable_sha256:
            raise SystemExit(
                f"{tool.name} executable digest mismatch: expected "
                f"{tool.executable_sha256}, got {actual_executable_sha256}"
            )
        extracted.chmod(stat.S_IRUSR | stat.S_IWUSR | stat.S_IXUSR)
        os.replace(extracted, destination)
    return destination


def install_tools(root: Path) -> dict[str, Path]:
    installed = {tool.name: install_tool(tool, root) for tool in TOOLS}
    for tool in TOOLS:
        result = subprocess.run(
            [str(installed[tool.name]), "version" if tool.name == "swiftlint" else "--version"],
            check=True,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )
        if result.stdout.strip() != tool.version:
            raise SystemExit(
                f"{tool.name} version mismatch: expected {tool.version}, "
                f"got {result.stdout.strip() or 'missing'}"
            )
        print(f"{tool.name} {tool.version}: {installed[tool.name]}")
    return installed


def git(*arguments: str) -> str:
    result = subprocess.run(
        ["/usr/bin/git", "-C", str(ROOT), *arguments],
        check=True,
        stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )
    return result.stdout


def changed_paths() -> tuple[str, ...]:
    if os.environ.get("SWIFT_STYLE_ALL") == "1":
        output = git("ls-files", "Package.swift", "Sources", "Tests")
    elif files_from := os.environ.get("SWIFT_STYLE_FILES_FROM"):
        path = Path(files_from)
        if not path.is_absolute():
            raise SystemExit(f"SWIFT_STYLE_FILES_FROM must be absolute: {path}")
        output = path.read_text(encoding="utf-8")
    elif os.environ.get("SWIFT_STYLE_STAGED") == "1":
        output = git("diff", "--cached", "--name-only", "--diff-filter=ACMR")
    else:
        base = os.environ.get("SWIFT_STYLE_BASE", "origin/main")
        head = os.environ.get("SWIFT_STYLE_HEAD", "HEAD")
        output = git("diff", "--name-only", "--diff-filter=ACMR", f"{base}...{head}")
    return tuple(line for line in output.splitlines() if line)


def style_paths(paths: tuple[str, ...]) -> tuple[str, ...]:
    selected = []
    for relative in paths:
        if relative in LEGACY_EXCLUSIONS:
            continue
        if relative == "Package.swift" or (
            relative.endswith(".swift")
            and (relative.startswith("Sources/") or relative.startswith("Tests/"))
        ):
            candidate = ROOT / relative
            if candidate.is_file() and not candidate.is_symlink():
                selected.append(relative)
    return tuple(sorted(set(selected)))


def run_style(action: str) -> None:
    paths = style_paths(changed_paths())
    if not paths:
        print("No Swift style paths selected.")
        return
    print("Selected Swift style paths:")
    for path in paths:
        print(f"  {path}")
    tools = install_tools(cache_root())
    if action == "lint":
        subprocess.run(
            [
                str(tools["swiftlint"]),
                "lint",
                "--strict",
                "--quiet",
                "--config",
                str(ROOT / ".swiftlint.yml"),
                *paths,
            ],
            check=True,
            cwd=ROOT,
            stdin=subprocess.DEVNULL,
        )
        subprocess.run(
            [
                str(tools["swiftformat"]),
                *paths,
                "--lint",
                "--config",
                str(ROOT / ".swiftformat"),
            ],
            check=True,
            cwd=ROOT,
            stdin=subprocess.DEVNULL,
        )
    else:
        subprocess.run(
            [
                str(tools["swiftformat"]),
                *paths,
                "--config",
                str(ROOT / ".swiftformat"),
            ],
            check=True,
            cwd=ROOT,
            stdin=subprocess.DEVNULL,
        )


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=("install", "paths", "lint", "format"))
    arguments = parser.parse_args()
    if arguments.action == "install":
        install_tools(cache_root())
    elif arguments.action == "paths":
        print("\n".join(style_paths(changed_paths())))
    else:
        run_style(arguments.action)


if __name__ == "__main__":
    main()
