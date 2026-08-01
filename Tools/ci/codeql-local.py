#!/usr/bin/python3 -I
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

"""Run the pinned local CodeQL Go analysis and upload exact-commit SARIF."""

from __future__ import annotations

import argparse
from dataclasses import dataclass
from datetime import date
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import platform
import pwd
import re
import shutil
import shlex
import stat
import subprocess
import sys
import tempfile
import time
from typing import Any
import urllib.parse
import zipfile


CODEQL_VERSION = "2.26.2"
CODEQL_QUERY_PACK = "codeql/go-queries"
CODEQL_QUERY_PACK_VERSION = "1.6.7"
CODEQL_QUERY_SUITE = (
    f"{CODEQL_QUERY_PACK}@{CODEQL_QUERY_PACK_VERSION}:"
    "codeql-suites/go-code-scanning.qls"
)
GO_TOOLCHAIN_VERSION = "go1.26.3"
GITHUB_CLI_VERSION = "2.96.0"
CODEQL_CATEGORY = "/language:swift-go"
CODEQL_SARIF_AUTOMATION_ID = f"{CODEQL_CATEGORY}/"
CODEQL_BUILD_TARGET = "go-build"
CODEQL_BUILD_ENVIRONMENT = {
    "CGO_ENABLED": "0",
    "GOENV": "off",
    "GOFLAGS": "-mod=readonly",
    "GOARCH": "amd64",
    "GOOS": "linux",
    "GONOPROXY": "",
    "GONOSUMDB": "",
    "GOPRIVATE": "",
    "GOPROXY": "https://proxy.golang.org",
    "GOSUMDB": "sum.golang.org",
    "GOTOOLCHAIN": "local",
    "GOVCS": "*:off",
    "GOWORK": "off",
}
CODEQL_ENVIRONMENT_POLICY = "allowlist-trusted-system-temp-v2"
CODEQL_GO_CACHE_POLICY = "fresh-temporary-v1"
CODEQL_TEMPORARY_ROOT_POLICY = "fixed-root-owned-sticky-v1"
CODEQL_FIXED_PATH = "/usr/bin:/bin:/usr/sbin:/sbin"
CODEQL_GIT_ENVIRONMENT = {
    "GIT_ASKPASS": "/usr/bin/false",
    "GIT_CONFIG_COUNT": "0",
    "GIT_CONFIG_GLOBAL": "/dev/null",
    "GIT_CONFIG_NOSYSTEM": "1",
    "GIT_CONFIG_SYSTEM": "/dev/null",
    "GIT_NO_REPLACE_OBJECTS": "1",
    "GIT_OPTIONAL_LOCKS": "0",
    "GIT_PAGER": "cat",
    "GIT_TERMINAL_PROMPT": "0",
    "SSH_ASKPASS": "/usr/bin/false",
}
CODEQL_GIT_COMMAND_CONFIG = {
    "core.attributesFile": "/dev/null",
    "core.excludesFile": "/dev/null",
    "core.fsmonitor": "false",
    "core.hooksPath": "/dev/null",
    "credential.helper": "",
    "protocol.allow": "never",
    "protocol.ext.allow": "never",
    "protocol.file.allow": "never",
    "protocol.git.allow": "never",
    "protocol.http.allow": "never",
    "protocol.https.allow": "always",
    "protocol.ssh.allow": "never",
}
CODEQL_CREDENTIAL_PASSTHROUGH_ENVIRONMENT = (
    "LANG",
    "LC_ALL",
    "LC_CTYPE",
)
CODEQL_NETWORK_PASSTHROUGH_ENVIRONMENT = (
    "SSL_CERT_FILE",
    "SSL_CERT_DIR",
    "HTTP_PROXY",
    "HTTPS_PROXY",
    "NO_PROXY",
    "http_proxy",
    "https_proxy",
    "no_proxy",
)
CODEQL_PASSTHROUGH_ENVIRONMENT = (
    CODEQL_CREDENTIAL_PASSTHROUGH_ENVIRONMENT
    + CODEQL_NETWORK_PASSTHROUGH_ENVIRONMENT
)
CODEQL_CREDENTIAL_ENVIRONMENT_POLICY = (
    "post-scrub-cli-auth-store-direct-system-trust-no-proxy-trusted-temp-v3"
)
CODEQL_CREDENTIAL_SOURCE = "pinned-github-cli-auth-store-post-scrub-v1"
CODEQL_REMOTE_IDENTITY_ENVIRONMENT_POLICY = "direct-system-trust-no-proxy-v1"
TRUSTED_TEMPORARY_ROOT = Path("/private/tmp" if sys.platform == "darwin" else "/tmp")
TRUSTED_MAKE_CANDIDATES = (Path("/usr/bin/make"),)
TRUSTED_MAKE_ROOTS = (Path("/usr/bin"),)
TRUSTED_WORKFLOW_TOOL_CANDIDATES = {
    "osx64": {
        "git": (Path("/usr/bin/git"),),
        "archiveExtractor": (Path("/usr/bin/tar"),),
        "downloader": (Path("/usr/bin/curl"),),
    },
    "linux64": {
        "git": (Path("/usr/bin/git"), Path("/bin/git")),
        "archiveExtractor": (Path("/usr/bin/tar"), Path("/bin/tar")),
        "downloader": (Path("/usr/bin/curl"), Path("/bin/curl")),
    },
}
TRUSTED_WORKFLOW_TOOL_ROOTS = {
    "osx64": (Path("/usr/bin"),),
    "linux64": (Path("/usr/bin"), Path("/bin")),
}
CODEQL_SOURCE_ISOLATION = "independent-clone-fsck-detached-raw-worktree-v2"
CODEQL_BUILD_OUTPUT_PATH = "Tools/compose-normalizer/compose-normalizer"
CODEQL_SUPPORTED_IGNORE_FILES = (".gitignore",)
CODEQL_CONFIG = Path(".github/codeql/codeql-config.yml")
CODEQL_BASELINE = Path(".github/codeql/codeql-baseline.json")
DEFAULT_CACHE_ROOT = Path(".local/share/codeql")
DEFAULT_ARTIFACT_ROOT = Path(".build/codeql")
MANIFEST_NAME = "manifest.json"
SARIF_NAME = "results.sarif"
UPLOAD_NAME = "upload.json"
COMMIT_PATTERN = re.compile(r"[0-9a-f]{40}(?:[0-9a-f]{24})?")
REF_PATTERN = re.compile(
    r"(?:refs/(?:heads|tags)/[A-Za-z0-9][A-Za-z0-9._/-]*"
    r"|refs/pull/[1-9][0-9]*/(?:head|merge))"
)
MAKE_ENVIRONMENT_ARGUMENTS = {
    "cache_root": "CODEQL_CACHE_ROOT",
    "artifact_root": "CODEQL_ARTIFACT_ROOT",
    "repository": "CODEQL_UPLOAD_REPOSITORY",
    "ref": "CODEQL_UPLOAD_REF",
    "commit": "CODEQL_UPLOAD_COMMIT",
}
CLEAN_MAKE_ENTRY = "CONTAINER_COMPOSE_CODEQL_CLEAN_MAKE_ENTRY"
ALLOWED_DISPOSITIONS = {
    "accepted-risk",
    "false-positive",
    "used-in-tests",
    "won't-fix",
}


class CodeQLError(RuntimeError):
    """A fail-closed local CodeQL workflow error."""


@dataclass(frozen=True)
class BundlePin:
    """One supported CodeQL bundle and its immutable checksum."""

    name: str
    sha256: str
    url: str


@dataclass(frozen=True)
class AuthenticatedAnalysis:
    """Digests retained in memory from one verified analyzer invocation."""

    path: Path
    commit: str
    manifest_sha256: str
    sarif_sha256: str
    result_count: int


BUNDLE_PINS = {
    "linux64": BundlePin(
        name="codeql-bundle-linux64.tar.gz",
        sha256="cb361567fa1bdb9d322da4240f621b36f245e4d7bb97db3c3a2ad7f743c8e8e7",
        url=(
            "https://github.com/github/codeql-action/releases/download/"
            f"codeql-bundle-v{CODEQL_VERSION}/codeql-bundle-linux64.tar.gz"
        ),
    ),
    "osx64": BundlePin(
        name="codeql-bundle-osx64.tar.gz",
        sha256="31641108d48133206e1ccd4bf047b21a0ce3347fdee66443cc3f7acf1b413126",
        url=(
            "https://github.com/github/codeql-action/releases/download/"
            f"codeql-bundle-v{CODEQL_VERSION}/codeql-bundle-osx64.tar.gz"
        ),
    ),
}
GO_TOOLCHAIN_PINS = {
    "darwin-amd64": BundlePin(
        name="go1.26.3.darwin-amd64.tar.gz",
        sha256="278d580b32e299fe4a9c990fcf2d02acfe538c7e551a6ee18f9c7164573d2c63",
        url="https://go.dev/dl/go1.26.3.darwin-amd64.tar.gz",
    ),
    "darwin-arm64": BundlePin(
        name="go1.26.3.darwin-arm64.tar.gz",
        sha256="875cf54a15311eee2c99b9dd67c68c4a49351d489ab622bf2cfd28c8f2078d3c",
        url="https://go.dev/dl/go1.26.3.darwin-arm64.tar.gz",
    ),
    "linux-amd64": BundlePin(
        name="go1.26.3.linux-amd64.tar.gz",
        sha256="2b2cfc7148493da5e73981bffbf3353af381d5f93e789c82c79aff64962eb556",
        url="https://go.dev/dl/go1.26.3.linux-amd64.tar.gz",
    ),
}
GITHUB_CLI_PINS = {
    "linux-amd64": BundlePin(
        name=f"gh_{GITHUB_CLI_VERSION}_linux_amd64.tar.gz",
        sha256="83d5c2ccad5498f58bf6368acb1ab32588cf43ab3a4b1c301bf36328b1c8bd60",
        url=(
            "https://github.com/cli/cli/releases/download/"
            f"v{GITHUB_CLI_VERSION}/gh_{GITHUB_CLI_VERSION}_linux_amd64.tar.gz"
        ),
    ),
    "macos-amd64": BundlePin(
        name=f"gh_{GITHUB_CLI_VERSION}_macOS_amd64.zip",
        sha256="4bd449df9ad639391bc62b8032546f0fe9edcd8526e06682a4f88abd8c5d163c",
        url=(
            "https://github.com/cli/cli/releases/download/"
            f"v{GITHUB_CLI_VERSION}/gh_{GITHUB_CLI_VERSION}_macOS_amd64.zip"
        ),
    ),
    "macos-arm64": BundlePin(
        name=f"gh_{GITHUB_CLI_VERSION}_macOS_arm64.zip",
        sha256="f23a0c37d963aacc3bed703ccbd59b41c5ca22101fab7f00eb2b7cad23aba463",
        url=(
            "https://github.com/cli/cli/releases/download/"
            f"v{GITHUB_CLI_VERSION}/gh_{GITHUB_CLI_VERSION}_macOS_arm64.zip"
        ),
    ),
}


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--make-environment",
        action="store_true",
        help=argparse.SUPPRESS,
    )
    parser.add_argument(
        "--repository-root",
        type=Path,
        default=Path.cwd(),
        help="container-compose checkout (default: current directory)",
    )
    parser.add_argument(
        "--cache-root",
        type=Path,
        default=DEFAULT_CACHE_ROOT,
        help="ignored persistent pinned-archive cache",
    )
    parser.add_argument(
        "--artifact-root",
        type=Path,
        default=DEFAULT_ARTIFACT_ROOT,
        help="commit-keyed SARIF evidence root",
    )
    subparsers = parser.add_subparsers(dest="command", required=True)

    subparsers.add_parser(
        "analyze",
        help="privately extract verified tools and retain local SARIF",
    )

    upload = subparsers.add_parser(
        "upload",
        help="upload retained SARIF only after exact repository/ref/head checks",
    )
    upload.add_argument("--repository", help="GitHub owner/repository")
    upload.add_argument("--ref", help="full Git ref for the analysis")
    upload.add_argument("--commit", help="exact full commit SHA")
    upload.add_argument(
        "--dry-run",
        action="store_true",
        help="verify identity and retained evidence without reading a token or uploading",
    )
    upload.add_argument(
        "--poll-interval",
        type=float,
        default=5.0,
        help="seconds between GitHub processing checks",
    )
    upload.add_argument(
        "--poll-timeout",
        type=float,
        default=300.0,
        help="maximum seconds to wait for the exact analysis",
    )
    upload.add_argument(
        "--gh",
        default="gh",
        help="checksum-pinned GitHub CLI (custom executables are unsupported)",
    )
    args = parser.parse_args()
    if args.make_environment:
        if os.environ.get(CLEAN_MAKE_ENTRY) != "1":
            parser.error(
                "invoke CodeQL Make goals through "
                "'source Tools/ci/codeql-entry.sh && "
                "container_compose_codeql <goal>'"
            )
        names = ("cache_root", "artifact_root")
        if args.command == "upload":
            names += ("repository", "ref", "commit")
        for name in names:
            environment_name = MAKE_ENVIRONMENT_ARGUMENTS[name]
            value = os.environ.get(environment_name, "")
            if not value:
                parser.error(f"{environment_name} is required")
            setattr(args, name, Path(value) if name.endswith("_root") else value)
    if args.command == "upload":
        for name in ("repository", "ref", "commit"):
            if not getattr(args, name):
                parser.error(f"--{name.replace('_', '-')} is required")
    return args


