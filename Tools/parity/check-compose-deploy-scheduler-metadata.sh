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
#   check-compose-deploy-scheduler-metadata.sh [options]
#
# OPTIONS:
#   --strict    Fail when Docker Compose V2 or container-compose is unavailable.
#   -h, --help  Show this help.
#
# ENVIRONMENT:
#   CONTAINER_COMPOSE  Path to the container-compose binary. Defaults to the
#                      local SwiftPM debug build at .build/debug/compose.
#   DOCKER_COMPOSE     Docker Compose command to compare with. Defaults to
#                      "docker compose" when available, otherwise docker-compose.
#
# This script is intentionally local-only and is not part of CI. It verifies
# Docker Compose V2 preserves deploy.update_config, deploy.rollback_config,
# and deploy.placement in config output while local dry-run orchestration
# accepts the service, then verifies container-compose mirrors that local-mode
# metadata behavior without treating supported update orders as unsupported
# deploy fields.

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
PROJECT_NAME="cc-deploy-scheduler-$RANDOM"

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
    sed -n '/^# USAGE:/,/^# This script/ { /^# This script/d; s/^# //; s/^#//; p; }' "$SELF_PATH" | sed "s/check-compose-deploy-scheduler-metadata.sh/$SCRIPT_NAME/"
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

    warning "$message; skipping Docker Compose deploy scheduler metadata parity check"
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

    if [[ ! -x "$CONTAINER_COMPOSE" ]]; then
        skip_or_fail "container-compose binary is not executable: $CONTAINER_COMPOSE"
    fi
}

# Create a minimal Compose fixture with Deploy update and scheduler metadata.
create_fixture() {
    FIXTURE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/compose-deploy-scheduler.XXXXXX")"
    cat >"$FIXTURE_DIR/compose.yml" <<'YAML'
services:
  api:
    image: alpine:3.20
    deploy:
      update_config:
        parallelism: 1
        delay: 2s
        order: start-first
      rollback_config:
        parallelism: 2
        order: stop-first
        failure_action: pause
        monitor: 15s
      placement:
        constraints:
          - node.role == worker
        preferences:
          - spread: node.labels.zone
        max_replicas_per_node: 1
YAML
}

# Remove temporary fixture files.
cleanup() {
    if [[ -n "$FIXTURE_DIR" ]]; then
        rm -rf "$FIXTURE_DIR"
    fi
}

# Assert Docker Compose preserves Deploy update and scheduler metadata in config output.
assert_docker_config_preserves_scheduler_metadata() {
    local path="$1"

    python3 - "$path" <<'PY'
import json
import pathlib
import sys

doc = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
deploy = doc.get("services", {}).get("api", {}).get("deploy", {})
update = deploy.get("update_config", {})
rollback = deploy.get("rollback_config", {})
placement = deploy.get("placement", {})
if update.get("order") != "start-first":
    raise SystemExit(f"Docker Compose update_config.order = {update.get('order')!r}, want 'start-first'")
if rollback.get("parallelism") != 2:
    raise SystemExit(f"Docker Compose rollback_config.parallelism = {rollback.get('parallelism')!r}, want 2")
if rollback.get("order") != "stop-first":
    raise SystemExit(f"Docker Compose rollback_config.order = {rollback.get('order')!r}, want 'stop-first'")
if placement.get("constraints") != ["node.role == worker"]:
    raise SystemExit(f"Docker Compose placement.constraints = {placement.get('constraints')!r}")
if placement.get("max_replicas_per_node") != 1:
    raise SystemExit(f"Docker Compose placement.max_replicas_per_node = {placement.get('max_replicas_per_node')!r}, want 1")
PY
}

