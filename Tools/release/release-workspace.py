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
import uuid
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
MUTABLE_TAGS_BY_COMPONENT = {
    "container": frozenset({"homebrew-main"}),
    "container-compose": frozenset({"current"}),
}


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


def parse_remote_semantic_tags(output: str) -> dict[str, str]:
    component_tags: dict[str, str] = {}
    for line in output.splitlines():
        reference_sha, reference = line.split(maxsplit=1)
        name = reference.removeprefix("refs/tags/")
        if SEMVER.fullmatch(name):
            component_tags[name] = reference_sha
    return component_tags


def remote_semantic_tags(url: str) -> dict[str, str]:
    return parse_remote_semantic_tags(run_git("ls-remote", "--tags", url))


def mutable_tags(component_name: str) -> frozenset[str]:
    return MUTABLE_TAGS_BY_COMPONENT.get(component_name, frozenset())


def remote_immutable_tag_refs(url: str, component_name: str) -> dict[str, str]:
    refs: dict[str, str] = {}
    for line in run_git("ls-remote", "--tags", "--refs", url).splitlines():
        reference_sha, reference = line.split(maxsplit=1)
        name = reference.removeprefix("refs/tags/")
        if name not in mutable_tags(component_name):
            refs[name] = reference_sha
    return refs


def local_immutable_tag_refs(path: Path, component_name: str) -> dict[str, str]:
    refs: dict[str, str] = {}
    lines = run_git(
        "for-each-ref",
        "--format=%(refname:strip=2) %(objectname)",
        "refs/tags",
        cwd=path,
    ).splitlines()
    for line in lines:
        fields = line.split()
        if len(fields) != 2 or not SHA.fullmatch(fields[1]):
            raise WorkspaceError(f"could not inspect tags in {path}")
        if fields[0] not in mutable_tags(component_name):
            refs[fields[0]] = fields[1]
    return refs


def local_semantic_tag_targets(path: Path) -> dict[str, str]:
    targets: dict[str, str] = {}
    for name in run_git(
        "tag", "--list", "[0-9]*.[0-9]*.[0-9]*", cwd=path
    ).splitlines():
        if not SEMVER.fullmatch(name):
            continue
        target = run_git("rev-parse", f"refs/tags/{name}", cwd=path).strip()
        if not SHA.fullmatch(target):
            raise WorkspaceError(f"could not inspect semantic tag {name} in {path}")
        targets[name] = target
    return targets


def local_remote_tracking_refs(path: Path) -> dict[str, str]:
    refs: dict[str, str] = {}
    lines = run_git(
        "for-each-ref",
        "--format=%(refname) %(objectname)",
        "refs/remotes",
        cwd=path,
    ).splitlines()
    for line in lines:
        fields = line.split()
        if (
            len(fields) != 2
            or not fields[0].startswith("refs/remotes/")
            or not SHA.fullmatch(fields[1])
        ):
            raise WorkspaceError(f"could not inspect remote refs in {path}")
        refs[fields[0]] = fields[1]
    return refs


def local_recovery_objects(path: Path) -> list[str]:
    """Return objects protected by reflogs or Git recovery pseudorefs."""

    objects = {
        value
        for value in run_git("reflog", "show", "--all", "--format=%H", cwd=path)
        .splitlines()
        if value
    }
    git_directory = Path(run_git("rev-parse", "--absolute-git-dir", cwd=path).strip())
    fetch_head = git_directory / "FETCH_HEAD"
    if fetch_head.is_symlink():
        raise WorkspaceError(f"Git recovery state is unsafe in {path}")
    if fetch_head.is_file():
        for line in fetch_head.read_text(encoding="utf-8").splitlines():
            fields = line.split(maxsplit=1)
            if not fields or not SHA.fullmatch(fields[0]):
                raise WorkspaceError(f"could not inspect Git recovery state in {path}")
            objects.add(fields[0])
    for name in ("AUTO_MERGE", "BISECT_HEAD", "MERGE_AUTOSTASH", "ORIG_HEAD"):
        pseudoref = git_directory / name
        if pseudoref.is_symlink():
            raise WorkspaceError(f"Git recovery state is unsafe in {path}")
        if not pseudoref.is_file():
            continue
        value = pseudoref.read_text(encoding="utf-8").strip()
        if not SHA.fullmatch(value):
            raise WorkspaceError(f"could not inspect Git recovery state in {path}")
        objects.add(value)
    return sorted(objects)


