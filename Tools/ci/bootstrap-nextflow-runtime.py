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

"""Install the checksum-pinned Nextflow, JDK and Hawkeye tools atomically."""

from __future__ import annotations

import argparse
import hashlib
import os
from pathlib import Path, PurePosixPath
import re
import shutil
import stat
import subprocess
import sys
import tarfile
import tempfile
import time
from typing import Callable, Optional
import urllib.error
import urllib.parse
import urllib.request
import uuid


STATE_MARKER = "container-compose recoverable pipeline v1"
Download = Callable[[str, Path], None]


class BootstrapError(RuntimeError):
    """A deterministic bootstrap contract was not satisfied."""


def sha256(path: Path) -> str:
    """Return the SHA-256 digest for one regular file."""
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def require_digest(value: str, name: str) -> str:
    """Validate one lowercase SHA-256 command-line value."""
    if len(value) != 64 or any(character not in "0123456789abcdef" for character in value):
        raise BootstrapError(f"{name} is not a lowercase SHA-256 digest")
    return value


def tree_sha256(root: Path) -> str:
    """Return a deterministic digest of a complete regular-file directory tree."""
    if root.is_symlink() or not root.is_dir():
        raise BootstrapError(f"runtime tree is indirect or invalid: {root}")
    digest = hashlib.sha256()
    paths = [root, *sorted(root.rglob("*"), key=lambda path: path.relative_to(root).as_posix())]
    for path in paths:
        metadata = path.lstat()
        relative = "." if path == root else path.relative_to(root).as_posix()
        if stat.S_ISDIR(metadata.st_mode):
            kind = "directory"
            size = 0
        elif stat.S_ISREG(metadata.st_mode):
            kind = "file"
            size = metadata.st_size
        else:
            raise BootstrapError(f"runtime tree contains an unsupported entry: {path}")
        record = (
            f"{kind}\0{stat.S_IMODE(metadata.st_mode):o}\0{relative}\0{size}\0"
        ).encode("utf-8")
        digest.update(len(record).to_bytes(8, "big"))
        digest.update(record)
        if kind == "file":
            with path.open("rb") as stream:
                for chunk in iter(lambda: stream.read(1024 * 1024), b""):
                    digest.update(chunk)
    return digest.hexdigest()


def marked_state_root(path: Path) -> Path:
    """Return a physical, marker-protected pipeline state root."""
    if not path.is_absolute() or path.is_symlink() or not path.is_dir():
        raise BootstrapError(f"pipeline state root is indirect or invalid: {path}")
    root = path.resolve(strict=True)
    marker = root / ".container-compose-pipeline-root"
    if marker.is_symlink() or not marker.is_file():
        raise BootstrapError(f"pipeline state marker is indirect or missing: {marker}")
    if marker.read_text(encoding="utf-8").rstrip("\n") != STATE_MARKER:
        raise BootstrapError(f"pipeline state marker does not match: {marker}")
    return root


def require_managed_parent(path: Path, expected: Path) -> Path:
    """Create and verify one physical directory below the marked root."""
    if path != expected:
        raise BootstrapError(f"managed tool directory has the wrong path: {path}")
    missing: list[Path] = []
    existing = path
    while not os.path.lexists(existing):
        missing.append(existing)
        existing = existing.parent
    marked_ancestor: Optional[Path] = None
    for ancestor in (existing, *existing.parents):
        if ancestor.is_symlink() or not ancestor.is_dir():
            raise BootstrapError(
                f"managed tool ancestor is indirect or invalid: {ancestor}"
            )
        marker = ancestor / ".container-compose-pipeline-root"
        if marker.is_symlink():
            raise BootstrapError(f"pipeline state marker is indirect: {marker}")
        if marker.is_file() and marker.read_text(encoding="utf-8").rstrip("\n") == STATE_MARKER:
            marked_ancestor = ancestor
            break
    if marked_ancestor is None:
        raise BootstrapError(f"managed tool directory is outside marked state: {path}")
    for candidate in reversed(missing):
        parent = candidate.parent
        if parent.is_symlink() or not parent.is_dir():
            raise BootstrapError(
                f"managed tool ancestor became indirect or invalid: {parent}"
            )
        candidate.mkdir()
        fsync_directory(parent)
    if path.is_symlink() or not path.is_dir():
        raise BootstrapError(f"managed tool directory is indirect or invalid: {path}")
    physical = path.resolve(strict=True)
    if physical != expected or not physical.is_relative_to(marked_ancestor):
        raise BootstrapError(f"managed tool directory escaped its state root: {physical}")
    return physical