# Assert container-compose preserves Deploy update and scheduler metadata.
assert_container_config_preserves_scheduler_metadata() {
    local path="$1"

    python3 - "$path" <<'PY'
import json
import pathlib
import sys

doc = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
service = doc.get("services", {}).get("api", {})
fields = service.get("unsupportedDeployFields") or []
unexpected = [field for field in fields if field == "update_config.order" or field == "update_config.order.start-first" or field == "placement" or field == "rollback_config" or field.startswith("placement.") or field.startswith("rollback_config.")]
if unexpected:
    raise SystemExit(f"container-compose still reports Deploy update or scheduler metadata as unsupported: {fields!r}")
deploy = service.get("deploy", {})
update = deploy.get("update_config", {})
rollback = deploy.get("rollback_config", {})
placement = deploy.get("placement", {})
if update.get("order") != "start-first":
    raise SystemExit(f"container-compose update_config.order = {update.get('order')!r}, want 'start-first'")
if rollback.get("parallelism") != 2:
    raise SystemExit(f"container-compose rollback_config.parallelism = {rollback.get('parallelism')!r}, want 2")
if rollback.get("order") != "stop-first":
    raise SystemExit(f"container-compose rollback_config.order = {rollback.get('order')!r}, want 'stop-first'")
if placement.get("constraints") != ["node.role == worker"]:
    raise SystemExit(f"container-compose placement.constraints = {placement.get('constraints')!r}")
if placement.get("max_replicas_per_node") != 1:
    raise SystemExit(f"container-compose placement.max_replicas_per_node = {placement.get('max_replicas_per_node')!r}, want 1")
PY
}

# Exercise Docker Compose as the local-mode parity baseline.
expect_docker_behavior() {
    local config_output="$FIXTURE_DIR/docker-compose-config.json"
    local dry_run_output="$FIXTURE_DIR/docker-compose-dry-run.txt"

    "${DOCKER_COMPOSE_COMMAND[@]}" \
        --project-directory "$FIXTURE_DIR" \
        -f "$FIXTURE_DIR/compose.yml" \
        config --format json >"$config_output"
    assert_docker_config_preserves_scheduler_metadata "$config_output"

    if ! "${DOCKER_COMPOSE_COMMAND[@]}" \
        --ansi never \
        --dry-run \
        --project-directory "$FIXTURE_DIR" \
        -p "$PROJECT_NAME" \
        -f "$FIXTURE_DIR/compose.yml" \
        up --no-start api >"$dry_run_output" 2>&1; then
        error 'Docker Compose Deploy update and scheduler metadata dry-run failed'
        sed -n '1,120p' "$dry_run_output" >&2
        return 1
    fi
    if ! grep -F "Container $PROJECT_NAME-api-1 Created" "$dry_run_output" >/dev/null; then
        error 'Docker Compose did not accept Deploy update and scheduler metadata in local dry-run up'
        sed -n '1,120p' "$dry_run_output" >&2
        return 1
    fi
}

# Exercise container-compose against the same fixture.
expect_container_behavior() {
    local config_output="$FIXTURE_DIR/container-compose-config.json"
    local dry_run_output="$FIXTURE_DIR/container-compose-dry-run.txt"

    "$CONTAINER_COMPOSE" \
        --ansi never \
        --project-directory "$FIXTURE_DIR" \
        -p "$PROJECT_NAME" \
        -f "$FIXTURE_DIR/compose.yml" \
        config --format json >"$config_output"
    assert_container_config_preserves_scheduler_metadata "$config_output"

    if ! "$CONTAINER_COMPOSE" \
        --ansi never \
        --dry-run \
        --project-directory "$FIXTURE_DIR" \
        -p "$PROJECT_NAME" \
        -f "$FIXTURE_DIR/compose.yml" \
        up --no-start api >"$dry_run_output" 2>&1; then
        error 'container-compose Deploy update and scheduler metadata dry-run failed'
        sed -n '1,120p' "$dry_run_output" >&2
        return 1
    fi
    if ! grep -F "container create --name $PROJECT_NAME-api-1" "$dry_run_output" >/dev/null; then
        error 'container-compose did not accept Deploy update and scheduler metadata in local dry-run up'
        sed -n '1,120p' "$dry_run_output" >&2
        return 1
    fi
}

# Run the parity check.
main() {
    parse_args "$@"
    detect_docker_compose
    check_tools
    create_fixture
    trap cleanup EXIT

    expect_docker_behavior
    expect_container_behavior

    info 'Docker Compose Deploy update and scheduler metadata parity passed.'
}

main "$@"
