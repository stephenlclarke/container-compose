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

"""Create and recover exact, isolated Container-family release workspaces."""

from __future__ import annotations

import argparse
import fcntl
import json
import os
import re
import shutil
import socket
import subprocess
import tempfile
import urllib.error
import urllib.request
from collections.abc import Iterable, Iterator
from concurrent.futures import ThreadPoolExecutor
from contextlib import contextmanager
from dataclasses import dataclass
from pathlib import Path


SEMVER = re.compile(r"^[0-9]+[.][0-9]+[.][0-9]+$")
SHA = re.compile(r"^[0-9a-f]{40}$")
BUILD_MARKER = ".container-compose-release-root.json"
WORKSPACE_MARKER = ".container-compose-release-workspace.json"
BUILD_LOCK = ".container-compose-release.lock"
DEFAULT_GIT_TIMEOUT_SECONDS = 300


@dataclass(frozen=True)
class Component:
    name: str
    repository: str
    clone_remote: str = "origin"
    upstream: str | None = None

    @property
    def url(self) -> str:
        return f"https://github.com/{self.repository}.git"


COMPONENTS = (
    Component(
        "container-builder-shim",
        "stephenlclarke/container-builder-shim",
        clone_remote="fork",
        upstream="apple/container-builder-shim",
    ),
    Component(
        "containerization",
        "stephenlclarke/containerization",
        upstream="apple/containerization",
    ),
    Component(
        "container",
        "stephenlclarke/container",
        clone_remote="fork",
        upstream="apple/container",
    ),
    Component("container-compose", "stephenlclarke/container-compose"),
    Component("homebrew-tap", "stephenlclarke/homebrew-tap"),
)
SOURCE_COMPONENTS = COMPONENTS[:-1]


class WorkspaceError(RuntimeError):
    """Raised when an isolated workspace cannot be proven safe or exact."""


def run_git(*arguments: str, cwd: Path | None = None) -> str:
    """Run Git without inheriting checkout-selection environment variables."""

    environment = os.environ.copy()
    for name in (
        "GIT_ALTERNATE_OBJECT_DIRECTORIES",
        "GIT_COMMON_DIR",
        "GIT_DIR",
        "GIT_OBJECT_DIRECTORY",
        "GIT_WORK_TREE",
    ):
        environment.pop(name, None)
    try:
        timeout = int(
            os.environ.get(
                "CONTAINER_STACK_RELEASE_GIT_TIMEOUT_SECONDS",
                str(DEFAULT_GIT_TIMEOUT_SECONDS),
            )
        )
    except ValueError as error:
        raise WorkspaceError(
            "CONTAINER_STACK_RELEASE_GIT_TIMEOUT_SECONDS is not an integer"
        ) from error
    if timeout < 1 or timeout > 1800:
        raise WorkspaceError(
            "CONTAINER_STACK_RELEASE_GIT_TIMEOUT_SECONDS is outside 1..1800"
        )
    try:
        completed = subprocess.run(
            ["git", *arguments],
            cwd=cwd,
            env=environment,
            capture_output=True,
            text=True,
            check=False,
            timeout=timeout,
        )
    except subprocess.TimeoutExpired as error:
        raise WorkspaceError(
            f"git {' '.join(arguments)} exceeded {timeout} seconds"
        ) from error
    if completed.returncode != 0:
        detail = completed.stderr.strip() or completed.stdout.strip()
        raise WorkspaceError(f"git {' '.join(arguments)} failed: {detail}")
    return completed.stdout


def resolve_remote(component: Component, remote_root: Path | None = None) -> str:
    if remote_root is None:
        return component.url
    return str(remote_root / f"{component.name}.git")