def https_download(url: str, destination: Path) -> None:
    """Download one HTTPS resource with bounded retries and no credential helpers."""
    if urllib.parse.urlparse(url).scheme != "https":
        raise BootstrapError(f"runtime URL must use HTTPS: {url}")
    last_error: Optional[Exception] = None
    for attempt in range(3):
        try:
            request = urllib.request.Request(
                url,
                headers={"User-Agent": "container-compose-runtime-bootstrap/1"},
            )
            with urllib.request.urlopen(request, timeout=60) as response:
                if urllib.parse.urlparse(response.geturl()).scheme != "https":
                    raise BootstrapError("runtime download redirected away from HTTPS")
                with destination.open("wb") as output:
                    shutil.copyfileobj(response, output, length=1024 * 1024)
            return
        except (OSError, urllib.error.URLError) as error:
            last_error = error
            destination.unlink(missing_ok=True)
            if attempt < 2:
                time.sleep(attempt + 1)
    raise BootstrapError(f"runtime download failed after three attempts: {last_error}")


def fsync_directory(path: Path) -> None:
    """Persist a completed atomic rename on the containing filesystem."""
    descriptor = os.open(path, os.O_RDONLY)
    try:
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


def install_launcher(
    *,
    destination: Path,
    expected_parent: Path,
    version: str,
    url: str,
    expected_sha256: str,
    downloader: Download = https_download,
) -> None:
    """Install or validate the exact Nextflow launcher."""
    expected_sha256 = require_digest(expected_sha256, "Nextflow digest")
    parent = require_managed_parent(destination.parent, expected_parent)
    for candidate in parent.glob(".nextflow-download.*"):
        if not re.fullmatch(r"[.]nextflow-download[.][A-Za-z0-9_-]+", candidate.name):
            raise BootstrapError(f"unexpected Nextflow temporary path: {candidate}")
        remove_managed_path(candidate, parent)
    if (
        destination.is_file()
        and not destination.is_symlink()
        and os.access(destination, os.X_OK)
        and sha256(destination) == expected_sha256
    ):
        print(f"Pinned Nextflow {version} is already installed at {destination}")
        return

    descriptor, temporary_name = tempfile.mkstemp(
        prefix=".nextflow-download.", dir=parent
    )
    os.close(descriptor)
    temporary = Path(temporary_name)
    try:
        downloader(url, temporary)
        actual_sha256 = sha256(temporary)
        if actual_sha256 != expected_sha256:
            raise BootstrapError(
                "Nextflow digest mismatch: "
                f"expected {expected_sha256}, got {actual_sha256}"
            )
        temporary.chmod(0o755)
        os.replace(temporary, destination)
        fsync_directory(parent)
    finally:
        temporary.unlink(missing_ok=True)
    print(f"Installed verified Nextflow {version} at {destination}")


def valid_runtime(
    root: Path, files: dict[Path, str], expected_tree_sha256: str
) -> bool:
    """Return whether every pinned runtime file is present and unchanged."""
    if root.is_symlink() or not root.is_dir():
        return False
    for relative, expected_sha256 in files.items():
        candidate = root / relative
        if candidate.is_symlink() or not candidate.is_file():
            return False
        if sha256(candidate) != expected_sha256:
            return False
    try:
        return tree_sha256(root) == expected_tree_sha256
    except (BootstrapError, OSError):
        return False