def remote_reachable_objects(url: str) -> set[str]:
    objects: set[str] = set()
    for line in run_git("ls-remote", url).splitlines():
        fields = line.split()
        if len(fields) != 2 or not SHA.fullmatch(fields[0]):
            raise WorkspaceError(f"could not inspect remote refs at {url}")
        objects.add(fields[0])
    return objects


def object_reachable_from_advertised_refs(
    path: Path, candidate: str, advertised: set[str]
) -> bool:
    """Return whether an object is named by, or is history of, a remote ref."""

    if candidate in advertised:
        return True
    try:
        containing_refs = run_git(
            "for-each-ref",
            "--contains",
            candidate,
            "--format=%(objectname)",
            "refs/heads",
            "refs/remotes",
            "refs/tags",
            cwd=path,
        ).splitlines()
    except WorkspaceError:
        return False
    return any(tip in advertised for tip in containing_refs)


def expected_fetch_remotes(component: Component, clone_url: str) -> dict[str, str]:
    """Return the exact, controller-owned fetch remotes for a component."""

    remotes = {component.clone_remote: clone_url}
    if component.upstream is None:
        return remotes
    upstream_url = f"https://github.com/{component.upstream}.git"
    remotes["upstream"] = upstream_url
    if component.clone_remote == "fork":
        remotes["origin"] = upstream_url
    return remotes


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

        component_tags = remote_semantic_tags(url)
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
    immutable_tags = marker.get("immutableTagRefs")
    remote_refs = marker.get("remoteTrackingRefs")
    recovery_objects = marker.get("recoveryObjects")
    semantic_tags = marker.get("semanticTagTargets")
    if not isinstance(version, str) or not SEMVER.fullmatch(version):
        raise WorkspaceError("release workspace version is invalid")
    if resolved.name != version:
        raise WorkspaceError("release workspace directory does not match its version")
    if not isinstance(refs, dict):
        raise WorkspaceError("release workspace refs are invalid")
    if not isinstance(remotes, dict):
        raise WorkspaceError("release workspace remotes are invalid")
    if immutable_tags is not None:
        if not isinstance(immutable_tags, dict) or set(immutable_tags) != {
            component.name for component in COMPONENTS
        }:
            raise WorkspaceError("release workspace tag refs are invalid")
        for component_name, component_tags in immutable_tags.items():
            if not isinstance(component_tags, dict) or any(
                not isinstance(name, str)
                or not name
                or name in mutable_tags(component_name)
                or not isinstance(value, str)
                or not SHA.fullmatch(value)
                for name, value in component_tags.items()
            ):
                raise WorkspaceError("release workspace tag refs are invalid")
    if remote_refs is not None:
        if not isinstance(remote_refs, dict) or set(remote_refs) != {
            component.name for component in COMPONENTS
        }:
            raise WorkspaceError("release workspace remote refs are invalid")
        for component_refs in remote_refs.values():
            if not isinstance(component_refs, dict) or any(
                not isinstance(name, str)
                or not name.startswith("refs/remotes/")
                or not isinstance(value, str)
                or not SHA.fullmatch(value)
                for name, value in component_refs.items()
            ):
                raise WorkspaceError("release workspace remote refs are invalid")
    if recovery_objects is not None:
        if not isinstance(recovery_objects, dict) or set(recovery_objects) != {
            component.name for component in COMPONENTS
        }:
            raise WorkspaceError("release workspace recovery objects are invalid")
        for component_objects in recovery_objects.values():
            if not isinstance(component_objects, list) or any(
                not isinstance(value, str) or not SHA.fullmatch(value)
                for value in component_objects
            ) or component_objects != sorted(set(component_objects)):
                raise WorkspaceError("release workspace recovery objects are invalid")
    if semantic_tags is not None:
        if not isinstance(semantic_tags, dict) or set(semantic_tags) != {
            component.name for component in COMPONENTS
        }:
            raise WorkspaceError("release workspace semantic tags are invalid")
        for component_tags in semantic_tags.values():
            if not isinstance(component_tags, dict) or any(
                not isinstance(name, str)
                or not SEMVER.fullmatch(name)
                or not isinstance(value, str)
                or not SHA.fullmatch(value)
                for name, value in component_tags.items()
            ):
                raise WorkspaceError("release workspace semantic tags are invalid")

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
        "--no-write-fetch-head",
        "origin",
        "+refs/tags/current:refs/tags/current",
        cwd=compose,
    )
    local_current = run_git("rev-parse", "refs/tags/current", cwd=compose).strip()
    if local_current != fields[0]:
        raise WorkspaceError("container-compose current tag changed while refreshing")