def remote_snapshot(
    remote_root: Path | None = None,
) -> tuple[dict[str, str], dict[str, dict[str, str]]]:
    """Read exact main and semantic-tag refs without touching a checkout."""

    def inspect(component: Component) -> tuple[str, str, dict[str, str]]:
        url = resolve_remote(component, remote_root)
        main_output = run_git("ls-remote", "--heads", url, "refs/heads/main")
        main_lines = [line.split() for line in main_output.splitlines() if line]
        if len(main_lines) != 1 or not SHA.fullmatch(main_lines[0][0]):
            raise WorkspaceError(f"could not resolve {component.name} main")

        tag_output = run_git("ls-remote", "--tags", url)
        component_tags: dict[str, str] = {}
        peeled: dict[str, str] = {}
        for line in tag_output.splitlines():
            reference_sha, reference = line.split(maxsplit=1)
            name = reference.removeprefix("refs/tags/")
            if name.endswith("^{}"):
                peeled[name[:-3]] = reference_sha
            elif SEMVER.fullmatch(name):
                component_tags[name] = reference_sha
        component_tags.update(
            {name: value for name, value in peeled.items() if SEMVER.fullmatch(name)}
        )
        return component.name, main_lines[0][0], component_tags

    main_refs: dict[str, str] = {}
    tags: dict[str, dict[str, str]] = {}
    with ThreadPoolExecutor(max_workers=len(COMPONENTS)) as executor:
        for name, main_ref, component_tags in executor.map(inspect, COMPONENTS):
            main_refs[name] = main_ref
            tags[name] = component_tags
    return main_refs, tags


def semantic_key(version: str) -> tuple[int, int, int]:
    parts = version.split(".")
    return int(parts[0]), int(parts[1]), int(parts[2])


def latest_tag(tags: dict[str, str]) -> str:
    return max(tags, key=semantic_key) if tags else ""


def resolve_selector(selector: str, base: str) -> str:
    if not SEMVER.fullmatch(base):
        raise WorkspaceError(f"base version is not semantic: {base}")
    if SEMVER.fullmatch(selector):
        return selector
    if selector not in {"--+", "-+-", "+--"}:
        raise WorkspaceError(f"invalid version selector: {selector}")
    major, minor, patch = semantic_key(base)
    if selector == "+--":
        return f"{major + 1}.0.0"
    if selector == "-+-":
        return f"{major}.{minor + 1}.0"
    return f"{major}.{minor}.{patch + 1}"


def compose_version(main_sha: str, remote_root: Path | None = None) -> str:
    if remote_root is not None:
        makefile = run_git(
            f"--git-dir={remote_root / 'container-compose.git'}",
            "show",
            f"{main_sha}:Makefile",
        )
    else:
        url = (
            "https://raw.githubusercontent.com/stephenlclarke/"
            f"container-compose/{main_sha}/Makefile"
        )
        try:
            with urllib.request.urlopen(url, timeout=30) as response:  # noqa: S310
                makefile = response.read().decode("utf-8")
        except (OSError, UnicodeError, urllib.error.URLError) as error:
            raise WorkspaceError(f"could not read remote compose version: {error}") from error
    match = re.search(
        r"^COMPOSE_VERSION[ ]*[?]=[ ]*([0-9]+[.][0-9]+[.][0-9]+)$",
        makefile,
        re.MULTILINE,
    )
    if match is None or not SEMVER.fullmatch(match.group(1)):
        raise WorkspaceError("remote container-compose version is missing or invalid")
    return match.group(1)


def read_json(path: Path) -> dict[str, object]:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise WorkspaceError(f"invalid marker {path}: {error}") from error
    if not isinstance(value, dict):
        raise WorkspaceError(f"invalid marker object: {path}")
    return value


def fsync_directory(path: Path) -> None:
    """Persist a directory entry update before reporting checkpoint success."""

    descriptor = os.open(path, os.O_RDONLY)
    try:
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


def atomic_json(path: Path, value: dict[str, object]) -> None:
    stage = path.with_name(f".{path.name}.{os.getpid()}.tmp")
    contents = (json.dumps(value, indent=2, sort_keys=True) + "\n").encode("utf-8")
    flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    try:
        descriptor = os.open(stage, flags, 0o600)
        try:
            offset = 0
            while offset < len(contents):
                offset += os.write(descriptor, contents[offset:])
            os.fsync(descriptor)
        finally:
            os.close(descriptor)
        os.replace(stage, path)
        fsync_directory(path.parent)
    except BaseException:
        stage.unlink(missing_ok=True)
        raise


@contextmanager
def build_lock(build_root: Path) -> Iterator[None]:
    """Serialize transaction creation, recovery claims, and cleanup."""

    descriptor = os.open(build_root / BUILD_LOCK, os.O_CREAT | os.O_RDWR, 0o600)
    try:
        fcntl.flock(descriptor, fcntl.LOCK_EX)
        yield
    finally:
        fcntl.flock(descriptor, fcntl.LOCK_UN)
        os.close(descriptor)


