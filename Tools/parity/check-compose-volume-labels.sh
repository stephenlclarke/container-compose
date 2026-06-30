#!/usr/bin/env bash
#===----------------------------------------------------------------------===#
# Copyright (c) 2026 container-compose project authors.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#   https://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#===----------------------------------------------------------------------===#

#
# USAGE:
#   check-compose-volume-labels.sh [options]
#
# OPTIONS:
#   --strict    Fail when Docker Compose V2, Docker Engine, or container-compose is unavailable.
#   -h, --help  Show this help.
#
# ENVIRONMENT:
#   CONTAINER_COMPOSE  Path to the container-compose binary. Defaults to the
#                      local SwiftPM debug build at .build/debug/compose.
#   DOCKER_COMPOSE     Docker Compose command to compare with. Defaults to
#                      "docker compose" when available, otherwise docker-compose.
#
# This script is intentionally local-only and is not part of CI. It verifies
# Docker Compose V2 preserves service long-form `volume.labels`, applies those
# labels to anonymous runtime volumes, and does not apply named service mount
# labels to the named volume resource. It then verifies container-compose
# preserves the same config metadata and projects labeled anonymous volume
# creation into the Apple runtime command stream.

set -euo pipefail

readonly SELF_PATH="${BASH_SOURCE[0]:-$0}"
SCRIPT_NAME="$(basename "$SELF_PATH")"
readonly SCRIPT_NAME
REPO_ROOT="$(cd "$(dirname "$SELF_PATH")/../.." && pwd)"
readonly REPO_ROOT

STRICT=0
CONTAINER_COMPOSE="${CONTAINER_COMPOSE:-$REPO_ROOT/.build/debug/compose}"
DOCKER_COMPOSE_COMMAND=()
FIXTURE_DIR=""
PROJECT_NAME="cc-volume-labels-$RANDOM"

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

# Show usage extracted from the top-of-file help block.
usage() {
    sed -n '/^# USAGE:/,/^# This script/ { /^# This script/d; s/^# //; s/^#//; p; }' "$SELF_PATH" | sed "s/check-compose-volume-labels.sh/$SCRIPT_NAME/"
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

# Skip optional parity checks, or fail when strict mode is active.
skip_or_fail() {
    local message="$1"

    if ((STRICT == 1)); then
        error "$message"
        return 1
    fi

    warning "$message; skipping Docker Compose volume labels parity check"
    exit 0
}

# Resolve the Docker Compose command used as the parity oracle.
detect_docker_compose() {
    if [[ -n "${DOCKER_COMPOSE:-}" ]]; then
        IFS=' ' read -r -a DOCKER_COMPOSE_COMMAND <<<"$DOCKER_COMPOSE"
    elif docker compose version >/dev/null 2>&1; then
        DOCKER_COMPOSE_COMMAND=(docker compose)
    elif command -v docker-compose >/dev/null 2>&1 && docker-compose version >/dev/null 2>&1; then
        DOCKER_COMPOSE_COMMAND=(docker-compose)
    else
        skip_or_fail 'Docker Compose V2 is not available'
    fi
}

# Ensure required local tools are available.
check_tools() {
    if ! command -v python3 >/dev/null 2>&1; then
        skip_or_fail 'python3 is not available'
    fi
    if ! command -v docker >/dev/null 2>&1; then
        skip_or_fail 'docker is not available'
    fi
    if ! docker info >/dev/null 2>&1; then
        skip_or_fail 'Docker Engine is not available'
    fi
    if [[ ! -x "$CONTAINER_COMPOSE" ]]; then
        skip_or_fail "container-compose binary is not executable: $CONTAINER_COMPOSE"
    fi
}

# Create a Compose fixture with named and anonymous long-form volume labels.
create_fixture() {
    FIXTURE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/compose-volume-labels.XXXXXX")"
    cat >"$FIXTURE_DIR/compose.yml" <<'YAML'
services:
  named:
    image: alpine:3.20
    command: ["true"]
    volumes:
      - type: volume
        source: cache
        target: /cache
        volume:
          labels:
            com.example.mount: named-service
  anon:
    image: alpine:3.20
    command: ["true"]
    volumes:
      - type: volume
        target: /scratch
        volume:
          labels:
            com.example.mount: anonymous-service
volumes:
  cache:
    labels:
      com.example.volume: named-project
YAML
}

# Remove temporary fixture files and Docker Compose resources.
cleanup() {
    if [[ -n "$FIXTURE_DIR" ]]; then
        "${DOCKER_COMPOSE_COMMAND[@]}" \
            --project-directory "$FIXTURE_DIR" \
            -p "$PROJECT_NAME" \
            -f "$FIXTURE_DIR/compose.yml" \
            down -v --remove-orphans >/dev/null 2>&1 || true
        rm -rf "$FIXTURE_DIR"
    fi
}

# Assert Docker Compose config preserves service and top-level volume labels.
assert_docker_config_preserves_volume_labels() {
    local path="$1"

    python3 - "$path" <<'PY'
import json
import pathlib
import sys

doc = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
services = doc.get("services", {})
named = services.get("named", {}).get("volumes", [{}])[0].get("volume", {}).get("labels", {})
anon = services.get("anon", {}).get("volumes", [{}])[0].get("volume", {}).get("labels", {})
volume = doc.get("volumes", {}).get("cache", {}).get("labels", {})
if named.get("com.example.mount") != "named-service":
    raise SystemExit(f"Docker Compose named mount labels = {named!r}")
if anon.get("com.example.mount") != "anonymous-service":
    raise SystemExit(f"Docker Compose anonymous mount labels = {anon!r}")
if volume.get("com.example.volume") != "named-project":
    raise SystemExit(f"Docker Compose top-level volume labels = {volume!r}")
PY
}

# Assert container-compose config preserves service and top-level volume labels.
assert_container_config_preserves_volume_labels() {
    local path="$1"

    python3 - "$path" <<'PY'
import json
import pathlib
import sys

doc = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
services = doc.get("services", {})

def service_mount_label(service_name):
    mount = services.get(service_name, {}).get("volumes", [{}])[0]
    raw = (mount.get("volume") or {}).get("labels") or {}
    normalized = mount.get("volumeLabels") or {}
    return raw.get("com.example.mount") or normalized.get("com.example.mount")

named = service_mount_label("named")
anon = service_mount_label("anon")
volume = doc.get("volumes", {}).get("cache", {}).get("labels", {})
if named != "named-service":
    raise SystemExit(f"container-compose named mount label = {named!r}")
if anon != "anonymous-service":
    raise SystemExit(f"container-compose anonymous mount label = {anon!r}")
if volume.get("com.example.volume") != "named-project":
    raise SystemExit(f"container-compose top-level volume labels = {volume!r}")
PY
}

# Assert Docker Compose applies anonymous mount labels to the anonymous volume
# and keeps named service mount labels off the named volume resource.
assert_docker_runtime_labels() {
    local named_volume="${PROJECT_NAME}_cache"
    local anonymous_volume
    local inspect_output="$FIXTURE_DIR/docker-volume-inspect.json"

    anonymous_volume="$(docker inspect "$PROJECT_NAME-anon-1" |
        python3 -c 'import json, sys; doc=json.load(sys.stdin); print(next(m["Name"] for m in doc[0]["Mounts"] if m["Destination"] == "/scratch"))')"

    docker volume inspect "$named_volume" "$anonymous_volume" >"$inspect_output"
    python3 - "$inspect_output" "$named_volume" "$anonymous_volume" <<'PY'
import json
import sys

path, named_volume, anonymous_volume = sys.argv[1:4]
with open(path, encoding="utf-8") as handle:
    volumes = {entry["Name"]: (entry.get("Labels") or {}) for entry in json.load(handle)}
named = volumes[named_volume]
anonymous = volumes[anonymous_volume]
if named.get("com.example.volume") != "named-project":
    raise SystemExit(f"Docker named volume labels = {named!r}")
if "com.example.mount" in named:
    raise SystemExit(f"Docker applied named service mount labels to named volume: {named!r}")
if anonymous.get("com.example.mount") != "anonymous-service":
    raise SystemExit(f"Docker anonymous volume labels = {anonymous!r}")
PY
}

