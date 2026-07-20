#!/usr/bin/env bash
#===----------------------------------------------------------------------===#
# Copyright © 2026 container-compose project authors.
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
#   check-compose-network-ipam-options.sh [options]
#
# OPTIONS:
#   --strict    Fail when Docker Compose V2 or container-compose is unavailable.
#   -h, --help  Show this help.
#
# ENVIRONMENT:
#   CONTAINER_COMPOSE  Path to the container-compose binary. Defaults to the
#                      local SwiftPM debug build at .build/debug/compose.
#   DOCKER_COMPOSE     Docker Compose command to compare with. Defaults to a
#                      working "docker compose" plugin when available,
#                      otherwise docker-compose.
#
# This script is intentionally local-only and is not part of CI. It validates
# that Docker Compose V2 accepts and preserves top-level network `ipam.options`,
# then checks that container-compose keeps the same inspection metadata while
# using the ordinary local VMnet creation path.

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
COMPOSE_FILE=""
PROJECT_NAME="container-compose-network-ipam-options-$RANDOM-$$"

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

# Print usage text extracted from the top of this script.
usage() {
    sed -n '/^# USAGE:/,/^# This script/ { /^# This script/d; s/^# //; s/^#//; p; }' "$SELF_PATH" | sed "s/check-compose-network-ipam-options.sh/$SCRIPT_NAME/"
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

# Exit cleanly for optional local runtime dependencies, or fail in strict mode.
skip_or_fail() {
    local message="$1"

    if ((STRICT == 1)); then
        error "$message"
        return 1
    fi

    warning "$message; skipping Docker/container-compose project network metadata parity check"
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

# Ensure required local tools are available.
check_tools() {
    detect_docker_compose

    if ! command -v python3 >/dev/null 2>&1; then
        skip_or_fail 'python3 is not available'
    fi

    if [[ ! -x "$CONTAINER_COMPOSE" ]]; then
        skip_or_fail "container-compose binary is not executable: $CONTAINER_COMPOSE"
    fi
}

# Create a minimal Compose fixture with inspection-only IPAM metadata.
create_fixture() {
    FIXTURE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/compose-network-ipam-options.XXXXXX")"
    COMPOSE_FILE="$FIXTURE_DIR/compose.yml"

    cat >"$COMPOSE_FILE" <<'YAML'
services:
  api:
    image: alpine:3.20
    command: ["true"]
    networks:
      - backend
networks:
  backend:
    ipam:
      options:
        com.example.ipam: enabled
YAML
}

# Remove temporary fixture files.
cleanup() {
    if [[ -n "$FIXTURE_DIR" ]]; then
        rm -rf "$FIXTURE_DIR"
    fi
}

# Assert Docker Compose preserves IPAM options in config output.
assert_docker_config_ipam_options() {
    local path="$1"

    python3 - "$path" <<'PY'
import json
import pathlib
import sys

doc = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
network = doc.get("networks", {}).get("backend", {})
options = network.get("ipam", {}).get("options")
expected = {"com.example.ipam": "enabled"}
if options != expected:
    raise SystemExit(f"Docker Compose networks.backend.ipam.options = {options!r}, want {expected!r}")
PY
}

# Assert container-compose preserves IPAM options without reporting an unsupported field.
assert_container_config_ipam_options() {
    local path="$1"

    python3 - "$path" <<'PY'
import json
import pathlib
import sys

doc = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
network = doc.get("networks", {}).get("backend", {})
options = network.get("ipamOptions")
expected = {"com.example.ipam": "enabled"}
if options != expected:
    raise SystemExit(f"container-compose networks.backend.ipamOptions = {options!r}, want {expected!r}")
if "unsupportedFields" in network:
    raise SystemExit(f"container-compose networks.backend.unsupportedFields = {network['unsupportedFields']!r}, want absent")
PY
}

# Validate Docker Compose parses the field.
validate_docker_behavior() {
    local config_output="$FIXTURE_DIR/docker-compose-config.json"

    "${DOCKER_COMPOSE_COMMAND[@]}" -p "$PROJECT_NAME" -f "$COMPOSE_FILE" config --format json >"$config_output"
    assert_docker_config_ipam_options "$config_output"
}

# Validate container-compose preserves the field and uses the normal local path.
validate_container_compose_behavior() {
    local config_output="$FIXTURE_DIR/container-compose-config.json"
    local up_output

    "$CONTAINER_COMPOSE" --ansi never -p "$PROJECT_NAME" -f "$COMPOSE_FILE" config --format json >"$config_output"
    assert_container_config_ipam_options "$config_output"

    up_output="$("$CONTAINER_COMPOSE" --ansi never --dry-run -p "$PROJECT_NAME" -f "$COMPOSE_FILE" up api 2>&1)"
    printf '%s\n' "$up_output" | grep -F '+ container network create ' >/dev/null
    if printf '%s\n' "$up_output" | grep -F 'com.example.ipam=enabled' >/dev/null; then
        error 'container-compose forwarded inspection-only IPAM options to VMnet'
        return 1
    fi
}

# Run the local-only parity check.
main() {
    parse_args "$@"
    check_tools
    create_fixture
    trap cleanup EXIT

    validate_docker_behavior
    validate_container_compose_behavior

    info "IPAM option parity check passed using ${DOCKER_COMPOSE_COMMAND[*]} and $CONTAINER_COMPOSE"
}

main "$@"
