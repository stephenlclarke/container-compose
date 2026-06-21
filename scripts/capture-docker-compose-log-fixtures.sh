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
#   capture-docker-compose-log-fixtures.sh [options]
#
# OPTIONS:
#   --compose-file PATH   Compose file to run. Defaults to examples/logging/compose.yml.
#   --expected PATH       Expected fixture file to compare or update.
#   --update              Replace the expected fixture with the current Docker output.
#   --strict              Fail when Docker, Compose, or the daemon is unavailable.
#   -h, --help            Show this help.
#
# The script is intentionally optional for CI. It compares Docker Compose's
# rotated log tail behavior when a local Docker daemon is available, and skips
# cleanly otherwise unless --strict is supplied.

set -euo pipefail

readonly SELF_PATH="${BASH_SOURCE[0]:-$0}"
SCRIPT_NAME="$(basename "$SELF_PATH")"
readonly SCRIPT_NAME
readonly PROJECT_NAME="container-compose-log-fixture-$$"

REPO_ROOT=""
COMPOSE_FILE=""
EXPECTED_FILE=""
ACTUAL_FILE=""
UPDATE=0
STRICT=0
COMPOSE_COMMAND=()

# Print an informational message to stdout.
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
    sed -n '/^# USAGE:/,/^# The script/ { /^# The script/d; s/^# //; s/^#//; p; }' "$SELF_PATH" | sed "s/capture-docker-compose-log-fixtures.sh/$SCRIPT_NAME/"
}

