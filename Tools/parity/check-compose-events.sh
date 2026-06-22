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
#   check-compose-events.sh [options]
#
# OPTIONS:
#   --strict    Fail when Docker Compose V2 or the Docker daemon is unavailable.
#   -h, --help  Show this help.
#
# This script is intentionally local-only and is not part of CI. It verifies the
# Docker Compose V2 event semantics used by container-compose: JSON output is
# container-scoped, selected service filtering excludes other services, internal
# Compose labels are stripped, one-off run containers are not emitted, and
# --since/--until can replay a bounded project event window.

set -euo pipefail

readonly SELF_PATH="${BASH_SOURCE[0]:-$0}"
SCRIPT_NAME="$(basename "$SELF_PATH")"
readonly SCRIPT_NAME

STRICT=0
TMPDIR=""
COMPOSE_FILE=""
EVENTS_FILE=""
FILTERED_EVENTS_FILE=""
PROJECT_NAME="container-compose-events-$RANDOM-$$"
EVENTS_PID=""

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
    sed -n '/^# USAGE:/,/^# This script/ { /^# This script/d; s/^# //; s/^#//; p; }' "$SELF_PATH" | sed "s/check-compose-events.sh/$SCRIPT_NAME/"
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

    warning "$message; skipping Docker Compose events parity check"
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

# Create a minimal project used to observe selected-service event behavior.
create_fixture() {
    TMPDIR="$(mktemp -d)"
    COMPOSE_FILE="$TMPDIR/compose.yml"
    EVENTS_FILE="$TMPDIR/events.jsonl"
    FILTERED_EVENTS_FILE="$TMPDIR/events-filtered.jsonl"

    cat >"$COMPOSE_FILE" <<'YAML'
services:
  api:
    image: alpine:3.20
    command: ["sh", "-c", "sleep 30"]
  db:
    image: alpine:3.20
    command: ["sh", "-c", "sleep 30"]
YAML
    : >"$EVENTS_FILE"
}

# Stop the background event watcher if it is still running.
stop_events_watcher() {
    if [[ -z "$EVENTS_PID" ]]; then
        return 0
    fi

    kill "$EVENTS_PID" >/dev/null 2>&1 || true
    wait "$EVENTS_PID" >/dev/null 2>&1 || true
    EVENTS_PID=""
}

# Clean up the temporary Docker Compose project and local files.
cleanup() {
    stop_events_watcher
    if [[ -n "$COMPOSE_FILE" ]]; then
        docker compose -p "$PROJECT_NAME" -f "$COMPOSE_FILE" down --volumes --remove-orphans >/dev/null 2>&1 || true
    fi
    if [[ -n "$TMPDIR" ]]; then
        rm -rf "$TMPDIR"
    fi
}

# Start `docker compose events --json` in the background.
start_events_watcher() {
    docker compose -p "$PROJECT_NAME" -f "$COMPOSE_FILE" events --json api >"$EVENTS_FILE" &
    EVENTS_PID="$!"
    sleep 1
}

# Wait until Docker Compose has emitted at least one API container event.
wait_for_api_event() {
    local deadline
    ((deadline = SECONDS + 60))

    while ((SECONDS < deadline)); do
        if python3 - "$EVENTS_FILE" <<'PY'
import json
import sys

for line in open(sys.argv[1], encoding="utf-8"):
    if not line.strip():
        continue
    event = json.loads(line)
    if event.get("type") == "container" and event.get("service") == "api":
        sys.exit(0)
sys.exit(1)
PY
        then
            return 0
        fi
        sleep 1
    done

    error 'timed out waiting for docker compose events --json api output'
    return 1
}

# Wait for the event file line count to stop changing.
stable_event_count() {
    local previous
    local current

    previous="$(wc -l <"$EVENTS_FILE" | tr -d ' ')"
    for _ in 1 2 3; do
        sleep 1
        current="$(wc -l <"$EVENTS_FILE" | tr -d ' ')"
        if [[ "$current" != "$previous" ]]; then
            previous="$current"
            continue
        fi
    done
    printf '%s\n' "$previous"
}

