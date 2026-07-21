#!/usr/bin/env bash
#===----------------------------------------------------------------------===#
# Copyright (c) 2026 container-compose project authors.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
# http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#===----------------------------------------------------------------------===#

#
# USAGE:
#   check-compose-image-volumes.sh [options]
#
# OPTIONS:
#   --strict    Fail when Docker Compose V2, Docker Engine, or container-compose is unavailable.
#   -h, --help  Show this help.
#
# ENVIRONMENT:
#   CONTAINER_COMPOSE  Path to the container-compose binary. Defaults to the
#                      local SwiftPM debug build at .build/debug/compose.
#   CONTAINER_COMPOSE_CONTAINER
#                      Runtime CLI used for live macOS validation. Defaults to
#                      container from PATH.
#   CONTAINER_COMPOSE_LIVE
#                      Set to 1 when an isolated matching Apple runtime is
#                      running. The check then verifies seeded data and a
#                      retained marker through down/up reuse.
#   DOCKER_COMPOSE     Docker Compose command to compare with. Defaults to
#                      "docker compose" when available, otherwise docker-compose.
#
# This local parity check verifies Docker Compose V2's image-declared `VOLUME`
# behavior: implicit anonymous volumes, explicit-volume copy-up, a pre-created
# volume subpath, and seeded image data. It also verifies container-compose
# preserves the same Compose file mount projection and, on an isolated macOS
# runtime, the same first-use copy-up, `volume.nocopy`, subpath, and
# retained-volume behavior across down/up.

set -euo pipefail

SELF_PATH="${BASH_SOURCE[0]:-$0}"
readonly SELF_PATH
SCRIPT_NAME="$(basename "$SELF_PATH")"
readonly SCRIPT_NAME
REPO_ROOT="$(cd "$(dirname "$SELF_PATH")/../.." && pwd)"
readonly REPO_ROOT
readonly FIXTURE_DIR="$REPO_ROOT/Tools/parity/fixtures/image-volumes"
readonly COMPOSE_FILE="$FIXTURE_DIR/compose.yaml"

STRICT=0
CONTAINER_COMPOSE="${CONTAINER_COMPOSE:-$REPO_ROOT/.build/debug/compose}"
CONTAINER_BINARY="${CONTAINER_COMPOSE_CONTAINER:-container}"
CONTAINER_COMPOSE_LIVE="${CONTAINER_COMPOSE_LIVE:-0}"
DOCKER_COMPOSE_COMMAND=()
PROJECT_NAME="container-compose-image-volumes-$RANDOM-$$"
WORK_DIR=""
CONTAINER_PROJECT_STARTED=0

# Print an informational line to stdout.
info() {
    printf '%s\n' "$*"
}

# Print a warning to stderr.
warning() {
    printf 'warning: %s\n' "$*" >&2
}

# Print an error to stderr.
error() {
    printf 'error: %s\n' "$*" >&2
}

# Show usage extracted from this script's header.
usage() {
    sed -n '/^# USAGE:/,/^# This local parity/ { /^# This local parity/d; s/^# //; s/^#//; p; }' "$SELF_PATH" \
        | sed "s/check-compose-image-volumes.sh/$SCRIPT_NAME/"
}

# Parse command-line options.
parse_args() {
    while (($# > 0)); do
        case "$1" in
            --strict)
                STRICT=1
                shift
                ;;
            -h | --help)
                usage
                exit 0
                ;;
            *)
                error "unknown argument: $1"
                usage >&2
                return 2
                ;;
        esac
    done
}

# Skip optional local parity validation, or fail in strict mode.
skip_or_fail() {
    local message="$1"

    if ((STRICT == 1)); then
        error "$message"
        return 1
    fi

    warning "$message; skipping image-declared volume parity check"
    exit 0
}

# Locate Docker Compose V2 in plugin or standalone form.
detect_docker_compose() {
    if [[ -n "${DOCKER_COMPOSE:-}" ]]; then
        IFS=' ' read -r -a DOCKER_COMPOSE_COMMAND <<<"$DOCKER_COMPOSE"
        "${DOCKER_COMPOSE_COMMAND[@]}" version >/dev/null 2>&1 \
            || skip_or_fail "Docker Compose V2 command is unavailable: $DOCKER_COMPOSE"
        return
    fi
    if docker compose version >/dev/null 2>&1; then
        DOCKER_COMPOSE_COMMAND=(docker compose)
        return
    fi
    if command -v docker-compose >/dev/null 2>&1 && docker-compose version >/dev/null 2>&1; then
        DOCKER_COMPOSE_COMMAND=(docker-compose)
        return
    fi
    skip_or_fail 'Docker Compose V2 is not available'
}