def run_command(
    arguments: list[str],
    *,
    cwd: Path | None = None,
    env: dict[str, str] | None = None,
    capture_output: bool = True,
) -> subprocess.CompletedProcess[str]:
    try:
        result = subprocess.run(
            arguments,
            cwd=cwd,
            env=env,
            check=False,
            capture_output=capture_output,
            text=True,
        )
    except OSError as error:
        raise CodeQLError(f"could not run {arguments[0]}: {error}") from error
    if result.returncode != 0:
        detail = ""
        if capture_output:
            detail = result.stderr.strip() or result.stdout.strip()
        suffix = f": {detail}" if detail else ""
        raise CodeQLError(f"{' '.join(arguments)} failed with exit {result.returncode}{suffix}")
    return result


def command_output(
    arguments: list[str],
    *,
    cwd: Path | None = None,
    env: dict[str, str] | None = None,
) -> str:
    return run_command(arguments, cwd=cwd, env=env).stdout.strip()


def command_bytes(
    arguments: list[str],
    *,
    cwd: Path | None = None,
    env: dict[str, str] | None = None,
) -> bytes:
    """Run a command without decoding output that may contain paths or blobs."""

    try:
        result = subprocess.run(
            arguments,
            cwd=cwd,
            env=env,
            check=False,
            capture_output=True,
        )
    except OSError as error:
        raise CodeQLError(f"could not run {arguments[0]}: {error}") from error
    if result.returncode != 0:
        detail = (result.stderr or result.stdout).decode("utf-8", errors="replace").strip()
        suffix = f": {detail}" if detail else ""
        raise CodeQLError(
            f"{' '.join(arguments)} failed with exit {result.returncode}{suffix}"
        )
    return result.stdout


def controlled_environment(
    overrides: dict[str, str] | None = None,
    *,
    passthrough: tuple[str, ...] = CODEQL_PASSTHROUGH_ENVIRONMENT,
) -> dict[str, str]:
    """Retain only infrastructure variables, then apply reviewed build values."""

    environment = {
        name: value
        for name in passthrough
        if (value := os.environ.get(name)) is not None
    }
    environment.update(overrides or {})
    environment.pop("TMP", None)
    environment.pop("TEMP", None)
    environment["HOME"] = pwd.getpwuid(os.getuid()).pw_dir
    environment["PATH"] = CODEQL_FIXED_PATH
    environment["TMPDIR"] = str(trusted_temporary_root())
    return environment


def trusted_temporary_root() -> Path:
    """Select a fixed root-owned temporary parent that other users cannot replace."""

    root = TRUSTED_TEMPORARY_ROOT
    try:
        metadata = os.lstat(root)
    except OSError as error:
        raise CodeQLError(
            f"could not inspect trusted temporary root {root}: {error}"
        ) from error
    if not stat.S_ISDIR(metadata.st_mode):
        raise CodeQLError(f"trusted temporary root is not a directory: {root}")
    if metadata.st_uid != 0:
        raise CodeQLError(f"trusted temporary root is not owned by root: {root}")
    writable_by_others = metadata.st_mode & (stat.S_IWGRP | stat.S_IWOTH)
    if writable_by_others and not metadata.st_mode & stat.S_ISVTX:
        raise CodeQLError(
            f"trusted temporary root is writable without the sticky bit: {root}"
        )
    tempfile.tempdir = str(root)
    return root


def require_nonreplaceable_directory(path: Path, description: str) -> Path:
    """Reject a directory whose owner or writable ancestors can replace it."""

    resolved = path.resolve()
    allowed_owners = {0, os.getuid()}
    for candidate in (resolved, *resolved.parents):
        try:
            metadata = os.lstat(candidate)
        except OSError as error:
            raise CodeQLError(f"could not inspect {description} {candidate}: {error}") from error
        if not stat.S_ISDIR(metadata.st_mode):
            raise CodeQLError(f"{description} ancestor is not a directory: {candidate}")
        if metadata.st_uid not in allowed_owners:
            raise CodeQLError(
                f"{description} ancestor has an untrusted owner: {candidate}"
            )
        writable_by_others = metadata.st_mode & (stat.S_IWGRP | stat.S_IWOTH)
        if writable_by_others and not metadata.st_mode & stat.S_ISVTX:
            raise CodeQLError(
                f"{description} ancestor is writable without the sticky bit: "
                f"{candidate}"
            )
    return resolved


def github_cli_environment(token: str | None = None) -> dict[str, str]:
    """Expose one credential without caller proxy or custom trust controls."""

    return controlled_environment(
        {"GITHUB_TOKEN": token} if token is not None else None,
        passthrough=CODEQL_CREDENTIAL_PASSTHROUGH_ENVIRONMENT,
    )


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as input_file:
        for chunk in iter(lambda: input_file.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def verify_checksum(path: Path, expected: str) -> None:
    actual = sha256_file(path)
    if actual != expected:
        raise CodeQLError(
            f"checksum mismatch for {path}: expected {expected}, found {actual}"
        )


def cached_pinned_archive(
    cache_root: Path,
    version: str,
    pin: BundlePin,
    description: str,
) -> Path:
    """Download one immutable archive into an untrusted reusable cache."""

    cache_root = cache_root.expanduser().resolve()
    downloads = cache_root / "downloads"
    downloads.mkdir(parents=True, exist_ok=True)
    archive = downloads / f"{version}-{pin.name}"
    if archive.exists():
        return archive

    downloader = trusted_workflow_tool("downloader")
    descriptor, temporary_name = tempfile.mkstemp(
        prefix=f".{version}-download-",
        dir=downloads,
    )
    os.close(descriptor)
    temporary = Path(temporary_name)
    try:
        print(f"Downloading pinned {description} ({pin.name})...")
        run_command(
            [
                str(downloader),
                "--fail",
                "--location",
                "--retry",
                "3",
                "--retry-all-errors",
                "--output",
                str(temporary),
                pin.url,
            ],
            env=controlled_environment(),
            capture_output=False,
        )
        temporary.replace(archive)
    finally:
        temporary.unlink(missing_ok=True)
    return archive


def snapshot_verified_archive(source: Path, destination: Path, expected: str) -> None:
    """Copy an untrusted cache entry once and authenticate the private bytes."""

    source_descriptor = -1
    destination_descriptor = -1
    digest = hashlib.sha256()
    try:
        source_descriptor = os.open(
            source,
            os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0),
        )
        if not stat.S_ISREG(os.fstat(source_descriptor).st_mode):
            raise CodeQLError(f"pinned archive cache entry is not a file: {source}")
        destination_descriptor = os.open(
            destination,
            os.O_WRONLY | os.O_CREAT | os.O_EXCL,
            0o600,
        )
        with (
            os.fdopen(source_descriptor, "rb") as input_file,
            os.fdopen(destination_descriptor, "wb") as output_file,
        ):
            source_descriptor = -1
            destination_descriptor = -1
            for chunk in iter(lambda: input_file.read(1024 * 1024), b""):
                digest.update(chunk)
                output_file.write(chunk)
    except OSError as error:
        raise CodeQLError(f"could not snapshot pinned archive {source}: {error}") from error
    finally:
        if source_descriptor >= 0:
            os.close(source_descriptor)
        if destination_descriptor >= 0:
            os.close(destination_descriptor)
    actual = digest.hexdigest()
    if actual != expected:
        destination.unlink(missing_ok=True)
        raise CodeQLError(
            f"checksum mismatch for {source}: expected {expected}, found {actual}"
        )


def extract_pinned_zip(archive: Path, destination: Path) -> None:
    """Extract a verified zip while rejecting paths outside its private root."""

    try:
        with zipfile.ZipFile(archive) as bundle:
            for member in bundle.infolist():
                path = PurePosixPath(member.filename)
                if path.is_absolute() or ".." in path.parts:
                    raise CodeQLError(
                        f"pinned archive contains an unsafe path: {member.filename!r}"
                    )
            bundle.extractall(destination)
    except (OSError, zipfile.BadZipFile) as error:
        raise CodeQLError(f"could not extract pinned archive {archive}: {error}") from error