def safe_build_root(configured: Path) -> Path:
    expanded = configured.expanduser()
    if expanded.is_symlink():
        raise WorkspaceError(f"release build root must not use symlinks: {configured}")
    absolute = expanded.resolve(strict=False)
    external_volume = Path("/Volumes/SSD")
    if absolute.is_relative_to(external_volume) and not external_volume.is_mount():
        raise WorkspaceError("/Volumes/SSD is not mounted; refusing a system-disk fallback")
    absolute.mkdir(parents=True, exist_ok=True)
    marker = absolute / BUILD_MARKER
    if marker.is_symlink():
        raise WorkspaceError(f"release build root marker is unsafe: {marker}")
    if marker.exists():
        value = read_json(marker)
        if value != {"owner": "container-compose", "schemaVersion": 1}:
            raise WorkspaceError(f"release build root marker is invalid: {marker}")
    else:
        unexpected = [item for item in absolute.iterdir() if item.name != marker.name]
        if unexpected:
            raise WorkspaceError(
                f"unmarked release build root is not empty: {absolute}"
            )
        atomic_json(marker, {"owner": "container-compose", "schemaVersion": 1})
    return absolute


def workspace_marker(root: Path) -> dict[str, object]:
    marker = root / WORKSPACE_MARKER
    if marker.is_symlink():
        raise WorkspaceError(f"release workspace marker is unsafe: {marker}")
    value = read_json(marker)
    if value.get("schemaVersion") != 1 or value.get("owner") != "container-compose":
        raise WorkspaceError(f"release workspace marker is invalid: {marker}")
    return value


def verify_workspace(root: Path, build_root: Path) -> dict[str, object]:
    safe_root = safe_build_root(build_root)
    resolved = root.absolute()
    if root.is_symlink() or resolved.parent != safe_root or not resolved.is_dir():
        raise WorkspaceError(f"release workspace escaped its build root: {root}")
    marker = workspace_marker(resolved)
    if marker.get("state") != "ready":
        raise WorkspaceError("release workspace is not a completed checkpoint")
    version = marker.get("version")
    refs = marker.get("mainRefs")
    remotes = marker.get("remoteUrls")
    if not isinstance(version, str) or not SEMVER.fullmatch(version):
        raise WorkspaceError("release workspace version is invalid")
    if resolved.name != version:
        raise WorkspaceError("release workspace directory does not match its version")
    if not isinstance(refs, dict):
        raise WorkspaceError("release workspace refs are invalid")
    if not isinstance(remotes, dict):
        raise WorkspaceError("release workspace remotes are invalid")

    for component in COMPONENTS:
        path = resolved / component.name
        expected = refs.get(component.name)
        git_directory = path / ".git"
        if path.is_symlink() or git_directory.is_symlink() or not git_directory.is_dir():
            raise WorkspaceError(f"release checkout is missing or unsafe: {path}")
        if not isinstance(expected, str) or not SHA.fullmatch(expected):
            raise WorkspaceError(f"release ref is invalid for {component.name}")
        expected_remote = remotes.get(component.name)
        if not isinstance(expected_remote, str):
            raise WorkspaceError(f"release remote is invalid for {component.name}")
        actual_remote = run_git(
            "remote", "get-url", component.clone_remote, cwd=path
        ).strip()
        if actual_remote != expected_remote:
            raise WorkspaceError(
                f"release remote changed for {component.name}: {actual_remote}"
            )
        push_remote = run_git(
            "remote", "get-url", "--push", component.clone_remote, cwd=path
        ).strip()
        if push_remote != expected_remote:
            raise WorkspaceError(
                f"release push remote changed for {component.name}: {push_remote}"
            )
        if component.upstream is not None:
            upstream_url = f"https://github.com/{component.upstream}.git"
            upstream_fetch = run_git("remote", "get-url", "upstream", cwd=path).strip()
            upstream_push = run_git(
                "remote", "get-url", "--push", "upstream", cwd=path
            ).strip()
            if upstream_fetch != upstream_url or upstream_push != "no_push":
                raise WorkspaceError(
                    f"Apple upstream boundary changed for {component.name}"
                )
            if component.clone_remote == "fork":
                origin_fetch = run_git("remote", "get-url", "origin", cwd=path).strip()
                origin_push = run_git(
                    "remote", "get-url", "--push", "origin", cwd=path
                ).strip()
                if origin_fetch != upstream_url or origin_push != "no_push":
                    raise WorkspaceError(
                        f"Apple origin boundary changed for {component.name}"
                    )
        try:
            run_git("cat-file", "-e", f"{expected}^{{commit}}", cwd=path)
        except WorkspaceError:
            run_git("fetch", component.clone_remote, expected, cwd=path)
            run_git("cat-file", "-e", f"{expected}^{{commit}}", cwd=path)
    return marker


