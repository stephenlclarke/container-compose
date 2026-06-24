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
#   check-compose-restart-policy.sh [options]
#
# OPTIONS:
#   --strict    Fail when Docker Compose V2 or the Docker daemon is unavailable.
#   -h, --help  Show this help.
#
# This script is intentionally local-only and is not part of CI. It verifies the
# Docker Compose V2 restart-policy HostConfig shape used by container-compose:
# service-level restart values, deploy-over-service precedence, deploy
# condition:any, deploy condition:none, and on-failure:0 as an unlimited retry
# policy.

set -euo pipefail

readonly SELF_PATH="${BASH_SOURCE[0]:-$0}"
SCRIPT_NAME="$(basename "$SELF_PATH")"
readonly SCRIPT_NAME

STRICT=0
TMPDIR=""
COMPOSE_FILE=""
PROJECT_NAME="container-compose-restart-$RANDOM-$$"

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
    sed -n '/^# USAGE:/,/^# This script/ { /^# This script/d; s/^# //; s/^#//; p; }' "$SELF_PATH" | sed "s/check-compose-restart-policy.sh/$SCRIPT_NAME/"
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

# Exit cleanly for optional Docker dependencies, or fail in strict mode.
skip_or_fail() {
    local message="$1"

    if ((STRICT == 1)); then
        error "$message"
        return 1
    fi

    warning "$message; skipping Docker Compose restart-policy parity check"
    exit 0
}

# Check Docker Compose V2 and daemon availability.
check_docker() {
    if ! docker compose version >/dev/null 2>&1; then
        skip_or_fail 'Docker Compose V2 is not available'
    fi

    if ! docker info >/dev/null 2>&1; then
        skip_or_fail 'Docker daemon is not available'
    fi
}

# Create a minimal project used to inspect Docker restart-policy HostConfig.
create_fixture() {
    TMPDIR="$(mktemp -d)"
    COMPOSE_FILE="$TMPDIR/compose.yml"

    cat >"$COMPOSE_FILE" <<'YAML'
services:
  svcservice:
    image: alpine:3.20
    command: ["sh", "-c", "sleep 60"]
    restart: unless-stopped
  svczero:
    image: alpine:3.20
    command: ["sh", "-c", "sleep 60"]
    restart: on-failure:0
  deployprec:
    image: alpine:3.20
    command: ["sh", "-c", "sleep 60"]
    restart: unless-stopped
    deploy:
      restart_policy:
        condition: on-failure
        max_attempts: 3
  deployany:
    image: alpine:3.20
    command: ["sh", "-c", "sleep 60"]
    deploy:
      restart_policy:
        condition: any
  deploynone:
    image: alpine:3.20
    command: ["sh", "-c", "sleep 60"]
    deploy:
      restart_policy:
        condition: none
YAML
}

# Clean up the temporary Docker Compose project and local files.
cleanup() {
    if [[ -n "$COMPOSE_FILE" ]]; then
        docker compose -p "$PROJECT_NAME" -f "$COMPOSE_FILE" down --volumes --remove-orphans >/dev/null 2>&1 || true
    fi
    if [[ -n "$TMPDIR" ]]; then
        rm -rf "$TMPDIR"
    fi
}

# Validate Docker Compose's rendered HostConfig restart policy values.
validate_restart_policies() {
    python3 - "$PROJECT_NAME" "$COMPOSE_FILE" <<'PY'
import json
import subprocess
import sys

project, compose_file = sys.argv[1], sys.argv[2]
expected = {
    "svcservice": ("unless-stopped", 0),
    "svczero": ("on-failure", 0),
    "deployprec": ("on-failure", 3),
    "deployany": ("always", 0),
    "deploynone": ("no", 0),
}

for service, (name, maximum_retry_count) in expected.items():
    container_id = subprocess.check_output(
        ["docker", "compose", "-p", project, "-f", compose_file, "ps", "-q", service],
        text=True,
    ).strip()
    if not container_id:
        raise SystemExit(f"service {service!r} did not create a container")

    inspect = subprocess.check_output(["docker", "inspect", container_id], text=True)
    policy = json.loads(inspect)[0]["HostConfig"]["RestartPolicy"]
    actual = (policy.get("Name"), int(policy.get("MaximumRetryCount") or 0))
    wanted = (name, maximum_retry_count)
    if actual != wanted:
        raise SystemExit(
            f"service {service!r} restart policy {actual!r}, want {wanted!r}"
        )
PY
}

# Run the local-only Docker Compose V2 parity check.
main() {
    parse_args "$@"
    check_docker
    create_fixture
    trap cleanup EXIT

    docker compose -p "$PROJECT_NAME" -f "$COMPOSE_FILE" create --force-recreate >/dev/null
    validate_restart_policies
    printf 'Docker Compose restart-policy parity check passed for project %s\n' "$PROJECT_NAME"
}

main "$@"