def resolve_private_executable(
    executable: Path,
    installation: Path,
    description: str,
    *,
    make_executable: bool = False,
) -> Path:
    """Require a regular executable contained by its private installation."""

    try:
        installation_status = installation.lstat()
        executable_status = executable.lstat()
    except OSError as error:
        raise CodeQLError(f"private {description} executable is missing: {executable}") from error
    if not stat.S_ISDIR(installation_status.st_mode):
        raise CodeQLError(
            f"private {description} installation is not a directory: {installation}"
        )
    if not stat.S_ISREG(executable_status.st_mode):
        raise CodeQLError(
            f"private {description} executable is not a regular file: {executable}"
        )
    if make_executable:
        try:
            executable.chmod(0o755)
        except OSError as error:
            raise CodeQLError(
                f"could not make private {description} executable runnable: {executable}"
            ) from error
    try:
        resolved_installation = installation.resolve(strict=True)
        resolved = executable.resolve(strict=True)
    except OSError as error:
        raise CodeQLError(
            f"could not resolve private {description} executable: {executable}"
        ) from error
    if resolved_installation not in resolved.parents:
        raise CodeQLError(
            f"private {description} executable escaped its installation: {resolved}"
        )
    if not os.access(resolved, os.X_OK):
        raise CodeQLError(
            f"private {description} executable is not executable: {resolved}"
        )
    return resolved


def selected_platform() -> str:
    system = platform.system()
    machine = platform.machine().lower()
    if system == "Darwin" and machine in {"arm64", "x86_64"}:
        return "osx64"
    if system == "Linux" and machine in {"amd64", "x86_64"}:
        return "linux64"
    raise CodeQLError(f"unsupported CodeQL host: {system} {machine}")


def selected_go_platform() -> str:
    system = platform.system()
    machine = platform.machine().lower()
    if system == "Darwin" and machine == "arm64":
        return "darwin-arm64"
    if system == "Darwin" and machine in {"amd64", "x86_64"}:
        return "darwin-amd64"
    if system == "Linux" and machine in {"amd64", "x86_64"}:
        return "linux-amd64"
    raise CodeQLError(f"unsupported Go toolchain host: {system} {machine}")


def selected_github_cli_platform() -> str:
    system = platform.system()
    machine = platform.machine().lower()
    if system == "Darwin" and machine == "arm64":
        return "macos-arm64"
    if system == "Darwin" and machine in {"amd64", "x86_64"}:
        return "macos-amd64"
    if system == "Linux" and machine in {"amd64", "x86_64"}:
        return "linux-amd64"
    raise CodeQLError(f"unsupported GitHub CLI host: {system} {machine}")


def resolve_fixed_tool(
    candidates: tuple[Path, ...],
    trusted_roots: tuple[Path, ...],
    description: str,
) -> Path:
    """Select an executable only from reviewed absolute locations."""

    resolved_roots = tuple(root.resolve() for root in trusted_roots)
    for candidate in candidates:
        if not candidate.is_absolute():
            raise CodeQLError(f"{description} candidate is not absolute: {candidate}")
        try:
            resolved = candidate.resolve(strict=True)
        except OSError:
            continue
        if not resolved.is_file() or not os.access(resolved, os.X_OK):
            continue
        if any(resolved == root or root in resolved.parents for root in resolved_roots):
            return resolved
    rendered = ", ".join(str(candidate) for candidate in candidates)
    raise CodeQLError(
        f"no trusted {description} executable found in fixed candidates: {rendered}"
    )


def resolve_workflow_tools(host_platform: str) -> tuple[dict[str, Path], dict[str, Any]]:
    """Resolve and attest fixed Git, archive, and download executables."""

    candidates = TRUSTED_WORKFLOW_TOOL_CANDIDATES[host_platform]
    roots = TRUSTED_WORKFLOW_TOOL_ROOTS[host_platform]
    paths = {
        name: resolve_fixed_tool(values, roots, name)
        for name, values in candidates.items()
    }
    environment = controlled_environment()
    version_commands = {
        "git": [str(paths["git"]), "--version"],
        "archiveExtractor": [str(paths["archiveExtractor"]), "--version"],
        "downloader": [str(paths["downloader"]), "--version"],
    }
    expected_prefixes = {
        "git": "git version ",
        "archiveExtractor": ("bsdtar ", "tar (GNU tar) "),
        "downloader": "curl ",
    }
    attestations: dict[str, Any] = {}
    for name, command in version_commands.items():
        output = command_output(command, env=environment).splitlines()
        if not output:
            raise CodeQLError(f"trusted {name} returned no version metadata")
        version_output = output[0]
        prefixes = expected_prefixes[name]
        if isinstance(prefixes, str):
            prefixes = (prefixes,)
        if not version_output.startswith(prefixes):
            raise CodeQLError(
                f"trusted {name} returned unexpected version metadata: {version_output!r}"
            )
        attestations[name] = {
            "path": str(paths[name]),
            "versionOutput": version_output,
            "sha256": sha256_file(paths[name]),
        }
    return paths, attestations


def trusted_workflow_tool(name: str) -> Path:
    """Resolve one workflow executable without consulting caller PATH."""

    host_platform = selected_platform()
    try:
        candidates = TRUSTED_WORKFLOW_TOOL_CANDIDATES[host_platform][name]
    except KeyError as error:
        raise CodeQLError(f"unsupported trusted workflow tool: {name}") from error
    return resolve_fixed_tool(
        candidates,
        TRUSTED_WORKFLOW_TOOL_ROOTS[host_platform],
        name,
    )


def ensure_github_cli(
    cache_root: Path,
    installation: Path,
    requested: str,
) -> tuple[Path, dict[str, Any]]:
    """Extract the checksum-pinned GitHub CLI into one private operation."""

    if requested != "gh":
        raise CodeQLError("custom GitHub CLI executables are not supported")
    gh_platform = selected_github_cli_platform()
    pin = GITHUB_CLI_PINS[gh_platform]
    archive = cached_pinned_archive(
        cache_root,
        GITHUB_CLI_VERSION,
        pin,
        f"GitHub CLI {GITHUB_CLI_VERSION}",
    )
    installation.mkdir(parents=True, mode=0o700)
    private_archive = installation / pin.name
    snapshot_verified_archive(archive, private_archive, pin.sha256)
    if pin.name.endswith(".zip"):
        directory_name = pin.name.removesuffix(".zip")
        try:
            extract_pinned_zip(private_archive, installation)
        finally:
            private_archive.unlink(missing_ok=True)
    elif pin.name.endswith(".tar.gz"):
        directory_name = pin.name.removesuffix(".tar.gz")
        archive_extractor = trusted_workflow_tool("archiveExtractor")
        try:
            run_command(
                [
                    str(archive_extractor),
                    "-xzf",
                    str(private_archive),
                    "-C",
                    str(installation),
                ],
                env=controlled_environment(),
                capture_output=False,
            )
        finally:
            private_archive.unlink(missing_ok=True)
    else:
        private_archive.unlink(missing_ok=True)
        raise CodeQLError(f"unsupported GitHub CLI archive: {pin.name}")

    gh = resolve_private_executable(
        installation / directory_name / "bin" / "gh",
        installation,
        "GitHub CLI",
        make_executable=True,
    )
    version_lines = command_output(
        [str(gh), "--version"], env=controlled_environment()
    ).splitlines()
    expected_version = f"gh version {GITHUB_CLI_VERSION} "
    if not version_lines or not version_lines[0].startswith(expected_version):
        rendered = version_lines[0] if version_lines else ""
        raise CodeQLError(
            f"pinned GitHub CLI returned unexpected version metadata: {rendered!r}"
        )
    return gh, {
        "path": str(gh),
        "versionOutput": version_lines[0],
        "sha256": sha256_file(gh),
        "archive": {
            "name": pin.name,
            "platform": gh_platform,
            "sha256": pin.sha256,
            "url": pin.url,
        },
    }


def exact_build_command(make: Path) -> str:
    return f"{shlex.quote(str(make))} GO=go {CODEQL_BUILD_TARGET}"


def exact_build_path(go: Path) -> str:
    return f"{go.parent}:{CODEQL_FIXED_PATH}"


def ensure_go_toolchain(
    cache_root: Path,
    installation: Path,
) -> tuple[Path, str, BundlePin]:
    """Extract official Go into a private operation-scoped installation."""

    go_platform = selected_go_platform()
    pin = GO_TOOLCHAIN_PINS[go_platform]
    archive = cached_pinned_archive(
        cache_root,
        GO_TOOLCHAIN_VERSION,
        pin,
        f"{GO_TOOLCHAIN_VERSION} toolchain",
    )
    installation.mkdir(parents=True, mode=0o700)
    private_archive = installation / pin.name
    snapshot_verified_archive(archive, private_archive, pin.sha256)
    archive_extractor = trusted_workflow_tool("archiveExtractor")
    environment = controlled_environment(
        {"GOENV": "off", "GOTOOLCHAIN": "local"}
    )
    try:
        print(f"Extracting private verified {GO_TOOLCHAIN_VERSION} toolchain...")
        run_command(
            [
                str(archive_extractor),
                "-xzf",
                str(private_archive),
                "-C",
                str(installation),
            ],
            env=environment,
            capture_output=False,
        )
    finally:
        private_archive.unlink(missing_ok=True)
    go = resolve_private_executable(
        installation / "go" / "bin" / "go",
        installation,
        "Go",
    )
    validate_go_toolchain(go, environment)
    return go, go_platform, pin


def validate_go_toolchain(go: Path, environment: dict[str, str]) -> str:
    if not go.is_file() or not os.access(go, os.X_OK):
        raise CodeQLError(f"pinned Go executable is missing or not executable: {go}")
    version_output = command_output([str(go), "version"], env=environment)
    match = re.fullmatch(r"go version (go[0-9]+(?:\.[0-9]+)+) [^\s]+", version_output)
    if not match or match.group(1) != GO_TOOLCHAIN_VERSION:
        raise CodeQLError(
            f"pinned Go version mismatch: expected {GO_TOOLCHAIN_VERSION}, "
            f"found {version_output!r}"
        )
    return version_output


def resolve_build_tools(
    host_platform: str, cache_root: Path, private_root: Path
) -> tuple[str, str, dict[str, Any]]:
    """Resolve and attest absolute Make and official pinned Go paths."""

    make = resolve_fixed_tool(
        TRUSTED_MAKE_CANDIDATES,
        TRUSTED_MAKE_ROOTS,
        "GNU Make",
    )
    go, go_platform, go_pin = ensure_go_toolchain(cache_root, private_root / "go")
    if (host_platform == "osx64") != go_platform.startswith("darwin-"):
        raise CodeQLError(
            f"CodeQL/Go host platform mismatch: {host_platform} and {go_platform}"
        )
    environment = controlled_environment(CODEQL_BUILD_ENVIRONMENT)
    make_version_lines = command_output(
        [str(make), "--version"], env=environment
    ).splitlines()
    if not make_version_lines:
        raise CodeQLError("trusted Make returned no version metadata")
    make_version = make_version_lines[0]
    if not make_version.startswith("GNU Make "):
        raise CodeQLError(f"trusted Make did not report GNU Make: {make_version!r}")
    go_version_output = validate_go_toolchain(go, environment)
    tools = {
        "make": {
            "path": str(make),
            "version": make_version,
            "sha256": sha256_file(make),
        },
        "go": {
            "path": str(go),
            "version": GO_TOOLCHAIN_VERSION,
            "versionOutput": go_version_output,
            "sha256": sha256_file(go),
            "archive": {
                "name": go_pin.name,
                "platform": go_platform,
                "sha256": go_pin.sha256,
                "url": go_pin.url,
            },
        },
    }
    return exact_build_command(make), exact_build_path(go), tools