def ensure_workspace_is_idle(marker: dict[str, object]) -> None:
    lease_host = marker.get("leaseHost")
    lease_pid = marker.get("leasePid")
    if lease_host is None and lease_pid is None:
        return
    if (
        lease_host == socket.gethostname()
        and isinstance(lease_pid, int)
        and not process_is_alive(lease_pid)
    ):
        return
    if lease_host == socket.gethostname() and isinstance(lease_pid, int):
        raise WorkspaceError(
            f"release transaction is already active in process {lease_pid}"
        )
    raise WorkspaceError("release transaction lease belongs to another host")


def refresh_mutable_current_tag(root: Path) -> None:
    """Refresh the one mutable release pointer before resuming a checkpoint."""

    compose = root / "container-compose"
    output = run_git(
        "ls-remote",
        "--tags",
        "--refs",
        "origin",
        "refs/tags/current",
        cwd=compose,
    )
    if not output.strip():
        raise WorkspaceError("container-compose current tag is missing from origin")
    fields = output.split()
    if len(fields) != 2 or not SHA.fullmatch(fields[0]):
        raise WorkspaceError("could not resolve container-compose current tag")
    run_git(
        "fetch",
        "origin",
        "+refs/tags/current:refs/tags/current",
        cwd=compose,
    )
    local_current = run_git("rev-parse", "refs/tags/current", cwd=compose).strip()
    if local_current != fields[0]:
        raise WorkspaceError("container-compose current tag changed while refreshing")


def configure_remotes(path: Path, component: Component) -> None:
    if component.upstream is None:
        return
    upstream_url = f"https://github.com/{component.upstream}.git"
    if component.clone_remote == "fork":
        run_git("remote", "add", "origin", upstream_url, cwd=path)
        run_git("remote", "set-url", "--push", "origin", "no_push", cwd=path)
        run_git("remote", "add", "upstream", upstream_url, cwd=path)
        run_git("remote", "set-url", "--push", "upstream", "no_push", cwd=path)
    else:
        run_git("remote", "add", "upstream", upstream_url, cwd=path)
        run_git("remote", "set-url", "--push", "upstream", "no_push", cwd=path)


def clone_workspace(
    stage: Path,
    refs: dict[str, str],
    remote_root: Path | None = None,
) -> None:
    def clone(component: Component) -> None:
        path = stage / component.name
        run_git(
            "clone",
            "--filter=blob:none",
            "--no-checkout",
            "--origin",
            component.clone_remote,
            resolve_remote(component, remote_root),
            str(path),
        )
        run_git("checkout", "-B", "main", refs[component.name], cwd=path)
        configure_remotes(path, component)

    try:
        clone_workers = int(
            os.environ.get("CONTAINER_STACK_RELEASE_CLONE_JOBS", "4")
        )
    except ValueError as error:
        raise WorkspaceError(
            "CONTAINER_STACK_RELEASE_CLONE_JOBS is not an integer"
        ) from error
    if clone_workers < 1 or clone_workers > len(COMPONENTS):
        raise WorkspaceError("CONTAINER_STACK_RELEASE_CLONE_JOBS is outside 1..5")
    with ThreadPoolExecutor(max_workers=clone_workers) as executor:
        list(executor.map(clone, COMPONENTS))


def retained_workspace(build_root: Path, selector: str) -> Path | None:
    matches: list[Path] = []
    for item in build_root.iterdir():
        if not item.is_dir() or item.is_symlink() or not SEMVER.fullmatch(item.name):
            continue
        marker_path = item / WORKSPACE_MARKER
        if not marker_path.is_file() or marker_path.is_symlink():
            continue
        marker = read_json(marker_path)
        if marker.get("selector") == selector or marker.get("version") == selector:
            matches.append(item)
    if len(matches) > 1:
        raise WorkspaceError(f"multiple retained release workspaces match {selector}")
    return matches[0] if matches else None