def workspace_matches_initial_checkpoint(
    root: Path,
    marker: dict[str, object],
) -> bool:
    """Return whether a retained transaction is still safe to replace."""

    refs = marker["mainRefs"]
    remotes = marker["remoteUrls"]
    recorded_tags = marker.get("immutableTagRefs")
    recorded_remote_refs = marker.get("remoteTrackingRefs")
    recorded_recovery_objects = marker.get("recoveryObjects")
    assert isinstance(refs, dict)
    assert isinstance(remotes, dict)
    assert recorded_tags is None or isinstance(recorded_tags, dict)
    assert recorded_remote_refs is None or isinstance(recorded_remote_refs, dict)
    assert recorded_recovery_objects is None or isinstance(
        recorded_recovery_objects, dict
    )
    advertised_by_url: dict[str, set[str]] = {}
    advertised_refs_by_url: dict[str, dict[str, str]] = {}

    def advertised_objects(url: str) -> set[str]:
        if url in advertised_refs_by_url:
            return set(advertised_refs_by_url[url].values())
        if url not in advertised_by_url:
            advertised_by_url[url] = remote_reachable_objects(url)
        return advertised_by_url[url]

    def advertised_refs(url: str) -> dict[str, str]:
        if url not in advertised_refs_by_url:
            refs: dict[str, str] = {}
            for line in run_git("ls-remote", url).splitlines():
                fields = line.split()
                if len(fields) != 2 or not SHA.fullmatch(fields[0]):
                    raise WorkspaceError(f"could not inspect remote refs at {url}")
                refs[fields[1]] = fields[0]
            advertised_refs_by_url[url] = refs
            advertised_by_url[url] = set(refs.values())
        return advertised_refs_by_url[url]

    def tracked_ref_target(
        ref: str, expected_remotes: dict[str, str]
    ) -> tuple[str, str] | None:
        suffix = ref.removeprefix("refs/remotes/")
        remote_name, separator, remote_ref = suffix.partition("/")
        if not separator or remote_name not in expected_remotes:
            return None
        advertised_ref = "HEAD" if remote_ref == "HEAD" else f"refs/heads/{remote_ref}"
        return expected_remotes[remote_name], advertised_ref

    for component in COMPONENTS:
        path = root / component.name
        expected = refs[component.name]
        clone_url = str(remotes[component.name])
        expected_remotes = expected_fetch_remotes(component, clone_url)
        actual_remotes = set(run_git("remote", cwd=path).splitlines())
        if actual_remotes != set(expected_remotes):
            return False
        if any(
            run_git("remote", "get-url", name, cwd=path).strip() != url
            for name, url in expected_remotes.items()
        ):
            return False
        if run_git("branch", "--show-current", cwd=path).strip() != "main":
            return False
        if run_git("rev-parse", "HEAD", cwd=path).strip() != expected:
            return False
        worktrees = run_git(
            "worktree", "list", "--porcelain", "-z", cwd=path
        ).split("\0")
        if sum(field.startswith("worktree ") for field in worktrees) != 1:
            return False
        index_entries = run_git("ls-files", "-v", cwd=path).splitlines()
        if any(
            entry.startswith("S ") or (entry and entry[0].islower())
            for entry in index_entries
        ):
            return False
        git_directory = Path(
            run_git("rev-parse", "--absolute-git-dir", cwd=path).strip()
        )
        grafts = git_directory / "info" / "grafts"
        if grafts.exists() or grafts.is_symlink():
            return False
        local_remote_refs = local_remote_tracking_refs(path)
        if recorded_remote_refs is not None:
            initial_remote_refs = recorded_remote_refs[component.name]
            assert isinstance(initial_remote_refs, dict)
            # A failed child may already have fetched before it stopped. Treat
            # only the exact tracking-ref value currently advertised by that
            # configured remote as disposable controller state.
            for name, value in local_remote_refs.items():
                if initial_remote_refs.get(name) == value:
                    continue
                target = tracked_ref_target(name, expected_remotes)
                if target is None or advertised_refs(target[0]).get(target[1]) != value:
                    return False
            for name in initial_remote_refs.keys() - local_remote_refs.keys():
                target = tracked_ref_target(name, expected_remotes)
                if target is None or target[1] in advertised_refs(target[0]):
                    return False
        else:
            for name, value in local_remote_refs.items():
                suffix = name.removeprefix("refs/remotes/")
                remote_name, separator, _ = suffix.partition("/")
                if (
                    not separator
                    or remote_name not in expected_remotes
                    or (
                        value not in advertised_objects(expected_remotes[remote_name])
                        and not (
                            remote_name == component.clone_remote
                            and value == expected
                        )
                    )
                ):
                    return False
        recovery_objects = set(local_recovery_objects(path))
        if recorded_recovery_objects is not None:
            initial_recovery_objects = recorded_recovery_objects[component.name]
            assert isinstance(initial_recovery_objects, list)
            new_recovery_objects = recovery_objects - set(initial_recovery_objects)
        else:
            new_recovery_objects = recovery_objects
        if new_recovery_objects:
            advertised = set(advertised_objects(clone_url))
            advertised.add(str(expected))
            missing = {
                value
                for value in new_recovery_objects
                if not object_reachable_from_advertised_refs(
                    path, value, advertised
                )
            }
            for name, url in expected_remotes.items():
                if not missing or name == component.clone_remote:
                    continue
                remote_advertised = advertised_objects(url)
                missing = {
                    value
                    for value in missing
                    if not object_reachable_from_advertised_refs(
                        path, value, remote_advertised
                    )
                }
            if missing:
                return False
        repository_refs = run_git(
            "for-each-ref", "--format=%(refname)", cwd=path
        ).splitlines()
        if any(
            ref != "refs/heads/main"
            and not ref.startswith("refs/remotes/")
            and not ref.startswith("refs/tags/")
            for ref in repository_refs
        ):
            return False
        local_tags = local_immutable_tag_refs(path, component.name)
        if recorded_tags is not None:
            initial_tags = recorded_tags[component.name]
            assert isinstance(initial_tags, dict)
            if local_tags != initial_tags:
                return False
        else:
            remote_tags = remote_immutable_tag_refs(
                str(remotes[component.name]), component.name
            )
            if any(
                remote_tags.get(name) != value for name, value in local_tags.items()
            ):
                return False
        git_state_paths = (
            "BISECT_START",
            "CHERRY_PICK_HEAD",
            "MERGE_HEAD",
            "REVERT_HEAD",
            "rebase-apply",
            "rebase-merge",
            "sequencer",
        )
        if any(
            (git_directory / state_name).exists()
            or (git_directory / state_name).is_symlink()
            for state_name in git_state_paths
        ):
            return False
        release_evidence = path / ".build" / "release-evidence"
        if release_evidence.exists() or release_evidence.is_symlink():
            return False
        if run_git(
            "status",
            "--porcelain=v1",
            "--untracked-files=all",
            cwd=path,
        ).strip():
            return False
    return True