def validate_build_tools_manifest(manifest: dict[str, Any]) -> None:
    tools = manifest.get("buildTools")
    if not isinstance(tools, dict) or set(tools) != {"make", "go"}:
        raise CodeQLError("CodeQL evidence buildTools must identify Make and Go")
    for name in ("make", "go"):
        tool = tools.get(name)
        if not isinstance(tool, dict):
            raise CodeQLError(f"CodeQL evidence buildTools.{name} must be an object")
        path = tool.get("path")
        digest = tool.get("sha256")
        if not isinstance(path, str) or not Path(path).is_absolute():
            raise CodeQLError(f"CodeQL evidence buildTools.{name}.path must be absolute")
        if not isinstance(digest, str) or not re.fullmatch(r"[0-9a-f]{64}", digest):
            raise CodeQLError(f"CodeQL evidence buildTools.{name}.sha256 is invalid")
    make = tools["make"]
    go = tools["go"]
    if not isinstance(make.get("version"), str) or not make["version"].startswith(
        "GNU Make "
    ):
        raise CodeQLError("CodeQL evidence Make version is not GNU Make")
    if go.get("version") != GO_TOOLCHAIN_VERSION:
        raise CodeQLError("CodeQL evidence Go version does not match the pinned toolchain")
    version_output = go.get("versionOutput")
    if not isinstance(version_output, str) or not version_output.startswith(
        f"go version {GO_TOOLCHAIN_VERSION} "
    ):
        raise CodeQLError("CodeQL evidence Go version output is invalid")
    archive = go.get("archive")
    if not isinstance(archive, dict):
        raise CodeQLError("CodeQL evidence Go archive metadata is missing")
    go_platform = archive.get("platform")
    if not isinstance(go_platform, str) or go_platform not in GO_TOOLCHAIN_PINS:
        raise CodeQLError("CodeQL evidence Go archive platform is unsupported")
    pin = GO_TOOLCHAIN_PINS[go_platform]
    expected_archive = {
        "name": pin.name,
        "platform": go_platform,
        "sha256": pin.sha256,
        "url": pin.url,
    }
    if archive != expected_archive:
        raise CodeQLError("CodeQL evidence Go archive does not match the reviewed pin")
    expected_command = exact_build_command(Path(make["path"]))
    if manifest.get("buildCommand") != expected_command:
        raise CodeQLError(
            "CodeQL evidence buildCommand does not use the recorded absolute tools"
        )
    expected_path = exact_build_path(Path(go["path"]))
    if manifest.get("buildPath") != expected_path:
        raise CodeQLError(
            "CodeQL evidence buildPath does not select the recorded Go toolchain"
        )


def validate_workflow_tools_manifest(manifest: dict[str, Any]) -> None:
    tools = manifest.get("workflowTools")
    expected_names = {"git", "archiveExtractor", "downloader"}
    if not isinstance(tools, dict) or set(tools) != expected_names:
        raise CodeQLError(
            "CodeQL evidence workflowTools must identify Git, archive extraction, "
            "and download executables"
        )
    expected_prefixes = {
        "git": ("git version ",),
        "archiveExtractor": ("bsdtar ", "tar (GNU tar) "),
        "downloader": ("curl ",),
    }
    for name in sorted(expected_names):
        tool = tools.get(name)
        if not isinstance(tool, dict):
            raise CodeQLError(f"CodeQL evidence workflowTools.{name} must be an object")
        path = tool.get("path")
        digest = tool.get("sha256")
        version_output = tool.get("versionOutput")
        if not isinstance(path, str) or not Path(path).is_absolute():
            raise CodeQLError(f"CodeQL evidence workflowTools.{name}.path must be absolute")
        if not isinstance(digest, str) or not re.fullmatch(r"[0-9a-f]{64}", digest):
            raise CodeQLError(
                f"CodeQL evidence workflowTools.{name}.sha256 is invalid"
            )
        if not isinstance(version_output, str) or not version_output.startswith(
            expected_prefixes[name]
        ):
            raise CodeQLError(
                f"CodeQL evidence workflowTools.{name}.versionOutput is invalid"
            )


def parse_json_file(path: Path, description: str) -> Any:
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except FileNotFoundError as error:
        raise CodeQLError(f"{description} is missing: {path}") from error
    except json.JSONDecodeError as error:
        raise CodeQLError(f"{description} is not valid JSON: {path}: {error}") from error


def write_json_file(path: Path, payload: Any) -> None:
    path.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")


def validate_installed_codeql(codeql: Path) -> None:
    if not codeql.is_file() or not os.access(codeql, os.X_OK):
        raise CodeQLError(f"CodeQL executable is missing or not executable: {codeql}")
    version_payload = command_output(
        [str(codeql), "version", "--format=json"],
        env=controlled_environment(),
    )
    try:
        version = json.loads(version_payload).get("version")
    except (AttributeError, json.JSONDecodeError) as error:
        raise CodeQLError("CodeQL returned invalid version metadata") from error
    if version != CODEQL_VERSION:
        raise CodeQLError(
            f"CodeQL version mismatch: expected {CODEQL_VERSION}, found {version!r}"
        )
    pack = (
        codeql.parent
        / "qlpacks"
        / "codeql"
        / "go-queries"
        / CODEQL_QUERY_PACK_VERSION
        / "qlpack.yml"
    )
    if not pack.is_file():
        raise CodeQLError(
            f"pinned query pack {CODEQL_QUERY_PACK}@{CODEQL_QUERY_PACK_VERSION} "
            f"is missing from {codeql.parent}"
        )
    try:
        pack_metadata = pack.read_text(encoding="utf-8")
    except OSError as error:
        raise CodeQLError(f"could not read pinned query-pack metadata: {pack}: {error}") from error
    expected_metadata = {
        "name": CODEQL_QUERY_PACK,
        "version": CODEQL_QUERY_PACK_VERSION,
        "cliVersion": CODEQL_VERSION,
    }
    for key, expected in expected_metadata.items():
        match = re.search(rf"(?m)^\s*{re.escape(key)}:\s*([^\s#]+)\s*$", pack_metadata)
        actual = match.group(1) if match else None
        if actual != expected:
            raise CodeQLError(
                f"query-pack {key} mismatch: expected {expected!r}, found {actual!r}"
            )


def ensure_codeql(
    cache_root: Path,
    installation: Path,
) -> tuple[Path, str, BundlePin]:
    """Extract CodeQL into a private operation-scoped installation."""

    host_platform = selected_platform()
    pin = BUNDLE_PINS[host_platform]
    archive = cached_pinned_archive(
        cache_root,
        CODEQL_VERSION,
        pin,
        f"CodeQL {CODEQL_VERSION} bundle",
    )
    installation.mkdir(parents=True, mode=0o700)
    private_archive = installation / pin.name
    snapshot_verified_archive(archive, private_archive, pin.sha256)
    archive_extractor = trusted_workflow_tool("archiveExtractor")
    workflow_environment = controlled_environment()
    codeql = installation / "codeql" / "codeql"
    try:
        print(f"Extracting private verified CodeQL {CODEQL_VERSION} bundle...")
        run_command(
            [
                str(archive_extractor),
                "-xzf",
                str(private_archive),
                "-C",
                str(installation),
            ],
            env=workflow_environment,
            capture_output=False,
        )
    finally:
        private_archive.unlink(missing_ok=True)
    codeql = resolve_private_executable(codeql, installation, "CodeQL")
    validate_installed_codeql(codeql)
    return codeql, host_platform, pin


def git_output(
    repository_root: Path,
    *arguments: str,
    environment: dict[str, str] | None = None,
) -> str:
    git = trusted_workflow_tool("git")
    return command_output(
        git_command(git, *arguments),
        cwd=repository_root,
        env=environment if environment is not None else git_environment(),
    )


def git_bytes(repository_root: Path, *arguments: str) -> bytes:
    git = trusted_workflow_tool("git")
    return command_bytes(
        git_command(git, *arguments),
        cwd=repository_root,
        env=git_environment(),
    )


def git_environment() -> dict[str, str]:
    """Build a Git environment with no ambient global or system config."""

    return controlled_environment(CODEQL_GIT_ENVIRONMENT)


def remote_identity_environment() -> dict[str, str]:
    """Verify GitHub refs without caller proxy or custom trust controls."""

    return controlled_environment(
        CODEQL_GIT_ENVIRONMENT,
        passthrough=CODEQL_CREDENTIAL_PASSTHROUGH_ENVIRONMENT,
    )


def git_command(git: Path, *arguments: str, allow_file: bool = False) -> list[str]:
    """Build a Git argv with executable local configuration overridden."""

    command = [str(git)]
    for name, value in CODEQL_GIT_COMMAND_CONFIG.items():
        command.extend(("-c", f"{name}={value}"))
    if allow_file:
        command.extend(("-c", "protocol.file.allow=always"))
    command.extend(arguments)
    return command


def normalize_github_repository(remote: str) -> str:
    value = remote.strip()
    prefixes = ("git@github.com:", "ssh://git@github.com/", "https://github.com/")
    for prefix in prefixes:
        if value.startswith(prefix):
            value = value.removeprefix(prefix)
            break
    if value.endswith(".git"):
        value = value[:-4]
    if not re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", value):
        raise CodeQLError(f"origin is not a canonical GitHub repository: {remote}")
    return value


def repository_identity(repository_root: Path) -> tuple[str, str]:
    head = git_output(repository_root, "rev-parse", "HEAD")
    if not COMMIT_PATTERN.fullmatch(head):
        raise CodeQLError(f"git returned an invalid full commit ID: {head}")
    remote = git_output(
        repository_root, "config", "--local", "--get", "remote.origin.url"
    )
    return normalize_github_repository(remote), head


def nul_records(output: bytes, description: str) -> list[bytes]:
    if not output:
        return []
    if not output.endswith(b"\0"):
        raise CodeQLError(f"git returned unterminated {description}")
    return output[:-1].split(b"\0")


def repository_path(raw_path: bytes, description: str) -> str:
    path = os.fsdecode(raw_path)
    candidate = Path(path)
    if not path or candidate.is_absolute() or ".." in candidate.parts:
        raise CodeQLError(f"git returned an invalid {description}: {path!r}")
    return path


def git_tree_entries(repository_root: Path, commit: str) -> dict[str, tuple[str, str]]:
    entries: dict[str, tuple[str, str]] = {}
    output = git_bytes(repository_root, "ls-tree", "-rz", "--full-tree", commit)
    for record in nul_records(output, "tree entries"):
        try:
            metadata, raw_path = record.split(b"\t", 1)
            mode, kind, object_id = metadata.decode("ascii").split()
        except (UnicodeDecodeError, ValueError) as error:
            raise CodeQLError("git returned a malformed tree entry") from error
        path = repository_path(raw_path, "tree path")
        if kind not in {"blob", "commit"} or not COMMIT_PATTERN.fullmatch(object_id):
            raise CodeQLError(f"git returned invalid tree metadata for {path!r}")
        if path in entries:
            raise CodeQLError(f"git returned a duplicate tree path: {path!r}")
        entries[path] = (mode, object_id)
    return entries


