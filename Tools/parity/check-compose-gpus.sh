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
#   check-compose-gpus.sh [options]
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
# This local parity check compares service `gpus` and deploy GPU reservations
# with Docker Compose V2 config output, then verifies the supported single
# virtio-gpu subset is projected into container-compose runtime commands.

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
UNSUPPORTED_FILE=""
PROJECT_NAME="container-compose-gpus-$RANDOM-$$"

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
    sed -n '/^# USAGE:/,/^# This local parity/ { /^# This local parity/d; s/^# //; s/^#//; p; }' "$SELF_PATH" | sed "s/check-compose-gpus.sh/$SCRIPT_NAME/"
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

    warning "$message; skipping Docker/container-compose GPU parity check"
    exit 0
}

# Locate Docker Compose V2 in plugin or standalone form.
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

# Ensure the model comparison tools are available.
check_tools() {
    detect_docker_compose
    command -v python3 >/dev/null 2>&1 || skip_or_fail 'python3 is not available'
    [[ -x "$CONTAINER_COMPOSE" ]] || skip_or_fail "container-compose binary is not executable: $CONTAINER_COMPOSE"
}

# Create supported and unsupported Compose fixtures.
create_fixture() {
    FIXTURE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/compose-gpus.XXXXXX")"
    COMPOSE_FILE="$FIXTURE_DIR/compose.yml"
    UNSUPPORTED_FILE="$FIXTURE_DIR/unsupported.yml"

    cat >"$COMPOSE_FILE" <<'YAML'
services:
  service-gpu:
    image: alpine:3.20
    command: ["true"]
    gpus: all
  deploy-gpu:
    image: alpine:3.20
    command: ["true"]
    deploy:
      resources:
        reservations:
          devices:
            - capabilities: [gpu]
              count: all
YAML

    cat >"$UNSUPPORTED_FILE" <<'YAML'
services:
  nvidia:
    image: alpine:3.20
    gpus:
      - driver: nvidia
        count: 1
        capabilities: [gpu]
YAML
}

# Remove temporary fixture files.
cleanup() {
    if [[ -n "$FIXTURE_DIR" ]]; then
        rm -rf "$FIXTURE_DIR"
    fi
}

# Assert normalized service and deploy GPU model shapes.
assert_config_gpus() {
    local path="$1"
    local source="$2"

    python3 - "$path" "$source" <<'PY'
import json
import pathlib
import sys

doc = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
source = sys.argv[2]
services = doc.get("services", {})
service_gpu = services.get("service-gpu", {}).get("gpus")
deploy_gpu = (
    services.get("deploy-gpu", {})
    .get("deploy", {})
    .get("resources", {})
    .get("reservations", {})
    .get("devices")
)
if service_gpu != [{"count": -1}]:
    raise SystemExit(f"{source} service gpus = {service_gpu!r}, want [{{'count': -1}}]")
if deploy_gpu != [{"capabilities": ["gpu"], "count": -1}]:
    raise SystemExit(f"{source} deploy GPU reservation = {deploy_gpu!r}")
PY
}

# Return the first dry-run command line for a service.
dry_run_service_line() {
    local output="$1"
    local service="$2"

    printf '%s\n' "$output" | grep -F -- "-$service-" | grep -E 'container (run|create) ' | head -n 1
}

# Validate Docker Compose normalized model behavior.
validate_docker_behavior() {
    local output="$FIXTURE_DIR/docker-compose-config.json"

    "${DOCKER_COMPOSE_COMMAND[@]}" -p "$PROJECT_NAME" -f "$COMPOSE_FILE" config --format json >"$output"
    assert_config_gpus "$output" "Docker Compose"
}

# Validate container-compose normalized model and runtime command projection.
validate_container_compose_behavior() {
    local config_output="$FIXTURE_DIR/container-compose-config.json"
    local up_output
    local create_output
    local run_output
    local line
    local unsupported_output

    "$CONTAINER_COMPOSE" --ansi never -p "$PROJECT_NAME" -f "$COMPOSE_FILE" config --format json >"$config_output"
    assert_config_gpus "$config_output" "container-compose"

    up_output="$("$CONTAINER_COMPOSE" --ansi never --dry-run -p "$PROJECT_NAME" -f "$COMPOSE_FILE" up service-gpu deploy-gpu)"
    create_output="$("$CONTAINER_COMPOSE" --ansi never --dry-run -p "$PROJECT_NAME" -f "$COMPOSE_FILE" create service-gpu deploy-gpu)"
    run_output="$("$CONTAINER_COMPOSE" --ansi never --dry-run -p "$PROJECT_NAME" -f "$COMPOSE_FILE" run service-gpu true)"

    for service in service-gpu deploy-gpu; do
        line="$(dry_run_service_line "$up_output" "$service")"
        [[ "$line" == *"--gpus all"* ]] || { error "missing $service GPU request in dry-run up: $line"; return 1; }
        line="$(dry_run_service_line "$create_output" "$service")"
        [[ "$line" == *"--gpus all"* ]] || { error "missing $service GPU request in dry-run create: $line"; return 1; }
    done
    line="$(dry_run_service_line "$run_output" "service-gpu")"
    [[ "$line" == *"--gpus all"* ]] || { error "missing service GPU request in dry-run run: $line"; return 1; }

    unsupported_output="$("$CONTAINER_COMPOSE" --ansi never --dry-run -p "$PROJECT_NAME-unsupported" -f "$UNSUPPORTED_FILE" up 2>&1 || true)"
    [[ "$unsupported_output" == *"requests GPU driver 'nvidia'"* ]] || {
        error "unsupported GPU driver blocker changed: $unsupported_output"
        return 1
    }
}

# Run the local Docker Compose V2 GPU parity check.
main() {
    parse_args "$@"
    check_tools
    create_fixture
    trap cleanup EXIT

    validate_docker_behavior
    validate_container_compose_behavior
    info "Docker Compose GPU parity check passed for project $PROJECT_NAME"
}

main "$@"