def workspace_semantic_tag_targets(
    root: Path, marker: dict[str, object]
) -> dict[str, dict[str, str]]:
    recorded = marker.get("semanticTagTargets")
    if recorded is not None:
        assert isinstance(recorded, dict)
        return recorded
    return {
        component.name: local_semantic_tag_targets(root / component.name)
        for component in COMPONENTS
    }


def workspace_baseline_state(root: Path) -> dict[str, object]:
    """Capture the local Git state recorded by a fresh checkpoint."""

    return {
        "immutableTagRefs": {
            component.name: local_immutable_tag_refs(
                root / component.name, component.name
            )
            for component in COMPONENTS
        },
        "remoteTrackingRefs": {
            component.name: local_remote_tracking_refs(root / component.name)
            for component in COMPONENTS
        },
        "recoveryObjects": {
            component.name: local_recovery_objects(root / component.name)
            for component in COMPONENTS
        },
    }


def update_workspace_tag_state(
    root: Path,
    marker: dict[str, object],
    semantic_tags: dict[str, dict[str, str]],
    baseline: dict[str, object] | None = None,
) -> None:
    marker.update(baseline if baseline is not None else workspace_baseline_state(root))
    marker["semanticTagTargets"] = semantic_tags
    atomic_json(root / WORKSPACE_MARKER, marker)


