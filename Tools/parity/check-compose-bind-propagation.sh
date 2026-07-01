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
#   check-compose-bind-propagation.sh [options]
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
# Docker Compose V2 preserves service bind propagation in config output, and
# verifies container-compose preserves the same surface while rendering the
# changed apple/container short volume argument in dry-run output.

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
PROJECT_NAME="cc-bind-propagation-$RANDOM"

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
    sed -n '/^# USAGE:/,/^# This script/ { /^# This script/d; s/^# //; s/^#//; p; }' "$SELF_PATH" | sed "s/check-compose-bind-propagation.sh/$SCRIPT_NAME/"
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

    warning "$message; skipping Docker Compose bind propagation parity check"
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

# Create a minimal Compose fixture with an existing propagated bind source.
create_fixture() {
    FIXTURE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/compose-bind-propagation.XXXXXX")"
    mkdir -p "$FIXTURE_DIR/host"
    cat >"$FIXTURE_DIR/compose.yml" <<'YAML'
services:
  node-exporter:
    image: alpine:3.20
    command: ["true"]
    volumes:
      - type: bind
        source: ./host
        target: /host
        read_only: true
        bind:
          propagation: rslave
YAML
}

# Remove temporary fixture files.
cleanup() {
    if [[ -n "$FIXTURE_DIR" ]]; then
        rm -rf "$FIXTURE_DIR"
    fi
}

# Assert Docker Compose config preserves the bind propagation value.
assert_docker_config_preserves_bind_propagation() {
    local path="$1"

    python3 - "$path" <<'PY'
import json
import pathlib
import sys

doc = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
mount = doc.get("services", {}).get("node-exporter", {}).get("volumes", [{}])[0]
bind = mount.get("bind") or {}
if bind.get("propagation") != "rslave":
    raise SystemExit(f"Docker Compose bind.propagation = {bind.get('propagation')!r}, want rslave")
if mount.get("read_only") is not True:
    raise SystemExit(f"Docker Compose read_only = {mount.get('read_only')!r}, want True")
PY
}

# Assert container-compose config preserves raw and normalized propagation data.
assert_container_config_preserves_bind_propagation() {
    local path="$1"

    python3 - "$path" <<'PY'
import json
import pathlib
import sys

doc = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
mount = doc.get("services", {}).get("node-exporter", {}).get("volumes", [{}])[0]
bind = mount.get("bind") or {}
normalized = mount.get("bindPropagation")
if bind.get("propagation") != "rslave" and normalized != "rslave":
    raise SystemExit(
        "container-compose bind propagation "
        f"= raw {bind.get('propagation')!r}, normalized {normalized!r}; want rslave"
    )
if mount.get("read_only") is not True and mount.get("readOnly") is not True:
    raise SystemExit(
        "container-compose read_only/readOnly "
        f"= raw {mount.get('read_only')!r}, normalized {mount.get('readOnly')!r}; want True"
    )
PY
}

# Exercise Docker Compose as the Compose V2 normalization baseline.
expect_docker_behavior() {
    local config_output="$FIXTURE_DIR/docker-compose-config.json"

    "${DOCKER_COMPOSE_COMMAND[@]}" \
        --project-directory "$FIXTURE_DIR" \
        -f "$FIXTURE_DIR/compose.yml" \
        config --format json >"$config_output"
    assert_docker_config_preserves_bind_propagation "$config_output"
}

# Exercise container-compose config and command-line argument rendering.
expect_container_behavior() {
    local config_output="$FIXTURE_DIR/container-compose-config.json"
    local dry_run_output="$FIXTURE_DIR/container-compose-dry-run.txt"

    "$CONTAINER_COMPOSE" \
        --ansi never \
        --project-directory "$FIXTURE_DIR" \
        -p "$PROJECT_NAME" \
        -f "$FIXTURE_DIR/compose.yml" \
        config --format json >"$config_output"
    assert_container_config_preserves_bind_propagation "$config_output"

    "$CONTAINER_COMPOSE" \
        --ansi never \
        --dry-run \
        --project-directory "$FIXTURE_DIR" \
        -p "$PROJECT_NAME" \
        -f "$FIXTURE_DIR/compose.yml" \
        up --no-start node-exporter >"$dry_run_output" 2>&1
    if ! grep -F "container create --name $PROJECT_NAME-node-exporter-1" "$dry_run_output" >/dev/null; then
        error 'container-compose did not render a create command for the propagated bind fixture'
        sed -n '1,160p' "$dry_run_output" >&2
        return 1
    fi
    if ! grep -F ':/host:ro,rslave' "$dry_run_output" >/dev/null; then
        error 'container-compose did not render bind propagation in the short volume argument'
        sed -n '1,160p' "$dry_run_output" >&2
        return 1
    fi
    if grep -F 'unsupported compose feature' "$dry_run_output" >/dev/null; then
        error 'container-compose still reports bind propagation as unsupported'
        sed -n '1,160p' "$dry_run_output" >&2
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

    info 'Docker Compose bind propagation parity passed.'
}

main "$@"