def validate_archive(archive: tarfile.TarFile, expected_root: str) -> None:
    """Reject paths or entry types that could escape the staging directory."""
    members = archive.getmembers()
    if not members:
        raise BootstrapError("Temurin archive is empty")
    roots: set[str] = set()
    for member in members:
        path = PurePosixPath(member.name)
        if path.is_absolute() or ".." in path.parts or not path.parts:
            raise BootstrapError(f"unsafe Temurin archive path: {member.name}")
        roots.add(path.parts[0])
        if not (member.isfile() or member.isdir()):
            raise BootstrapError(f"unsupported Temurin archive entry: {member.name}")
    if roots != {expected_root}:
        raise BootstrapError(
            f"Temurin archive has unexpected roots: {', '.join(sorted(roots))}"
        )


def remove_managed_path(path: Path, parent: Path) -> None:
    """Remove only a named temporary entry in the verified tool parent."""
    if path.parent != parent:
        raise BootstrapError(f"refusing to remove unmanaged path: {path}")
    if path.is_symlink() or path.is_file():
        path.unlink(missing_ok=True)
    elif path.is_dir():
        shutil.rmtree(path)


def recover_java_install(
    *,
    root: Path,
    parent: Path,
    runtime_files: dict[Path, str],
    expected_tree_sha256: str,
) -> None:
    """Recover or remove exact temporary paths left by a hard interruption."""
    previous_paths = list(parent.glob(".temurin-previous.*"))
    staging_paths = list(parent.glob(".temurin-install.*"))
    for candidate in previous_paths + staging_paths:
        if not re.fullmatch(
            r"[.]temurin-(previous|install)[.][A-Za-z0-9_-]+", candidate.name
        ):
            raise BootstrapError(f"unexpected Temurin temporary path: {candidate}")
    for staging in staging_paths:
        remove_managed_path(staging, parent)

    valid_previous = [
        candidate
        for candidate in previous_paths
        if valid_runtime(candidate, runtime_files, expected_tree_sha256)
    ]
    if valid_runtime(root, runtime_files, expected_tree_sha256):
        for previous in previous_paths:
            remove_managed_path(previous, parent)
        return
    if not os.path.lexists(root) and len(valid_previous) == 1:
        recovered = valid_previous[0]
        os.replace(recovered, root)
        fsync_directory(parent)
        previous_paths.remove(recovered)
    elif not os.path.lexists(root) and len(valid_previous) > 1:
        raise BootstrapError("multiple valid interrupted Temurin installations exist")
    for previous in previous_paths:
        remove_managed_path(previous, parent)