def selected_version(
    selector: str,
    refs: dict[str, str],
    tags: dict[str, dict[str, str]],
    remote_root: Path | None,
) -> str:
    latest = latest_tag(tags["container-compose"])
    base = latest or compose_version(refs["container-compose"], remote_root)
    return resolve_selector(selector, base)


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


def cleanup_orphaned_ready_stages(build_root: Path) -> None:
    """Remove completed clone stages that were never journaled for handover."""

    referenced: set[str] = set()
    for item in build_root.iterdir():
        if not item.is_dir() or item.is_symlink():
            continue
        marker_path = item / WORKSPACE_MARKER
        if not marker_path.is_file() or marker_path.is_symlink():
            continue
        replacement = read_json(marker_path).get("replacement")
        stage = replacement.get("stage") if isinstance(replacement, dict) else None
        if isinstance(stage, str):
            referenced.add(stage)

    for item in build_root.iterdir():
        if (
            not item.name.startswith(".")
            or ".replaced." in item.name
            or item.name in referenced
            or not item.is_dir()
            or item.is_symlink()
        ):
            continue
        marker_path = item / WORKSPACE_MARKER
        if not marker_path.is_file() or marker_path.is_symlink():
            continue
        marker = read_json(marker_path)
        version = marker.get("version")
        if (
            marker.get("owner") == "container-compose"
            and marker.get("schemaVersion") == 1
            and marker.get("state") == "ready"
            and isinstance(version, str)
            and SEMVER.fullmatch(version)
            and item.name.startswith(f".{version}.")
        ):
            shutil.rmtree(item)
            fsync_directory(build_root)


def replacement_path(build_root: Path, value: object, label: str) -> Path:
    if not isinstance(value, str) or Path(value).name != value or value in {".", ".."}:
        raise WorkspaceError(f"release replacement {label} is invalid")
    return build_root / value


def remove_replacement_stage(stage: Path | None, version: str) -> None:
    if stage is None:
        return
    if not stage.exists():
        return
    if stage.is_symlink() or not stage.is_dir():
        raise WorkspaceError(f"release replacement stage is unsafe: {stage}")
    marker = workspace_marker(stage)
    if marker.get("state") not in {"cloning", "ready"} or marker.get("version") != version:
        raise WorkspaceError(f"release replacement stage marker is invalid: {stage}")
    shutil.rmtree(stage)


def retired_workspace_path(build_root: Path, version: object) -> Path:
    """Choose a durable, process-independent name for a retired checkpoint."""

    if not isinstance(version, str) or not SEMVER.fullmatch(version):
        raise WorkspaceError(f"release workspace version is invalid: {version}")
    return build_root / f".{version}.replaced.{uuid.uuid4().hex}"


