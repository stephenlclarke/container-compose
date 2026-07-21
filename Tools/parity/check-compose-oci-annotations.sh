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
#   check-compose-oci-annotations.sh [options]
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
# This script proves Docker Compose V2 and container-compose retain Compose
# service annotations independently from same-key labels, then verifies the
# local adapter emits distinct generic runtime options.

set -euo pipefail

readonly SELF_PATH="${BASH_SOURCE[0]:-$0}"
readonly SCRIPT_NAME="$(basename "$SELF_PATH")"
readonly REPO_ROOT="$(cd "$(dirname "$SELF_PATH")/../.." && pwd)"
readonly FIXTURE_FILE="$REPO_ROOT/Tools/parity/fixtures/oci-annotations/compose.yaml"
readonly PROJECT_NAME="cc-oci-annotations-parity"

STRICT=0
CONTAINER_COMPOSE="${CONTAINER_COMPOSE:-$REPO_ROOT/.build/debug/compose}"
DOCKER_COMPOSE_COMMAND=()

info() { printf '%s\n' "$*"; }
warning() { printf 'warning: %s\n' "$*" >&2; }
error() { printf 'error: %s\n' "$*" >&2; }

usage() {
    sed -n '/^# USAGE:/,/^# This script/ { /^# This script/d; s/^# //; s/^#//; p; }' "$SELF_PATH" \
        | sed "s/check-compose-oci-annotations.sh/$SCRIPT_NAME/"
}

parse_args() {
    while (($# > 0)); do
        case "$1" in
            --strict) STRICT=1; shift ;;
            -h | --help) usage; exit 0 ;;
            *) error "unknown argument: $1"; usage >&2; return 2 ;;
        esac
    done
}

skip_or_fail() {
    local message="$1"
    if ((STRICT == 1)); then
        error "$message"
        return 1
    fi
    warning "$message; skipping OCI annotation parity check"
    exit 0
}

detect_docker_compose() {
    if [[ -n "${DOCKER_COMPOSE:-}" ]]; then
        IFS=' ' read -r -a DOCKER_COMPOSE_COMMAND <<<"$DOCKER_COMPOSE"
        "${DOCKER_COMPOSE_COMMAND[@]}" version >/dev/null 2>&1 \
            || skip_or_fail "Docker Compose V2 command is unavailable: $DOCKER_COMPOSE"
        return
    fi
    if docker compose version >/dev/null 2>&1; then
        DOCKER_COMPOSE_COMMAND=(docker compose)
        return
    fi
    if command -v docker-compose >/dev/null 2>&1 && docker-compose version >/dev/null 2>&1; then
        DOCKER_COMPOSE_COMMAND=(docker-compose)
        return
    fi
    skip_or_fail 'Docker Compose V2 is not available'
}

check_tools() {
    command -v python3 >/dev/null 2>&1 || skip_or_fail 'python3 is not available'
    [[ -x "$CONTAINER_COMPOSE" ]] || skip_or_fail "container-compose binary is not executable: $CONTAINER_COMPOSE"
    [[ -f "$FIXTURE_FILE" ]] || { error "missing OCI annotation fixture: $FIXTURE_FILE"; return 1; }
}

assert_annotation_config() {
    local implementation="$1"
    python3 -c '
import json
import sys

implementation = sys.argv[1]
service = json.load(sys.stdin).get("services", {}).get("api", {})
labels = service.get("labels")
annotations = service.get("annotations")

if labels != {"com.example.metadata": "label=with=equals"}:
    raise SystemExit(f"{implementation}: labels = {labels!r}, want only the label map")
if annotations != {
    "com.example.metadata": "annotation",
    "com.example.owner": "platform",
}:
    raise SystemExit(f"{implementation}: annotations = {annotations!r}, want the OCI annotation map")
' "$implementation"
}

expect_docker_config() {
    "${DOCKER_COMPOSE_COMMAND[@]}" \
        --project-name "$PROJECT_NAME" \
        --file "$FIXTURE_FILE" \
        config --format json | assert_annotation_config 'Docker Compose V2'
}

expect_container_config() {
    "$CONTAINER_COMPOSE" \
        --ansi never \
        --project-name "$PROJECT_NAME" \
        --file "$FIXTURE_FILE" \
        config --format json | assert_annotation_config 'container-compose'
}

expect_container_dry_run() {
    local output
    output="$("$CONTAINER_COMPOSE" \
        --ansi never \
        --project-name "$PROJECT_NAME" \
        --file "$FIXTURE_FILE" \
        --dry-run up --no-start api)"
    if [[ "$output" != *"--label com.example.metadata=label=with=equals"* ]]; then
        error 'container-compose dry-run did not retain the service label'
        printf '%s\n' "$output" >&2
        return 1
    fi
    if [[ "$output" != *"--annotation com.example.metadata=annotation"* ]] || \
        [[ "$output" != *"--annotation com.example.owner=platform"* ]]; then
        error 'container-compose dry-run did not emit OCI annotation options'
        printf '%s\n' "$output" >&2
        return 1
    fi
}

main() {
    parse_args "$@"
    detect_docker_compose
    check_tools
    expect_docker_config
    expect_container_config
    expect_container_dry_run
    info 'Docker Compose V2 and container-compose OCI annotation parity passed.'
}

main "$@"