# Validate the Docker Compose event stream shape this repository mirrors.
validate_events() {
    local before_one_off="$1"
    local after_one_off="$2"

    python3 - "$EVENTS_FILE" "$before_one_off" "$after_one_off" <<'PY'
import json
import sys

path, before_one_off, after_one_off = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
events = []
for line in open(path, encoding="utf-8"):
    if not line.strip():
        continue
    events.append(json.loads(line))

if not events:
    raise SystemExit("no Docker Compose events were captured")

required = {"time", "type", "service", "id", "action", "attributes"}
for index, event in enumerate(events, start=1):
    missing = required.difference(event)
    if missing:
        raise SystemExit(f"event {index} missing fields: {sorted(missing)}")
    if event["type"] != "container":
        raise SystemExit(f"event {index} is not container-scoped: {event['type']!r}")
    if event["service"] != "api":
        raise SystemExit(f"selected-service filter leaked service {event['service']!r}")
    attributes = event.get("attributes") or {}
    for key in attributes:
        if key.startswith("com.docker.compose."):
            raise SystemExit(f"event {index} retained internal Compose label {key!r}")

if before_one_off != after_one_off:
    raise SystemExit(
        "one-off docker compose run emitted service events; "
        f"line count changed from {before_one_off} to {after_one_off}"
    )
PY
}

# Extract the first and last captured API event timestamps for replay filters.
event_time_window() {
    python3 - "$EVENTS_FILE" <<'PY'
import json
import sys

times = []
for line in open(sys.argv[1], encoding="utf-8"):
    if not line.strip():
        continue
    event = json.loads(line)
    if event.get("type") == "container" and event.get("service") == "api":
        times.append(event["time"])

if not times:
    raise SystemExit("no API container events captured for time-filter replay")

print(times[0])
print(times[-1])
PY
}

# Run a Docker Compose event replay command with a bounded wait.
run_filtered_replay() {
    local since="$1"
    local until="$2"
    local replay_pid
    local deadline

    docker compose -p "$PROJECT_NAME" -f "$COMPOSE_FILE" events --json --since "$since" --until "$until" api >"$FILTERED_EVENTS_FILE" &
    replay_pid="$!"
    ((deadline = SECONDS + 30))

    while kill -0 "$replay_pid" >/dev/null 2>&1; do
        if ((SECONDS >= deadline)); then
            kill "$replay_pid" >/dev/null 2>&1 || true
            wait "$replay_pid" >/dev/null 2>&1 || true
            error 'timed out waiting for docker compose events --since/--until replay'
            return 1
        fi
        sleep 1
    done

    wait "$replay_pid"
}

# Validate that Docker Compose time-filtered replay keeps the same event shape.
validate_time_filtered_events() {
    python3 - "$FILTERED_EVENTS_FILE" <<'PY'
import json
import sys

events = []
for line in open(sys.argv[1], encoding="utf-8"):
    if not line.strip():
        continue
    events.append(json.loads(line))

if not events:
    raise SystemExit("no Docker Compose events were captured by --since/--until replay")

for index, event in enumerate(events, start=1):
    if event.get("type") != "container":
        raise SystemExit(f"replayed event {index} is not container-scoped: {event.get('type')!r}")
    if event.get("service") != "api":
        raise SystemExit(f"replayed selected-service filter leaked service {event.get('service')!r}")
PY
}

# Run the local-only Docker Compose V2 parity check.
main() {
    parse_args "$@"
    check_docker
    create_fixture
    trap cleanup EXIT

    start_events_watcher
    docker compose -p "$PROJECT_NAME" -f "$COMPOSE_FILE" up -d --force-recreate api db >/dev/null
    wait_for_api_event

    local before_one_off
    local after_one_off
    before_one_off="$(stable_event_count)"
    docker compose -p "$PROJECT_NAME" -f "$COMPOSE_FILE" run --rm api true >/dev/null
    sleep 3
    after_one_off="$(wc -l <"$EVENTS_FILE" | tr -d ' ')"

    stop_events_watcher
    validate_events "$before_one_off" "$after_one_off"
    local window
    local since
    local until
    window="$(event_time_window)"
    since="$(printf '%s\n' "$window" | sed -n '1p')"
    until="$(printf '%s\n' "$window" | sed -n '2p')"
    run_filtered_replay "$since" "$until"
    validate_time_filtered_events
    printf 'Docker Compose events parity check passed for project %s\n' "$PROJECT_NAME"
}

main "$@"
