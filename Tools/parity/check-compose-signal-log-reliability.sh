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
#   check-compose-signal-log-reliability.sh [options]
#
# OPTIONS:
#   --strict    Fail when Docker Compose V2, Docker Engine, or container-compose is unavailable.
#   -h, --help  Show this help.
#
# ENVIRONMENT:
#   CONTAINER_COMPOSE       Path to the container-compose binary. Defaults to
#                           the local SwiftPM debug build at .build/debug/compose.
#   CONTAINER_COMPOSE_CONTAINER
#                           Runtime CLI used for matching live macOS validation.
#                           Defaults to container from PATH.
#   CONTAINER_COMPOSE_LIVE  Set to 1 when an isolated matching Apple runtime is
#                           running. The check then runs the same committed
#                           signal and logging fixture through container-compose.
#   DOCKER_COMPOSE          Docker Compose command to compare with. Defaults to
#                           "docker compose" when available, otherwise docker-compose.
#
# This local parity check proves foreground attach signal delivery, complete
# backward log tails across 1024-byte read boundaries, and persistent log
# capture after an attached client disconnects against Docker Compose V2.

set -euo pipefail

readonly SELF_PATH="${BASH_SOURCE[0]:-$0}"
SCRIPT_NAME="$(basename "$SELF_PATH")"
readonly SCRIPT_NAME
REPO_ROOT="$(cd "$(dirname "$SELF_PATH")/../.." && pwd)"
readonly REPO_ROOT
readonly FIXTURE_DIR="$REPO_ROOT/Tools/parity/fixtures/signal-log-reliability"
readonly COMPOSE_FILE="$FIXTURE_DIR/compose.yaml"

STRICT=0
CONTAINER_COMPOSE="${CONTAINER_COMPOSE:-$REPO_ROOT/.build/debug/compose}"
CONTAINER_BINARY="${CONTAINER_COMPOSE_CONTAINER:-container}"
CONTAINER_COMPOSE_LIVE="${CONTAINER_COMPOSE_LIVE:-0}"
DOCKER_COMPOSE_COMMAND=()
DOCKER_PROJECT="cc-sl-d-$RANDOM-$$"
CONTAINER_PROJECT="cc-sl-a-$RANDOM-$$"
ACTIVE_IMPLEMENTATION=""
ACTIVE_PROJECT=""
ATTACH_PROCESS_ID=""
ATTACH_INPUT_FD=""
ATTACH_EXIT=""
SERVICE_WAIT_PROCESS_ID=""
SERVICE_WAIT_OUTPUT=""
SERVICE_EXIT=""
WORK_DIR=""

# Writes an informational message to stdout.
info() {
    printf '%s\n' "$*"
}

# Writes a warning message to stderr.
warning() {
    printf 'warning: %s\n' "$*" >&2
}

# Writes an error message to stderr.
error() {
    printf 'error: %s\n' "$*" >&2
}

# Renders usage from the maintained header.
usage() {
    sed -n '/^# USAGE:/,/^# This local parity/ { /^# This local parity/d; s/^# //; s/^#//; p; }' "$SELF_PATH" \
        | sed "s/check-compose-signal-log-reliability.sh/$SCRIPT_NAME/"
}

# Parses supported command-line options.
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

# Converts a missing prerequisite into a skip or strict failure.
skip_or_fail() {
    local message="$1"

    if ((STRICT == 1)); then
        error "$message"
        return 1
    fi

    warning "$message; skipping signal/log reliability parity check"
    exit 0
}

# Selects an available Docker Compose V2 command.
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

# Verifies the tools and committed fixture required by the parity run.
check_tools() {
    command -v python3 >/dev/null 2>&1 || skip_or_fail 'python3 is not available'
    command -v docker >/dev/null 2>&1 || skip_or_fail 'docker is not available'
    docker info >/dev/null 2>&1 || skip_or_fail 'Docker Engine is not available'
    [[ -x "$CONTAINER_COMPOSE" ]] || skip_or_fail "container-compose binary is not executable: $CONTAINER_COMPOSE"
    [[ -f "$COMPOSE_FILE" ]] || { error "missing signal/log fixture: $COMPOSE_FILE"; return 1; }
}

