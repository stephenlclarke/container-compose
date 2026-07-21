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
#   check-compose-state-status.sh [options]
#
# OPTIONS:
#   --strict    Fail when Docker Compose V2 or the Docker daemon is unavailable.
#   -h, --help  Show this help.
#
# ENVIRONMENT:
#   DOCKER_COMPOSE  Docker Compose command to compare with. Defaults to
#                   "docker compose" when available, otherwise docker-compose.
#
# This script is intentionally local-only and is not part of CI. It records the
# Docker Compose V2 status lifecycle that container-compose projects from
# apple/container's stopped snapshots: a never-started service is `created`,
# while a service stopped after start is `exited`.

set -euo pipefail

readonly SELF_PATH="${BASH_SOURCE[0]:-$0}"
SCRIPT_NAME="$(basename "$SELF_PATH")"
readonly SCRIPT_NAME
REPO_ROOT="$(cd "$(dirname "$SELF_PATH")/../.." && pwd)"
readonly REPO_ROOT
readonly FIXTURE_FILE="$REPO_ROOT/Tools/parity/fixtures/state-status/compose.yaml"

STRICT=0
PARITY_TEMP_DIR=""
PROJECT_NAME="container-compose-state-status-$RANDOM-$$"
DOCKER_COMPOSE_COMMAND=()

# Print a warning message to stderr.
warning() {
    printf 'warning: %s\n' "$*" >&2
}

# Print an error message to stderr.
error() {
    printf 'error: %s\n' "$*" >&2
}

# Print usage text extracted from this script header.
usage() {
    sed -n '/^# USAGE:/,/^# This script/ { /^# This script/d; s/^# //; s/^#//; p; }' "$SELF_PATH" | sed "s/check-compose-state-status.sh/$SCRIPT_NAME/"
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

    warning "$message; skipping Docker Compose state-status parity check"
    exit 0
}

# Locate Docker Compose V2, accepting either plugin or standalone command form.
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

# Check Docker Compose V2 and daemon availability.
check_docker() {
    detect_docker_compose
    if ! docker info >/dev/null 2>&1; then
        skip_or_fail 'Docker daemon is not available'
    fi
}

# Remove the isolated reference project and its captured JSON output.
cleanup() {
    if ((${#DOCKER_COMPOSE_COMMAND[@]} > 0)); then
        "${DOCKER_COMPOSE_COMMAND[@]}" -p "$PROJECT_NAME" -f "$FIXTURE_FILE" down --volumes --remove-orphans >/dev/null 2>&1 || true
    fi
    if [[ -n "$PARITY_TEMP_DIR" ]]; then
        rm -rf "$PARITY_TEMP_DIR"
    fi
}

# Capture all status views needed to distinguish created from exited services.
capture_statuses() {
    PARITY_TEMP_DIR="$(mktemp -d)"
    [[ -f "$FIXTURE_FILE" ]] || { error "missing state-status fixture: $FIXTURE_FILE"; return 1; }

    "${DOCKER_COMPOSE_COMMAND[@]}" -p "$PROJECT_NAME" -f "$FIXTURE_FILE" create >/dev/null
    "${DOCKER_COMPOSE_COMMAND[@]}" -p "$PROJECT_NAME" -f "$FIXTURE_FILE" ps --all --format json >"$PARITY_TEMP_DIR/created.jsonl"

    "${DOCKER_COMPOSE_COMMAND[@]}" -p "$PROJECT_NAME" -f "$FIXTURE_FILE" start api >/dev/null
    "${DOCKER_COMPOSE_COMMAND[@]}" -p "$PROJECT_NAME" -f "$FIXTURE_FILE" kill api >/dev/null
    "${DOCKER_COMPOSE_COMMAND[@]}" -p "$PROJECT_NAME" -f "$FIXTURE_FILE" ps --all --format json >"$PARITY_TEMP_DIR/all.jsonl"
    "${DOCKER_COMPOSE_COMMAND[@]}" -p "$PROJECT_NAME" -f "$FIXTURE_FILE" ps --all --status created --format json >"$PARITY_TEMP_DIR/filter-created.jsonl"
    "${DOCKER_COMPOSE_COMMAND[@]}" -p "$PROJECT_NAME" -f "$FIXTURE_FILE" ps --all --status exited --format json >"$PARITY_TEMP_DIR/filter-exited.jsonl"
    "${DOCKER_COMPOSE_COMMAND[@]}" -p "$PROJECT_NAME" -f "$FIXTURE_FILE" ps --all --status stopped --format json >"$PARITY_TEMP_DIR/filter-stopped.jsonl"
}

# Validate the exact Docker Compose V2 lifecycle shape that Compose mirrors.
validate_statuses() {
    python3 - "$PARITY_TEMP_DIR" <<'PY'
import json
import sys
from pathlib import Path


def records(path: Path) -> list[dict[str, object]]:
    text = path.read_text(encoding="utf-8").strip()
    if not text:
        return []
    if text.startswith("["):
        return json.loads(text)
    return [json.loads(line) for line in text.splitlines() if line.strip()]


def services(path: Path) -> dict[str, dict[str, object]]:
    return {str(record["Service"]): record for record in records(path)}


root = Path(sys.argv[1])
created = services(root / "created.jsonl")
if set(created) != {"api", "db"}:
    raise SystemExit(f"created ps services = {sorted(created)}, want api and db")
for service, record in created.items():
    if record.get("State") != "created" or record.get("Status") != "Created":
        raise SystemExit(f"{service} after create = {record.get('State')!r}/{record.get('Status')!r}, want created/Created")
    if record.get("ExitCode") != 0:
        raise SystemExit(f"{service} after create ExitCode = {record.get('ExitCode')!r}, want 0")

all_services = services(root / "all.jsonl")
api = all_services.get("api")
db = all_services.get("db")
if api is None or db is None:
    raise SystemExit(f"post-kill ps services = {sorted(all_services)}, want api and db")
if api.get("State") != "exited" or api.get("ExitCode") != 137:
    raise SystemExit(f"api after kill = {api.get('State')!r}/ExitCode {api.get('ExitCode')!r}, want exited/137")
if not str(api.get("Status", "")).startswith("Exited (137)"):
    raise SystemExit(f"api after kill Status = {api.get('Status')!r}, want Exited (137) ...")
if db.get("State") != "created":
    raise SystemExit(f"db after api kill State = {db.get('State')!r}, want created")

for filename, expected in (("filter-created.jsonl", {"db": "created"}), ("filter-exited.jsonl", {"api": "exited"})):
    actual = {service: record.get("State") for service, record in services(root / filename).items()}
    if actual != expected:
        raise SystemExit(f"{filename} = {actual!r}, want {expected!r}")

if records(root / "filter-stopped.jsonl"):
    raise SystemExit("ps --status stopped unexpectedly matched a Docker Compose V2 service")
PY
}

main() {
    parse_args "$@"
    check_docker
    trap cleanup EXIT
    capture_statuses
    validate_statuses
    printf 'Docker Compose V2 state-status parity passed (%s)\n' "${DOCKER_COMPOSE_COMMAND[*]}"
}

main "$@"
