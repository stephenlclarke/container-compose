#!/usr/bin/env bash
#===----------------------------------------------------------------------===#
# Copyright © 2026 container-compose project authors.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
# https://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#===----------------------------------------------------------------------===#

#
# USAGE:
#   check-compose-network-attachable.sh [options]
#
# OPTIONS:
#   --strict    Fail when Docker Compose V2 or container-compose is unavailable.
#   -h, --help  Show this help.
#
# ENVIRONMENT:
#   CONTAINER_COMPOSE       Path to container-compose. Defaults to the local
#                           SwiftPM debug build.
#   CONTAINER_COMPOSE_CONTAINER
#                           Runtime CLI used for live standalone-attachment
#                           validation. Defaults to container from PATH.
#   CONTAINER_COMPOSE_LIVE  Set to 1 when an isolated Apple runtime is running.
#   DOCKER_COMPOSE          Docker Compose command to compare with.
#
# This local-only check confirms Docker Compose V2 retains `attachable: true`,
# verifies the same normalized Compose field in both `config` and `convert`,
# verifies the no-side-effect lifecycle path,
# and, when a runtime is supplied, proves a standalone macOS container can join
# the created vmnet network. Docker's meaningful attachable restriction applies
# to Swarm overlay networks; Apple vmnet supplies only local networks and
# already allows standalone attachment.

set -euo pipefail

readonly SELF_PATH="${BASH_SOURCE[0]:-$0}"
SCRIPT_NAME="$(basename "$SELF_PATH")"
readonly SCRIPT_NAME
REPO_ROOT="$(cd "$(dirname "$SELF_PATH")/../.." && pwd)"
readonly REPO_ROOT

STRICT=0
CONTAINER_COMPOSE="${CONTAINER_COMPOSE:-$REPO_ROOT/.build/debug/compose}"
CONTAINER_BINARY="${CONTAINER_COMPOSE_CONTAINER:-container}"
CONTAINER_COMPOSE_LIVE="${CONTAINER_COMPOSE_LIVE:-0}"
DOCKER_COMPOSE_COMMAND=()
FIXTURE_DIR=""
COMPOSE_FILE=""
PROJECT_NAME="container-compose-network-attachable-$RANDOM-$$"
PROJECT_STARTED=0

# Print an informational line to stdout.
info() {
    printf '%s\n' "$*"
}

# Print a warning message to stderr.
warning() {
    printf 'warning: %s\n' "$*" >&2
}

# Print an error message to stderr.
error() {
    printf 'error: %s\n' "$*" >&2
}

# Print usage text extracted from this script's header.
usage() {
    sed -n '/^# USAGE:/,/^# This local-only check/ { /^# This local-only check/d; s/^# //; s/^#//; p; }' "$SELF_PATH" | sed "s/check-compose-network-attachable.sh/$SCRIPT_NAME/"
}

# Parse command-line flags.
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

# Exit cleanly for optional local dependencies, or fail in strict mode.
skip_or_fail() {
    local message="$1"

    if ((STRICT == 1)); then
        error "$message"
        return 1
    fi

    warning "$message; skipping Docker/container-compose attachable parity check"
    exit 0
}

# Locate Docker Compose V2, accepting either plugin or standalone command form.
detect_docker_compose() {
    if [[ -n "${DOCKER_COMPOSE:-}" ]]; then
        IFS=' ' read -r -a DOCKER_COMPOSE_COMMAND <<<"$DOCKER_COMPOSE"
    elif docker compose --help 2>&1 | grep -q 'Usage:.*docker compose' && docker compose version >/dev/null 2>&1; then
        DOCKER_COMPOSE_COMMAND=(docker compose)
    elif command -v docker-compose >/dev/null 2>&1 && docker-compose version >/dev/null 2>&1; then
        DOCKER_COMPOSE_COMMAND=(docker-compose)
    else
        skip_or_fail 'Docker Compose V2 is not available'
    fi
}

# Ensure the comparison and local Compose binary are available.
check_tools() {
    detect_docker_compose

    if ! command -v python3 >/dev/null 2>&1; then
        skip_or_fail 'python3 is not available'
    fi

    if [[ ! -x "$CONTAINER_COMPOSE" ]]; then
        skip_or_fail "container-compose binary is not executable: $CONTAINER_COMPOSE"
    fi
}