# Creates an invocation-private directory for captured output.
prepare_work_dir() {
    WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/container-compose-signal-log.XXXXXX")"
    mkfifo "$WORK_DIR/attach-input"
    exec {ATTACH_INPUT_FD}<>"$WORK_DIR/attach-input"
}

# Runs the active implementation against the committed fixture.
compose() {
    if [[ "$ACTIVE_IMPLEMENTATION" == "docker" ]]; then
        "${DOCKER_COMPOSE_COMMAND[@]}" \
            --ansi never \
            --project-directory "$FIXTURE_DIR" \
            --project-name "$ACTIVE_PROJECT" \
            --file "$COMPOSE_FILE" \
            "$@"
        return
    fi

    env CONTAINER_BIN="$CONTAINER_BINARY" CONTAINER_COMPOSE_CONTAINER="$CONTAINER_BINARY" \
        "$CONTAINER_COMPOSE" \
        --ansi never \
        --project-directory "$FIXTURE_DIR" \
        --project-name "$ACTIVE_PROJECT" \
        --file "$COMPOSE_FILE" \
        "$@"
}

# Starts an attach client as a directly signalable child process.
start_attach() {
    local signal_proxy="$1"
    local output_file="$2"
    local service="$3"

    if [[ "$ACTIVE_IMPLEMENTATION" == "docker" ]]; then
        "${DOCKER_COMPOSE_COMMAND[@]}" \
            --ansi never \
            --project-directory "$FIXTURE_DIR" \
            --project-name "$ACTIVE_PROJECT" \
            --file "$COMPOSE_FILE" \
            attach "--sig-proxy=$signal_proxy" "$service" <&"$ATTACH_INPUT_FD" >"$output_file" 2>&1 &
    else
        env CONTAINER_BIN="$CONTAINER_BINARY" CONTAINER_COMPOSE_CONTAINER="$CONTAINER_BINARY" \
            "$CONTAINER_COMPOSE" \
            --ansi never \
            --project-directory "$FIXTURE_DIR" \
            --project-name "$ACTIVE_PROJECT" \
            --file "$COMPOSE_FILE" \
            attach "--sig-proxy=$signal_proxy" "$service" <&"$ATTACH_INPUT_FD" >"$output_file" 2>&1 &
    fi
    ATTACH_PROCESS_ID=$!
}

# Resolves the leaf attach client below wrapper and plugin processes.
attach_leaf_process_id() {
    local leaf="$ATTACH_PROCESS_ID"
    local child
    local _depth

    for _depth in {1..8}; do
        child="$(pgrep -P "$leaf" | sed -n '1p' || true)"
        if [[ -z "$child" ]]; then
            break
        fi
        leaf="$child"
    done
    printf '%s\n' "$leaf"
}

# Sends one signal directly to the attach client that owns signal proxying.
signal_attach() {
    local signal_name="$1"
    local leaf

    leaf="$(attach_leaf_process_id)"
    kill "-$signal_name" "$leaf"
}

