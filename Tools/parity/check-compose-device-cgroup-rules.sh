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
#   check-compose-device-cgroup-rules.sh [options]
#
# OPTIONS:
#   --strict    Fail when Docker Compose V2, the Docker daemon, or container-compose is unavailable.
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
# Docker Compose V2 handling for service `device_cgroup_rules`, checks Docker
# Engine HostConfig projection when a daemon is available, then checks the same
# Compose file through container-compose dry-run output. Host `devices` and GPU
# requests are covered by their own parity slices.

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
INVALID_FILE=""
PROJECT_NAME="container-compose-devices-$RANDOM-$$"

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
    sed -n '/^# USAGE:/,/^# This script/ { /^# This script/d; s/^# //; s/^#//; p; }' "$SELF_PATH" | sed "s/check-compose-device-cgroup-rules.sh/$SCRIPT_NAME/"
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

    warning "$message; skipping Docker/container-compose device cgroup rule parity check"
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

    if ! docker info >/dev/null 2>&1; then
        skip_or_fail 'Docker daemon is not available'
    fi

    if [[ ! -x "$CONTAINER_COMPOSE" ]]; then
        skip_or_fail "container-compose binary is not executable: $CONTAINER_COMPOSE"
    fi
}

# Create minimal Compose fixtures for supported and invalid rule forms.
create_fixture() {
    FIXTURE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/compose-device-cgroup-rules.XXXXXX")"
    COMPOSE_FILE="$FIXTURE_DIR/compose.yml"
    INVALID_FILE="$FIXTURE_DIR/invalid.yml"

    cat >"$COMPOSE_FILE" <<'YAML'
services:
  api:
    image: alpine:3.20
    command: ["sh", "-c", "sleep 60"]
    device_cgroup_rules:
      - "c 1:3 mr"
      - "a *:* rwm"
YAML

    cat >"$INVALID_FILE" <<'YAML'
services:
  api:
    image: alpine:3.20
    command: ["true"]
    device_cgroup_rules:
      - "x 1:3 rwm"
YAML
}

# Remove runtime containers and temporary fixture files.
cleanup() {
    if [[ -n "$COMPOSE_FILE" ]]; then
        "${DOCKER_COMPOSE_COMMAND[@]}" -p "$PROJECT_NAME" -f "$COMPOSE_FILE" down --volumes --remove-orphans >/dev/null 2>&1 || true
    fi
    if [[ -n "$FIXTURE_DIR" ]]; then
        rm -rf "$FIXTURE_DIR"
    fi
}

# Assert a JSON Compose service preserves the expected device cgroup rules.
assert_config_rules() {
    local path="$1"
    local source="$2"

    python3 - "$path" "$source" <<'PY'
import json
import pathlib
import sys

doc = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
source = sys.argv[2]
service = doc.get("services", {}).get("api", {})
rules = service.get("device_cgroup_rules")
if rules is None:
    rules = service.get("deviceCgroupRules")
expected = ["c 1:3 mr", "a *:* rwm"]
if rules != expected:
    raise SystemExit(f"{source} device_cgroup_rules = {rules!r}, want {expected!r}")
PY
}

# Validate Docker Compose normalized config and runtime host config.
validate_docker_behavior() {
    local config_output="$FIXTURE_DIR/docker-compose-config.json"

    "${DOCKER_COMPOSE_COMMAND[@]}" -p "$PROJECT_NAME" -f "$COMPOSE_FILE" config --format json >"$config_output"
    assert_config_rules "$config_output" "Docker Compose"

    "${DOCKER_COMPOSE_COMMAND[@]}" -p "$PROJECT_NAME" -f "$COMPOSE_FILE" up -d --quiet-pull >/dev/null
    python3 - "$PROJECT_NAME" "$COMPOSE_FILE" "${DOCKER_COMPOSE_COMMAND[@]}" <<'PY'
import json
import subprocess
import sys

project, compose_file = sys.argv[1], sys.argv[2]
compose_command = sys.argv[3:]
container_id = subprocess.check_output(
    compose_command + ["-p", project, "-f", compose_file, "ps", "-q", "api"],
    text=True,
).strip()
if not container_id:
    raise SystemExit("Docker Compose did not create an api container")

inspect = subprocess.check_output(["docker", "inspect", container_id], text=True)
rules = json.loads(inspect)[0]["HostConfig"].get("DeviceCgroupRules")
expected = ["c 1:3 mr", "a *:* rwm"]
if rules != expected:
    raise SystemExit(f"Docker HostConfig.DeviceCgroupRules = {rules!r}, want {expected!r}")
PY
}