# Ensure all local parity dependencies and the checked-in fixture are present.
check_tools() {
    command -v python3 >/dev/null 2>&1 || skip_or_fail 'python3 is not available'
    command -v docker >/dev/null 2>&1 || skip_or_fail 'docker is not available'
    docker info >/dev/null 2>&1 || skip_or_fail 'Docker Engine is not available'
    [[ -x "$CONTAINER_COMPOSE" ]] || skip_or_fail "container-compose binary is not executable: $CONTAINER_COMPOSE"
    [[ -f "$COMPOSE_FILE" ]] || { error "missing image volume fixture: $COMPOSE_FILE"; return 1; }
    [[ -f "$FIXTURE_DIR/Dockerfile" ]] || { error "missing image volume Dockerfile: $FIXTURE_DIR/Dockerfile"; return 1; }
}

# Create a unique temporary directory for command output and inspection data.
prepare_work_dir() {
    WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/container-compose-image-volumes.XXXXXX")"
}

# Remove only this slice's project-scoped resources and temporary files.
cleanup() {
    "${DOCKER_COMPOSE_COMMAND[@]}" \
        --project-directory "$FIXTURE_DIR" \
        --project-name "$PROJECT_NAME" \
        --file "$COMPOSE_FILE" \
        down --volumes --remove-orphans >/dev/null 2>&1 || true
    if ((CONTAINER_PROJECT_STARTED == 1)); then
        "$CONTAINER_COMPOSE" \
            --ansi never \
            --project-directory "$FIXTURE_DIR" \
            --project-name "$PROJECT_NAME" \
            --file "$COMPOSE_FILE" \
            down --volumes --remove-orphans >/dev/null 2>&1 || true
    fi
    if [[ -n "$WORK_DIR" ]]; then
        rm -rf "$WORK_DIR"
    fi
}

# Assert both Compose implementations preserve the explicit service mount.
assert_compose_projection() {
    local implementation="$1"
    local config_file="$2"

    python3 - "$implementation" "$config_file" <<'PY'
import json
import pathlib
import sys

implementation, config_file = sys.argv[1:3]
model = json.loads(pathlib.Path(config_file).read_text(encoding="utf-8"))
services = model.get("services", {})
implicit = services.get("implicit", {})
overridden = services.get("overridden", {})
nocopy = services.get("nocopy", {})
subpath = services.get("subpath", {})
mounts = overridden.get("volumes", [])
nocopy_mounts = nocopy.get("volumes", [])
subpath_mounts = subpath.get("volumes", [])

if implicit.get("volumes"):
    raise SystemExit(f"{implementation}: implicit service unexpectedly has Compose mounts: {implicit['volumes']!r}")
if not any(
    mount.get("type") == "volume"
    and mount.get("source") == "override-data"
    and mount.get("target") == "/image-data"
    for mount in mounts
):
    raise SystemExit(f"{implementation}: missing override-data volume at /image-data: {mounts!r}")
if "override-data" not in model.get("volumes", {}):
    raise SystemExit(f"{implementation}: missing top-level override-data volume")
if not any(
    mount.get("type") == "volume"
    and mount.get("source") == "nocopy-data"
    and mount.get("target") == "/image-data"
    for mount in nocopy_mounts
):
    raise SystemExit(f"{implementation}: missing nocopy-data volume at /image-data: {nocopy_mounts!r}")
if "nocopy-data" not in model.get("volumes", {}):
    raise SystemExit(f"{implementation}: missing top-level nocopy-data volume")
if not any(
    mount.get("type") == "volume"
    and mount.get("source") == "subpath-data"
    and mount.get("target") == "/image-data"
    and mount.get("volume", {}).get("subpath", mount.get("volumeSubpath")) == "nested"
    for mount in subpath_mounts
):
    raise SystemExit(f"{implementation}: missing subpath-data volume at /image-data: {subpath_mounts!r}")
if "subpath-data" not in model.get("volumes", {}):
    raise SystemExit(f"{implementation}: missing top-level subpath-data volume")
PY
}

# Compare Docker Compose V2's normalized Compose model with the fixture.
expect_docker_config() {
    local config_file="$WORK_DIR/docker-compose-config.json"

    "${DOCKER_COMPOSE_COMMAND[@]}" \
        --project-directory "$FIXTURE_DIR" \
        --project-name "$PROJECT_NAME" \
        --file "$COMPOSE_FILE" \
        config --format json >"$config_file"
    assert_compose_projection 'Docker Compose V2' "$config_file"
}