def git_index_entries(repository_root: Path) -> dict[str, tuple[str, str]]:
    entries: dict[str, tuple[str, str]] = {}
    output = git_bytes(repository_root, "ls-files", "--stage", "-z", "--")
    for record in nul_records(output, "index entries"):
        try:
            metadata, raw_path = record.split(b"\t", 1)
            mode, object_id, stage = metadata.decode("ascii").split()
        except (UnicodeDecodeError, ValueError) as error:
            raise CodeQLError("git returned a malformed index entry") from error
        path = repository_path(raw_path, "index path")
        if stage != "0" or not COMMIT_PATTERN.fullmatch(object_id):
            raise CodeQLError(f"git index has an unresolved entry for {path!r}")
        if path in entries:
            raise CodeQLError(f"git returned a duplicate index path: {path!r}")
        entries[path] = (mode, object_id)
    return entries


def git_untracked_paths(
    repository_root: Path,
    tree_entries: dict[str, tuple[str, str]],
    *,
    allow_reviewed_ignores: bool,
) -> set[str]:
    arguments = ["ls-files", "--others", "-z"]
    if allow_reviewed_ignores:
        ignore_files = sorted(
            path for path in tree_entries if Path(path).name == ".gitignore"
        )
        unexpected = sorted(set(ignore_files) - set(CODEQL_SUPPORTED_IGNORE_FILES))
        if unexpected:
            raise CodeQLError(
                "CodeQL exact-source verification does not support nested ignore files:\n  - "
                + "\n  - ".join(unexpected)
            )
        for path in ignore_files:
            arguments.append(f"--exclude-from={repository_root / path}")
    arguments.append("--")
    return {
        repository_path(record, "untracked path")
        for record in nul_records(
            git_bytes(repository_root, *arguments), "untracked paths"
        )
    }


def worktree_blob(repository_root: Path, relative_path: str, mode: str) -> bytes:
    components = Path(relative_path).parts
    directory_descriptor = -1
    descriptor = -1
    try:
        directory_descriptor = os.open(
            repository_root,
            os.O_RDONLY | getattr(os, "O_DIRECTORY", 0),
        )
        for component in components[:-1]:
            previous_descriptor = directory_descriptor
            next_descriptor = os.open(
                component,
                os.O_RDONLY
                | getattr(os, "O_DIRECTORY", 0)
                | getattr(os, "O_NOFOLLOW", 0),
                dir_fd=previous_descriptor,
            )
            directory_descriptor = next_descriptor
            os.close(previous_descriptor)
        leaf = components[-1]
        path_status = os.stat(
            leaf,
            dir_fd=directory_descriptor,
            follow_symlinks=False,
        )
    except FileNotFoundError as error:
        if directory_descriptor >= 0:
            os.close(directory_descriptor)
        raise CodeQLError(f"tracked worktree path is missing: {relative_path}") from error
    except OSError as error:
        if directory_descriptor >= 0:
            os.close(directory_descriptor)
        raise CodeQLError(
            f"could not inspect tracked worktree path {relative_path}: {error}"
        ) from error

    try:
        if mode in {"100644", "100755"}:
            if not stat.S_ISREG(path_status.st_mode):
                raise CodeQLError(
                    f"tracked worktree path is not a regular file: {relative_path}"
                )
            executable = bool(path_status.st_mode & 0o111)
            if executable != (mode == "100755"):
                raise CodeQLError(f"tracked worktree mode changed: {relative_path}")
            descriptor = os.open(
                leaf,
                os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0),
                dir_fd=directory_descriptor,
            )
            opened_status = os.fstat(descriptor)
            if (
                not stat.S_ISREG(opened_status.st_mode)
                or opened_status.st_dev != path_status.st_dev
                or opened_status.st_ino != path_status.st_ino
            ):
                raise CodeQLError(f"tracked worktree path changed while reading: {relative_path}")
            with os.fdopen(descriptor, "rb") as input_file:
                descriptor = -1
                return input_file.read()
        if mode == "120000":
            if not stat.S_ISLNK(path_status.st_mode):
                raise CodeQLError(f"tracked worktree symlink changed: {relative_path}")
            return os.fsencode(os.readlink(leaf, dir_fd=directory_descriptor))
        if mode == "160000":
            raise CodeQLError(
                f"CodeQL exact-source verification does not support submodules: {relative_path}"
            )
        raise CodeQLError(f"unsupported tracked worktree mode {mode}: {relative_path}")
    except OSError as error:
        raise CodeQLError(
            f"could not read tracked worktree path {relative_path}: {error}"
        ) from error
    finally:
        if descriptor >= 0:
            os.close(descriptor)
        if directory_descriptor >= 0:
            os.close(directory_descriptor)


def verify_raw_worktree(
    repository_root: Path,
    commit: str,
    *,
    expected_untracked: set[str] | None = None,
    allow_reviewed_ignores: bool = False,
) -> None:
    """Compare HEAD, index, and raw bytes without Git conversion filters."""

    tree_entries = git_tree_entries(repository_root, commit)
    index_entries = git_index_entries(repository_root)
    if index_entries != tree_entries:
        changed = sorted(
            path
            for path in set(index_entries) | set(tree_entries)
            if index_entries.get(path) != tree_entries.get(path)
        )
        raise CodeQLError(
            "CodeQL exact-source index differs from HEAD:\n  - "
            + "\n  - ".join(changed)
        )

    changed_worktree = []
    for path, (mode, object_id) in tree_entries.items():
        expected_blob = git_bytes(repository_root, "cat-file", "blob", object_id)
        if worktree_blob(repository_root, path, mode) != expected_blob:
            changed_worktree.append(path)
    if changed_worktree:
        raise CodeQLError(
            "CodeQL exact-source worktree differs from HEAD:\n  - "
            + "\n  - ".join(sorted(changed_worktree))
        )

    untracked = git_untracked_paths(
        repository_root,
        tree_entries,
        allow_reviewed_ignores=allow_reviewed_ignores,
    )
    allowed_untracked = expected_untracked or set()
    if untracked != allowed_untracked:
        rendered = "\n  - ".join(sorted(untracked)) or "(none)"
        expected = "\n  - ".join(sorted(allowed_untracked)) or "(none)"
        raise CodeQLError(
            "CodeQL exact-source untracked paths changed: "
            f"expected\n  - {expected}\nfound\n  - {rendered}"
        )


def require_clean_worktree(repository_root: Path) -> None:
    commit = git_output(repository_root, "rev-parse", "HEAD")
    if not COMMIT_PATTERN.fullmatch(commit):
        raise CodeQLError(f"git returned an invalid full commit ID: {commit}")
    try:
        verify_raw_worktree(
            repository_root,
            commit,
            allow_reviewed_ignores=True,
        )
    except CodeQLError as error:
        raise CodeQLError(
            "CodeQL requires a clean exact-commit worktree; commit or remove the "
            f"reported paths:\n{error}"
        ) from error


def require_supported_go_scope(repository_root: Path) -> None:
    tracked = git_output(repository_root, "ls-files", "--", "*.go").splitlines()
    if not tracked:
        raise CodeQLError("CodeQL found no tracked Go source to analyze")
    unexpected = sorted(
        path for path in tracked if not path.startswith("Tools/compose-normalizer/")
    )
    if unexpected:
        raise CodeQLError(
            "CodeQL Go path filters are not enforced by the extractor; review these "
            "tracked files before expanding the supported surface:\n  - "
            + "\n  - ".join(unexpected)
        )
    workspaces = git_output(
        repository_root, "ls-files", "--", "go.work", "go.work.sum"
    ).splitlines()
    if workspaces:
        raise CodeQLError(
            "CodeQL exact-source isolation does not admit a tracked Go workspace; "
            "review these files before expanding the build surface:\n  - "
            + "\n  - ".join(sorted(workspaces))
        )


def git_tree(repository_root: Path, commit: str) -> str:
    tree = git_output(repository_root, "rev-parse", f"{commit}^{{tree}}")
    if not COMMIT_PATTERN.fullmatch(tree):
        raise CodeQLError(f"git returned an invalid source tree ID: {tree}")
    return tree


def verify_independent_object_database(repository_root: Path, commit: str) -> None:
    """Require owned Git objects and verify their content-addressed identities."""

    git_directory = repository_root / ".git"
    objects_directory = git_directory / "objects"
    for directory in (git_directory, objects_directory):
        try:
            directory_status = os.lstat(directory)
        except OSError as error:
            raise CodeQLError(
                f"exact source object database is unavailable: {directory}: {error}"
            ) from error
        if not stat.S_ISDIR(directory_status.st_mode):
            raise CodeQLError(
                f"exact source object database path is not a directory: {directory}"
            )
    alternates = objects_directory / "info" / "alternates"
    if os.path.lexists(alternates):
        raise CodeQLError(
            "exact source object database must not borrow mutable alternate objects"
        )
    git = trusted_workflow_tool("git")
    run_command(
        git_command(
            git,
            "fsck",
            "--strict",
            "--no-reflogs",
            "--no-dangling",
            commit,
        ),
        cwd=repository_root,
        env=git_environment(),
    )


def verify_exact_checkout(
    repository_root: Path,
    commit: str,
    *,
    expected_untracked: set[str] | None = None,
) -> None:
    verify_independent_object_database(repository_root, commit)
    checkout_commit = git_output(repository_root, "rev-parse", "HEAD")
    if checkout_commit != commit:
        raise CodeQLError(
            f"exact source checkout mismatch: expected {commit}, found {checkout_commit}"
        )
    expected_tree = git_tree(repository_root, commit)
    checkout_tree = git_tree(repository_root, "HEAD")
    if checkout_tree != expected_tree:
        raise CodeQLError(
            "exact source tree mismatch: "
            f"expected {expected_tree}, found {checkout_tree}"
        )
    try:
        verify_raw_worktree(
            repository_root,
            commit,
            expected_untracked=expected_untracked or set(),
        )
    except CodeQLError as error:
        raise CodeQLError(f"exact source checkout inputs changed: {error}") from error


def create_exact_checkout(repository_root: Path, commit: str, destination: Path) -> None:
    if destination.exists():
        raise CodeQLError(f"exact source destination already exists: {destination}")
    git = trusted_workflow_tool("git")
    environment = git_environment()
    run_command(
        git_command(
            git,
            "clone",
            "--quiet",
            "--no-local",
            "--no-checkout",
            str(repository_root),
            str(destination),
            allow_file=True,
        ),
        cwd=destination.parent,
        env=environment,
    )
    run_command(
        git_command(git, "checkout", "--quiet", "--detach", commit),
        cwd=destination,
        env=environment,
    )
    verify_exact_checkout(destination, commit)
    require_supported_go_scope(destination)