def retire_workspace(
    source: Path,
    backup: Path,
    marker: dict[str, object],
    build_root: Path,
) -> Path:
    """Atomically hide and revalidate a checkpoint before retiring it."""

    if backup.exists():
        raise WorkspaceError(f"release workspace backup already exists: {backup}")
    os.replace(source, backup)
    fsync_directory(build_root)
    if workspace_matches_initial_checkpoint(backup, marker):
        return backup
    if source.exists():
        raise WorkspaceError(
            f"release workspace changed while being retired; preserved at {backup}"
        )
    os.replace(backup, source)
    fsync_directory(build_root)
    restored = marker.copy()
    restored.pop("replacement", None)
    atomic_json(source / WORKSPACE_MARKER, restored)
    raise WorkspaceError(f"release workspace changed while being retired: {source}")


def finalize_retired_workspace(path: Path, build_root: Path) -> None:
    """Retain a superseded checkpoint without leaving an active handover journal."""

    marker = workspace_marker(path)
    marker.pop("replacement", None)
    marker["state"] = "retired"
    atomic_json(path / WORKSPACE_MARKER, marker)
    fsync_directory(build_root)


def recover_interrupted_replacements(build_root: Path) -> None:
    """Finish or roll back marker-journaled checkpoint handovers."""

    for item in list(build_root.iterdir()):
        if not item.is_dir() or item.is_symlink():
            continue
        marker_path = item / WORKSPACE_MARKER
        if not marker_path.is_file() or marker_path.is_symlink():
            continue
        marker = read_json(marker_path)
        replacement = marker.get("replacement")
        if replacement is None:
            continue
        if (
            marker.get("owner") != "container-compose"
            or marker.get("schemaVersion") != 1
            or marker.get("state") != "ready"
            or not isinstance(replacement, dict)
        ):
            raise WorkspaceError(f"release replacement marker is invalid: {item}")
        version = replacement.get("version")
        selector = replacement.get("selector")
        refs = replacement.get("mainRefs")
        semantic_tags = replacement.get("semanticTagTargets")
        if (
            not isinstance(version, str)
            or not SEMVER.fullmatch(version)
            or not isinstance(selector, str)
            or not isinstance(refs, dict)
            or set(refs) != {component.name for component in COMPONENTS}
            or any(
                not isinstance(value, str) or not SHA.fullmatch(value)
                for value in refs.values()
            )
            or not isinstance(semantic_tags, dict)
            or set(semantic_tags) != {component.name for component in COMPONENTS}
            or any(
                not isinstance(component_tags, dict)
                or any(
                    not isinstance(name, str)
                    or not SEMVER.fullmatch(name)
                    or not isinstance(value, str)
                    or not SHA.fullmatch(value)
                    for name, value in component_tags.items()
                )
                for component_tags in semantic_tags.values()
            )
        ):
            raise WorkspaceError(f"release replacement record is invalid: {item}")
        destination = replacement_path(
            build_root, replacement.get("destination"), "destination"
        )
        source_value = replacement.get("source", marker.get("version"))
        source = replacement_path(build_root, source_value, "source")
        stage_value = replacement.get("stage")
        stage = (
            replacement_path(build_root, stage_value, "stage")
            if stage_value is not None
            else None
        )
        if (
            destination.name != version
            or source.name != marker.get("version")
            or (
                stage is not None
                and not stage.name.startswith(f".{version}.")
            )
        ):
            raise WorkspaceError(f"release replacement paths are inconsistent: {item}")
        ensure_workspace_is_idle(marker)

        installed = False
        if destination.exists() and destination != item:
            destination_marker = verify_workspace(destination, build_root)
            ensure_workspace_is_idle(destination_marker)
            destination_matches = (
                destination_marker.get("version") == version
                and destination_marker.get("mainRefs") == refs
                and destination_marker.get("semanticTagTargets") == semantic_tags
            )
            if destination_matches:
                installed = True

        if installed:
            if not item.name.startswith("."):
                if item != source:
                    raise WorkspaceError(
                        f"release replacement source path is inconsistent: {item}"
                    )
                if not workspace_matches_initial_checkpoint(item, marker):
                    if destination_marker.get("selector") != version:
                        destination_marker["selector"] = version
                        atomic_json(
                            destination / WORKSPACE_MARKER, destination_marker
                        )
                    restored = marker.copy()
                    restored.pop("replacement")
                    atomic_json(item / WORKSPACE_MARKER, restored)
                    remove_replacement_stage(stage, version)
                    fsync_directory(build_root)
                    continue
                backup = retired_workspace_path(build_root, marker["version"])
                item = retire_workspace(item, backup, marker, build_root)
            if destination_marker.get("selector") != selector:
                destination_marker["selector"] = selector
                atomic_json(destination / WORKSPACE_MARKER, destination_marker)
            finalize_retired_workspace(item, build_root)
            remove_replacement_stage(stage, version)
            fsync_directory(build_root)
            continue

        if item.name.startswith("."):
            if source.exists():
                raise WorkspaceError(
                    f"release replacement rollback source exists: {source}"
                )
            os.replace(item, source)
            fsync_directory(build_root)
            item = source
        elif item != source:
            raise WorkspaceError(
                f"release replacement source path is inconsistent: {item}"
            )
        restored = marker.copy()
        restored.pop("replacement")
        atomic_json(item / WORKSPACE_MARKER, restored)
        remove_replacement_stage(stage, version)
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
    recover_interrupted_replacements(safe_root)
    cleanup_orphaned_ready_stages(safe_root)
    snapshot: tuple[dict[str, str], dict[str, dict[str, str]]] | None = None
    stale_retained: Path | None = None
    retained = retained_workspace(safe_root, selector)
    if retained is not None:
        marker = verify_workspace(retained, safe_root)
        ensure_workspace_is_idle(marker)
        retained_needs_baseline = any(
            marker.get(field) is None
            for field in (
                "immutableTagRefs",
                "recoveryObjects",
                "remoteTrackingRefs",
                "semanticTagTargets",
            )
        )
        retained_baseline = (
            workspace_baseline_state(retained) if retained_needs_baseline else None
        )
        if workspace_matches_initial_checkpoint(retained, marker):
            snapshot = remote_snapshot(remote_root)
            refs, tags = snapshot
            if (
                refs != marker["mainRefs"]
                or workspace_semantic_tag_targets(retained, marker) != tags
                or selected_version(selector, refs, tags, remote_root)
                != marker["version"]
            ):
                stale_retained = retained
            else:
                refresh_mutable_current_tag(retained)
                if retained_baseline is not None and (
                    workspace_baseline_state(retained) == retained_baseline
                    and workspace_matches_initial_checkpoint(retained, marker)
                ):
                    update_workspace_tag_state(
                        retained, marker, tags, retained_baseline
                    )
                return retained
        else:
            refresh_mutable_current_tag(retained)
            return retained

    if snapshot is None:
        snapshot = remote_snapshot(remote_root)
    refs, tags = snapshot
    version = selected_version(selector, refs, tags, remote_root)
    destination = safe_root / version
    stale_destination: Path | None = None
    if destination.exists():
        marker = verify_workspace(destination, safe_root)
        ensure_workspace_is_idle(marker)
        destination_needs_baseline = any(
            marker.get(field) is None
            for field in (
                "immutableTagRefs",
                "recoveryObjects",
                "remoteTrackingRefs",
                "semanticTagTargets",
            )
        )
        destination_baseline = (
            workspace_baseline_state(destination)
            if destination_needs_baseline
            else None
        )
        destination_matches_initial = workspace_matches_initial_checkpoint(
            destination, marker
        )
        if (
            destination_matches_initial
            and (
                marker["mainRefs"] != refs
                or marker["version"] != version
                or workspace_semantic_tag_targets(destination, marker) != tags
            )
        ):
            stale_destination = destination
        elif destination != stale_retained:
            refresh_mutable_current_tag(destination)
            destination_tags = workspace_semantic_tag_targets(destination, marker)
            retired: Path | None = None
            if stale_retained is not None:
                stale_marker = verify_workspace(stale_retained, safe_root)
                ensure_workspace_is_idle(stale_marker)
                if not workspace_matches_initial_checkpoint(
                    stale_retained, stale_marker
                ):
                    raise WorkspaceError(
                        "release workspace changed before destination reuse"
                    )
                backup = retired_workspace_path(safe_root, stale_retained.name)
                replacement = {
                    "destination": destination.name,
                    "mainRefs": marker["mainRefs"],
                    "selector": selector,
                    "semanticTagTargets": destination_tags,
                    "source": stale_retained.name,
                    "stage": None,
                    "version": marker["version"],
                }
                stale_marker["replacement"] = replacement
                atomic_json(stale_retained / WORKSPACE_MARKER, stale_marker)
                retired = retire_workspace(
                    stale_retained, backup, stale_marker, safe_root
                )
            marker = workspace_marker(destination)
            marker["selector"] = selector
            if (
                destination_baseline is not None
                and workspace_baseline_state(destination) == destination_baseline
                and workspace_matches_initial_checkpoint(destination, marker)
            ):
                update_workspace_tag_state(
                    destination, marker, tags, destination_baseline
                )
            else:
                atomic_json(destination / WORKSPACE_MARKER, marker)
            if retired is not None:
                finalize_retired_workspace(retired, safe_root)
            return destination
        else:
            stale_destination = destination

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
            "semanticTagTargets": tags,
            "stageHost": socket.gethostname(),
            "stagePid": os.getpid(),
            "state": "cloning",
            "version": version,
        }
        atomic_json(stage / WORKSPACE_MARKER, marker)
        clone_workspace(stage, refs, remote_root)
        marker.update(workspace_baseline_state(stage))
        fresh_refs, fresh_tags = remote_snapshot(remote_root)
        if fresh_refs != refs or fresh_tags != tags:
            raise WorkspaceError(
                "a component main or semantic tag moved while the workspace was cloned"
            )
        stale_workspaces: list[Path] = []
        for path in (stale_destination, stale_retained):
            if path is not None and path not in stale_workspaces:
                stale_workspaces.append(path)
        for stale in stale_workspaces:
            stale_marker = verify_workspace(stale, safe_root)
            ensure_workspace_is_idle(stale_marker)
            if not workspace_matches_initial_checkpoint(stale, stale_marker):
                raise WorkspaceError(
                    f"release workspace changed while its replacement was cloned: {stale}"
                )
        marker["state"] = "ready"
        marker.pop("stageHost")
        marker.pop("stagePid")
        atomic_json(stage / WORKSPACE_MARKER, marker)
        replacement = {
            "destination": destination.name,
            "mainRefs": refs,
            "selector": selector,
            "semanticTagTargets": tags,
            "stage": stage.name,
            "version": version,
        }
        for stale in stale_workspaces:
            stale_marker = workspace_marker(stale)
            stale_replacement = replacement.copy()
            stale_replacement["source"] = stale.name
            stale_marker["replacement"] = stale_replacement
            atomic_json(stale / WORKSPACE_MARKER, stale_marker)
        retired_workspaces: list[Path] = []
        try:
            for stale in stale_workspaces:
                backup_path = retired_workspace_path(safe_root, stale.name)
                stale_marker = workspace_marker(stale)
                retired_workspaces.append(
                    retire_workspace(
                        stale,
                        backup_path,
                        stale_marker,
                        safe_root,
                    )
                )
            os.replace(stage, destination)
            fsync_directory(safe_root)
        except BaseException:
            recover_interrupted_replacements(safe_root)
            raise
        for retired in retired_workspaces:
            finalize_retired_workspace(retired, safe_root)
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