# Compare container-compose's normalized Compose model with the fixture.
expect_container_config() {
    local config_file="$WORK_DIR/container-compose-config.json"

    "$CONTAINER_COMPOSE" \
        --ansi never \
        --project-directory "$FIXTURE_DIR" \
        --project-name "$PROJECT_NAME" \
        --file "$COMPOSE_FILE" \
        config --format json >"$config_file"
    assert_compose_projection 'container-compose' "$config_file"
}

# Assert Docker copied image data into the volumes and chose the expected identities.
assert_docker_runtime_behavior() {
    local implicit_container="$PROJECT_NAME-implicit-1"
    local overridden_container="$PROJECT_NAME-overridden-1"
    local nocopy_container="$PROJECT_NAME-nocopy-1"
    local subpath_container="$PROJECT_NAME-subpath-1"
    local inspection="$WORK_DIR/docker-inspect.json"

    docker exec "$implicit_container" sh -ec \
        "test \"\$(cat /image-data/seed.txt)\" = image-data-seed && test \"\$(cat /image-cache/seed.txt)\" = image-cache-seed"
    docker exec "$overridden_container" sh -ec \
        "test \"\$(cat /image-data/seed.txt)\" = image-data-seed && test \"\$(cat /image-cache/seed.txt)\" = image-cache-seed"
    docker exec "$nocopy_container" sh -ec \
        "test ! -e /image-data/seed.txt && test \"\$(cat /image-cache/seed.txt)\" = image-cache-seed"
    docker exec "$subpath_container" sh -ec \
        "test ! -e /image-data/seed.txt && test \"\$(cat /image-cache/seed.txt)\" = image-cache-seed"
    docker inspect "$implicit_container" "$overridden_container" "$nocopy_container" "$subpath_container" >"$inspection"

    python3 - "$inspection" "$PROJECT_NAME" <<'PY'
import json
import pathlib
import sys

path, project = sys.argv[1:3]
containers = {entry["Name"].lstrip("/"): entry for entry in json.loads(pathlib.Path(path).read_text(encoding="utf-8"))}
implicit = containers[f"{project}-implicit-1"]
overridden = containers[f"{project}-overridden-1"]
nocopy = containers[f"{project}-nocopy-1"]
subpath = containers[f"{project}-subpath-1"]

def volume_mount(container, destination):
    mounts = [
        mount
        for mount in container.get("Mounts", [])
        if mount.get("Destination") == destination and mount.get("Type") == "volume"
    ]
    if len(mounts) != 1:
        raise SystemExit(f"{container['Name']}: expected one volume mount at {destination}: {mounts!r}")
    return mounts[0]

implicit_data = volume_mount(implicit, "/image-data")
implicit_cache = volume_mount(implicit, "/image-cache")
overridden_data = volume_mount(overridden, "/image-data")
overridden_cache = volume_mount(overridden, "/image-cache")
nocopy_data = volume_mount(nocopy, "/image-data")
nocopy_cache = volume_mount(nocopy, "/image-cache")
subpath_data = volume_mount(subpath, "/image-data")
subpath_cache = volume_mount(subpath, "/image-cache")
expected_named = f"{project}_override-data"
expected_nocopy = f"{project}_nocopy-data"
expected_subpath = f"{project}_subpath-data"

if not implicit_data.get("Name") or not implicit_cache.get("Name"):
    raise SystemExit("Docker Compose did not create anonymous image volume names")
if implicit_data["Name"] == implicit_cache["Name"]:
    raise SystemExit("Docker Compose reused one anonymous volume for two image VOLUME targets")
if overridden_data.get("Name") != expected_named:
    raise SystemExit(f"Docker Compose override volume = {overridden_data.get('Name')!r}, expected {expected_named!r}")
if not overridden_cache.get("Name") or overridden_cache["Name"] == expected_named:
    raise SystemExit(f"Docker Compose image-cache mount = {overridden_cache.get('Name')!r}")
if nocopy_data.get("Name") != expected_nocopy:
    raise SystemExit(f"Docker Compose nocopy volume = {nocopy_data.get('Name')!r}, expected {expected_nocopy!r}")
if not nocopy_cache.get("Name") or nocopy_cache["Name"] == expected_nocopy:
    raise SystemExit(f"Docker Compose nocopy image-cache mount = {nocopy_cache.get('Name')!r}")
if subpath_data.get("Name") != expected_subpath:
    raise SystemExit(f"Docker Compose subpath volume = {subpath_data.get('Name')!r}, expected {expected_subpath!r}")
if not subpath_cache.get("Name") or subpath_cache["Name"] == expected_subpath:
    raise SystemExit(f"Docker Compose subpath image-cache mount = {subpath_cache.get('Name')!r}")
PY
}

