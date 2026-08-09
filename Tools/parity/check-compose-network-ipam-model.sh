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
#   check-compose-network-ipam-model.sh [options]
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
# This local-only static-model certificate compares Docker Compose `config`
# with container-compose `config` and `convert`. It deliberately does not run
# `up`: advanced IPAM values remain requested state until the runtime contract
# is available, and unsupported runtime fields must stay preflight-gated.

set -euo pipefail

readonly SELF_PATH="${BASH_SOURCE[0]:-$0}"
SCRIPT_NAME="$(basename "$SELF_PATH")"
readonly SCRIPT_NAME
REPO_ROOT="$(cd "$(dirname "$SELF_PATH")/../.." && pwd)"
readonly REPO_ROOT
readonly FIXTURE_MARKER=".container-compose-network-ipam-model-root"

STRICT=0
DEFAULT_CONTAINER_COMPOSE="$REPO_ROOT/.build/debug/compose"
if [[ ! -x "$DEFAULT_CONTAINER_COMPOSE" ]]; then
    for CANDIDATE_BINARY in "$REPO_ROOT"/.build/*/debug/compose; do
        if [[ -x "$CANDIDATE_BINARY" ]]; then
            DEFAULT_CONTAINER_COMPOSE="$CANDIDATE_BINARY"
            break
        fi
    done
fi
readonly DEFAULT_CONTAINER_COMPOSE
CONTAINER_COMPOSE="${CONTAINER_COMPOSE:-$DEFAULT_CONTAINER_COMPOSE}"
DOCKER_COMPOSE_COMMAND=()
FIXTURE_DIR=""
COMPOSE_FILE=""
PROJECT_NAME="container-compose-network-ipam-model-$RANDOM-$$"

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
    sed -n '/^# USAGE:/,/^# This local-only/ { /^# This local-only/d; s/^# //; s/^#//; p; }' "$SELF_PATH" | sed "s/check-compose-network-ipam-model.sh/$SCRIPT_NAME/"
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

    warning "$message; skipping advanced IPAM static-model parity check"
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

# Create a source-model fixture with every IPAM field Docker preserves in config.
create_fixture() {
    FIXTURE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/compose-network-ipam-model.XXXXXX")"
    COMPOSE_FILE="$FIXTURE_DIR/compose.yaml"
    : >"$FIXTURE_DIR/$FIXTURE_MARKER"

    cat >"$COMPOSE_FILE" <<'YAML'
services:
  api:
    image: alpine:3.20
    command: ["true"]
    networks:
      - advanced
      - ipv6_only
networks:
  advanced:
    driver: bridge
    driver_opts:
      com.docker.network.driver.mtu: "1450"
    enable_ipv4: true
    enable_ipv6: true
    ipam:
      driver: default
      options:
        com.example.ipam: enabled
      config:
        - subnet: 10.72.0.0/24
          ip_range: 10.72.0.128/25
          gateway: 10.72.0.1
          aux_addresses:
            dns: 10.72.0.2
            reserve: 10.72.0.3
        - subnet: fd72::/64
          ip_range: fd72::100/120
          gateway: fd72::1
          aux_addresses:
            dns6: fd72::2
  ipv6_only:
    enable_ipv4: false
    enable_ipv6: true
    ipam:
      config:
        - subnet: fd73::/64
          ip_range: fd73::100/120
          gateway: fd73::1
          aux_addresses:
            dns6: fd73::2
YAML
}

# Remove only the marker-protected disposable fixture root.
cleanup() {
    if [[ -n "$FIXTURE_DIR" && -f "$FIXTURE_DIR/$FIXTURE_MARKER" ]]; then
        rm -rf -- "$FIXTURE_DIR"
    elif [[ -n "$FIXTURE_DIR" ]]; then
        warning "refusing to remove fixture root without $FIXTURE_MARKER: $FIXTURE_DIR"
    fi
}

# Assert Docker Compose's snake_case source model from config JSON.
assert_docker_config_ipam_model() {
    local path="$1"

    python3 - "$path" <<'PY'
import json
import pathlib
import sys

doc = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
networks = doc.get("networks", {})
expected = {
    "advanced": {
        "driver": "bridge",
        "driver_opts": {"com.docker.network.driver.mtu": "1450"},
        "enable_ipv4": True,
        "enable_ipv6": True,
        "ipam": {
            "driver": "default",
            "options": {"com.example.ipam": "enabled"},
            "config": [
                {
                    "subnet": "10.72.0.0/24",
                    "ip_range": "10.72.0.128/25",
                    "gateway": "10.72.0.1",
                    "aux_addresses": {"dns": "10.72.0.2", "reserve": "10.72.0.3"},
                },
                {
                    "subnet": "fd72::/64",
                    "ip_range": "fd72::100/120",
                    "gateway": "fd72::1",
                    "aux_addresses": {"dns6": "fd72::2"},
                },
            ],
        },
    },
    "ipv6_only": {
        "enable_ipv4": False,
        "enable_ipv6": True,
        "ipam": {
            "config": [
                {
                    "subnet": "fd73::/64",
                    "ip_range": "fd73::100/120",
                    "gateway": "fd73::1",
                    "aux_addresses": {"dns6": "fd73::2"},
                },
            ],
        },
    },
}
for name, expected_network in expected.items():
    network = networks.get(name, {})
    for key, value in expected_network.items():
        if network.get(key) != value:
            raise SystemExit(
                f"Docker Compose networks.{name}.{key} = {network.get(key)!r}, want {value!r}"
            )
PY
}

# Assert the camelCase public source model and intentional runtime gates.
assert_container_config_ipam_model() {
    local path="$1"

    python3 - "$path" <<'PY'
import json
import pathlib
import sys

doc = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
networks = doc.get("networks", {})
expected = {
    "advanced": {
        "driver": "bridge",
        "driverOpts": {"com.docker.network.driver.mtu": "1450"},
        "enableIPv4": True,
        "enableIPv6": True,
        "ipam": {
            "driver": "default",
            "options": {"com.example.ipam": "enabled"},
            "config": [
                {
                    "subnet": "10.72.0.0/24",
                    "allocationRange": "10.72.0.128/25",
                    "gateway": "10.72.0.1",
                    "auxiliaryAddresses": {"dns": "10.72.0.2", "reserve": "10.72.0.3"},
                },
                {
                    "subnet": "fd72::/64",
                    "allocationRange": "fd72::100/120",
                    "gateway": "fd72::1",
                    "auxiliaryAddresses": {"dns6": "fd72::2"},
                },
            ],
        },
        "unsupportedFields": ["ipam.driver", "ipam.config.ip_range", "ipam.config.aux_addresses"],
    },
    "ipv6_only": {
        "enableIPv4": False,
        "enableIPv6": True,
        "ipam": {
            "config": [
                {
                    "subnet": "fd73::/64",
                    "allocationRange": "fd73::100/120",
                    "gateway": "fd73::1",
                    "auxiliaryAddresses": {"dns6": "fd73::2"},
                },
            ],
        },
        "unsupportedFields": ["enable_ipv4", "ipam.config.ip_range", "ipam.config.aux_addresses"],
    },
}
for name, expected_network in expected.items():
    network = networks.get(name, {})
    for key, value in expected_network.items():
        if network.get(key) != value:
            raise SystemExit(
                f"container-compose networks.{name}.{key} = {network.get(key)!r}, want {value!r}"
            )
PY
}

# Validate Docker Compose's canonical static source projection.
validate_docker_behavior() {
    local config_output="$FIXTURE_DIR/docker-compose-config.json"

    "${DOCKER_COMPOSE_COMMAND[@]}" -p "$PROJECT_NAME" -f "$COMPOSE_FILE" config --format json >"$config_output"
    assert_docker_config_ipam_model "$config_output"
}

# Validate both container-compose static public entry points without runtime creation.
validate_container_compose_behavior() {
    local config_output="$FIXTURE_DIR/container-compose-config.json"
    local convert_output="$FIXTURE_DIR/container-compose-convert.json"

    "$CONTAINER_COMPOSE" --ansi never -p "$PROJECT_NAME" -f "$COMPOSE_FILE" config --format json >"$config_output"
    assert_container_config_ipam_model "$config_output"

    "$CONTAINER_COMPOSE" --ansi never -p "$PROJECT_NAME" -f "$COMPOSE_FILE" convert --format json >"$convert_output"
    assert_container_config_ipam_model "$convert_output"
}

# Run the local-only static-model parity check.
main() {
    parse_args "$@"
    check_tools
    create_fixture
    trap cleanup EXIT

    validate_docker_behavior
    validate_container_compose_behavior

    info "Advanced IPAM source-model parity check passed using ${DOCKER_COMPOSE_COMMAND[*]} and $CONTAINER_COMPOSE"
}

main "$@"