def install_java(
    *,
    root: Path,
    expected_parent: Path,
    version: str,
    release: str,
    url: str,
    archive_sha256: str,
    expected_tree_sha256: str,
    runtime_files: dict[Path, str],
    temporary_root: Path,
    downloader: Download = https_download,
) -> None:
    """Install or validate the exact Temurin runtime directory."""
    archive_sha256 = require_digest(archive_sha256, "Temurin archive digest")
    expected_tree_sha256 = require_digest(
        expected_tree_sha256, "Temurin tree digest"
    )
    runtime_files = {
        path: require_digest(digest, f"Temurin file digest for {path}")
        for path, digest in runtime_files.items()
    }
    parent = require_managed_parent(root.parent, expected_parent)
    recover_java_install(
        root=root,
        parent=parent,
        runtime_files=runtime_files,
        expected_tree_sha256=expected_tree_sha256,
    )
    if valid_runtime(root, runtime_files, expected_tree_sha256):
        print(f"Pinned Temurin {release} is already installed at {root}")
        return

    descriptor, archive_name = tempfile.mkstemp(
        prefix=".temurin-download.", dir=temporary_root
    )
    os.close(descriptor)
    archive_path = Path(archive_name)
    staging = Path(tempfile.mkdtemp(prefix=".temurin-install.", dir=parent))
    previous = parent / f".temurin-previous.{uuid.uuid4().hex}"
    moved_previous = False
    try:
        downloader(url, archive_path)
        actual_archive_sha256 = sha256(archive_path)
        if actual_archive_sha256 != archive_sha256:
            raise BootstrapError(
                "Temurin archive digest mismatch: "
                f"expected {archive_sha256}, got {actual_archive_sha256}"
            )
        archive_root = f"jdk-{release}"
        with tarfile.open(archive_path, "r:gz") as archive:
            validate_archive(archive, archive_root)
            try:
                archive.extractall(staging, filter="fully_trusted")
            except TypeError:
                # Python 3.9 predates extraction filters. Every member was
                # already checked above before this compatibility fallback.
                archive.extractall(staging)
        candidate = staging / archive_root
        if not valid_runtime(candidate, runtime_files, expected_tree_sha256):
            raise BootstrapError("extracted Temurin runtime does not match its file pins")
        java = candidate / "Contents/Home/bin/java"
        completed = subprocess.run(
            [str(java), "-version"],
            env={"PATH": "/usr/bin:/bin", "LANG": "C", "LC_ALL": "C"},
            stdin=subprocess.DEVNULL,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.PIPE,
            text=True,
            timeout=30,
            check=False,
        )
        if completed.returncode != 0 or f'version "{version}"' not in completed.stderr:
            raise BootstrapError(f"extracted Temurin runtime is not Java {version}")
        if os.path.lexists(root):
            os.replace(root, previous)
            moved_previous = True
        try:
            os.replace(candidate, root)
        except BaseException:
            if moved_previous:
                os.replace(previous, root)
                moved_previous = False
            raise
        fsync_directory(parent)
        if moved_previous:
            remove_managed_path(previous, parent)
            moved_previous = False
    finally:
        archive_path.unlink(missing_ok=True)
        remove_managed_path(staging, parent)
        if moved_previous and not os.path.lexists(root):
            os.replace(previous, root)
        elif os.path.lexists(previous):
            remove_managed_path(previous, parent)
    print(f"Installed verified Temurin {release} at {root}")


def valid_hawkeye(
    executable: Path, version: str, expected_sha256: str
) -> bool:
    """Return whether one direct executable has the pinned Hawkeye CLI."""
    if executable.is_symlink() or not executable.is_file() or not os.access(
        executable, os.X_OK
    ):
        return False
    if sha256(executable) != expected_sha256:
        return False
    environment = {"PATH": "/usr/bin:/bin", "LANG": "C", "LC_ALL": "C"}
    try:
        version_result = subprocess.run(
            [str(executable), "--version"],
            env=environment,
            stdin=subprocess.DEVNULL,
            capture_output=True,
            text=True,
            timeout=30,
            check=False,
        )
        check_result = subprocess.run(
            [str(executable), "check", "--help"],
            env=environment,
            stdin=subprocess.DEVNULL,
            capture_output=True,
            text=True,
            timeout=30,
            check=False,
        )
        format_result = subprocess.run(
            [str(executable), "format", "--help"],
            env=environment,
            stdin=subprocess.DEVNULL,
            capture_output=True,
            text=True,
            timeout=30,
            check=False,
        )
    except (OSError, subprocess.SubprocessError):
        return False
    version_text = version_result.stdout + version_result.stderr
    return (
        version_result.returncode == 0
        and re.search(
            rf"(?:hawkeye\s+|version:\s*)v?{re.escape(version)}(?:\s|$)",
            version_text,
        )
        is not None
        and check_result.returncode == 0
        and "--fail-if-unknown" in check_result.stdout + check_result.stderr
        and format_result.returncode == 0
        and "--fail-if-updated" in format_result.stdout + format_result.stderr
    )