def result_identity(result: dict[str, Any]) -> tuple[str, str, str]:
    rule_id = result.get("ruleId")
    if not isinstance(rule_id, str) or not rule_id:
        raise CodeQLError("CodeQL SARIF result is missing ruleId")
    try:
        physical = result["locations"][0]["physicalLocation"]
        uri = physical["artifactLocation"]["uri"]
    except (IndexError, KeyError, TypeError) as error:
        raise CodeQLError(f"CodeQL SARIF result {rule_id} has no primary file location") from error
    if not isinstance(uri, str) or not uri:
        raise CodeQLError(f"CodeQL SARIF result {rule_id} has an invalid file URI")
    fingerprints = result.get("partialFingerprints")
    if not isinstance(fingerprints, dict):
        raise CodeQLError(f"CodeQL SARIF result {rule_id} has no partial fingerprints")
    fingerprint = fingerprints.get("primaryLocationLineHash")
    if not isinstance(fingerprint, str) or not fingerprint:
        raise CodeQLError(
            f"CodeQL SARIF result {rule_id} has no primaryLocationLineHash"
        )
    return rule_id, uri, fingerprint


def load_baseline(path: Path) -> tuple[dict[tuple[str, str, str], dict[str, Any]], str]:
    payload = parse_json_file(path, "CodeQL baseline")
    if not isinstance(payload, dict) or payload.get("schemaVersion") != 1:
        raise CodeQLError("CodeQL baseline must be a schemaVersion 1 object")
    expected_metadata = {
        "toolVersion": CODEQL_VERSION,
        "queryPack": f"{CODEQL_QUERY_PACK}@{CODEQL_QUERY_PACK_VERSION}",
        "category": CODEQL_CATEGORY,
    }
    for key, expected in expected_metadata.items():
        if payload.get(key) != expected:
            raise CodeQLError(
                f"CodeQL baseline {key} mismatch: expected {expected!r}, "
                f"found {payload.get(key)!r}"
            )
    allowed_results = payload.get("allowedResults")
    if not isinstance(allowed_results, list):
        raise CodeQLError("CodeQL baseline allowedResults must be a list")
    allowed: dict[tuple[str, str, str], dict[str, Any]] = {}
    for entry in allowed_results:
        if not isinstance(entry, dict):
            raise CodeQLError("CodeQL baseline entries must be objects")
        identity = (
            entry.get("ruleId"),
            entry.get("path"),
            entry.get("partialFingerprint"),
        )
        if not all(isinstance(value, str) and value for value in identity):
            raise CodeQLError("CodeQL baseline entry identity fields must be non-empty strings")
        disposition = entry.get("disposition")
        if disposition not in ALLOWED_DISPOSITIONS:
            raise CodeQLError(f"unsupported CodeQL baseline disposition: {disposition!r}")
        if not isinstance(entry.get("rationale"), str) or not entry["rationale"].strip():
            raise CodeQLError("CodeQL baseline entries require a rationale")
        if not isinstance(entry.get("reviewedBy"), str) or not entry["reviewedBy"].strip():
            raise CodeQLError("CodeQL baseline entries require reviewedBy")
        reviewed_at = entry.get("reviewedAt")
        try:
            date.fromisoformat(reviewed_at)
        except (TypeError, ValueError) as error:
            raise CodeQLError("CodeQL baseline entries require ISO reviewedAt dates") from error
        typed_identity = (str(identity[0]), str(identity[1]), str(identity[2]))
        if typed_identity in allowed:
            raise CodeQLError(f"duplicate CodeQL baseline entry: {typed_identity}")
        allowed[typed_identity] = entry
    return allowed, sha256_file(path)


def validate_sarif(
    sarif_path: Path, baseline_path: Path
) -> tuple[int, int, str]:
    payload = parse_json_file(sarif_path, "CodeQL SARIF")
    if not isinstance(payload, dict) or payload.get("version") != "2.1.0":
        raise CodeQLError("CodeQL SARIF must be a SARIF 2.1.0 object")
    runs = payload.get("runs")
    if not isinstance(runs, list) or not runs:
        raise CodeQLError("CodeQL SARIF must contain at least one run")
    allowed, baseline_sha256 = load_baseline(baseline_path)
    actual: dict[tuple[str, str, str], dict[str, Any]] = {}
    rule_count = 0
    for run in runs:
        if not isinstance(run, dict):
            raise CodeQLError("CodeQL SARIF runs must be objects")
        driver = run.get("tool", {}).get("driver", {})
        if not isinstance(driver, dict) or driver.get("name") != "CodeQL":
            raise CodeQLError("SARIF run was not produced by CodeQL")
        version = driver.get("semanticVersion", driver.get("version"))
        if version != CODEQL_VERSION:
            raise CodeQLError(
                f"SARIF CodeQL version mismatch: expected {CODEQL_VERSION}, found {version!r}"
            )
        automation_id = run.get("automationDetails", {}).get("id")
        if automation_id != CODEQL_SARIF_AUTOMATION_ID:
            raise CodeQLError(
                f"SARIF automation ID mismatch: expected "
                f"{CODEQL_SARIF_AUTOMATION_ID!r}, "
                f"found {automation_id!r}"
            )
        rules = driver.get("rules", [])
        if not isinstance(rules, list):
            raise CodeQLError("CodeQL SARIF driver rules must be a list")
        rule_count += len(rules)
        results = run.get("results", [])
        if not isinstance(results, list):
            raise CodeQLError("CodeQL SARIF results must be a list")
        for result in results:
            if not isinstance(result, dict):
                raise CodeQLError("CodeQL SARIF results must be objects")
            identity = result_identity(result)
            if identity in actual:
                raise CodeQLError(f"duplicate CodeQL SARIF result: {identity}")
            actual[identity] = result

    unexpected = sorted(set(actual) - set(allowed))
    stale = sorted(set(allowed) - set(actual))
    if unexpected:
        details = "\n".join(
            f"  - rule={rule_id} path={path} fingerprint={fingerprint}"
            for rule_id, path, fingerprint in unexpected
        )
        raise CodeQLError(
            "CodeQL found results without a reviewed baseline disposition:\n" + details
        )
    if stale:
        details = "\n".join(
            f"  - rule={rule_id} path={path} fingerprint={fingerprint}"
            for rule_id, path, fingerprint in stale
        )
        raise CodeQLError(
            "CodeQL baseline contains stale dispositions; review and remove them:\n"
            + details
        )
    return len(actual), rule_count, baseline_sha256


def replace_evidence_directory(temporary: Path, target: Path, artifact_root: Path) -> None:
    resolved_root = require_nonreplaceable_directory(
        artifact_root,
        "CodeQL artifact root",
    )
    resolved_target = target.resolve()
    if resolved_target.parent != resolved_root or not COMMIT_PATTERN.fullmatch(target.name):
        raise CodeQLError(f"refusing unsafe CodeQL evidence replacement: {target}")
    projection = Path(
        tempfile.mkdtemp(prefix=f".{target.name}-retain-", dir=artifact_root)
    )
    try:
        projection.rmdir()
        shutil.copytree(temporary, projection, symlinks=True)
        if target.exists():
            shutil.rmtree(target)
        require_nonreplaceable_directory(artifact_root, "CodeQL artifact root")
        projection.replace(target)
    finally:
        shutil.rmtree(projection, ignore_errors=True)
        shutil.rmtree(temporary, ignore_errors=True)


def analyze(
    repository_root: Path,
    cache_root: Path,
    artifact_root: Path,
) -> AuthenticatedAnalysis:
    temporary_root = trusted_temporary_root()
    repository_root = repository_root.expanduser().resolve()
    cache_root = (repository_root / cache_root).resolve() if not cache_root.is_absolute() else cache_root
    artifact_root = (
        (repository_root / artifact_root).resolve()
        if not artifact_root.is_absolute()
        else artifact_root.resolve()
    )
    expected_platform = selected_platform()
    _, workflow_tools = resolve_workflow_tools(expected_platform)
    require_clean_worktree(repository_root)
    require_supported_go_scope(repository_root)
    repository, commit = repository_identity(repository_root)
    private_tools_handle = tempfile.TemporaryDirectory(
        prefix="container-compose-codeql-tools-"
    )
    private_tools = Path(private_tools_handle.name)
    try:
        codeql, host_platform, pin = ensure_codeql(
            cache_root,
            private_tools / "codeql",
        )
        if host_platform != expected_platform:
            raise CodeQLError(
                f"CodeQL host platform changed during analysis: "
                f"expected {expected_platform}, found {host_platform}"
            )
        build_command, build_path, build_tools = resolve_build_tools(
            host_platform,
            cache_root,
            private_tools,
        )
    except BaseException:
        private_tools_handle.cleanup()
        raise

    artifact_root.mkdir(parents=True, exist_ok=True)
    artifact_root = require_nonreplaceable_directory(
        artifact_root,
        "CodeQL artifact root",
    )
    temporary = Path(
        tempfile.mkdtemp(
            prefix=f"container-compose-codeql-analysis-{commit}-",
            dir=temporary_root,
        )
    )
    target = artifact_root / commit
    database = temporary / "database"
    sarif = temporary / SARIF_NAME
    try:
        with (
            tempfile.TemporaryDirectory(
                prefix="container-compose-codeql-source-"
            ) as source_directory,
            tempfile.TemporaryDirectory(
                prefix="container-compose-codeql-go-cache-"
            ) as go_cache_directory,
        ):
            exact_source = Path(source_directory) / "source"
            create_exact_checkout(repository_root, commit, exact_source)
            source_tree = git_tree(exact_source, commit)
            config = exact_source / CODEQL_CONFIG
            baseline = exact_source / CODEQL_BASELINE
            if not config.is_file():
                raise CodeQLError(f"CodeQL configuration is missing: {config}")
            load_baseline(baseline)
            build_environment = controlled_environment(CODEQL_BUILD_ENVIRONMENT)
            build_environment["PATH"] = build_path
            build_environment["GOCACHE"] = str(Path(go_cache_directory) / "build")
            build_environment["GOMODCACHE"] = str(Path(go_cache_directory) / "modules")
            run_command(
                [
                    str(codeql),
                    "database",
                    "create",
                    str(database),
                    "--language=go",
                    f"--source-root={exact_source}",
                    f"--command={build_command}",
                    f"--codescanning-config={config}",
                    "--threads=0",
                ],
                cwd=exact_source,
                env=build_environment,
                capture_output=False,
            )
            run_command(
                [
                    str(codeql),
                    "database",
                    "analyze",
                    str(database),
                    CODEQL_QUERY_SUITE,
                    "--format=sarifv2.1.0",
                    f"--output={sarif}",
                    f"--sarif-category={CODEQL_CATEGORY}",
                    "--threads=0",
                    "--rerun",
                ],
                cwd=exact_source,
                env=build_environment,
                capture_output=False,
            )
            verify_exact_checkout(
                exact_source,
                commit,
                expected_untracked={CODEQL_BUILD_OUTPUT_PATH},
            )
            result_count, rule_count, baseline_sha256 = validate_sarif(
                sarif, baseline
            )
            config_sha256 = sha256_file(config)
        manifest = {
            "schemaVersion": 1,
            "repository": repository,
            "commit": commit,
            "buildCommand": build_command,
            "buildPath": build_path,
            "buildTools": build_tools,
            "workflowTools": workflow_tools,
            "buildEnvironment": CODEQL_BUILD_ENVIRONMENT,
            "environmentPolicy": CODEQL_ENVIRONMENT_POLICY,
            "gitCommandConfig": CODEQL_GIT_COMMAND_CONFIG,
            "gitEnvironment": CODEQL_GIT_ENVIRONMENT,
            "goCachePolicy": CODEQL_GO_CACHE_POLICY,
            "temporaryRootPolicy": CODEQL_TEMPORARY_ROOT_POLICY,
            "temporaryRoot": str(temporary_root),
            "passThroughEnvironment": list(CODEQL_PASSTHROUGH_ENVIRONMENT),
            "sourceIsolation": CODEQL_SOURCE_ISOLATION,
            "sourceTree": source_tree,
            "category": CODEQL_CATEGORY,
            "sarifAutomationId": CODEQL_SARIF_AUTOMATION_ID,
            "codeqlVersion": CODEQL_VERSION,
            "queryPack": f"{CODEQL_QUERY_PACK}@{CODEQL_QUERY_PACK_VERSION}",
            "querySuite": CODEQL_QUERY_SUITE,
            "platform": host_platform,
            "bundleSha256": pin.sha256,
            "configSha256": config_sha256,
            "baselineSha256": baseline_sha256,
            "sarif": SARIF_NAME,
            "sarifSha256": sha256_file(sarif),
            "resultCount": result_count,
            "ruleCount": rule_count,
        }
        manifest_path = temporary / MANIFEST_NAME
        write_json_file(manifest_path, manifest)
        authenticated = AuthenticatedAnalysis(
            path=target,
            commit=commit,
            manifest_sha256=sha256_file(manifest_path),
            sarif_sha256=str(manifest["sarifSha256"]),
            result_count=result_count,
        )
        replace_evidence_directory(temporary, target, artifact_root)
        projected_evidence, projected_manifest = load_retained_evidence(
            repository_root,
            artifact_root,
            repository,
            commit,
        )
        authenticate_retained_evidence(
            projected_evidence,
            projected_manifest,
            authenticated,
        )
    except BaseException:
        shutil.rmtree(temporary, ignore_errors=True)
        raise
    finally:
        private_tools_handle.cleanup()
    print(
        f"CodeQL {CODEQL_VERSION} retained {result_count} results across "
        f"{rule_count} rules at {target}"
    )
    return authenticated