# Create an isolated Compose fixture.
create_fixture() {
    FIXTURE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/compose-network-attachable.XXXXXX")"
    COMPOSE_FILE="$FIXTURE_DIR/compose.yml"

    cat >"$COMPOSE_FILE" <<'YAML'
services:
  api:
    image: alpine:3.20
    command: ["sleep", "infinity"]
    networks:
      - backend
networks:
  backend:
    attachable: true
YAML
}

# Stop the project and remove the exact temporary fixture.
cleanup() {
    if ((PROJECT_STARTED == 1)); then
        "$CONTAINER_COMPOSE" --ansi never -p "$PROJECT_NAME" -f "$COMPOSE_FILE" down --remove-orphans >/dev/null 2>&1 || true
    fi
    if [[ -n "$FIXTURE_DIR" ]]; then
        rm -rf "$FIXTURE_DIR"
    fi
}

# Assert Docker Compose V2 exposes the requested metadata.
assert_docker_attachable() {
    local file_name="$1"

    python3 - "$file_name" <<'PY'
import json
import pathlib
import sys

network = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8")).get("networks", {}).get("backend", {})
if network.get("attachable") is not True:
    raise SystemExit(f"Docker Compose networks.backend.attachable = {network.get('attachable')!r}, want True")
PY
}

# Assert container-compose retains the field without an unsupported marker.
assert_container_attachable() {
    local file_name="$1"

    python3 - "$file_name" <<'PY'
import json
import pathlib
import sys

network = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8")).get("networks", {}).get("backend", {})
if network.get("attachable") is not True:
    raise SystemExit(f"container-compose networks.backend.attachable = {network.get('attachable')!r}, want True")
if network.get("unsupportedFields") is not None:
    raise SystemExit(f"container-compose networks.backend.unsupportedFields = {network.get('unsupportedFields')!r}, want absent")
PY
}

# Compare Docker Compose V2's normalized configuration.
validate_docker_configuration() {
    local output_file="$FIXTURE_DIR/docker-compose-config.json"

    "${DOCKER_COMPOSE_COMMAND[@]}" -p "$PROJECT_NAME" -f "$COMPOSE_FILE" config --format json >"$output_file"
    assert_docker_attachable "$output_file"
}

# Validate container-compose normalization and lifecycle planning without side effects.
validate_container_compose_configuration() {
    local config_file="$FIXTURE_DIR/container-compose-config.json"
    local convert_file="$FIXTURE_DIR/container-compose-convert.json"

    "$CONTAINER_COMPOSE" --ansi never -p "$PROJECT_NAME" -f "$COMPOSE_FILE" config --format json >"$config_file"
    assert_container_attachable "$config_file"
    "$CONTAINER_COMPOSE" --ansi never -p "$PROJECT_NAME" -f "$COMPOSE_FILE" convert --format json >"$convert_file"
    assert_container_attachable "$convert_file"
    "$CONTAINER_COMPOSE" --ansi never --dry-run -p "$PROJECT_NAME" -f "$COMPOSE_FILE" up api >/dev/null
}

# Prove the macOS local network accepts a standalone attachment when requested.
validate_live_apple_runtime() {
    if [[ "$CONTAINER_COMPOSE_LIVE" != "1" ]]; then
        info 'live Apple runtime validation not requested; configuration and dry-run parity passed'
        return
    fi
    if [[ ! -x "$CONTAINER_BINARY" ]] && ! command -v "$CONTAINER_BINARY" >/dev/null 2>&1; then
        skip_or_fail "container runtime binary is not executable: $CONTAINER_BINARY"
    fi

    "$CONTAINER_COMPOSE" --ansi never -p "$PROJECT_NAME" -f "$COMPOSE_FILE" up -d api
    PROJECT_STARTED=1
    "$CONTAINER_BINARY" run --rm --network "${PROJECT_NAME}_backend" alpine:3.20 true
}

# Run the local-only Docker Compose V2 and macOS runtime comparison.
main() {
    parse_args "$@"
    check_tools
    create_fixture
    trap cleanup EXIT

    validate_docker_configuration
    validate_container_compose_configuration
    validate_live_apple_runtime

    info "attachable network parity check passed using ${DOCKER_COMPOSE_COMMAND[*]} and $CONTAINER_COMPOSE"
}

main "$@"