# Return the first dry-run command line for the api service container.
dry_run_api_line() {
    local output="$1"

    printf '%s\n' "$output" | grep -F "container run --name $PROJECT_NAME-api-" | head -n 1
}

# Return success when a dry-run command line includes a device cgroup rule.
line_has_rule() {
    local line="$1"
    local rule="$2"

    printf '%s\n' "$line" | grep -F -- "--device-cgroup-rule '$rule'" >/dev/null \
        || printf '%s\n' "$line" | grep -F -- "--device-cgroup-rule $rule" >/dev/null
}

# Validate container-compose config and dry-run command projection.
validate_container_compose_behavior() {
    local config_output="$FIXTURE_DIR/container-compose-config.json"
    local up_output
    local create_output
    local run_output
    local up_line
    local create_line
    local run_line
    local invalid_output

    "$CONTAINER_COMPOSE" --ansi never -p "$PROJECT_NAME" -f "$COMPOSE_FILE" config --format json >"$config_output"
    assert_config_rules "$config_output" "container-compose"

    up_output="$("$CONTAINER_COMPOSE" --ansi never --dry-run -p "$PROJECT_NAME" -f "$COMPOSE_FILE" up api)"
    create_output="$("$CONTAINER_COMPOSE" --ansi never --dry-run -p "$PROJECT_NAME" -f "$COMPOSE_FILE" create api)"
    run_output="$("$CONTAINER_COMPOSE" --ansi never --dry-run -p "$PROJECT_NAME" -f "$COMPOSE_FILE" run api true)"
    up_line="$(dry_run_api_line "$up_output")"
    create_line="$(printf '%s\n' "$create_output" | grep -F "container create --name $PROJECT_NAME-api-" | head -n 1)"
    run_line="$(dry_run_api_line "$run_output")"

    [[ -n "$up_line" ]] || { error 'missing dry-run command for device_cgroup_rules service up'; return 1; }
    [[ -n "$create_line" ]] || { error 'missing dry-run command for device_cgroup_rules service create'; return 1; }
    [[ -n "$run_line" ]] || { error 'missing dry-run command for device_cgroup_rules service run'; return 1; }

    for line in "$up_line" "$create_line" "$run_line"; do
        line_has_rule "$line" "c 1:3 mr" || { error "missing character-device rule in dry-run line: $line"; return 1; }
        line_has_rule "$line" "a *:* rwm" || { error "missing all-device rule in dry-run line: $line"; return 1; }
    done

    invalid_output="$("$CONTAINER_COMPOSE" --ansi never --dry-run -p "$PROJECT_NAME-invalid" -f "$INVALID_FILE" up api 2>&1 || true)"
    [[ "$invalid_output" == *"service 'api' has invalid device_cgroup_rules"* ]] || {
        error "invalid device_cgroup_rules blocker changed: $invalid_output"
        return 1
    }
}

# Run the local-only Docker Compose V2 parity check.
main() {
    parse_args "$@"
    check_tools
    create_fixture
    trap cleanup EXIT

    validate_docker_behavior
    validate_container_compose_behavior
    info "Docker Compose device cgroup rule parity check passed for project $PROJECT_NAME"
}

main "$@"