def load_retained_evidence(
    repository_root: Path,
    artifact_root: Path,
    repository: str,
    commit: str,
) -> tuple[Path, dict[str, Any]]:
    evidence = artifact_root / commit
    manifest_path = evidence / MANIFEST_NAME
    manifest = parse_json_file(manifest_path, "CodeQL evidence manifest")
    if not isinstance(manifest, dict) or manifest.get("schemaVersion") != 1:
        raise CodeQLError("CodeQL evidence manifest must be a schemaVersion 1 object")
    expected = {
        "repository": repository,
        "commit": commit,
        "buildEnvironment": CODEQL_BUILD_ENVIRONMENT,
        "environmentPolicy": CODEQL_ENVIRONMENT_POLICY,
        "gitCommandConfig": CODEQL_GIT_COMMAND_CONFIG,
        "gitEnvironment": CODEQL_GIT_ENVIRONMENT,
        "goCachePolicy": CODEQL_GO_CACHE_POLICY,
        "temporaryRootPolicy": CODEQL_TEMPORARY_ROOT_POLICY,
        "temporaryRoot": str(trusted_temporary_root()),
        "passThroughEnvironment": list(CODEQL_PASSTHROUGH_ENVIRONMENT),
        "sourceIsolation": CODEQL_SOURCE_ISOLATION,
        "sourceTree": git_tree(repository_root, commit),
        "category": CODEQL_CATEGORY,
        "sarifAutomationId": CODEQL_SARIF_AUTOMATION_ID,
        "codeqlVersion": CODEQL_VERSION,
        "queryPack": f"{CODEQL_QUERY_PACK}@{CODEQL_QUERY_PACK_VERSION}",
        "querySuite": CODEQL_QUERY_SUITE,
        "sarif": SARIF_NAME,
    }
    for key, value in expected.items():
        if manifest.get(key) != value:
            raise CodeQLError(
                f"CodeQL evidence {key} mismatch: expected {value!r}, "
                f"found {manifest.get(key)!r}"
            )
    validate_build_tools_manifest(manifest)
    validate_workflow_tools_manifest(manifest)
    manifest_platform = manifest.get("platform")
    if not isinstance(manifest_platform, str) or manifest_platform not in BUNDLE_PINS:
        raise CodeQLError(
            f"CodeQL evidence platform is unsupported: {manifest_platform!r}"
        )
    expected_bundle = BUNDLE_PINS[manifest_platform].sha256
    if manifest.get("bundleSha256") != expected_bundle:
        raise CodeQLError(
            "CodeQL evidence bundleSha256 mismatch: expected "
            f"{expected_bundle!r}, found {manifest.get('bundleSha256')!r}"
        )
    sarif = evidence / SARIF_NAME
    baseline = repository_root / CODEQL_BASELINE
    result_count, rule_count, baseline_sha256 = validate_sarif(sarif, baseline)
    checks = {
        "sarifSha256": sha256_file(sarif),
        "baselineSha256": baseline_sha256,
        "configSha256": sha256_file(repository_root / CODEQL_CONFIG),
        "resultCount": result_count,
        "ruleCount": rule_count,
    }
    for key, value in checks.items():
        if manifest.get(key) != value:
            raise CodeQLError(
                f"CodeQL evidence {key} mismatch: expected {value!r}, "
                f"found {manifest.get(key)!r}"
            )
    return evidence, manifest


def authenticate_retained_evidence(
    evidence: Path,
    manifest: dict[str, Any],
    analysis: AuthenticatedAnalysis,
) -> None:
    """Bind ignored retained files to this process's verified analyzer run."""

    if evidence != analysis.path or manifest.get("commit") != analysis.commit:
        raise CodeQLError("retained CodeQL evidence does not match the regenerated analysis")
    manifest_sha256 = sha256_file(evidence / MANIFEST_NAME)
    if manifest_sha256 != analysis.manifest_sha256:
        raise CodeQLError(
            "retained CodeQL manifest changed after regenerated analysis: "
            f"expected {analysis.manifest_sha256}, found {manifest_sha256}"
        )
    if manifest.get("sarifSha256") != analysis.sarif_sha256:
        raise CodeQLError(
            "retained CodeQL SARIF digest does not match the regenerated analysis"
        )
    if manifest.get("resultCount") != analysis.result_count:
        raise CodeQLError(
            "retained CodeQL result count does not match the regenerated analysis"
        )


def snapshot_retained_sarif(
    evidence: Path,
    expected_sha256: str,
    destination: Path,
) -> Path:
    """Copy the validated SARIF through one open descriptor and verify its hash."""

    if not re.fullmatch(r"[0-9a-f]{64}", expected_sha256):
        raise CodeQLError("expected CodeQL SARIF digest is not a SHA-256 value")
    source = evidence / SARIF_NAME
    flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0)
    try:
        descriptor = os.open(source, flags)
    except OSError as error:
        raise CodeQLError(f"could not open retained CodeQL SARIF: {source}: {error}") from error
    digest = hashlib.sha256()
    try:
        if not stat.S_ISREG(os.fstat(descriptor).st_mode):
            raise CodeQLError(f"retained CodeQL SARIF is not a regular file: {source}")
        with os.fdopen(descriptor, "rb") as input_file:
            descriptor = -1
            with destination.open("xb") as output_file:
                for chunk in iter(lambda: input_file.read(1024 * 1024), b""):
                    digest.update(chunk)
                    output_file.write(chunk)
    finally:
        if descriptor >= 0:
            os.close(descriptor)
    actual_sha256 = digest.hexdigest()
    if actual_sha256 != expected_sha256:
        destination.unlink(missing_ok=True)
        raise CodeQLError(
            "retained CodeQL SARIF changed while preparing its upload snapshot: "
            f"expected {expected_sha256}, found {actual_sha256}"
        )
    return destination


def verify_upload_identity(
    repository_root: Path, repository: str, ref: str, commit: str
) -> None:
    trusted_temporary_root()
    if not COMMIT_PATTERN.fullmatch(commit):
        raise CodeQLError("CodeQL upload commit must be a full SHA-1 or SHA-256 ID")
    if not REF_PATTERN.fullmatch(ref):
        raise CodeQLError("CodeQL upload ref must be a full heads, tags, or pull ref")
    require_clean_worktree(repository_root)
    actual_repository, head = repository_identity(repository_root)
    if actual_repository != repository:
        raise CodeQLError(
            f"CodeQL upload repository mismatch: origin is {actual_repository}, "
            f"requested {repository}"
        )
    if head != commit:
        raise CodeQLError(
            f"CodeQL upload head mismatch: checkout is {head}, requested {commit}"
        )
    remote_patterns = [ref]
    if ref.startswith("refs/tags/"):
        remote_patterns.append(f"{ref}^{{}}")
    canonical_remote = f"https://github.com/{repository}.git"
    with tempfile.TemporaryDirectory(
        prefix="container-compose-codeql-remote-"
    ) as remote_directory:
        remote_output = git_output(
            Path(remote_directory),
            "ls-remote",
            "--exit-code",
            canonical_remote,
            *remote_patterns,
            environment=remote_identity_environment(),
        )
    remote_by_ref = {
        fields[1]: fields[0]
        for line in remote_output.splitlines()
        if len(fields := line.split()) == 2 and COMMIT_PATTERN.fullmatch(fields[0])
    }
    peeled = remote_by_ref.get(f"{ref}^{{}}")
    remote_commits = {peeled or remote_by_ref.get(ref)} - {None}
    if remote_commits != {commit}:
        rendered = ", ".join(sorted(remote_commits)) or "no commit"
        raise CodeQLError(
            f"CodeQL upload ref mismatch: origin {ref} resolves to {rendered}, "
            f"requested {commit}"
        )


def resolve_github_token(gh: str) -> str:
    inherited = [
        name for name in ("GITHUB_TOKEN", "GH_TOKEN") if os.environ.get(name)
    ]
    if inherited:
        raise CodeQLError(
            "credential environment reached the post-scrub uploader: "
            + ", ".join(inherited)
        )
    token = command_output([gh, "auth", "token"], env=github_cli_environment())
    if not token:
        raise CodeQLError(
            "the pinned GitHub CLI auth store returned no token; authenticate "
            "with gh auth login before entering the credential-free CodeQL shell"
        )
    return token


def github_api_json(
    gh: str,
    endpoint: str,
    description: str,
    *,
    environment: dict[str, str],
) -> Any:
    output = command_output([gh, "api", endpoint], env=environment)
    try:
        return json.loads(output)
    except json.JSONDecodeError as error:
        raise CodeQLError(f"GitHub returned invalid {description} JSON") from error