# Terminates an attach process tree without widening cleanup scope.
terminate_attach() {
    local -a process_ids=()
    local process_id
    local child
    local index

    [[ -n "$ATTACH_PROCESS_ID" ]] || return
    ATTACH_EXIT=""
    process_ids=("$ATTACH_PROCESS_ID")
    for ((index = 0; index < ${#process_ids[@]}; index++)); do
        process_id="${process_ids[$index]}"
        while IFS= read -r child; do
            [[ -n "$child" ]] && process_ids+=("$child")
        done < <(pgrep -P "$process_id" || true)
    done
    for ((index = ${#process_ids[@]} - 1; index >= 0; index--)); do
        kill -KILL "${process_ids[$index]}" >/dev/null 2>&1 || true
    done
    wait_for_attach_exit 20
    set +e
    wait "$ATTACH_PROCESS_ID" >/dev/null 2>&1
    ATTACH_EXIT=$?
    set -e
    ATTACH_PROCESS_ID=""
}

# Waits for a captured output file to contain one marker.
wait_for_pattern() {
    local file="$1"
    local pattern="$2"
    local _attempt

    for _attempt in {1..200}; do
        if [[ -f "$file" ]] && grep -Fq "$pattern" "$file"; then
            return
        fi
        sleep 0.1
    done

    error "$ACTIVE_IMPLEMENTATION output did not contain '$pattern'"
    if [[ -f "$file" ]]; then
        sed -n '1,160p' "$file" >&2
    fi
    return 1
}

# Waits for the active attach child to exit.
wait_for_attach_exit() {
    local maximum_attempts="${1:-100}"
    local process_state
    local _attempt

    for ((_attempt = 1; _attempt <= maximum_attempts; _attempt++)); do
        if ! kill -0 "$ATTACH_PROCESS_ID" >/dev/null 2>&1; then
            return
        fi
        process_state="$(ps -o state= -p "$ATTACH_PROCESS_ID" 2>/dev/null | tr -d '[:space:]' || true)"
        if [[ -z "$process_state" || "$process_state" == Z* ]]; then
            return
        fi
        sleep 0.1
    done

    error "$ACTIVE_IMPLEMENTATION attach process did not exit"
    return 1
}

# Reads current service logs into a file until a marker appears.
wait_for_service_log() {
    local service="$1"
    local pattern="$2"
    local output_file="$3"
    local _attempt

    for _attempt in {1..200}; do
        compose logs --no-color --no-log-prefix "$service" >"$output_file" 2>/dev/null || true
        if grep -Fq "$pattern" "$output_file"; then
            return
        fi
        sleep 0.1
    done

    error "$ACTIVE_IMPLEMENTATION service '$service' did not log '$pattern'"
    sed -n '1,160p' "$output_file" >&2
    return 1
}

# Starts an Apple-runtime wait before a service exits so the live process wait
# result, rather than a later container snapshot, supplies its exit code.
start_service_exit_observer() {
    local service="$1"

    SERVICE_WAIT_PROCESS_ID=""
    SERVICE_WAIT_OUTPUT=""
    if [[ "$ACTIVE_IMPLEMENTATION" != "container" ]]; then
        return
    fi

    SERVICE_WAIT_OUTPUT="$WORK_DIR/$ACTIVE_IMPLEMENTATION-$service-wait.log"
    compose wait "$service" >"$SERVICE_WAIT_OUTPUT" 2>"$SERVICE_WAIT_OUTPUT.stderr" &
    SERVICE_WAIT_PROCESS_ID=$!
    sleep 0.5
    if ! kill -0 "$SERVICE_WAIT_PROCESS_ID" >/dev/null 2>&1; then
        error "$ACTIVE_IMPLEMENTATION service '$service' exit observer stopped before the workload"
        sed -n '1,160p' "$SERVICE_WAIT_OUTPUT.stderr" >&2
        return 1
    fi
}

# Waits for one service to expose a terminal exit code.
wait_for_service_exit() {
    local service="$1"
    local output_file="$WORK_DIR/$ACTIVE_IMPLEMENTATION-$service-ps.json"
    local service_exit
    local _attempt

    SERVICE_EXIT=""
    if [[ "$ACTIVE_IMPLEMENTATION" == "container" ]]; then
        if [[ -z "$SERVICE_WAIT_PROCESS_ID" || -z "$SERVICE_WAIT_OUTPUT" ]]; then
            error "$ACTIVE_IMPLEMENTATION service '$service' has no active exit observer"
            return 1
        fi
        for _attempt in {1..100}; do
            if ! kill -0 "$SERVICE_WAIT_PROCESS_ID" >/dev/null 2>&1; then
                set +e
                wait "$SERVICE_WAIT_PROCESS_ID"
                local observer_exit=$?
                set -e
                SERVICE_WAIT_PROCESS_ID=""
                if ((observer_exit != 0)); then
                    error "$ACTIVE_IMPLEMENTATION service '$service' exit observer failed with status $observer_exit"
                    sed -n '1,160p' "$SERVICE_WAIT_OUTPUT.stderr" >&2
                    return 1
                fi
                service_exit="$(sed -n '/^[0-9][0-9]*$/p' "$SERVICE_WAIT_OUTPUT" | tail -n 1)"
                if [[ "$service_exit" =~ ^[0-9]+$ ]]; then
                    SERVICE_EXIT="$service_exit"
                    return
                fi
                error "$ACTIVE_IMPLEMENTATION service '$service' exit observer produced no exit code"
                sed -n '1,160p' "$SERVICE_WAIT_OUTPUT" >&2
                return 1
            fi
            sleep 0.1
        done
        error "$ACTIVE_IMPLEMENTATION service '$service' exit observer did not finish"
        return 1
    fi

    for _attempt in {1..100}; do
        compose ps --all --format json "$service" >"$output_file" 2>/dev/null || true
        service_exit="$(python3 - "$service" "$output_file" <<'PY'
import json
import pathlib
import sys

service, output_path = sys.argv[1:3]
text = pathlib.Path(output_path).read_text(encoding="utf-8").strip()
if not text:
    raise SystemExit(1)
records = json.loads(text) if text.startswith("[") else [
    json.loads(line) for line in text.splitlines() if line.strip()
]
for record in records:
    if record.get("Service") == service and str(record.get("State", "")).lower() in {"exited", "stopped"}:
        print(record.get("ExitCode"))
        raise SystemExit
raise SystemExit(1)
PY
        )" || true
        if [[ "$service_exit" =~ ^[0-9]+$ ]]; then
            SERVICE_EXIT="$service_exit"
            return
        fi
        sleep 0.1
    done

    error "$ACTIVE_IMPLEMENTATION service '$service' did not expose a terminal exit code"
    sed -n '1,160p' "$output_file" >&2
    return 1
}

# Verifies exact long-tail bytes for one implementation.
check_log_tails() {
    local single_output="$WORK_DIR/$ACTIVE_IMPLEMENTATION-tail-single.log"
    local multiple_output="$WORK_DIR/$ACTIVE_IMPLEMENTATION-tail-multiple.log"

    compose up --detach tail-single tail-multiple >/dev/null
    wait_for_service_log tail-single "END" "$single_output"
    wait_for_service_log tail-multiple "CCCCCCCC" "$multiple_output"
    compose logs --no-color --no-log-prefix --tail 1 tail-single >"$single_output"
    compose logs --no-color --no-log-prefix --tail 2 tail-multiple >"$multiple_output"

    python3 - "$ACTIVE_IMPLEMENTATION" "$single_output" "$multiple_output" <<'PY'
import pathlib
import sys

implementation, single_path, multiple_path = sys.argv[1:4]
single = pathlib.Path(single_path).read_bytes()
multiple = pathlib.Path(multiple_path).read_bytes()
expected_single = b"START" + (b"X" * 3000) + b"END\n"
expected_multiple = (b"B" * 800) + b"\n" + (b"C" * 800) + b"\n"
if single != expected_single:
    raise SystemExit(
        f"{implementation}: single-line tail length {len(single)}, want {len(expected_single)}"
    )
if multiple != expected_multiple:
    raise SystemExit(
        f"{implementation}: multi-line tail length {len(multiple)}, want {len(expected_multiple)}"
    )
PY
}

# Proves a foreground attach signal reaches the Linux init process.
check_attach_signal() {
    local attach_output="$WORK_DIR/$ACTIVE_IMPLEMENTATION-signal-attach.log"
    local service_output="$WORK_DIR/$ACTIVE_IMPLEMENTATION-signal-service.log"
    local attach_exit
    local service_exit

    compose up --detach signal >/dev/null
    start_service_exit_observer signal
    start_attach true "$attach_output" signal
    wait_for_pattern "$attach_output" "SIGNAL:READY"
    signal_attach INT
    wait_for_service_log signal "SIGNAL:INT" "$service_output"
    wait_for_attach_exit
    set +e
    wait "$ATTACH_PROCESS_ID"
    attach_exit=$?
    set -e
    wait_for_service_exit signal
    service_exit="$SERVICE_EXIT"

    if ((service_exit != 42)); then
        error "$ACTIVE_IMPLEMENTATION signal service exited $service_exit, expected 42"
        return 1
    fi
    info "$ACTIVE_IMPLEMENTATION signal forwarding passed (attach exit $attach_exit, service exit $service_exit)"
}

# Proves persistent logs survive an attached-client failure.
check_disconnected_client_logging() {
    local attach_output="$WORK_DIR/$ACTIVE_IMPLEMENTATION-disconnect-attach.log"
    local service_output="$WORK_DIR/$ACTIVE_IMPLEMENTATION-disconnect-service.log"
    local attach_exit
    local service_exit

    compose up --detach disconnect >/dev/null
    start_service_exit_observer disconnect
    start_attach false "$attach_output" disconnect
    wait_for_pattern "$attach_output" "STREAM:BEFORE"
    terminate_attach
    attach_exit="$ATTACH_EXIT"
    compose logs --no-color --no-log-prefix disconnect >"$service_output"
    if grep -Fq "STREAM:AFTER" "$service_output"; then
        error "$ACTIVE_IMPLEMENTATION service emitted its second record before the attach client exited"
        return 1
    fi
    wait_for_service_log disconnect "STREAM:AFTER" "$service_output"
    wait_for_service_exit disconnect
    service_exit="$SERVICE_EXIT"

    if ((service_exit != 0)); then
        error "$ACTIVE_IMPLEMENTATION disconnect service exited $service_exit, expected 0"
        return 1
    fi
    compose logs --no-color --no-log-prefix disconnect >"$service_output"
    python3 - "$ACTIVE_IMPLEMENTATION" "$service_output" <<'PY'
import pathlib
import sys

implementation, output_path = sys.argv[1:3]
actual = pathlib.Path(output_path).read_bytes()
expected = b"STREAM:BEFORE\nSTREAM:AFTER\n"
if actual != expected:
    raise SystemExit(f"{implementation}: persistent log after disconnect = {actual!r}")
PY
    info "$ACTIVE_IMPLEMENTATION disconnected-client logging passed (attach exit $attach_exit)"
}

# Exercises all reliability scenarios for one implementation.
check_runtime() {
    ACTIVE_IMPLEMENTATION="$1"
    ACTIVE_PROJECT="$2"

    check_log_tails
    check_attach_signal
    check_disconnected_client_logging
}

# Removes only the projects and temporary files created by this invocation.
cleanup() {
    local implementation

    if [[ -n "$ATTACH_PROCESS_ID" ]] && kill -0 "$ATTACH_PROCESS_ID" >/dev/null 2>&1; then
        terminate_attach
    fi
    if [[ -n "$SERVICE_WAIT_PROCESS_ID" ]] && kill -0 "$SERVICE_WAIT_PROCESS_ID" >/dev/null 2>&1; then
        kill -KILL "$SERVICE_WAIT_PROCESS_ID" >/dev/null 2>&1 || true
        wait "$SERVICE_WAIT_PROCESS_ID" >/dev/null 2>&1 || true
    fi

    for implementation in docker container; do
        if [[ "$implementation" == "docker" ]]; then
            ACTIVE_PROJECT="$DOCKER_PROJECT"
        else
            [[ "$CONTAINER_COMPOSE_LIVE" == "1" ]] || continue
            ACTIVE_PROJECT="$CONTAINER_PROJECT"
        fi
        ACTIVE_IMPLEMENTATION="$implementation"
        compose down --volumes --remove-orphans >/dev/null 2>&1 || true
    done

    if [[ -n "$WORK_DIR" ]]; then
        if [[ -n "$ATTACH_INPUT_FD" ]]; then
            exec {ATTACH_INPUT_FD}>&-
        fi
        rm -rf "$WORK_DIR"
    fi
}

# Runs focused Compose adapter contracts for attach and logs.
check_unit_contracts() {
    env -u CONTAINER_BIN -u CONTAINER_COMPOSE_CONTAINER \
        swift test --disable-automatic-resolution \
        --filter 'ComposeOrchestratorTests/(attachInteractiveMode|attachOutputOnlyMode|logsPasses|logsAcceptsComposeAllTailValue)'
}

# Coordinates prerequisite, Docker, optional Apple runtime, and unit validation.
main() {
    parse_args "$@"
    detect_docker_compose
    check_tools
    prepare_work_dir
    trap cleanup EXIT

    check_runtime docker "$DOCKER_PROJECT"
    if [[ "$CONTAINER_COMPOSE_LIVE" == "1" ]]; then
        if [[ ! -x "$CONTAINER_BINARY" ]] && ! command -v "$CONTAINER_BINARY" >/dev/null 2>&1; then
            error "matching Apple runtime binary is unavailable: $CONTAINER_BINARY"
            return 1
        fi
        "$CONTAINER_BINARY" system status >/dev/null
        check_runtime container "$CONTAINER_PROJECT"
    else
        info 'live Apple runtime validation not requested; Docker Compose V2 reference passed'
    fi
    check_unit_contracts

    info 'Docker Compose V2 and container-compose signal/log reliability parity passed.'
}

main "$@"