# Build and start the Docker Compose V2 reference fixture before inspecting it.
expect_docker_runtime_behavior() {
    "${DOCKER_COMPOSE_COMMAND[@]}" \
        --project-directory "$FIXTURE_DIR" \
        --project-name "$PROJECT_NAME" \
        --file "$COMPOSE_FILE" \
        up --build --detach --quiet-pull
    assert_docker_runtime_behavior
}

# Assert that the Apple runtime sees Docker-compatible seeded image data.
assert_apple_runtime_seeded() {
    local implicit_container="$PROJECT_NAME-implicit-1"
    local overridden_container="$PROJECT_NAME-overridden-1"
    local nocopy_container="$PROJECT_NAME-nocopy-1"
    local subpath_container="$PROJECT_NAME-subpath-1"

    "$CONTAINER_BINARY" exec "$implicit_container" sh -ec \
        "test \"\$(cat /image-data/seed.txt)\" = image-data-seed && test \"\$(cat /image-cache/seed.txt)\" = image-cache-seed"
    "$CONTAINER_BINARY" exec "$overridden_container" sh -ec \
        "test \"\$(cat /image-data/seed.txt)\" = image-data-seed && test \"\$(cat /image-cache/seed.txt)\" = image-cache-seed"
    "$CONTAINER_BINARY" exec "$nocopy_container" sh -ec \
        "test ! -e /image-data/seed.txt && test \"\$(cat /image-cache/seed.txt)\" = image-cache-seed"
    "$CONTAINER_BINARY" exec "$subpath_container" sh -ec \
        "test ! -e /image-data/seed.txt && test \"\$(cat /image-cache/seed.txt)\" = image-cache-seed"
}

# Prove a retained volume is neither recreated nor seeded again after down/up.
assert_apple_runtime_volume_reuse() {
    local implicit_container="$PROJECT_NAME-implicit-1"

    "$CONTAINER_BINARY" exec "$implicit_container" sh -ec \
        'printf retained-through-down-up > /image-data/retained.txt'
    "$CONTAINER_COMPOSE" \
        --ansi never \
        --project-directory "$FIXTURE_DIR" \
        --project-name "$PROJECT_NAME" \
        --file "$COMPOSE_FILE" \
        down
    CONTAINER_PROJECT_STARTED=0
    CONTAINER_PROJECT_STARTED=1
    "$CONTAINER_COMPOSE" \
        --ansi never \
        --project-directory "$FIXTURE_DIR" \
        --project-name "$PROJECT_NAME" \
        --file "$COMPOSE_FILE" \
        up --detach
    assert_apple_runtime_seeded
    "$CONTAINER_BINARY" exec "$implicit_container" sh -ec \
        "test \"\$(cat /image-data/retained.txt)\" = retained-through-down-up"
}

# Run the image-volume behavior against the isolated matching Apple runtime.
expect_apple_runtime_behavior() {
    if [[ "$CONTAINER_COMPOSE_LIVE" != "1" ]]; then
        info 'live Apple runtime validation not requested; Docker Compose V2 reference and model parity passed'
        return
    fi
    if [[ ! -x "$CONTAINER_BINARY" ]] && ! command -v "$CONTAINER_BINARY" >/dev/null 2>&1; then
        skip_or_fail "container runtime binary is not executable: $CONTAINER_BINARY"
    fi
    "$CONTAINER_BINARY" system status >/dev/null 2>&1 \
        || skip_or_fail 'Apple container runtime is not running'

    CONTAINER_PROJECT_STARTED=1
    "$CONTAINER_COMPOSE" \
        --ansi never \
        --project-directory "$FIXTURE_DIR" \
        --project-name "$PROJECT_NAME" \
        --file "$COMPOSE_FILE" \
        up --build --detach --quiet-pull
    assert_apple_runtime_seeded
    assert_apple_runtime_volume_reuse
    "$CONTAINER_COMPOSE" \
        --ansi never \
        --project-directory "$FIXTURE_DIR" \
        --project-name "$PROJECT_NAME" \
        --file "$COMPOSE_FILE" \
        down --volumes --remove-orphans
    CONTAINER_PROJECT_STARTED=0
}

# Run Docker Compose V2 reference, Compose-model, and optional macOS runtime checks.
main() {
    parse_args "$@"
    detect_docker_compose
    check_tools
    prepare_work_dir
    trap cleanup EXIT

    expect_docker_config
    expect_container_config
    expect_docker_runtime_behavior
    expect_apple_runtime_behavior

    info 'Docker Compose V2 image-volume parity passed.'
}

main "$@"