def install_hawkeye(
    *,
    destination: Path,
    expected_parent: Path,
    version: str,
    expected_sha256: str,
    installer: Path,
    temporary_root: Path,
) -> None:
    """Install the repository-pinned Hawkeye into durable pipeline state."""
    expected_sha256 = require_digest(expected_sha256, "Hawkeye digest")
    parent = require_managed_parent(destination.parent, expected_parent)
    for candidate in list(parent.glob(".hawkeye-install.*")) + list(
        parent.glob(".hawkeye-ready.*")
    ):
        if not re.fullmatch(
            r"[.]hawkeye-(install|ready)[.][A-Za-z0-9_-]+", candidate.name
        ):
            raise BootstrapError(f"unexpected Hawkeye temporary path: {candidate}")
        remove_managed_path(candidate, parent)
    if valid_hawkeye(destination, version, expected_sha256):
        print(f"Pinned Hawkeye {version} is already installed at {destination}")
        return
    if (
        not installer.is_absolute()
        or installer.is_symlink()
        or not installer.is_file()
        or not os.access(installer, os.X_OK)
    ):
        raise BootstrapError(f"Hawkeye installer is indirect or invalid: {installer}")

    staging = Path(tempfile.mkdtemp(prefix=".hawkeye-install.", dir=parent))
    ready = parent / f".hawkeye-ready.{uuid.uuid4().hex}"
    try:
        completed = subprocess.run(
            [str(installer)],
            cwd=staging,
            env={
                "HOME": str(staging),
                "LANG": "C",
                "LC_ALL": "C",
                "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
                "TMPDIR": str(temporary_root),
            },
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            timeout=360,
            check=False,
        )
        candidate = staging / ".local/bin/hawkeye"
        if completed.returncode != 0:
            raise BootstrapError(
                "pinned Hawkeye installer failed: " + completed.stderr.rstrip()
            )
        if not valid_hawkeye(candidate, version, expected_sha256):
            raise BootstrapError("installed Hawkeye does not match its CLI pin")
        shutil.copyfile(candidate, ready)
        ready.chmod(0o755)
        if not valid_hawkeye(ready, version, expected_sha256):
            raise BootstrapError("staged Hawkeye changed before installation")
        os.replace(ready, destination)
        fsync_directory(parent)
    finally:
        remove_managed_path(staging, parent)
        ready.unlink(missing_ok=True)
    print(f"Installed verified Hawkeye {version} at {destination}")