def cleanup_incomplete_stages(build_root: Path) -> None:
    """Remove only marker-proven clone attempts that never became checkpoints."""

    for item in build_root.iterdir():
        if not item.name.startswith(".") or not item.is_dir() or item.is_symlink():
            continue
        marker_path = item / WORKSPACE_MARKER
        if not marker_path.is_file() or marker_path.is_symlink():
            continue
        marker = read_json(marker_path)
        if (
            marker.get("owner") == "container-compose"
            and marker.get("schemaVersion") == 1
            and marker.get("state") == "cloning"
        ):
            stage_host = marker.get("stageHost")
            stage_pid = marker.get("stagePid")
            if stage_host != socket.gethostname():
                raise WorkspaceError(
                    f"incomplete release clone belongs to another host: {item}"
                )
            if isinstance(stage_pid, int) and process_is_alive(stage_pid):
                raise WorkspaceError(f"release workspace clone is still active: {item}")
            shutil.rmtree(item)
            fsync_directory(build_root)


def process_is_alive(pid: int) -> bool:
    if pid < 1:
        return False
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    return True


def _materialize_locked(
    safe_root: Path,
    selector: str,
    remote_root: Path | None = None,
) -> Path:
    cleanup_incomplete_stages(safe_root)
    retained = retained_workspace(safe_root, selector)
    if retained is not None:
        marker = verify_workspace(retained, safe_root)
        ensure_workspace_is_idle(marker)
        refresh_mutable_current_tag(retained)
        return retained

    refs, tags = remote_snapshot(remote_root)
    latest = latest_tag(tags["container-compose"])
    base = latest or compose_version(refs["container-compose"], remote_root)
    version = resolve_selector(selector, base)
    destination = safe_root / version
    if destination.exists():
        marker = verify_workspace(destination, safe_root)
        ensure_workspace_is_idle(marker)
        refresh_mutable_current_tag(destination)
        return destination

    stage = Path(tempfile.mkdtemp(prefix=f".{version}.", dir=safe_root))
    try:
        remote_urls = {
            component.name: resolve_remote(component, remote_root)
            for component in COMPONENTS
        }
        marker = {
            "mainRefs": refs,
            "owner": "container-compose",
            "remoteUrls": remote_urls,
            "schemaVersion": 1,
            "selector": selector,
            "stageHost": socket.gethostname(),
            "stagePid": os.getpid(),
            "state": "cloning",
            "version": version,
        }
        atomic_json(stage / WORKSPACE_MARKER, marker)
        clone_workspace(stage, refs, remote_root)
        fresh_refs, fresh_tags = remote_snapshot(remote_root)
        if fresh_refs != refs or fresh_tags != tags:
            raise WorkspaceError(
                "a component main or semantic tag moved while the workspace was cloned"
            )
        marker["state"] = "ready"
        marker.pop("stageHost")
        marker.pop("stagePid")
        atomic_json(stage / WORKSPACE_MARKER, marker)
        os.replace(stage, destination)
        fsync_directory(safe_root)
    except BaseException:
        shutil.rmtree(stage, ignore_errors=True)
        raise
    verify_workspace(destination, safe_root)
    refresh_mutable_current_tag(destination)
    return destination


def materialize(
    build_root: Path,
    selector: str,
    remote_root: Path | None = None,
) -> Path:
    safe_root = safe_build_root(build_root)
    with build_lock(safe_root):
        return _materialize_locked(safe_root, selector, remote_root)


def claim(root: Path, build_root: Path, pid: int) -> None:
    if not process_is_alive(pid):
        raise WorkspaceError(f"release transaction claimant is not alive: {pid}")
    safe_root = safe_build_root(build_root)
    with build_lock(safe_root):
        marker = verify_workspace(root, safe_root)
        ensure_workspace_is_idle(marker)
        marker["leaseHost"] = socket.gethostname()
        marker["leasePid"] = pid
        atomic_json(root / WORKSPACE_MARKER, marker)


def release_claim(root: Path, build_root: Path, pid: int) -> None:
    safe_root = safe_build_root(build_root)
    with build_lock(safe_root):
        marker = verify_workspace(root, safe_root)
        if (
            marker.get("leaseHost") != socket.gethostname()
            or marker.get("leasePid") != pid
        ):
            raise WorkspaceError("release transaction lease identity changed")
        marker.pop("leaseHost")
        marker.pop("leasePid")
        atomic_json(root / WORKSPACE_MARKER, marker)


