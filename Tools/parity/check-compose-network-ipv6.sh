#!/usr/bin/env bash
#===----------------------------------------------------------------------===#
# Copyright © 2026 container-compose project authors.
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
#   check-compose-network-ipv6.sh [options]
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
# This script is intentionally local-only and is not part of CI. It confirms
# Docker Compose V2 accepts automatic IPv6, an explicit IPv6 IPAM gateway, and
# IPv6 disablement. The disabled case retains declared IPv6 IPAM metadata in
# config, but Docker Engine ignores it while creating the network. Verify the
# Compose layer preserves that model, applies an enabled gateway, and renders
# the disabled Apple runtime request without the contradictory IPv6 settings.

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
ENABLED_COMPOSE_FILE=""
EXPLICIT_COMPOSE_FILE=""
DISABLED_COMPOSE_FILE=""
PROJECT_NAME="container-compose-network-ipv6-$RANDOM-$$"

info() {
    printf '%s\n' "$*"
}

warning() {
    printf 'warning: %s\n' "$*" >&2
}

error() {
    printf 'error: %s\n' "$*" >&2
}

usage() {
    sed -n '/^# USAGE:/,/^# This script/ { /^# This script/d; s/^# //; s/^#//; p; }' "$SELF_PATH" | sed "s/check-compose-network-ipv6.sh/$SCRIPT_NAME/"
}

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

skip_or_fail() {
    local message="$1"

    if ((STRICT == 1)); then
        error "$message"
        return 1
    fi

    warning "$message; skipping Docker/container-compose IPv6 network parity check"
    exit 0
}

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

check_tools() {
    detect_docker_compose

    if ! command -v python3 >/dev/null 2>&1; then
        skip_or_fail 'python3 is not available'
    fi

    if [[ ! -x "$CONTAINER_COMPOSE" ]]; then
        skip_or_fail "container-compose binary is not executable: $CONTAINER_COMPOSE"
    fi
}

create_fixtures() {
    FIXTURE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/compose-network-ipv6.XXXXXX")"
    ENABLED_COMPOSE_FILE="$FIXTURE_DIR/enabled.yml"
    EXPLICIT_COMPOSE_FILE="$FIXTURE_DIR/explicit.yml"
    DISABLED_COMPOSE_FILE="$FIXTURE_DIR/disabled.yml"

    cat >"$ENABLED_COMPOSE_FILE" <<'YAML'
services:
  api:
    image: alpine:3.20
    command: ["true"]
    networks:
      - backend
networks:
  backend:
    enable_ipv6: true
YAML

    cat >"$EXPLICIT_COMPOSE_FILE" <<'YAML'
services:
  api:
    image: alpine:3.20
    command: ["true"]
    networks:
      - backend
networks:
  backend:
    enable_ipv6: true
    ipam:
      config:
        - subnet: fd00:10::/64
          gateway: fd00:10::53
YAML

    cat >"$DISABLED_COMPOSE_FILE" <<'YAML'
services:
  api:
    image: alpine:3.20
    command: ["true"]
    networks:
      - backend
networks:
  backend:
    enable_ipv6: false
    ipam:
      config:
        - subnet: fd00:10::/64
          gateway: fd00:10::53
YAML
}

cleanup() {
    if [[ -n "$FIXTURE_DIR" ]]; then
        rm -rf "$FIXTURE_DIR"
    fi
}

assert_docker_ipv6_value() {
    local path="$1"
    local expected="$2"

    python3 - "$path" "$expected" <<'PY'
import json
import pathlib
import sys

network = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8")).get("networks", {}).get("backend", {})
expected = sys.argv[2] == "true"
if network.get("enable_ipv6") is not expected:
    raise SystemExit(f"Docker Compose networks.backend.enable_ipv6 = {network.get('enable_ipv6')!r}, want {expected!r}")
PY
}

assert_container_ipv6_value() {
    local path="$1"
    local expected="$2"

    python3 - "$path" "$expected" <<'PY'
import json
import pathlib
import sys

network = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8")).get("networks", {}).get("backend", {})
expected = sys.argv[2] == "true"
if network.get("enableIPv6") is not expected:
    raise SystemExit(f"container-compose networks.backend.enableIPv6 = {network.get('enableIPv6')!r}, want {expected!r}")
if network.get("unsupportedFields") is not None:
    raise SystemExit(f"container-compose networks.backend.unsupportedFields = {network.get('unsupportedFields')!r}, want absent")
PY
}

assert_container_preserves_ipv6_subnet() {
    local path="$1"
    local expected="$2"

    python3 - "$path" "$expected" <<'PY'
import json
import pathlib
import sys

network = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8")).get("networks", {}).get("backend", {})
if network.get("ipv6Subnet") != sys.argv[2]:
    raise SystemExit(f"container-compose networks.backend.ipv6Subnet = {network.get('ipv6Subnet')!r}, want {sys.argv[2]!r}")
PY
}