# Exercise Docker Compose as the local-mode parity baseline.
expect_docker_behavior() {
    local config_output="$FIXTURE_DIR/docker-compose-config.json"
    local up_output="$FIXTURE_DIR/docker-compose-up.txt"

    "${DOCKER_COMPOSE_COMMAND[@]}" \
        --project-directory "$FIXTURE_DIR" \
        -f "$FIXTURE_DIR/compose.yml" \
        config --format json >"$config_output"
    assert_docker_config_preserves_volume_labels "$config_output"

    "${DOCKER_COMPOSE_COMMAND[@]}" \
        --project-directory "$FIXTURE_DIR" \
        -p "$PROJECT_NAME" \
        -f "$FIXTURE_DIR/compose.yml" \
        up --no-start --quiet-pull >"$up_output" 2>&1
    if ! grep -F "Container $PROJECT_NAME-anon-1 Created" "$up_output" >/dev/null; then
        error 'Docker Compose did not create the anonymous-volume service container'
        sed -n '1,120p' "$up_output" >&2
        return 1
    fi
    assert_docker_runtime_labels
}

# Exercise container-compose against the same fixture.
expect_container_behavior() {
    local config_output="$FIXTURE_DIR/container-compose-config.json"
    local up_output="$FIXTURE_DIR/container-compose-up.txt"

    "$CONTAINER_COMPOSE" \
        --ansi never \
        --project-directory "$FIXTURE_DIR" \
        -p "$PROJECT_NAME" \
        -f "$FIXTURE_DIR/compose.yml" \
        config --format json >"$config_output"
    assert_container_config_preserves_volume_labels "$config_output"

    "$CONTAINER_COMPOSE" \
        --ansi never \
        --dry-run \
        --project-directory "$FIXTURE_DIR" \
        -p "$PROJECT_NAME" \
        -f "$FIXTURE_DIR/compose.yml" \
        up --no-start >"$up_output" 2>&1
    if ! grep -F 'container volume create' "$up_output" >/dev/null ||
        ! grep -F -- '--label com.example.mount=anonymous-service' "$up_output" >/dev/null; then
        error 'container-compose did not render labeled anonymous volume creation'
        sed -n '1,160p' "$up_output" >&2
        return 1
    fi
    if grep -F -- '--label com.example.mount=named-service' "$up_output" >/dev/null; then
        error 'container-compose applied named service mount labels to the named volume resource'
        sed -n '1,160p' "$up_output" >&2
        return 1
    fi
}

# Run the local-only Docker Compose V2 parity check.
main() {
    parse_args "$@"
    detect_docker_compose
    check_tools
    create_fixture
    trap cleanup EXIT

    expect_docker_behavior
    expect_container_behavior

    info 'Docker Compose volume labels parity passed.'
}

main "$@"