def execute(root: Path, build_root: Path, arguments: list[str]) -> None:
    """Claim a transaction, then preserve that lease PID in the release child."""

    if not arguments or not arguments[0]:
        raise WorkspaceError("release transaction command is empty")
    claim(root, build_root, os.getpid())
    try:
        os.execvpe(arguments[0], arguments, os.environ)
    except OSError as error:
        raise WorkspaceError(
            f"could not execute release transaction command: {error}"
        ) from error


def cleanup(root: Path, build_root: Path) -> None:
    safe_root = safe_build_root(build_root)
    with build_lock(safe_root):
        marker = verify_workspace(root, safe_root)
        if marker.get("leaseHost") is not None or marker.get("leasePid") is not None:
            raise WorkspaceError("release transaction is still claimed")
        shutil.rmtree(root)
        fsync_directory(safe_root)


def format_plan(remote_root: Path | None = None) -> str:
    refs, tags = remote_snapshot(remote_root)
    current = compose_version(refs["container-compose"], remote_root)
    latest = latest_tag(tags["container-compose"]) or current
    lines = [
        "current COMPOSE_VERSION: " + current,
        "latest semantic tag:     " + latest,
        "next patch release:      " + resolve_selector("--+", latest),
        "next minor release:      " + resolve_selector("-+-", latest),
        "next major release:      " + resolve_selector("+--", latest),
        "",
        f"{'component':26} {'main-sha':40} {'changed-since-tag':18}",
    ]
    for component in SOURCE_COMPONENTS:
        last = latest_tag(tags[component.name])
        changed = "yes"
        if last and tags[component.name][last] == refs[component.name]:
            changed = "no"
        lines.append(f"{component.name:26} {refs[component.name]:40} {changed:18}")
    return "\n".join(lines)


def default_build_root() -> Path:
    configured = os.environ.get("CONTAINER_STACK_RELEASE_BUILD_ROOT")
    if configured:
        return Path(configured)
    return Path("/Volumes/SSD/github/container-compose-release-transactions")


def parse_arguments(arguments: Iterable[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--remote-root", type=Path)
    subparsers = parser.add_subparsers(dest="command", required=True)
    subparsers.add_parser("plan")
    materialize_parser = subparsers.add_parser("materialize")
    materialize_parser.add_argument("selector")
    materialize_parser.add_argument("--build-root", type=Path, default=default_build_root())
    verify_parser = subparsers.add_parser("verify")
    verify_parser.add_argument("root", type=Path)
    verify_parser.add_argument("--build-root", type=Path, default=default_build_root())
    cleanup_parser = subparsers.add_parser("cleanup")
    cleanup_parser.add_argument("root", type=Path)
    cleanup_parser.add_argument("--build-root", type=Path, default=default_build_root())
    claim_parser = subparsers.add_parser("claim")
    claim_parser.add_argument("root", type=Path)
    claim_parser.add_argument("--pid", type=int, required=True)
    claim_parser.add_argument("--build-root", type=Path, default=default_build_root())
    release_claim_parser = subparsers.add_parser("release-claim")
    release_claim_parser.add_argument("root", type=Path)
    release_claim_parser.add_argument("--pid", type=int, required=True)
    release_claim_parser.add_argument(
        "--build-root", type=Path, default=default_build_root()
    )
    execute_parser = subparsers.add_parser("execute")
    execute_parser.add_argument("root", type=Path)
    execute_parser.add_argument("--build-root", type=Path, default=default_build_root())
    execute_parser.add_argument("arguments", nargs=argparse.REMAINDER)
    return parser.parse_args(arguments)


def main(arguments: Iterable[str] | None = None) -> int:
    options = parse_arguments(arguments)
    if options.command == "plan":
        print(format_plan(options.remote_root))
    elif options.command == "materialize":
        print(materialize(options.build_root, options.selector, options.remote_root))
    elif options.command == "verify":
        verify_workspace(options.root, options.build_root)
        print(options.root.absolute())
    elif options.command == "cleanup":
        cleanup(options.root, options.build_root)
    elif options.command == "claim":
        claim(options.root, options.build_root, options.pid)
    elif options.command == "release-claim":
        release_claim(options.root, options.build_root, options.pid)
    elif options.command == "execute":
        execute(options.root, options.build_root, options.arguments)
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except WorkspaceError as error:
        raise SystemExit(str(error)) from error