assert_docker_ipv6_gateway() {
    local path="$1"
    local expected="$2"

    python3 - "$path" "$expected" <<'PY'
import json
import pathlib
import sys

network = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8")).get("networks", {}).get("backend", {})
pools = network.get("ipam", {}).get("config", [])
if not any(pool.get("subnet") == "fd00:10::/64" and pool.get("gateway") == sys.argv[2] for pool in pools):
    raise SystemExit(f"Docker Compose IPv6 IPAM config = {pools!r}, want gateway {sys.argv[2]!r}")
PY
}

assert_container_ipv6_gateway() {
    local path="$1"
    local expected="$2"

    python3 - "$path" "$expected" <<'PY'
import json
import pathlib
import sys

network = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8")).get("networks", {}).get("backend", {})
if network.get("ipv6Gateway") != sys.argv[2]:
    raise SystemExit(f"container-compose networks.backend.ipv6Gateway = {network.get('ipv6Gateway')!r}, want {sys.argv[2]!r}")
PY
}

validate_docker_behavior() {
    local enabled_output="$FIXTURE_DIR/docker-compose-enabled.json"
    local explicit_output="$FIXTURE_DIR/docker-compose-explicit.json"
    local disabled_output="$FIXTURE_DIR/docker-compose-disabled.json"

    "${DOCKER_COMPOSE_COMMAND[@]}" -p "$PROJECT_NAME" -f "$ENABLED_COMPOSE_FILE" config --format json >"$enabled_output"
    "${DOCKER_COMPOSE_COMMAND[@]}" -p "$PROJECT_NAME" -f "$EXPLICIT_COMPOSE_FILE" config --format json >"$explicit_output"
    "${DOCKER_COMPOSE_COMMAND[@]}" -p "$PROJECT_NAME" -f "$DISABLED_COMPOSE_FILE" config --format json >"$disabled_output"
    assert_docker_ipv6_value "$enabled_output" true
    assert_docker_ipv6_value "$explicit_output" true
    assert_docker_ipv6_gateway "$explicit_output" "fd00:10::53"
    assert_docker_ipv6_value "$disabled_output" false
    assert_docker_ipv6_gateway "$disabled_output" "fd00:10::53"
}

validate_container_compose_behavior() {
    local enabled_output="$FIXTURE_DIR/container-compose-enabled.json"
    local explicit_output="$FIXTURE_DIR/container-compose-explicit.json"
    local disabled_output="$FIXTURE_DIR/container-compose-disabled.json"

    "$CONTAINER_COMPOSE" --ansi never -p "$PROJECT_NAME" -f "$ENABLED_COMPOSE_FILE" config --format json >"$enabled_output"
    assert_container_ipv6_value "$enabled_output" true
    "$CONTAINER_COMPOSE" --ansi never --dry-run -p "$PROJECT_NAME" -f "$ENABLED_COMPOSE_FILE" up api >/dev/null

    "$CONTAINER_COMPOSE" --ansi never -p "$PROJECT_NAME" -f "$EXPLICIT_COMPOSE_FILE" config --format json >"$explicit_output"
    assert_container_ipv6_value "$explicit_output" true
    assert_container_preserves_ipv6_subnet "$explicit_output" "fd00:10::/64"
    assert_container_ipv6_gateway "$explicit_output" "fd00:10::53"
    explicit_up_output="$("$CONTAINER_COMPOSE" --ansi never --dry-run -p "$PROJECT_NAME" -f "$EXPLICIT_COMPOSE_FILE" up api 2>&1)"
    printf '%s\n' "$explicit_up_output" | grep -F -- '--subnet-v6 fd00:10::/64 --gateway-v6 fd00:10::53' >/dev/null

    "$CONTAINER_COMPOSE" --ansi never -p "$PROJECT_NAME" -f "$DISABLED_COMPOSE_FILE" config --format json >"$disabled_output"
    assert_container_ipv6_value "$disabled_output" false
    assert_container_preserves_ipv6_subnet "$disabled_output" "fd00:10::/64"
    assert_container_ipv6_gateway "$disabled_output" "fd00:10::53"

    disabled_up_output="$("$CONTAINER_COMPOSE" --ansi never --dry-run -p "$PROJECT_NAME" -f "$DISABLED_COMPOSE_FILE" up api 2>&1)"
    printf '%s\n' "$disabled_up_output" | grep -E '^\+ (.+/)?container network create --disable-ipv6 ' >/dev/null
    if printf '%s\n' "$disabled_up_output" | grep -E -- '--(subnet-v6|gateway-v6)' >/dev/null; then
        error 'container-compose forwarded IPv6 IPAM settings while IPv6 is disabled'
        return 1
    fi
}

main() {
    parse_args "$@"
    check_tools
    create_fixtures
    trap cleanup EXIT

    validate_docker_behavior
    validate_container_compose_behavior

    info "IPv6 network parity check passed using ${DOCKER_COMPOSE_COMMAND[*]} and $CONTAINER_COMPOSE"
}

main "$@"