# Parse command-line flags.
parse_args() {
    while (($# > 0)); do
        case "$1" in
            --compose-file)
                if (($# < 2)); then
                    error '--compose-file requires a path'
                    usage >&2
                    return 2
                fi
                COMPOSE_FILE="$2"
                shift 2
                ;;
            --expected)
                if (($# < 2)); then
                    error '--expected requires a path'
                    usage >&2
                    return 2
                fi
                EXPECTED_FILE="$2"
                shift 2
                ;;
            --update)
                UPDATE=1
                shift
                ;;
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

    warning "$message; skipping Docker Compose log fixture comparison"
    exit 0
}

# Locate the repository root and default fixture paths.
initialize_paths() {
    REPO_ROOT="$(git rev-parse --show-toplevel)"

    if [[ -z "$COMPOSE_FILE" ]]; then
        COMPOSE_FILE="$REPO_ROOT/examples/logging/compose.yml"
    fi

    if [[ -z "$EXPECTED_FILE" ]]; then
        EXPECTED_FILE="$REPO_ROOT/Tests/ComposeCoreTests/Fixtures/logging/docker-compose-rotated-tail.expected"
    fi
}

# Select docker compose or the standalone docker-compose command.
detect_compose_command() {
    if docker compose version >/dev/null 2>&1; then
        COMPOSE_COMMAND=(docker compose)
        return 0
    fi

    if command -v docker-compose >/dev/null 2>&1 && docker-compose version >/dev/null 2>&1; then
        COMPOSE_COMMAND=(docker-compose)
        return 0
    fi

    skip_or_fail 'Docker Compose is not available'
}

# Check whether the Docker daemon can service API requests.
check_docker_daemon() {
    if docker info >/dev/null 2>&1; then
        return 0
    fi

    skip_or_fail 'Docker daemon is not available'
}

# Clean up the temporary Docker Compose project.
cleanup_project() {
    if ((${#COMPOSE_COMMAND[@]} == 0)); then
        return 0
    fi

    "${COMPOSE_COMMAND[@]}" -p "$PROJECT_NAME" -f "$COMPOSE_FILE" down --volumes --remove-orphans >/dev/null 2>&1 || true
}

# Remove temporary local files and Docker resources.
cleanup() {
    if [[ -n "$ACTUAL_FILE" ]]; then
        rm -f "$ACTUAL_FILE"
    fi

    cleanup_project
}

# Start the rotating fixture services.
start_rotating_services() {
    "${COMPOSE_COMMAND[@]}" -p "$PROJECT_NAME" -f "$COMPOSE_FILE" up -d --force-recreate rotating-json rotating-local >/dev/null
}

# Wait for short-lived fixture services to exit without using docker wait.
wait_for_services() {
    local deadline
    local ids
    local running
    local state

    ((deadline = SECONDS + 60))

    while true; do
        ids="$("${COMPOSE_COMMAND[@]}" -p "$PROJECT_NAME" -f "$COMPOSE_FILE" ps -q rotating-json rotating-local)"
        running=0

        while IFS= read -r id; do
            if [[ -z "$id" ]]; then
                continue
            fi

            state="$(docker inspect -f '{{.State.Running}}' "$id")"
            if [[ "$state" == "true" ]]; then
                running=1
            fi
        done <<< "$ids"

        if ((running == 0)); then
            return 0
        fi

        if ((SECONDS >= deadline)); then
            error 'timed out waiting for rotating log fixture services'
            return 1
        fi

        sleep 0.25
    done
}

# Write a fixture section for one service and tail argument.
write_tail_section() {
    local service="$1"
    local tail_arg="$2"
    local label="$3"
    local output_file="$4"
    local line_count

    "${COMPOSE_COMMAND[@]}" -p "$PROJECT_NAME" -f "$COMPOSE_FILE" logs --no-color --no-log-prefix --tail "$tail_arg" "$service" > "$output_file"
    line_count="$(wc -l < "$output_file" | tr -d '[:space:]')"

    printf '## %s --tail %s\n' "$service" "$label"
    printf 'line-count: %s\n' "$line_count"
    if [[ "$tail_arg" == "5" || "$tail_arg" == "0" ]]; then
        printf 'lines:\n'
        cat "$output_file"
    else
        printf 'last-lines:\n'
        tail -n 5 "$output_file"
    fi
    printf '\n'
}

# Capture the current Docker Compose rotated-tail behavior.
capture_fixture() {
    local actual_file="$1"
    local output_file

    output_file="$(mktemp)"
    {
        printf '# Docker Compose rotated log tail fixture\n'
        printf '#\n'
        printf '# Captured from examples/logging/compose.yml with Docker Engine %s and\n' "$(docker version --format '{{.Server.Version}}')"
        printf '# Docker Compose %s. The fixture records logical-line behavior for\n' "$("${COMPOSE_COMMAND[@]}" version --short)"
        printf '# docker-compose logs --no-color --no-log-prefix over retained rotated logs.\n'
        printf "# Driver retention counts differ because Docker's json-file and local drivers\n"
        printf '# use different on-disk formats, but --tail remains line-based per service.\n'
        printf '\n'

        write_tail_section rotating-json 5 5 "$output_file"
        write_tail_section rotating-json 0 0 "$output_file"
        write_tail_section rotating-json -1 -1 "$output_file"
        write_tail_section rotating-json all all "$output_file"
        write_tail_section rotating-local 5 5 "$output_file"
        write_tail_section rotating-local 0 0 "$output_file"
        write_tail_section rotating-local -1 -1 "$output_file"
        write_tail_section rotating-local all all "$output_file"
    } > "$actual_file"

    rm -f "$output_file"
}

# Compare or update the expected fixture file.
compare_or_update_fixture() {
    local actual_file="$1"

    if ((UPDATE == 1)); then
        mkdir -p "$(dirname "$EXPECTED_FILE")"
        cp "$actual_file" "$EXPECTED_FILE"
        info "updated $EXPECTED_FILE"
        return 0
    fi

    diff -u "$EXPECTED_FILE" "$actual_file"
}

# Run the fixture comparison workflow.
main() {
    parse_args "$@"
    initialize_paths
    detect_compose_command || return $?
    check_docker_daemon || return $?

    ACTUAL_FILE="$(mktemp)"
    trap cleanup EXIT

    start_rotating_services
    wait_for_services
    capture_fixture "$ACTUAL_FILE"
    compare_or_update_fixture "$ACTUAL_FILE"
}

main "$@"