def parse_arguments() -> argparse.Namespace:
    """Parse the complete pinned runtime contract."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--state-root", type=Path, required=True)
    parser.add_argument("--nextflow-version", required=True)
    parser.add_argument("--nextflow-url", required=True)
    parser.add_argument("--nextflow-sha256", required=True)
    parser.add_argument("--nextflow-bin", type=Path, required=True)
    parser.add_argument("--java-version", required=True)
    parser.add_argument("--java-release", required=True)
    parser.add_argument("--java-url", required=True)
    parser.add_argument("--java-archive-sha256", required=True)
    parser.add_argument("--java-tree-sha256", required=True)
    parser.add_argument("--java-root", type=Path, required=True)
    parser.add_argument("--java-sha256", required=True)
    parser.add_argument("--java-modules-sha256", required=True)
    parser.add_argument("--java-libjvm-sha256", required=True)
    parser.add_argument("--java-release-sha256", required=True)
    parser.add_argument("--hawkeye-version", required=True)
    parser.add_argument("--hawkeye-sha256", required=True)
    parser.add_argument("--hawkeye-installer", type=Path, required=True)
    parser.add_argument("--hawkeye-bin", type=Path, required=True)
    return parser.parse_args()


def parse_verify_java_arguments() -> argparse.Namespace:
    """Parse the standalone complete-runtime verification contract."""
    parser = argparse.ArgumentParser(description="Verify one pinned Java tree.")
    parser.add_argument("command", choices=("verify-java",))
    parser.add_argument("--state-root", type=Path, required=True)
    parser.add_argument("--java-release", required=True)
    parser.add_argument("--java-root", type=Path, required=True)
    parser.add_argument("--java-tree-sha256", required=True)
    return parser.parse_args()


def verify_java_tree(
    *, state_root: Path, root: Path, release: str, expected_tree_sha256: str
) -> None:
    """Fail unless a complete installed runtime matches its pinned tree digest."""
    state = marked_state_root(state_root)
    parent = state / "tools/temurin"
    if (
        parent.is_symlink()
        or not parent.is_dir()
        or parent.resolve(strict=True) != parent
    ):
        raise BootstrapError(f"Temurin verification parent is invalid: {parent}")
    expected = parent / release
    if root != expected or root.is_symlink() or not root.is_dir():
        raise BootstrapError(f"Temurin verification root escaped its pin: {root}")
    expected_tree_sha256 = require_digest(
        expected_tree_sha256, "Temurin tree digest"
    )
    actual = tree_sha256(root)
    if actual != expected_tree_sha256:
        raise BootstrapError(
            "Temurin tree digest mismatch: "
            f"expected {expected_tree_sha256}, got {actual}"
        )


def main() -> int:
    """Install both runtime components below the marked pipeline root."""
    if sys.argv[1:2] == ["verify-java"]:
        verify_args = parse_verify_java_arguments()
        verify_java_tree(
            state_root=verify_args.state_root,
            root=verify_args.java_root,
            release=verify_args.java_release,
            expected_tree_sha256=verify_args.java_tree_sha256,
        )
        return 0
    args = parse_arguments()
    state_root = marked_state_root(args.state_root)
    tools = require_managed_parent(state_root / "tools", state_root / "tools")
    temporary_root = require_managed_parent(state_root / "tmp", state_root / "tmp")
    expected_launcher_parent = (
        tools / "nextflow" / args.nextflow_version
    )
    expected_java_parent = tools / "temurin"
    expected_hawkeye_parent = tools / "hawkeye" / args.hawkeye_version
    if args.nextflow_bin.parent.resolve(strict=False) != expected_launcher_parent:
        raise BootstrapError(
            f"Nextflow destination escaped its pinned tool root: {args.nextflow_bin}"
        )
    if args.java_root.parent.resolve(strict=False) != expected_java_parent:
        raise BootstrapError(
            f"Temurin destination escaped its pinned tool root: {args.java_root}"
        )
    if args.hawkeye_bin.parent.resolve(strict=False) != expected_hawkeye_parent:
        raise BootstrapError(
            f"Hawkeye destination escaped its pinned tool root: {args.hawkeye_bin}"
        )
    if (
        args.nextflow_bin.name != "nextflow"
        or args.java_root.name != args.java_release
        or args.hawkeye_bin.name != "hawkeye"
    ):
        raise BootstrapError("runtime destination name does not match its pin")
    nextflow_bin = expected_launcher_parent / "nextflow"
    java_root = expected_java_parent / args.java_release
    install_launcher(
        destination=nextflow_bin,
        expected_parent=expected_launcher_parent,
        version=args.nextflow_version,
        url=args.nextflow_url,
        expected_sha256=args.nextflow_sha256,
    )
    install_java(
        root=java_root,
        expected_parent=expected_java_parent,
        version=args.java_version,
        release=args.java_release,
        url=args.java_url,
        archive_sha256=args.java_archive_sha256,
        expected_tree_sha256=args.java_tree_sha256,
        runtime_files={
            Path("Contents/Home/bin/java"): args.java_sha256,
            Path("Contents/Home/lib/modules"): args.java_modules_sha256,
            Path("Contents/Home/lib/server/libjvm.dylib"): args.java_libjvm_sha256,
            Path("Contents/Home/release"): args.java_release_sha256,
        },
        temporary_root=temporary_root,
    )
    install_hawkeye(
        destination=expected_hawkeye_parent / "hawkeye",
        expected_parent=expected_hawkeye_parent,
        version=args.hawkeye_version,
        expected_sha256=args.hawkeye_sha256,
        installer=args.hawkeye_installer,
        temporary_root=temporary_root,
    )
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (BootstrapError, OSError, subprocess.SubprocessError, tarfile.TarError) as error:
        print(error, file=sys.stderr)
        raise SystemExit(2) from error