def parse_sarif_upload_receipt(
    output: str, repository: str
) -> tuple[str, str]:
    """Validate the receipt returned by the exact SARIF upload request."""

    try:
        receipt = json.loads(output)
    except json.JSONDecodeError as error:
        raise CodeQLError("CodeQL returned an invalid SARIF upload receipt") from error
    if not isinstance(receipt, dict):
        raise CodeQLError("CodeQL SARIF upload receipt must be an object")
    upload_id = receipt.get("id")
    upload_url = receipt.get("url")
    if not isinstance(upload_id, str) or not re.fullmatch(
        r"[A-Za-z0-9._-]{1,128}", upload_id
    ):
        raise CodeQLError("CodeQL SARIF upload receipt has an invalid id")
    expected_url = (
        f"https://api.github.com/repos/{repository}/code-scanning/sarifs/"
        f"{urllib.parse.quote(upload_id, safe='')}"
    )
    if upload_url != expected_url:
        raise CodeQLError(
            "CodeQL SARIF upload receipt URL mismatch: "
            f"expected {expected_url!r}, found {upload_url!r}"
        )
    return upload_id, upload_url


def validate_receipt_analyses_url(
    analyses_url: Any, repository: str, upload_id: str
) -> str:
    if not isinstance(analyses_url, str):
        raise CodeQLError("GitHub SARIF receipt did not identify its analysis URL")
    parsed = urllib.parse.urlparse(analyses_url)
    expected_path = f"/repos/{repository}/code-scanning/analyses"
    try:
        parameters = urllib.parse.parse_qs(
            parsed.query, keep_blank_values=True, strict_parsing=True
        )
    except ValueError as error:
        raise CodeQLError(
            f"GitHub SARIF analysis URL has an invalid query: {analyses_url!r}"
        ) from error
    if (
        parsed.scheme != "https"
        or parsed.netloc != "api.github.com"
        or parsed.path != expected_path
        or parsed.params
        or parsed.fragment
        or parameters != {"sarif_id": [upload_id]}
    ):
        raise CodeQLError(
            "GitHub SARIF analysis URL is not bound to the upload receipt: "
            f"{analyses_url!r}"
        )
    return analyses_url


def wait_for_uploaded_analysis(
    *,
    gh: str,
    repository: str,
    ref: str,
    commit: str,
    upload_id: str,
    upload_url: str,
    result_count: int,
    rule_count: int,
    poll_interval: float,
    poll_timeout: float,
    github_environment: dict[str, str],
) -> dict[str, Any]:
    deadline = time.monotonic() + poll_timeout
    while True:
        status = github_api_json(
            gh,
            upload_url,
            "SARIF upload status",
            environment=github_environment,
        )
        if not isinstance(status, dict):
            raise CodeQLError("GitHub SARIF upload status must be an object")
        processing_status = status.get("processing_status")
        if processing_status == "complete":
            analyses_url = validate_receipt_analyses_url(
                status.get("analyses_url"), repository, upload_id
            )
            analyses = github_api_json(
                gh,
                analyses_url,
                "receipt-bound CodeQL analysis",
                environment=github_environment,
            )
            if not isinstance(analyses, list) or len(analyses) != 1:
                raise CodeQLError(
                    "GitHub SARIF receipt must resolve to exactly one CodeQL analysis"
                )
            analysis = analyses[0]
            if not isinstance(analysis, dict):
                raise CodeQLError("GitHub returned an invalid receipt-bound analysis")
            expected_identity = {
                "commit_sha": commit,
                "ref": ref,
                "category": CODEQL_CATEGORY,
            }
            for key, expected in expected_identity.items():
                if analysis.get(key) != expected:
                    raise CodeQLError(
                        f"GitHub receipt-bound CodeQL {key} mismatch: "
                        f"expected {expected!r}, found {analysis.get(key)!r}"
                    )
            if analysis.get("error") or analysis.get("warning"):
                raise CodeQLError(
                    "GitHub processed the CodeQL upload with an error or warning: "
                    f"error={analysis.get('error')!r}, warning={analysis.get('warning')!r}"
                )
            if analysis.get("results_count") != result_count:
                raise CodeQLError(
                    "GitHub CodeQL result count mismatch: "
                    f"expected {result_count}, found {analysis.get('results_count')!r}"
                )
            if analysis.get("rules_count") != rule_count:
                raise CodeQLError(
                    "GitHub CodeQL rule count mismatch: "
                    f"expected {rule_count}, found {analysis.get('rules_count')!r}"
                )
            tool = analysis.get("tool")
            if (
                not isinstance(tool, dict)
                or tool.get("name") != "CodeQL"
                or tool.get("version") != CODEQL_VERSION
            ):
                raise CodeQLError(
                    f"GitHub CodeQL tool mismatch: expected CodeQL {CODEQL_VERSION}, "
                    f"found {tool!r}"
                )
            return analysis
        if processing_status == "failed":
            raise CodeQLError(
                "GitHub failed to process the receipt-bound CodeQL upload: "
                f"{status.get('errors')!r}"
            )
        if processing_status != "pending":
            raise CodeQLError(
                "GitHub returned an invalid SARIF processing status: "
                f"{processing_status!r}"
            )
        if time.monotonic() >= deadline:
            raise CodeQLError(
                f"timed out waiting for GitHub SARIF upload {upload_id} to process"
            )
        time.sleep(poll_interval)


def upload_with_private_tools(
    *,
    repository_root: Path,
    artifact_root: Path,
    repository: str,
    ref: str,
    commit: str,
    codeql: Path,
    github_cli: Path,
    github_cli_attestation: dict[str, Any],
    authenticated: AuthenticatedAnalysis,
    poll_interval: float,
    poll_timeout: float,
) -> Path:
    """Upload and confirm while both credential-bearing tools stay private."""

    trusted_temporary_root()
    verify_upload_identity(repository_root, repository, ref, commit)
    evidence, manifest = load_retained_evidence(
        repository_root, artifact_root, repository, commit
    )
    authenticate_retained_evidence(evidence, manifest, authenticated)
    token = resolve_github_token(str(github_cli))
    environment = github_cli_environment(token)
    with tempfile.TemporaryDirectory(
        prefix="container-compose-codeql-upload-"
    ) as upload_directory:
        sarif_snapshot = snapshot_retained_sarif(
            evidence,
            authenticated.sarif_sha256,
            Path(upload_directory) / SARIF_NAME,
        )
        upload_result = run_command(
            [
                str(codeql),
                "github",
                "upload-results",
                f"--repository={repository}",
                f"--ref={ref}",
                f"--commit={commit}",
                f"--sarif={sarif_snapshot}",
                "--format=json",
                "--no-wait-for-processing",
            ],
            cwd=repository_root,
            env=environment,
        )
        upload_id, upload_url = parse_sarif_upload_receipt(
            upload_result.stdout, repository
        )
    analysis = wait_for_uploaded_analysis(
        gh=str(github_cli),
        repository=repository,
        ref=ref,
        commit=commit,
        upload_id=upload_id,
        upload_url=upload_url,
        result_count=int(manifest["resultCount"]),
        rule_count=int(manifest["ruleCount"]),
        poll_interval=poll_interval,
        poll_timeout=poll_timeout,
        github_environment=environment,
    )
    evidence, manifest = load_retained_evidence(
        repository_root, artifact_root, repository, commit
    )
    authenticate_retained_evidence(evidence, manifest, authenticated)
    upload_path = evidence / UPLOAD_NAME
    write_json_file(
        upload_path,
        {
            "schemaVersion": 1,
            "repository": repository,
            "ref": ref,
            "commit": commit,
            "category": CODEQL_CATEGORY,
            "sarifUploadId": upload_id,
            "sarifUploadUrl": upload_url,
            "analysisId": analysis["id"],
            "analysisUrl": analysis.get("url"),
            "createdAt": analysis.get("created_at"),
            "resultCount": analysis.get("results_count"),
            "ruleCount": analysis.get("rules_count"),
            "toolVersion": analysis.get("tool", {}).get("version"),
            "githubCli": github_cli_attestation,
            "credentialSource": CODEQL_CREDENTIAL_SOURCE,
            "credentialEnvironmentPolicy": CODEQL_CREDENTIAL_ENVIRONMENT_POLICY,
            "remoteIdentityEnvironmentPolicy": (
                CODEQL_REMOTE_IDENTITY_ENVIRONMENT_POLICY
            ),
            "remoteIdentityPassThroughEnvironment": list(
                CODEQL_CREDENTIAL_PASSTHROUGH_ENVIRONMENT
            ),
            "temporaryRootPolicy": CODEQL_TEMPORARY_ROOT_POLICY,
            "temporaryRoot": str(trusted_temporary_root()),
            "credentialPassThroughEnvironment": list(
                CODEQL_CREDENTIAL_PASSTHROUGH_ENVIRONMENT
            ),
        },
    )
    print(
        f"GitHub accepted exact CodeQL analysis {analysis['id']} for "
        f"{repository} {ref} at {commit}"
    )
    return upload_path


def upload(
    *,
    repository_root: Path,
    cache_root: Path,
    artifact_root: Path,
    repository: str,
    ref: str,
    commit: str,
    dry_run: bool,
    gh: str,
    poll_interval: float,
    poll_timeout: float,
) -> Path | None:
    repository_root = repository_root.expanduser().resolve()
    cache_root = (repository_root / cache_root).resolve() if not cache_root.is_absolute() else cache_root
    artifact_root = (
        (repository_root / artifact_root).resolve()
        if not artifact_root.is_absolute()
        else artifact_root.resolve()
    )
    verify_upload_identity(repository_root, repository, ref, commit)
    require_nonreplaceable_directory(artifact_root, "CodeQL artifact root")
    if dry_run:
        load_retained_evidence(repository_root, artifact_root, repository, commit)
        print(
            f"CodeQL upload dry run passed for {repository} {ref} at {commit}; "
            "no token was read and no upload was made."
        )
        return None

    authenticated = analyze(repository_root, cache_root, artifact_root)
    with tempfile.TemporaryDirectory(
        prefix="container-compose-codeql-credential-tools-"
    ) as private_tools_directory:
        private_tools = Path(private_tools_directory)
        codeql, _, _ = ensure_codeql(cache_root, private_tools / "codeql")
        github_cli, github_cli_attestation = ensure_github_cli(
            cache_root,
            private_tools / "github-cli",
            gh,
        )
        return upload_with_private_tools(
            repository_root=repository_root,
            artifact_root=artifact_root,
            repository=repository,
            ref=ref,
            commit=commit,
            codeql=codeql,
            github_cli=github_cli,
            github_cli_attestation=github_cli_attestation,
            authenticated=authenticated,
            poll_interval=poll_interval,
            poll_timeout=poll_timeout,
        )


def main() -> int:
    args = parse_args()
    try:
        if args.command == "analyze":
            analyze(
                args.repository_root,
                args.cache_root,
                args.artifact_root,
            )
        elif args.command == "upload":
            upload(
                repository_root=args.repository_root,
                cache_root=args.cache_root,
                artifact_root=args.artifact_root,
                repository=args.repository,
                ref=args.ref,
                commit=args.commit,
                dry_run=args.dry_run,
                gh=args.gh,
                poll_interval=args.poll_interval,
                poll_timeout=args.poll_timeout,
            )
        else:
            raise AssertionError(f"unhandled command: {args.command}")
    except CodeQLError as error:
        print(f"codeql-local: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
