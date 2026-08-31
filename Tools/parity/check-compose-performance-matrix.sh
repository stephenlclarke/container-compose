#!/usr/bin/env bash
#===----------------------------------------------------------------------===#
# Copyright © 2026 container-compose project authors.
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
# http://www.apache.org/licenses/LICENSE-2.0
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#===----------------------------------------------------------------------===#

#
# USAGE:
#   check-compose-performance-matrix.sh [options]
#
# OPTIONS:
#   --strict         Fail when a required local runtime is unavailable.
#   --list-fixtures  Print the selected fixture identifiers without running.
#   --finalize-only  Render evidence already recorded by checkpointed runs.
#   -h, --help       Show this help.
#
# ENVIRONMENT:
#   CONTAINER_COMPOSE            Local container-compose binary.
#   CONTAINER_COMPOSE_CONTAINER  Matching Apple container CLI.
#   DOCKER_COMPOSE               Docker Compose command to compare with.
#   PARITY_EVIDENCE_DIR          Raw samples, JUnit, fingerprints, and matrix.
#   PARITY_WORK_ROOT             Local fixture root (default: .build/parity).
#   PARITY_INIT_IMAGE_ARCHIVE    Exact guest OCI archive used by the runtime.
#   PARITY_INIT_IMAGE_REFERENCES Space-separated immutable guest references.
#   PARITY_REPETITIONS           Timed repetitions per lane (default: 5).
#   PARITY_FIXTURE_GROUPS        Comma-separated fixture groups or `all`.
#                                Groups: lifecycle, logging-stream,
#                                logging-file, logging-read, logging-aggregate.
#   PARITY_EVIDENCE_MODE         `reset` starts new evidence; `append` adds a
#                                checkpoint to existing evidence (default:
#                                reset).
#   PARITY_FINALIZE_EVIDENCE     Render the matrix after timing (default: 1).
#   PARITY_TIMEOUT_SECONDS       Per-operation timeout (default: 300).
#   PARITY_TIMING_MAX_RATIO      Candidate median/P95 limit (default: 10).
#   PARITY_TIMING_POLICY         `enforce` fails the ratio guard; `record`
#                                records regressions without making a
#                                published-version comparison a release gate.
#                                Default: enforce.
#   PARITY_COMPARABLE_NOISE_PCT  Comparable-performance noise band (default: 5).
#   PARITY_SINK_STALL_SECONDS    Host slow-sink pause (default: 2).
#   PARITY_PRESSURE_RECORDS      Records in pressure workloads (default: 65536).
#   PARITY_INCLUDE_REMOTE_LOGGING
#                                Include cross-VM remote-sink lanes (default: 1).
#                                Set to 0 for unattended, approval-free runs.
#   PARITY_SINK_BIND_ADDRESS     Host address for the remote logging sink
#                                (default: 127.0.0.1). Cross-VM Docker probes
#                                must explicitly opt into a reachable address.
#   PARITY_DOCKER_HOST_ADDRESS   Host address visible to Docker (default:
#                                host.docker.internal).
#   PARITY_CONTAINER_HOST_ADDRESS
#                                Host address used by Container providers
#                                (default: 127.0.0.1).
#
# This local-only comparator records warm-image same-host evidence for the
# representative lifecycle and logging lanes. It covers detached 1/10/50-
# service startup/teardown, startup to first log, fixed stdout/stderr/mixed
# throughput, 16 KiB and 1 MiB records, local/compressed rotation,
# tail/since/until/follow, and 1/10/50-service foreground aggregation. When
# PARITY_INCLUDE_REMOTE_LOGGING=1, it also covers blocking and non-blocking
# remote sinks and dual-cache delivery/read. It reports median/P95, keeps the
# established 10x regression guard, and separately records whether both
# candidate statistics are comparable to or better than Docker outside the
# configured noise band. Cold runtime resets, resource collectors, develop
# sync, and build-context transfer remain release-scheduler lanes.

set -euo pipefail

readonly SELF_PATH="${BASH_SOURCE[0]:-$0}"
SCRIPT_NAME="$(basename "$SELF_PATH")"
readonly SCRIPT_NAME
REPO_ROOT="$(cd "$(dirname "$SELF_PATH")/../.." && pwd)"
readonly REPO_ROOT
STRICT=0
LIST_FIXTURES=0
FINALIZE_ONLY=0
FIXTURE_DIR=""
CONTAINER_COMPOSE="${CONTAINER_COMPOSE:-$REPO_ROOT/.build/debug/compose}"
CONTAINER_BINARY="${CONTAINER_COMPOSE_CONTAINER:-container}"
PARITY_EVIDENCE_DIR="${PARITY_EVIDENCE_DIR:-$REPO_ROOT/.build/parity/performance-matrix}"
PARITY_WORK_ROOT="${PARITY_WORK_ROOT:-$REPO_ROOT/.build/parity}"
PARITY_INIT_IMAGE_ARCHIVE="${PARITY_INIT_IMAGE_ARCHIVE:-}"
PARITY_INIT_IMAGE_REFERENCES="${PARITY_INIT_IMAGE_REFERENCES:-}"
PARITY_REPETITIONS="${PARITY_REPETITIONS:-5}"
PARITY_FIXTURE_GROUPS="${PARITY_FIXTURE_GROUPS-all}"
PARITY_EVIDENCE_MODE="${PARITY_EVIDENCE_MODE:-reset}"
PARITY_FINALIZE_EVIDENCE="${PARITY_FINALIZE_EVIDENCE:-1}"
PARITY_TIMEOUT_SECONDS="${PARITY_TIMEOUT_SECONDS:-300}"
PARITY_TIMING_MAX_RATIO="${PARITY_TIMING_MAX_RATIO:-10}"
PARITY_TIMING_POLICY="${PARITY_TIMING_POLICY:-enforce}"
PARITY_COMPARABLE_NOISE_PCT="${PARITY_COMPARABLE_NOISE_PCT:-5}"
PARITY_SINK_STALL_SECONDS="${PARITY_SINK_STALL_SECONDS:-2}"
PARITY_PRESSURE_RECORDS="${PARITY_PRESSURE_RECORDS:-65536}"
PARITY_INCLUDE_REMOTE_LOGGING="${PARITY_INCLUDE_REMOTE_LOGGING:-1}"
PARITY_SINK_BIND_ADDRESS="${PARITY_SINK_BIND_ADDRESS:-127.0.0.1}"
PARITY_DOCKER_HOST_ADDRESS="${PARITY_DOCKER_HOST_ADDRESS:-host.docker.internal}"
PARITY_CONTAINER_HOST_ADDRESS="${PARITY_CONTAINER_HOST_ADDRESS:-127.0.0.1}"
readonly FIXTURE_IMAGE="alpine:3.20"
readonly LOGGING_SINK="$REPO_ROOT/Tools/parity/logging_performance_sink.py"
readonly TIMING_TSV="$PARITY_EVIDENCE_DIR/timings.tsv"
readonly TIMING_JUNIT="$PARITY_EVIDENCE_DIR/timings.junit.xml"
readonly TIMING_MATRIX="$PARITY_EVIDENCE_DIR/timing-matrix.md"
readonly FINGERPRINT_JSON="$PARITY_EVIDENCE_DIR/fingerprints.json"
DOCKER_COMPOSE_COMMAND=()
ACTIVE_COMPOSE=()
LANE_ORDER=()
LANE_PREFIX=""
SINK_PID=""
SINK_PORT=""
SINK_PORT_FILE=""
SINK_RESULT_FILE=""
SINK_STOP_FILE=""
readonly LOGGING_WORKLOADS=(
    logging-throughput-stdout-small
    logging-throughput-stderr-small
    logging-throughput-mixed-small
    logging-throughput-stdout-16k
    logging-throughput-stdout-1m
)
readonly LOGGING_NONBLOCKING_BUFFERS=(64k 1m 4m)

# Return whether a named checkpoint group is selected.
group_enabled() {
    local group="$1"
    [[ ",$PARITY_FIXTURE_GROUPS," == *,all,* ]] ||
        [[ ",$PARITY_FIXTURE_GROUPS," == *,$group,* ]]
}

PERFORMANCE_FIXTURES=()
if group_enabled lifecycle; then
    PERFORMANCE_FIXTURES+=(
        startup-1-services teardown-1-services
        startup-10-services teardown-10-services
        startup-50-services teardown-50-services
    )
fi
if group_enabled logging-stream; then
    PERFORMANCE_FIXTURES+=(
        logging-startup-first-output
        logging-startup-first-output-attached
        "${LOGGING_WORKLOADS[@]}"
    )
    if [[ "$PARITY_INCLUDE_REMOTE_LOGGING" == 1 ]]; then
        PERFORMANCE_FIXTURES+=(
            logging-blocking-slow-sink
            logging-nonblocking-64k
            logging-nonblocking-1m
            logging-nonblocking-4m
        )
    fi
fi
if group_enabled logging-file; then
    PERFORMANCE_FIXTURES+=(
        logging-write-json-compression
        logging-write-local-rotation
    )
fi
if group_enabled logging-read; then
    PERFORMANCE_FIXTURES+=(
        logging-read-tail-10
        logging-read-tail-1000
        logging-read-all
        logging-read-since-until
        logging-follow-rotation
    )
    if [[ "$PARITY_INCLUDE_REMOTE_LOGGING" == 1 ]]; then
        PERFORMANCE_FIXTURES+=(
            logging-dual-cache-delivery
            logging-dual-cache-read
        )
    fi
fi
if group_enabled logging-aggregate; then
    PERFORMANCE_FIXTURES+=(
        logging-aggregate-1-services
        logging-aggregate-10-services
        logging-aggregate-50-services
    )
fi
readonly PERFORMANCE_FIXTURES

# Print a diagnostic error.
error() { printf 'error: %s\n' "$*" >&2; }

# Print a diagnostic warning.
warning() { printf 'warning: %s\n' "$*" >&2; }

# Print the embedded usage text.
usage() {
    sed -n '/^# USAGE:/,/^# This local-only/ { /^# This local-only/d; s/^# //; s/^#//; p; }' "$SELF_PATH" |
        sed "s/check-compose-performance-matrix.sh/$SCRIPT_NAME/"
}

# Parse command-line options.
parse_args() {
    while (($# > 0)); do
        case "$1" in
            --strict) STRICT=1 ;;
            --list-fixtures) LIST_FIXTURES=1 ;;
            --finalize-only) FINALIZE_ONLY=1 ;;
            -h | --help) usage; exit 0 ;;
            *) error "unknown argument: $1"; usage >&2; return 2 ;;
        esac
        shift
    done
}

# Validate controls shared by timing and finalize-only invocations.
validate_configuration() {
    local group
    [[ "$PARITY_REPETITIONS" =~ ^[1-9][0-9]*$ ]] || { error "PARITY_REPETITIONS must be a positive integer"; return 2; }
    [[ "$PARITY_TIMEOUT_SECONDS" =~ ^[1-9][0-9]*$ ]] || { error "PARITY_TIMEOUT_SECONDS must be a positive integer"; return 2; }
    [[ "$PARITY_TIMING_MAX_RATIO" =~ ^[1-9][0-9]*(\.[0-9]+)?$ ]] || { error "PARITY_TIMING_MAX_RATIO must be positive"; return 2; }
    [[ "$PARITY_TIMING_POLICY" == enforce || "$PARITY_TIMING_POLICY" == record ]] || { error "PARITY_TIMING_POLICY must be enforce or record"; return 2; }
    [[ "$PARITY_COMPARABLE_NOISE_PCT" =~ ^[0-9]+(\.[0-9]+)?$ ]] || { error "PARITY_COMPARABLE_NOISE_PCT must be zero or positive"; return 2; }
    [[ "$PARITY_SINK_STALL_SECONDS" =~ ^[0-9]+(\.[0-9]+)?$ ]] || { error "PARITY_SINK_STALL_SECONDS must be zero or positive"; return 2; }
    [[ "$PARITY_PRESSURE_RECORDS" =~ ^[1-9][0-9]*$ ]] || { error "PARITY_PRESSURE_RECORDS must be a positive integer"; return 2; }
    [[ "$PARITY_INCLUDE_REMOTE_LOGGING" == 0 || "$PARITY_INCLUDE_REMOTE_LOGGING" == 1 ]] || { error "PARITY_INCLUDE_REMOTE_LOGGING must be 0 or 1"; return 2; }
    [[ "$PARITY_EVIDENCE_MODE" == reset || "$PARITY_EVIDENCE_MODE" == append ]] || { error "PARITY_EVIDENCE_MODE must be reset or append"; return 2; }
    [[ "$PARITY_FINALIZE_EVIDENCE" == 0 || "$PARITY_FINALIZE_EVIDENCE" == 1 ]] || { error "PARITY_FINALIZE_EVIDENCE must be 0 or 1"; return 2; }
    [[ -n "$PARITY_FIXTURE_GROUPS" ]] || { error "PARITY_FIXTURE_GROUPS must not be empty"; return 2; }
    IFS=',' read -r -a groups <<<"$PARITY_FIXTURE_GROUPS"
    for group in "${groups[@]}"; do
        case "$group" in
            all | lifecycle | logging-stream | logging-file | logging-read | logging-aggregate) ;;
            *) error "unknown PARITY_FIXTURE_GROUPS entry: $group"; return 2 ;;
        esac
    done
    ((${#PERFORMANCE_FIXTURES[@]} > 0)) || { error "PARITY_FIXTURE_GROUPS selected no fixtures"; return 2; }
}

# Print the stable fixture inventory for focused harness validation.
list_fixtures() {
    printf '%s\n' "${PERFORMANCE_FIXTURES[@]}"
}

# Skip optional local work or fail a strict invocation.
skip_or_fail() {
    if ((STRICT == 1)); then error "$1"; return 1; fi
    warning "$1; skipping Compose performance matrix"
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
        skip_or_fail 'Docker Compose V2 is unavailable'
    fi
}

# Verify local dependencies and benchmark inputs.
check_tools() {
    validate_configuration
    detect_docker_compose
    docker info >/dev/null 2>&1 || skip_or_fail 'Docker Engine is unavailable'
    [[ -x "$CONTAINER_COMPOSE" ]] || skip_or_fail "container-compose binary is not executable: $CONTAINER_COMPOSE"
    command -v "$CONTAINER_BINARY" >/dev/null 2>&1 || skip_or_fail "container runtime is unavailable: $CONTAINER_BINARY"
    command -v python3 >/dev/null 2>&1 || skip_or_fail 'python3 is unavailable'
    [[ -x "$LOGGING_SINK" ]] || skip_or_fail "logging performance sink is not executable: $LOGGING_SINK"
    [[ "$PARITY_WORK_ROOT" == /* && "$PARITY_WORK_ROOT" != / ]] || { error "PARITY_WORK_ROOT must be an absolute non-root path"; return 2; }
    if { [[ -n "$PARITY_INIT_IMAGE_ARCHIVE" ]] && [[ -z "$PARITY_INIT_IMAGE_REFERENCES" ]]; } || \
        { [[ -z "$PARITY_INIT_IMAGE_ARCHIVE" ]] && [[ -n "$PARITY_INIT_IMAGE_REFERENCES" ]]; }; then
        error "PARITY_INIT_IMAGE_ARCHIVE and PARITY_INIT_IMAGE_REFERENCES must be set together"
        return 2
    fi
    if [[ -n "$PARITY_INIT_IMAGE_ARCHIVE" && ! -f "$PARITY_INIT_IMAGE_ARCHIVE" ]]; then
        error "PARITY_INIT_IMAGE_ARCHIVE does not exist: $PARITY_INIT_IMAGE_ARCHIVE"
        return 2
    fi
    if [[ "$PARITY_INCLUDE_REMOTE_LOGGING" == 1 && "$PARITY_SINK_BIND_ADDRESS" == "127.0.0.1" && "$PARITY_DOCKER_HOST_ADDRESS" != "127.0.0.1" ]]; then
        skip_or_fail 'Docker remote-logging probes require an explicit host-reachable PARITY_SINK_BIND_ADDRESS (for example 0.0.0.0); refusing to request local-network access implicitly'
    fi
}

# Remove generated projects and the local fixture directory.
cleanup() {
    local count
    stop_sink
    for count in 1 10 50; do
        "${DOCKER_COMPOSE_COMMAND[@]}" -p "cc-perf-d-$count" -f "$FIXTURE_DIR/services-$count.yml" down --volumes --remove-orphans >/dev/null 2>&1 || true
        "$CONTAINER_COMPOSE" --ansi never -p "cc-perf-c-$count" -f "$FIXTURE_DIR/services-$count.yml" down --volumes --remove-orphans >/dev/null 2>&1 || true
        "${DOCKER_COMPOSE_COMMAND[@]}" -p "cc-perf-d-aggregate-$count" -f "$FIXTURE_DIR/aggregate-$count.yml" down --volumes --remove-orphans >/dev/null 2>&1 || true
        "$CONTAINER_COMPOSE" --ansi never -p "cc-perf-c-aggregate-$count" -f "$FIXTURE_DIR/aggregate-$count.yml" down --volumes --remove-orphans >/dev/null 2>&1 || true
    done
    "${DOCKER_COMPOSE_COMMAND[@]}" -p cc-perf-d-logging -f "$FIXTURE_DIR/logging.yml" down --volumes --remove-orphans >/dev/null 2>&1 || true
    "$CONTAINER_COMPOSE" --ansi never -p cc-perf-c-logging -f "$FIXTURE_DIR/logging.yml" down --volumes --remove-orphans >/dev/null 2>&1 || true
    [[ -z "$FIXTURE_DIR" ]] || rm -rf "$FIXTURE_DIR"
}

# Write one otherwise-identical Compose project for each service count.
# Dollar expressions in the single-quoted templates are intentionally emitted
# for Compose or the guest shell rather than expanded by this harness.
# shellcheck disable=SC2016
create_fixtures() {
    local count index
    mkdir -p "$PARITY_WORK_ROOT"
    FIXTURE_DIR="$(mktemp -d "$PARITY_WORK_ROOT/performance-matrix.XXXXXX")"
    for count in 1 10 50; do
        {
            printf 'services:\n'
            for ((index = 1; index <= count; index++)); do
                printf '  worker%02d:\n    image: %s\n    command: ["sh", "-c", "sleep 600"]\n    stop_grace_period: 1s\n' "$index" "$FIXTURE_IMAGE"
            done
        } >"$FIXTURE_DIR/services-$count.yml"
        {
            printf 'services:\n'
            for ((index = 1; index <= count; index++)); do
                printf '  logger%02d:\n' "$index"
                printf '    image: %s\n' "$FIXTURE_IMAGE"
                printf '    command: ["sh", "-c", "index=0; while [ $$index -lt 64 ]; do printf '\''logger%02d-%%03d\\n'\'' $$index; index=$$((index + 1)); done"]\n' "$index"
                printf '    logging:\n      driver: json-file\n      options:\n        max-size: "8m"\n        max-file: "3"\n'
            done
        } >"$FIXTURE_DIR/aggregate-$count.yml"
    done
    {
        printf '%s\n' \
            'services:' \
            '  logger:' \
            "    image: $FIXTURE_IMAGE" \
            '    environment:' \
            '      LOG_WORKLOAD: ${LOG_WORKLOAD:-startup}' \
            '      LOG_RECORD_COUNT: ${LOG_RECORD_COUNT:-65536}' \
            '    command:' \
            '      - /bin/sh' \
            '      - -ec' \
            '      - |' \
            '        emit_bytes() {' \
            '          head -c "$$1" /dev/zero | tr '\''\000'\'' x' \
            '          printf '\''\n'\''' \
            '        }' \
            '        small_payload=xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx' \
            '        case "$${LOG_WORKLOAD}" in' \
            '          startup)' \
            '            printf '\''logging-ready\n'\''' \
            '            sleep 600' \
            '            ;;' \
            '          throughput-stdout-small)' \
            '            index=0; while [ "$$index" -lt 16384 ]; do printf '\''stdout-%06d %s\n'\'' "$$index" "$$small_payload"; index=$$((index + 1)); done' \
            '            ;;' \
            '          throughput-stderr-small)' \
            '            index=0; while [ "$$index" -lt 16384 ]; do printf '\''stderr-%06d %s\n'\'' "$$index" "$$small_payload" >&2; index=$$((index + 1)); done' \
            '            ;;' \
            '          throughput-mixed-small)' \
            '            index=0; while [ "$$index" -lt 8192 ]; do printf '\''stdout-%06d %s\n'\'' "$$index" "$$small_payload"; printf '\''stderr-%06d %s\n'\'' "$$index" "$$small_payload" >&2; index=$$((index + 1)); done' \
            '            ;;' \
            '          throughput-stdout-16k)' \
            '            index=0; while [ "$$index" -lt 256 ]; do emit_bytes 16383; index=$$((index + 1)); done' \
            '            ;;' \
            '          throughput-stdout-1m)' \
            '            index=0; while [ "$$index" -lt 4 ]; do emit_bytes 1048575; index=$$((index + 1)); done' \
            '            ;;' \
            '          history)' \
            '            index=0; while [ "$$index" -lt 10000 ]; do printf '\''stdout-%06d %s\n'\'' "$$index" "$$small_payload"; printf '\''stderr-%06d %s\n'\'' "$$index" "$$small_payload" >&2; index=$$((index + 1)); done' \
            '            ;;' \
            '          follow-rotation)' \
            '            printf '\''follow-ready\n'\''' \
            '            sleep 1' \
            '            index=0; while [ "$$index" -lt 4096 ]; do printf '\''follow-%06d xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx\n'\'' "$$index"; index=$$((index + 1)); done' \
            '            ;;' \
            '          pressure)' \
            '            index=0; while [ "$$index" -lt "$${LOG_RECORD_COUNT}" ]; do printf '\''perf-record-%06d %s\n'\'' "$$index" "$$small_payload"; index=$$((index + 1)); done' \
            '            if [ -n "$${LOG_COMPLETION_FILE:-}" ]; then printf complete >"/completion/$${LOG_COMPLETION_FILE}"; fi' \
            '            if [ "$${LOG_RETAIN_AFTER_COMPLETION:-0}" = 1 ]; then sleep 600; fi' \
            '            ;;' \
            '          history-window)' \
            '            printf '\''history-before\n'\''' \
            '            sleep 1' \
            '            index=0; while [ "$$index" -lt 100 ]; do printf '\''history-window-%03d\n'\'' "$$index"; index=$$((index + 1)); done' \
            '            sleep 1' \
            '            printf '\''history-after\n'\''' \
            '            ;;' \
            '          *)' \
            '            printf '\''unknown logging workload: %s\n'\'' "$${LOG_WORKLOAD}" >&2' \
            '            exit 64' \
            '            ;;' \
            '        esac'
    } >"$FIXTURE_DIR/logging-workload.yml"
    {
        printf '%s\n' \
            'services:' \
            '  logger:' \
            '    extends:' \
            '      file: logging-workload.yml' \
            '      service: logger' \
            '    logging:' \
            '      driver: json-file' \
            '      options:' \
            '        max-size: "${LOG_MAX_SIZE:-64m}"' \
            '        max-file: "3"'
    } >"$FIXTURE_DIR/logging.yml"
    {
        printf '%s\n' \
            'services:' \
            '  logger:' \
            '    extends:' \
            '      file: logging-workload.yml' \
            '      service: logger' \
            '    environment:' \
            '      LOG_COMPLETION_FILE: ${LOG_COMPLETION_FILE:?LOG_COMPLETION_FILE is required}' \
            '      LOG_RETAIN_AFTER_COMPLETION: "${LOG_RETAIN_AFTER_COMPLETION:-0}"' \
            '    volumes:' \
            '      - type: bind' \
            '        source: ${PERF_COMPLETION_DIR:?PERF_COMPLETION_DIR is required}' \
            '        target: /completion' \
            '    stop_grace_period: 1s' \
            '    logging:' \
            '      driver: json-file' \
            '      options:' \
            '        max-size: "4m"' \
            '        max-file: "20"' \
            '        compress: "true"'
    } >"$FIXTURE_DIR/logging-json-compress.yml"
    {
        printf '%s\n' \
            'services:' \
            '  logger:' \
            '    extends:' \
            '      file: logging-workload.yml' \
            '      service: logger' \
            '    environment:' \
            '      LOG_COMPLETION_FILE: ${LOG_COMPLETION_FILE:?LOG_COMPLETION_FILE is required}' \
            '      LOG_RETAIN_AFTER_COMPLETION: "${LOG_RETAIN_AFTER_COMPLETION:-0}"' \
            '    volumes:' \
            '      - type: bind' \
            '        source: ${PERF_COMPLETION_DIR:?PERF_COMPLETION_DIR is required}' \
            '        target: /completion' \
            '    stop_grace_period: 1s' \
            '    logging:' \
            '      driver: local' \
            '      options:' \
            '        max-size: "4m"' \
            '        max-file: "20"' \
            '        compress: "true"'
    } >"$FIXTURE_DIR/logging-local.yml"
    {
        printf '%s\n' \
            'services:' \
            '  logger:' \
            '    extends:' \
            '      file: logging-workload.yml' \
            '      service: logger' \
            '    environment:' \
            '      LOG_COMPLETION_FILE: ${LOG_COMPLETION_FILE:?LOG_COMPLETION_FILE is required}' \
            '    volumes:' \
            '      - type: bind' \
            '        source: ${PERF_COMPLETION_DIR:?PERF_COMPLETION_DIR is required}' \
            '        target: /completion' \
            '    logging:' \
            '      driver: syslog' \
            '      options:' \
            '        syslog-address: "${PERF_SYSLOG_ADDRESS:?PERF_SYSLOG_ADDRESS is required}"' \
            '        syslog-format: rfc5424micro' \
            '        cache-disabled: "true"'
    } >"$FIXTURE_DIR/logging-remote-blocking.yml"
    {
        printf '%s\n' \
            'services:' \
            '  logger:' \
            '    extends:' \
            '      file: logging-workload.yml' \
            '      service: logger' \
            '    environment:' \
            '      LOG_COMPLETION_FILE: ${LOG_COMPLETION_FILE:?LOG_COMPLETION_FILE is required}' \
            '    volumes:' \
            '      - type: bind' \
            '        source: ${PERF_COMPLETION_DIR:?PERF_COMPLETION_DIR is required}' \
            '        target: /completion' \
            '    logging:' \
            '      driver: syslog' \
            '      options:' \
            '        syslog-address: "${PERF_SYSLOG_ADDRESS:?PERF_SYSLOG_ADDRESS is required}"' \
            '        syslog-format: rfc5424micro' \
            '        mode: non-blocking' \
            '        max-buffer-size: "${LOG_BUFFER_SIZE:?LOG_BUFFER_SIZE is required}"' \
            '        cache-disabled: "true"'
    } >"$FIXTURE_DIR/logging-remote-nonblocking.yml"
    {
        printf '%s\n' \
            'services:' \
            '  logger:' \
            '    extends:' \
            '      file: logging-workload.yml' \
            '      service: logger' \
            '    logging:' \
            '      driver: syslog' \
            '      options:' \
            '        syslog-address: "${PERF_SYSLOG_ADDRESS:?PERF_SYSLOG_ADDRESS is required}"' \
            '        syslog-format: rfc5424micro' \
            '        cache-max-size: "64m"' \
            '        cache-max-file: "3"' \
            '        cache-compress: "true"'
    } >"$FIXTURE_DIR/logging-remote-cache.yml"
}

# Initialize raw samples and exact run fingerprints.
initialize_evidence() {
    local init_image_sha=
    if [[ -n "$PARITY_INIT_IMAGE_ARCHIVE" ]]; then
        init_image_sha="$(shasum -a 256 "$PARITY_INIT_IMAGE_ARCHIVE" | awk '{print $1}')"
    fi
    mkdir -p "$PARITY_EVIDENCE_DIR"
    PARITY_REPETITIONS="$PARITY_REPETITIONS" python3 - \
        "$PARITY_EVIDENCE_MODE" "$TIMING_TSV" "$FINGERPRINT_JSON" \
        "$TIMING_JUNIT" "$TIMING_MATRIX" \
        "$("${DOCKER_COMPOSE_COMMAND[@]}" version --short)" "$(docker version --format '{{json .Server}}')" \
        "$("$CONTAINER_COMPOSE" version --format json)" "$("$CONTAINER_BINARY" system version --format json)" \
        "$(git -C "$REPO_ROOT" rev-parse HEAD)" "$(sysctl -n hw.model)" "$(sysctl -n hw.memsize)" \
        "$(sw_vers -productVersion)" "$(uname -m)" "$(shasum -a 256 "$CONTAINER_COMPOSE" | awk '{print $1}')" \
        "$(shasum -a 256 "$(command -v "$CONTAINER_BINARY")" | awk '{print $1}')" \
        "$PARITY_COMPARABLE_NOISE_PCT" "$PARITY_TIMEOUT_SECONDS" \
        "$PARITY_TIMING_MAX_RATIO" "$PARITY_TIMING_POLICY" \
        "$PARITY_PRESSURE_RECORDS" \
        "$PARITY_SINK_STALL_SECONDS" "$PARITY_INCLUDE_REMOTE_LOGGING" \
        "$PARITY_SINK_BIND_ADDRESS" "$PARITY_DOCKER_HOST_ADDRESS" \
        "$PARITY_CONTAINER_HOST_ADDRESS" "$init_image_sha" \
        "$PARITY_INIT_IMAGE_REFERENCES" <<'PY'
import json, os, pathlib, sys
from datetime import datetime, timezone
(mode, timing, fingerprints, timing_junit, timing_matrix, docker_compose, docker_engine, compose_version, runtime_version, commit, model, memory, macos, architecture, compose_sha, runtime_sha, noise, timeout, maximum_ratio, timing_policy, pressure_records, sink_stall, include_remote_logging, sink_bind, docker_host, container_host, init_sha, init_references) = sys.argv[1:]
def decode(value):
    try: return json.loads(value)
    except json.JSONDecodeError: return value
runtime = {"sha256": runtime_sha, "version": decode(runtime_version)}
if init_sha:
    runtime["initImage"] = {
        "archiveSha256": init_sha,
        "references": init_references.split(),
    }
current = {
    "capturedAt": datetime.now(timezone.utc).isoformat(),
    "conditions": {
        "comparableNoisePercent": float(noise),
        "image": "alpine:3.20",
        "maximumCandidateRatio": float(maximum_ratio),
        "mode": "warm",
        "operationTimeoutSeconds": int(timeout),
        "pressureRecords": int(pressure_records),
        "remoteLogging": include_remote_logging == "1",
        "repetitions": int(os.environ["PARITY_REPETITIONS"]),
        "schedule": "Docker-first on odd repetitions; candidate-first on even repetitions",
        "sinkBindAddress": sink_bind,
        "sinkEndpoints": {"container": container_host, "docker": docker_host},
        "sinkStallSeconds": float(sink_stall),
        "timingDirection": "lower-is-better fixed-work duration",
        "timingPolicy": timing_policy,
    },
    "containerCompose": {"commit": commit, "sha256": compose_sha, "version": decode(compose_version)},
    "containerRuntime": runtime,
    "docker": {"composeVersion": docker_compose, "engine": decode(docker_engine)},
    "host": {"architecture": architecture, "hardwareMemoryBytes": int(memory), "hardwareModel": model, "macOSVersion": macos},
}
timing_path = pathlib.Path(timing)
fingerprint_path = pathlib.Path(fingerprints)
header = "fixture\tlane\trepetition\tschedule_position\tdirection\tduration_seconds\toutcome\tcommand\n"
if mode == "append":
    if not timing_path.is_file() or not timing_path.read_text(encoding="utf-8").startswith(header):
        raise SystemExit(f"append evidence is missing the canonical timing header: {timing_path}")
    if not fingerprint_path.is_file():
        raise SystemExit(f"append evidence is missing fingerprints: {fingerprint_path}")
    try:
        previous = json.loads(fingerprint_path.read_text(encoding="utf-8"))
    except (json.JSONDecodeError, OSError) as error:
        raise SystemExit(f"append evidence has invalid fingerprints: {error}") from error
    previous.pop("capturedAt", None)
    current.pop("capturedAt", None)
    if previous != current:
        changed = sorted(set(previous) | set(current))
        changed = [key for key in changed if previous.get(key) != current.get(key)]
        raise SystemExit(
            "append evidence fingerprint does not match the current run: "
            + ", ".join(changed)
        )
    pathlib.Path(timing_junit).unlink(missing_ok=True)
    pathlib.Path(timing_matrix).unlink(missing_ok=True)
else:
    pathlib.Path(timing_junit).unlink(missing_ok=True)
    pathlib.Path(timing_matrix).unlink(missing_ok=True)
    timing_path.write_text(header, encoding="utf-8")
    fingerprint_path.write_text(
        json.dumps(current, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )
PY
}

# Prove the candidate can complete one lifecycle before recording any timings.
preflight_candidate_lifecycle() {
    local file="$FIXTURE_DIR/services-1.yml"
    local project=cc-perf-c-preflight
    local status=0

    down_project container-compose "$project" "$file"
    "$CONTAINER_COMPOSE" --ansi never -p "$project" -f "$file" \
        up -d --pull never || status=$?
    "$CONTAINER_COMPOSE" --ansi never -p "$project" -f "$file" \
        down --volumes --remove-orphans >/dev/null 2>&1 || true
    if ((status != 0)); then
        error "candidate lifecycle preflight failed before benchmark timing"
        return "$status"
    fi
}

# Run one command under a monotonic timeout and append the raw outcome.
run_timed() {
    local fixture="$1" lane="$2" repetition="$3" schedule_position="$4"
    shift 4
    python3 - "$TIMING_TSV" "$fixture" "$lane" "$repetition" "$schedule_position" "$PARITY_TIMEOUT_SECONDS" "$@" <<'PY'
import csv, os, shlex, signal, subprocess, sys, time
timing, fixture, lane, repetition, schedule_position, timeout, *command = sys.argv[1:]
started = time.monotonic()
process = subprocess.Popen(command, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, text=True, start_new_session=True)
outcome = "success"
try: _, stderr = process.communicate(timeout=float(timeout))
except subprocess.TimeoutExpired:
    os.killpg(process.pid, signal.SIGKILL); _, stderr = process.communicate(); outcome = "timeout"
else:
    if process.returncode: outcome = f"exit-{process.returncode}"
duration = time.monotonic() - started
with open(timing, "a", encoding="utf-8", newline="") as handle:
    csv.writer(handle, delimiter="\t", lineterminator="\n").writerow([fixture, lane, repetition, schedule_position, "lower-is-better", f"{duration:.9f}", outcome, shlex.join(command)])
print(f"{fixture} {lane} repetition {repetition}: {duration:.3f}s ({outcome})")
if outcome != "success":
    if stderr: print(stderr, file=sys.stderr, end="" if stderr.endswith("\n") else "\n")
    raise SystemExit(124 if outcome == "timeout" else process.returncode or 1)
PY
}

# Time detached startup until the workload publishes its host completion file.
run_to_completion_marker() {
    local fixture="$1" lane="$2" repetition="$3" schedule_position="$4" marker="$5"
    shift 5
    python3 - "$TIMING_TSV" "$fixture" "$lane" "$repetition" \
        "$schedule_position" "$PARITY_TIMEOUT_SECONDS" "$marker" "$@" <<'PY'
import csv, pathlib, shlex, subprocess, sys, time
timing, fixture, lane, repetition, schedule_position, timeout, marker, *command = sys.argv[1:]
marker_path = pathlib.Path(marker); marker_path.unlink(missing_ok=True); started = time.monotonic(); outcome = "success"; diagnostic = ""
try:
    result = subprocess.run(command, capture_output=True, check=False, text=True, timeout=float(timeout))
    if result.returncode: outcome = f"exit-{result.returncode}"; diagnostic = result.stderr
    else:
        deadline = started + float(timeout)
        while time.monotonic() < deadline:
            if marker_path.is_file(): break
            time.sleep(0.005)
        else: outcome = "timeout"
except subprocess.TimeoutExpired as error:
    outcome = "timeout"; diagnostic = str(error)
duration = time.monotonic() - started
with open(timing, "a", encoding="utf-8", newline="") as handle:
    csv.writer(handle, delimiter="\t", lineterminator="\n").writerow([fixture, lane, repetition, schedule_position, "lower-is-better", f"{duration:.9f}", outcome, shlex.join(command) + f" until-file:{marker}"])
print(f"{fixture} {lane} repetition {repetition}: {duration:.3f}s ({outcome})")
if outcome != "success":
    if diagnostic: print(diagnostic, file=sys.stderr, end="" if diagnostic.endswith("\n") else "\n")
    raise SystemExit(124 if outcome == "timeout" else 1)
PY
}

# Require a semantic timing floor such as a configured blocking-sink stall.
assert_fixture_duration_at_least() {
    local fixture="$1" lane="$2" repetition="$3" minimum="$4"
    python3 - "$TIMING_TSV" "$fixture" "$lane" "$repetition" "$minimum" <<'PY'
import csv, pathlib, sys
timing = pathlib.Path(sys.argv[1]); fixture = sys.argv[2]; lane = sys.argv[3]; repetition = sys.argv[4]; minimum = float(sys.argv[5])
rows = [row for row in csv.DictReader(timing.open(encoding="utf-8"), delimiter="\t") if row["fixture"] == fixture and row["lane"] == lane and row["repetition"] == repetition]
if len(rows) != 1: raise SystemExit(f"expected one timing sample for {fixture}/{lane}/{repetition}, found {len(rows)}")
duration = float(rows[0]["duration_seconds"])
if duration < minimum: raise SystemExit(f"{fixture} completed in {duration:.3f}s before the {minimum:.3f}s blocking-sink stall elapsed")
PY
}

# Stop the exact host sink process owned by the current fixture.
stop_sink() {
    if [[ -n "$SINK_PID" ]] && kill -0 "$SINK_PID" >/dev/null 2>&1; then
        [[ -z "$SINK_STOP_FILE" ]] || touch "$SINK_STOP_FILE"
        sleep 0.1
        kill "$SINK_PID" >/dev/null 2>&1 || true
        wait "$SINK_PID" >/dev/null 2>&1 || true
    fi
    SINK_PID=""
    SINK_PORT=""
}

# Start one fast or stalled host TCP sink and wait for its published port.
start_sink() {
    local label="$1" stall_seconds="$2" attempt
    stop_sink
    mkdir -p "$PARITY_EVIDENCE_DIR/sinks"
    SINK_PORT_FILE="$PARITY_EVIDENCE_DIR/sinks/$label.port"
    SINK_RESULT_FILE="$PARITY_EVIDENCE_DIR/sinks/$label.json"
    SINK_STOP_FILE="$PARITY_EVIDENCE_DIR/sinks/$label.stop"
    rm -f "$SINK_PORT_FILE" "$SINK_RESULT_FILE" "$SINK_STOP_FILE"
    "$LOGGING_SINK" \
        --bind-address "$PARITY_SINK_BIND_ADDRESS" \
        --port-file "$SINK_PORT_FILE" \
        --result-file "$SINK_RESULT_FILE" \
        --stop-file "$SINK_STOP_FILE" \
        --stall-seconds "$stall_seconds" &
    SINK_PID=$!
    for ((attempt = 0; attempt < 500; attempt++)); do
        if [[ -s "$SINK_PORT_FILE" ]]; then
            SINK_PORT="$(<"$SINK_PORT_FILE")"
            [[ "$SINK_PORT" =~ ^[1-9][0-9]*$ ]] || { error "sink published an invalid port: $SINK_PORT"; return 1; }
            return
        fi
        if ! kill -0 "$SINK_PID" >/dev/null 2>&1; then
            wait "$SINK_PID" || true
            error "logging sink exited before publishing its port"
            return 1
        fi
        sleep 0.01
    done
    error "logging sink did not publish its port"
    return 1
}

# Wait for a sink result and validate exact delivery or observable dropping.
finish_sink() {
    local expectation="$1" expected_records="$2" attempt result_pid
    result_pid="$SINK_PID"
    touch "$SINK_STOP_FILE"
    for ((attempt = 0; attempt < PARITY_TIMEOUT_SECONDS * 20; attempt++)); do
        kill -0 "$result_pid" >/dev/null 2>&1 || break
        sleep 0.05
    done
    if kill -0 "$result_pid" >/dev/null 2>&1; then
        error "logging sink did not finish within ${PARITY_TIMEOUT_SECONDS}s"
        stop_sink
        return 1
    fi
    wait "$result_pid"
    SINK_PID=""
    python3 - "$SINK_RESULT_FILE" "$expectation" "$expected_records" <<'PY'
import json, pathlib, sys
path = pathlib.Path(sys.argv[1]); expectation = sys.argv[2]; expected = int(sys.argv[3])
result = json.loads(path.read_text(encoding="utf-8")); observed = int(result["recordCount"])
if not result["recordsAreOrdered"]: raise SystemExit(f"sink reordered markers: {result}")
if not result["recordsAreUnique"]: raise SystemExit(f"sink recorded duplicate markers: {result}")
if expectation == "exact" and observed != expected: raise SystemExit(f"sink recorded {observed} markers, expected {expected}")
if observed and (result["firstRecord"] != 0 or int(result["lastRecord"]) >= expected): raise SystemExit(f"sink recorded out-of-range markers: {result}")
if expectation == "dropped" and not 0 < observed < expected: raise SystemExit(f"sink recorded {observed} markers; expected partial ordered delivery below {expected}")
if expectation not in ("exact", "dropped"): raise SystemExit(f"unknown sink expectation: {expectation}")
PY
}

# Return the host endpoint reachable by one logging-provider lane.
syslog_address() {
    local lane="$1"
    if [[ "$lane" == docker ]]; then
        printf 'tcp://%s:%s\n' "$PARITY_DOCKER_HOST_ADDRESS" "$SINK_PORT"
    else
        printf 'tcp://%s:%s\n' "$PARITY_CONTAINER_HOST_ADDRESS" "$SINK_PORT"
    fi
}

# Retain an exact marker-count and digest assertion for one readable workload.
assert_logging_record_count() {
    local label="$1" expected="$2" project="$3" file="$4"
    shift 4
    mkdir -p "$PARITY_EVIDENCE_DIR/assertions"
    python3 - "$PARITY_EVIDENCE_DIR/assertions/$label.json" "$expected" \
        "$PARITY_TIMEOUT_SECONDS" "$project" "$file" "$@" <<'PY'
import hashlib, json, pathlib, re, subprocess, sys, time
result_path = pathlib.Path(sys.argv[1]); expected = int(sys.argv[2]); timeout = float(sys.argv[3]); project = sys.argv[4]; file = sys.argv[5]; compose = sys.argv[6:]
command = [*compose, "-p", project, "-f", file, "logs", "--no-color", "--no-log-prefix", "--tail", "all", "logger"]
deadline = time.monotonic() + min(timeout, 10.0)
while True:
    result = subprocess.run(command, capture_output=True, check=False)
    if result.returncode: raise SystemExit(result.stderr.decode(errors="replace"))
    markers = [int(value) for value in re.findall(rb"perf-record-(\d{6})", result.stdout)]
    if markers == list(range(expected)): break
    if time.monotonic() >= deadline:
        raise SystemExit(f"read {len(markers)} non-canonical markers (first={markers[:1]}, last={markers[-1:]}); expected {expected}")
    time.sleep(0.1)
result_path.write_text(json.dumps({"byteCount": len(result.stdout), "recordCount": len(markers), "sha256": hashlib.sha256(result.stdout).hexdigest()}, indent=2, sort_keys=True) + "\n", encoding="utf-8")
PY
}

# Wait until one canonical logging marker is readable through Compose.
wait_for_log_text() {
    local expected="$1" project="$2" file="$3"
    shift 3
    python3 - "$expected" "$project" "$file" "$PARITY_TIMEOUT_SECONDS" "$@" <<'PY'
import subprocess, sys, time
expected, project, file, timeout, *compose = sys.argv[1:]
base = [*compose, "-p", project, "-f", file]
deadline = time.monotonic() + float(timeout)
while time.monotonic() < deadline:
    result = subprocess.run([*base, "logs", "--no-color", "--no-log-prefix", "--tail", "all", "logger"], capture_output=True, check=False, text=True, timeout=min(10.0, max(0.1, deadline - time.monotonic())))
    if result.returncode: raise SystemExit(result.stderr)
    if expected in result.stdout: break
    time.sleep(0.02)
else: raise SystemExit(f"timed out waiting for log marker {expected!r}")
PY
}

# Return the canonical timestamp attached to one persisted logging marker.
wait_for_log_timestamp() {
    local expected="$1" project="$2" file="$3"
    shift 3
    python3 - "$expected" "$project" "$file" "$PARITY_TIMEOUT_SECONDS" "$@" <<'PY'
import subprocess, sys, time
expected, project, file, timeout, *compose = sys.argv[1:]
base = [*compose, "-p", project, "-f", file]
deadline = time.monotonic() + float(timeout)
while time.monotonic() < deadline:
    result = subprocess.run([*base, "logs", "--timestamps", "--no-color", "--no-log-prefix", "--tail", "all", "logger"], capture_output=True, check=False, text=True, timeout=min(10.0, max(0.1, deadline - time.monotonic())))
    if result.returncode: raise SystemExit(result.stderr)
    for line in result.stdout.splitlines():
        if expected in line:
            timestamp = line.split(maxsplit=1)[0]
            if "T" not in timestamp or not timestamp.endswith("Z"): raise SystemExit(f"invalid canonical log timestamp: {timestamp!r}")
            print(timestamp); raise SystemExit(0)
    time.sleep(0.02)
raise SystemExit(f"timed out waiting for timestamped log marker {expected!r}")
PY
}

# Return an RFC 3339 timestamp strictly between two persisted log records.
midpoint_log_timestamp() {
    python3 - "$1" "$2" <<'PY'
from datetime import datetime, timezone
import sys

start_text, end_text = sys.argv[1:]
start = datetime.fromisoformat(start_text.replace("Z", "+00:00"))
end = datetime.fromisoformat(end_text.replace("Z", "+00:00"))
if end <= start:
    raise SystemExit(
        f"log timestamp gap is not positive: {start_text!r} .. {end_text!r}"
    )
midpoint = start + (end - start) / 2
print(midpoint.astimezone(timezone.utc).isoformat(timespec="microseconds").replace("+00:00", "Z"))
PY
}

# Assert that one since/until query returns exactly the bounded history window.
assert_since_until_window() {
    local label="$1" since="$2" until="$3" project="$4" file="$5"
    shift 5
    mkdir -p "$PARITY_EVIDENCE_DIR/assertions"
    python3 - "$PARITY_EVIDENCE_DIR/assertions/$label.json" "$since" "$until" \
        "$project" "$file" "$@" <<'PY'
import hashlib, json, pathlib, re, subprocess, sys
result_path = pathlib.Path(sys.argv[1]); since = sys.argv[2]; until = sys.argv[3]; project = sys.argv[4]; file = sys.argv[5]; compose = sys.argv[6:]
command = [*compose, "-p", project, "-f", file, "logs", "--no-color", "--no-log-prefix", "--since", since, "--until", until, "logger"]
result = subprocess.run(command, capture_output=True, check=False)
if result.returncode: raise SystemExit(result.stderr.decode(errors="replace"))
markers = [int(value) for value in re.findall(rb"history-window-(\d{3})", result.stdout)]
has_before = b"history-before" in result.stdout; has_after = b"history-after" in result.stdout
if markers != list(range(100)) or has_before or has_after: raise SystemExit(f"since/until returned {len(markers)} window records (first={markers[:1]}, last={markers[-1:]}, before={has_before}, after={has_after})")
result_path.write_text(json.dumps({"byteCount": len(result.stdout), "recordCount": len(markers), "sha256": hashlib.sha256(result.stdout).hexdigest()}, indent=2, sort_keys=True) + "\n", encoding="utf-8")
PY
}

# Time attached startup until the first foreground record is observed.
run_attached_startup_to_first_output() {
    local lane="$1" repetition="$2" schedule_position="$3" project="$4" file="$5"
    shift 5
    python3 - "$TIMING_TSV" "$lane" "$repetition" "$schedule_position" \
        "$PARITY_TIMEOUT_SECONDS" "$project" "$file" "$@" <<'PY'
import csv, os, selectors, shlex, signal, subprocess, sys, time
timing, lane, repetition, schedule_position, timeout, project, file, *compose = sys.argv[1:]
environment = dict(os.environ); environment["LOG_WORKLOAD"] = "startup"; environment["LOG_MAX_SIZE"] = "64m"
command = [*compose, "-p", project, "-f", file, "up", "--pull", "never", "--no-log-prefix"]
started = time.monotonic(); outcome = "success"; diagnostic = bytearray(); process = None; duration = None
try:
    process = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, env=environment, start_new_session=True)
    assert process.stdout is not None
    selector = selectors.DefaultSelector(); selector.register(process.stdout, selectors.EVENT_READ)
    deadline = started + float(timeout)
    while time.monotonic() < deadline:
        if process.poll() is not None: outcome = f"exit-{process.returncode}"; break
        events = selector.select(timeout=min(0.1, deadline - time.monotonic()))
        for key, _ in events:
            chunk = os.read(key.fileobj.fileno(), 65536)
            diagnostic.extend(chunk)
            if b"logging-ready" in diagnostic: break
        if b"logging-ready" in diagnostic: break
    else: outcome = "timeout"
finally:
    if duration is None: duration = time.monotonic() - started
    if process is not None and process.poll() is None:
        os.killpg(process.pid, signal.SIGINT)
        try: process.wait(timeout=15)
        except subprocess.TimeoutExpired:
            os.killpg(process.pid, signal.SIGKILL); process.wait()
with open(timing, "a", encoding="utf-8", newline="") as handle:
    csv.writer(handle, delimiter="\t", lineterminator="\n").writerow(["logging-startup-first-output-attached", lane, repetition, schedule_position, "lower-is-better", f"{duration:.9f}", outcome, shlex.join(command) + " until:logging-ready"])
print(f"logging-startup-first-output-attached {lane} repetition {repetition}: {duration:.3f}s ({outcome})")
if outcome != "success":
    if diagnostic: print(diagnostic.decode(errors="replace"), file=sys.stderr)
    raise SystemExit(124 if outcome == "timeout" else 1)
PY
}

# Time detached startup until the first canonical logging marker is readable.
run_startup_to_first_output() {
    local lane="$1" repetition="$2" schedule_position="$3" project="$4" file="$5"
    shift 5
    python3 - "$TIMING_TSV" "$lane" "$repetition" "$schedule_position" \
        "$PARITY_TIMEOUT_SECONDS" "$project" "$file" "$@" <<'PY'
import csv, os, shlex, subprocess, sys, time
timing, lane, repetition, schedule_position, timeout, project, file, *compose = sys.argv[1:]
environment = dict(os.environ)
environment["LOG_WORKLOAD"] = "startup"
environment["LOG_MAX_SIZE"] = "64m"
base = [*compose, "-p", project, "-f", file]
started = time.monotonic()
outcome = "success"
diagnostic = ""
try:
    up = subprocess.run(
        [*base, "up", "-d", "--pull", "never"],
        capture_output=True,
        check=False,
        text=True,
        timeout=float(timeout),
        env=environment,
    )
    if up.returncode:
        outcome = f"exit-{up.returncode}"
        diagnostic = up.stderr
    else:
        deadline = started + float(timeout)
        while time.monotonic() < deadline:
            logs = subprocess.run(
                [*base, "logs", "--no-color", "--no-log-prefix", "--tail", "1", "logger"],
                capture_output=True,
                check=False,
                text=True,
                timeout=min(10.0, max(0.1, deadline - time.monotonic())),
                env=environment,
            )
            if logs.returncode:
                outcome = f"exit-{logs.returncode}"
                diagnostic = logs.stderr
                break
            if "logging-ready" in logs.stdout:
                break
            time.sleep(0.02)
        else:
            outcome = "timeout"
except subprocess.TimeoutExpired as error:
    outcome = "timeout"
    diagnostic = str(error)
duration = time.monotonic() - started
with open(timing, "a", encoding="utf-8", newline="") as handle:
    csv.writer(handle, delimiter="\t", lineterminator="\n").writerow([
        "logging-startup-first-output", lane, repetition, schedule_position,
        "lower-is-better", f"{duration:.9f}", outcome,
        shlex.join([*base, "up", "-d", "--pull", "never"]) + " && logs-until:logging-ready",
    ])
print(f"logging-startup-first-output {lane} repetition {repetition}: {duration:.3f}s ({outcome})")
if outcome != "success":
    if diagnostic:
        print(diagnostic, file=sys.stderr, end="" if diagnostic.endswith("\n") else "\n")
    raise SystemExit(124 if outcome == "timeout" else 1)
PY
}

# Select the exact Compose client for one benchmark lane.
select_lane() {
    local lane="$1"
    if [[ "$lane" == docker ]]; then
        ACTIVE_COMPOSE=("${DOCKER_COMPOSE_COMMAND[@]}" --ansi never)
        LANE_PREFIX=d
    else
        ACTIVE_COMPOSE=("$CONTAINER_COMPOSE" --ansi never)
        LANE_PREFIX=c
    fi
}

# Set a counterbalanced lane order for one repetition.
select_lane_order() {
    local repetition="$1"
    if ((repetition % 2 == 1)); then
        LANE_ORDER=(docker container-compose)
    else
        LANE_ORDER=(container-compose docker)
    fi
}

# Tear down one exact benchmark project outside the timed interval.
down_project() {
    local lane="$1" project="$2" file="$3"
    select_lane "$lane"
    "${ACTIVE_COMPOSE[@]}" -p "$project" -f "$file" down --volumes --remove-orphans >/dev/null 2>&1 || true
}

# Run one lifecycle startup/teardown pair for a lane.
run_lifecycle_lane() {
    local lane="$1" repetition="$2" schedule_position="$3" count="$4" file="$5" project
    select_lane "$lane"
    project="cc-perf-$LANE_PREFIX-$count"
    run_timed "startup-$count-services" "$lane" "$repetition" "$schedule_position" \
        "${ACTIVE_COMPOSE[@]}" -p "$project" -f "$file" up -d --pull never
    run_timed "teardown-$count-services" "$lane" "$repetition" "$schedule_position" \
        "${ACTIVE_COMPOSE[@]}" -p "$project" -f "$file" down --volumes --remove-orphans
}

# Run startup-to-first-output for one logging lane.
run_logging_startup_lane() {
    local lane="$1" repetition="$2" schedule_position="$3" file="$4" project
    select_lane "$lane"
    project="cc-perf-$LANE_PREFIX-logging"
    down_project "$lane" "$project" "$file"
    run_startup_to_first_output "$lane" "$repetition" "$schedule_position" \
        "$project" "$file" "${ACTIVE_COMPOSE[@]}"
    down_project "$lane" "$project" "$file"
}

# Run attached startup to the first foreground logging record for one lane.
run_logging_attached_startup_lane() {
    local lane="$1" repetition="$2" schedule_position="$3" file="$4" project
    select_lane "$lane"
    project="cc-perf-$LANE_PREFIX-logging"
    down_project "$lane" "$project" "$file"
    run_attached_startup_to_first_output "$lane" "$repetition" "$schedule_position" \
        "$project" "$file" "${ACTIVE_COMPOSE[@]}"
    down_project "$lane" "$project" "$file"
}

# Run one fixed-volume logging writer workload for a lane.
run_logging_throughput_lane() {
    local lane="$1" repetition="$2" schedule_position="$3" fixture="$4" workload="$5" file="$6" project
    select_lane "$lane"
    project="cc-perf-$LANE_PREFIX-logging"
    down_project "$lane" "$project" "$file"
    run_timed "$fixture" "$lane" "$repetition" "$schedule_position" \
        env LOG_WORKLOAD="$workload" LOG_MAX_SIZE=64m \
        "${ACTIVE_COMPOSE[@]}" -p "$project" -f "$file" up \
        --abort-on-container-exit --exit-code-from logger --pull never
    down_project "$lane" "$project" "$file"
}

# Time one blocking or non-blocking remote sink workload and prove delivery.
run_remote_sink_lane() {
    local lane="$1" repetition="$2" schedule_position="$3" fixture="$4"
    local file="$5" stall_seconds="$6" expectation="$7" buffer_size="$8"
    local project label address completion_dir completion_file completion_path
    select_lane "$lane"
    project="cc-perf-$LANE_PREFIX-logging"
    label="$fixture-$lane-$repetition"
    down_project "$lane" "$project" "$FIXTURE_DIR/logging.yml"
    start_sink "$label" "$stall_seconds"
    address="$(syslog_address "$lane")"
    # Keep the marker under the generated fixture root, which is always inside
    # the macOS workspace shared with the provider VM. Evidence directories may
    # be redirected to /tmp, which Docker Desktop/Colima do not necessarily
    # expose to bind mounts.
    completion_dir="$FIXTURE_DIR/completions"
    completion_file="$label.done"
    completion_path="$completion_dir/$completion_file"
    mkdir -p "$completion_dir"
    run_to_completion_marker "$fixture" "$lane" "$repetition" \
        "$schedule_position" "$completion_path" \
        env LOG_WORKLOAD=pressure LOG_RECORD_COUNT="$PARITY_PRESSURE_RECORDS" \
        LOG_COMPLETION_FILE="$completion_file" PERF_COMPLETION_DIR="$completion_dir" \
        LOG_BUFFER_SIZE="$buffer_size" PERF_SYSLOG_ADDRESS="$address" \
        "${ACTIVE_COMPOSE[@]}" -p "$project" -f "$file" up -d --pull never
    env LOG_WORKLOAD=pressure LOG_RECORD_COUNT="$PARITY_PRESSURE_RECORDS" \
        LOG_COMPLETION_FILE="$completion_file" PERF_COMPLETION_DIR="$completion_dir" \
        LOG_BUFFER_SIZE="$buffer_size" PERF_SYSLOG_ADDRESS="$address" \
        "${ACTIVE_COMPOSE[@]}" -p "$project" -f "$file" wait logger >/dev/null
    if [[ "$fixture" == logging-blocking-slow-sink ]]; then
        assert_fixture_duration_at_least \
            "$fixture" "$lane" "$repetition" "$stall_seconds"
    fi
    finish_sink "$expectation" "$PARITY_PRESSURE_RECORDS"
    down_project "$lane" "$project" "$FIXTURE_DIR/logging.yml"
}

# Time one retained built-in rotation/compression writer and prove exact reads.
run_file_logging_lane() {
    local lane="$1" repetition="$2" schedule_position="$3" fixture="$4" file="$5"
    local project completion_dir completion_file completion_path
    select_lane "$lane"
    project="cc-perf-$LANE_PREFIX-logging"
    completion_dir="$FIXTURE_DIR/completions"
    completion_file="$fixture-$lane-$repetition.done"
    completion_path="$completion_dir/$completion_file"
    mkdir -p "$completion_dir"
    down_project "$lane" "$project" "$FIXTURE_DIR/logging.yml"
    run_to_completion_marker "$fixture" "$lane" "$repetition" \
        "$schedule_position" "$completion_path" \
        env LOG_WORKLOAD=pressure LOG_RECORD_COUNT="$PARITY_PRESSURE_RECORDS" \
        LOG_COMPLETION_FILE="$completion_file" \
        LOG_RETAIN_AFTER_COMPLETION=1 PERF_COMPLETION_DIR="$completion_dir" \
        "${ACTIVE_COMPOSE[@]}" -p "$project" -f "$file" up \
        -d --pull never
    LOG_RECORD_COUNT="$PARITY_PRESSURE_RECORDS" \
        LOG_COMPLETION_FILE="$completion_file" \
        LOG_RETAIN_AFTER_COMPLETION=1 PERF_COMPLETION_DIR="$completion_dir" \
        assert_logging_record_count \
        "$fixture-$lane-$repetition" "$PARITY_PRESSURE_RECORDS" \
        "$project" "$file" "${ACTIVE_COMPOSE[@]}"
    down_project "$lane" "$project" "$FIXTURE_DIR/logging.yml"
}

# Populate one deterministic history corpus outside the timed read interval.
prepare_logging_history() {
    local lane="$1" file="$2" project
    select_lane "$lane"
    project="cc-perf-$LANE_PREFIX-logging"
    down_project "$lane" "$project" "$file"
    env LOG_WORKLOAD=history LOG_MAX_SIZE=64m \
        "${ACTIVE_COMPOSE[@]}" -p "$project" -f "$file" up \
        -d --pull never >/dev/null
    env LOG_WORKLOAD=history LOG_MAX_SIZE=64m \
        "${ACTIVE_COMPOSE[@]}" -p "$project" -f "$file" \
        wait logger >/dev/null
}

# Time one canonical historical logging query against a prepared corpus.
run_logging_read_lane() {
    local lane="$1" repetition="$2" schedule_position="$3" fixture="$4" tail="$5" file="$6" project
    select_lane "$lane"
    project="cc-perf-$LANE_PREFIX-logging"
    run_timed "$fixture" "$lane" "$repetition" "$schedule_position" \
        "${ACTIVE_COMPOSE[@]}" -p "$project" -f "$file" logs \
        --no-color --no-log-prefix --tail "$tail" logger
}

# Time and prove one absolute since/until query around a deterministic window.
run_logging_since_until_lane() {
    local lane="$1" repetition="$2" schedule_position="$3" file="$4"
    local project before first last after since until
    select_lane "$lane"
    project="cc-perf-$LANE_PREFIX-logging"
    down_project "$lane" "$project" "$file"
    env LOG_WORKLOAD=history-window LOG_MAX_SIZE=64m \
        "${ACTIVE_COMPOSE[@]}" -p "$project" -f "$file" up -d --pull never >/dev/null
    LOG_WORKLOAD=history-window wait_for_log_text \
        history-before "$project" "$file" "${ACTIVE_COMPOSE[@]}"
    before="$(LOG_WORKLOAD=history-window wait_for_log_timestamp \
        history-before "$project" "$file" "${ACTIVE_COMPOSE[@]}")"
    first="$(LOG_WORKLOAD=history-window wait_for_log_timestamp \
        history-window-000 "$project" "$file" "${ACTIVE_COMPOSE[@]}")"
    last="$(LOG_WORKLOAD=history-window wait_for_log_timestamp \
        history-window-099 "$project" "$file" "${ACTIVE_COMPOSE[@]}")"
    after="$(LOG_WORKLOAD=history-window wait_for_log_timestamp \
        history-after "$project" "$file" "${ACTIVE_COMPOSE[@]}")"
    since="$(midpoint_log_timestamp "$before" "$first")"
    until="$(midpoint_log_timestamp "$last" "$after")"
    env LOG_WORKLOAD=history-window LOG_MAX_SIZE=64m \
        "${ACTIVE_COMPOSE[@]}" -p "$project" -f "$file" wait logger >/dev/null
    run_timed logging-read-since-until "$lane" "$repetition" "$schedule_position" \
        env LOG_WORKLOAD=history-window LOG_MAX_SIZE=64m \
        "${ACTIVE_COMPOSE[@]}" -p "$project" -f "$file" logs \
        --no-color --no-log-prefix --since "$since" --until "$until" logger
    LOG_WORKLOAD=history-window LOG_MAX_SIZE=64m assert_since_until_window \
        "logging-read-since-until-$lane-$repetition" "$since" "$until" \
        "$project" "$file" "${ACTIVE_COMPOSE[@]}"
    down_project "$lane" "$project" "$file"
}

# Time a follow reader while forced json-file rotation occurs.
run_logging_follow_lane() {
    local lane="$1" repetition="$2" schedule_position="$3" file="$4" project
    select_lane "$lane"
    project="cc-perf-$LANE_PREFIX-logging"
    down_project "$lane" "$project" "$file"
    env LOG_WORKLOAD=follow-rotation LOG_MAX_SIZE=8k \
        "${ACTIVE_COMPOSE[@]}" -p "$project" -f "$file" up -d --pull never >/dev/null
    run_timed logging-follow-rotation "$lane" "$repetition" "$schedule_position" \
        "${ACTIVE_COMPOSE[@]}" -p "$project" -f "$file" logs \
        --follow --no-color --no-log-prefix logger
    down_project "$lane" "$project" "$file"
}

# Time remote delivery and its canonical dual-cache read for one lane.
run_dual_cache_lane() {
    local lane="$1" repetition="$2" schedule_position="$3" file="$4"
    local project label address
    select_lane "$lane"
    project="cc-perf-$LANE_PREFIX-logging"
    label="logging-dual-cache-$lane-$repetition"
    down_project "$lane" "$project" "$FIXTURE_DIR/logging.yml"
    start_sink "$label" 0
    address="$(syslog_address "$lane")"
    run_timed logging-dual-cache-delivery "$lane" "$repetition" "$schedule_position" \
        env LOG_WORKLOAD=pressure LOG_RECORD_COUNT="$PARITY_PRESSURE_RECORDS" \
        PERF_SYSLOG_ADDRESS="$address" \
        "${ACTIVE_COMPOSE[@]}" -p "$project" -f "$file" up \
        --abort-on-container-exit --exit-code-from logger --pull never
    run_timed logging-dual-cache-read "$lane" "$repetition" "$schedule_position" \
        env LOG_WORKLOAD=pressure LOG_RECORD_COUNT="$PARITY_PRESSURE_RECORDS" \
        PERF_SYSLOG_ADDRESS="$address" \
        "${ACTIVE_COMPOSE[@]}" -p "$project" -f "$file" logs \
        --no-color --no-log-prefix --tail all logger
    LOG_WORKLOAD=pressure LOG_RECORD_COUNT="$PARITY_PRESSURE_RECORDS" \
        PERF_SYSLOG_ADDRESS="$address" assert_logging_record_count \
        "logging-dual-cache-read-$lane-$repetition" "$PARITY_PRESSURE_RECORDS" \
        "$project" "$file" "${ACTIVE_COMPOSE[@]}"
    finish_sink exact "$PARITY_PRESSURE_RECORDS"
    down_project "$lane" "$project" "$FIXTURE_DIR/logging.yml"
}

# Time foreground aggregation for one service count.
run_logging_aggregate_lane() {
    local lane="$1" repetition="$2" schedule_position="$3" count="$4" file="$5" project
    select_lane "$lane"
    project="cc-perf-$LANE_PREFIX-aggregate-$count"
    down_project "$lane" "$project" "$file"
    run_timed "logging-aggregate-$count-services" "$lane" "$repetition" "$schedule_position" \
        "${ACTIVE_COMPOSE[@]}" -p "$project" -f "$file" up --pull never
    down_project "$lane" "$project" "$file"
}

# Require finalization to use the render controls retained with raw evidence.
validate_finalize_fingerprint() {
    python3 - "$FINGERPRINT_JSON" "$TIMING_TSV" "$PARITY_REPETITIONS" \
        "$PARITY_TIMING_MAX_RATIO" "$PARITY_COMPARABLE_NOISE_PCT" \
        "$PARITY_TIMING_POLICY" "$PARITY_INCLUDE_REMOTE_LOGGING" \
        "${PERFORMANCE_FIXTURES[@]}" <<'PY'
import collections, csv, json, pathlib, sys
fingerprint_path = pathlib.Path(sys.argv[1])
timing_path = pathlib.Path(sys.argv[2])
if not fingerprint_path.is_file():
    raise SystemExit(f"finalize evidence is missing fingerprints: {fingerprint_path}")
try:
    fingerprint = json.loads(fingerprint_path.read_text(encoding="utf-8"))
except (json.JSONDecodeError, OSError) as error:
    raise SystemExit(f"finalize evidence has invalid fingerprints: {error}") from error
conditions = fingerprint.get("conditions", {})
expected = {
    "repetitions": int(sys.argv[3]),
    "maximumCandidateRatio": float(sys.argv[4]),
    "comparableNoisePercent": float(sys.argv[5]),
    "timingPolicy": sys.argv[6],
    "remoteLogging": sys.argv[7] == "1",
}
changed = [key for key, value in expected.items() if conditions.get(key) != value]
if changed:
    raise SystemExit(
        "finalize controls do not match the retained fingerprint: "
        + ", ".join(changed)
    )
if not timing_path.is_file():
    raise SystemExit(f"finalize evidence is missing raw timings: {timing_path}")
try:
    with timing_path.open(encoding="utf-8", newline="") as handle:
        rows = list(csv.DictReader(handle, delimiter="\t"))
except (csv.Error, OSError) as error:
    raise SystemExit(f"finalize evidence has invalid raw timings: {error}") from error
expected_fixtures = set(sys.argv[8:])
actual_fixtures = {row.get("fixture", "") for row in rows}
if actual_fixtures != expected_fixtures:
    missing = sorted(expected_fixtures - actual_fixtures)
    unexpected = sorted(actual_fixtures - expected_fixtures)
    details = []
    if missing:
        details.append("missing=" + ",".join(missing))
    if unexpected:
        details.append("unexpected=" + ",".join(unexpected))
    raise SystemExit("finalize fixture inventory does not match raw timings: " + "; ".join(details))
sample_counts = collections.Counter((row.get("fixture"), row.get("lane")) for row in rows)
invalid_counts = [
    f"{fixture}/{lane}={sample_counts[(fixture, lane)]}"
    for fixture in sorted(expected_fixtures)
    for lane in ("docker", "container-compose")
    if sample_counts[(fixture, lane)] != expected["repetitions"]
]
expected_pairs = {(fixture, lane) for fixture in expected_fixtures for lane in ("docker", "container-compose")}
unexpected_pairs = sorted(set(sample_counts) - expected_pairs)
if invalid_counts or unexpected_pairs:
    details = invalid_counts
    details += [f"unexpected-lane={fixture}/{lane}" for fixture, lane in unexpected_pairs]
    raise SystemExit("finalize sample counts do not match raw timings: " + ", ".join(details))
PY
}

# Render JUnit and Markdown evidence and enforce the 10x regression guard.
finalize_evidence() {
    python3 - "$TIMING_TSV" "$TIMING_JUNIT" "$TIMING_MATRIX" "$PARITY_TIMING_MAX_RATIO" \
        "$PARITY_COMPARABLE_NOISE_PCT" "$PARITY_REPETITIONS" "$PARITY_TIMING_POLICY" \
        "${PERFORMANCE_FIXTURES[@]}" <<'PY'
import csv, math, pathlib, statistics, sys, xml.etree.ElementTree as ET
from collections import defaultdict
timing, junit, matrix = map(pathlib.Path, sys.argv[1:4])
threshold = float(sys.argv[4])
noise_ratio = 1 + float(sys.argv[5]) / 100
repetitions = int(sys.argv[6])
policy = sys.argv[7]
expected = sys.argv[8:]
rows = list(csv.DictReader(timing.open(encoding="utf-8"), delimiter="\t")); grouped = defaultdict(lambda: defaultdict(list))
for row in rows: grouped[row["fixture"]][row["lane"]].append(row)
def p95(samples): return sorted(samples)[math.ceil(len(samples) * .95) - 1]
failures = []; table = []; suite = ET.Element("testsuite", name="compose-performance-matrix", tests=str(len(expected)))
unexpected = sorted(set(grouped) - set(expected))
if unexpected:
    failures.append("unexpected fixtures: " + ", ".join(unexpected))
for fixture in expected:
    docker = grouped[fixture].get("docker", []); candidate = grouped[fixture].get("container-compose", [])
    testcase = ET.SubElement(suite, "testcase", classname="parity.performance", name=fixture)
    ET.SubElement(testcase, "system-out").text = "\n".join(f"{r['lane']} repetition={r['repetition']} duration={r['duration_seconds']} outcome={r['outcome']}" for r in docker + candidate)
    valid_counts = len(docker) == repetitions and len(candidate) == repetitions
    valid_direction = all(r.get("direction") == "lower-is-better" for r in docker + candidate)
    by_key = {(r["lane"], int(r["repetition"])): r for r in docker + candidate}
    valid_schedule = len(by_key) == repetitions * 2 and all(
        by_key[(lane, repetition)]["schedule_position"]
        == str(1 if (repetition % 2 == 1) == (lane == "docker") else 2)
        for repetition in range(1, repetitions + 1)
        for lane in ("docker", "container-compose")
    )
    if not valid_counts or not valid_direction or not valid_schedule or any(r["outcome"] != "success" for r in docker + candidate):
        reason = "fixture did not retain the required successful lower-is-better samples in both lanes"; ET.SubElement(testcase, "failure", message=reason).text = reason; failures.append(f"{fixture}: {reason}"); table.append((fixture, "n/a", "n/a", "n/a", "n/a", "n/a", "n/a", "NOT MET", "FAIL")); continue
    d = [float(r["duration_seconds"]) for r in docker]; c = [float(r["duration_seconds"]) for r in candidate]
    dm = statistics.median(d); dp = p95(d); cm = statistics.median(c); cp = p95(c)
    median_ratio = cm / dm if dm else float("inf"); p95_ratio = cp / dp if dp else float("inf"); result = "PASS"
    comparable = "MET" if median_ratio <= noise_ratio and p95_ratio <= noise_ratio else "NOT MET"
    if median_ratio >= threshold or p95_ratio >= threshold:
        reason = f"candidate median/P95 ratios are {median_ratio:.2f}x/{p95_ratio:.2f}x; threshold is <{threshold:g}x"
        if policy == "enforce":
            ET.SubElement(testcase, "failure", message=reason).text = reason; failures.append(f"{fixture}: {reason}"); result = "FAIL"
        else:
            result = "RECORDED"
    testcase.set("time", f"{cm:.9f}"); table.append((fixture, f"{dm:.3f}", f"{dp:.3f}", f"{cm:.3f}", f"{cp:.3f}", f"{median_ratio:.2f}x", f"{p95_ratio:.2f}x", comparable, result))
suite.set("failures", str(len(failures))); ET.ElementTree(suite).write(junit, encoding="utf-8", xml_declaration=True)
policy_text = (
    f"Timeout, incomplete execution, or a candidate median/P95 at least {threshold:g}x Docker fails the regression guard."
    if policy == "enforce"
    else f"Timeout or incomplete execution fails; the {threshold:g}x timing threshold is recorded but not enforced for this published-version comparison."
)
lines = ["# Compose Performance Matrix", "", f"Warm-image same-host fixed-work samples. {policy_text} Comparable-or-better requires both candidate statistics to be within {(noise_ratio - 1) * 100:g}% of Docker.", "", "| Fixture | Docker median (s) | Docker P95 (s) | container-compose median (s) | container-compose P95 (s) | Median ratio | P95 ratio | Comparable or better | Guard |", "| --- | ---: | ---: | ---: | ---: | ---: | ---: | --- | --- |"]
lines += [f"| {' | '.join(row)} |" for row in table]; lines += ["", "Raw repetitions are in `timings.tsv`; exact host and runtime fingerprints are in `fingerprints.json`.", ""]
matrix.write_text("\n".join(lines), encoding="utf-8"); print("\n".join(lines))
if failures: raise SystemExit("\n".join(failures))
PY
}

# Warm each image and run counterbalanced lifecycle and logging samples.
run_matrix() {
    local count repetition file lane position fixture workload tail buffer_size
    file="$FIXTURE_DIR/services-1.yml"
    "$CONTAINER_COMPOSE" --ansi never -p cc-perf-c-1 -f "$file" pull --quiet >/dev/null
    initialize_evidence
    preflight_candidate_lifecycle
    if group_enabled lifecycle; then
        for count in 1 10 50; do
            file="$FIXTURE_DIR/services-$count.yml"
            "${DOCKER_COMPOSE_COMMAND[@]}" -p "cc-perf-d-$count" -f "$file" pull --quiet >/dev/null
            if ((count != 1)); then
                "$CONTAINER_COMPOSE" --ansi never -p "cc-perf-c-$count" -f "$file" pull --quiet >/dev/null
            fi
        done
    fi
    if group_enabled logging-stream || group_enabled logging-file ||
        group_enabled logging-read || group_enabled logging-aggregate; then
        "${DOCKER_COMPOSE_COMMAND[@]}" -p cc-perf-d-logging -f "$FIXTURE_DIR/logging.yml" pull --quiet >/dev/null
        "$CONTAINER_COMPOSE" --ansi never -p cc-perf-c-logging -f "$FIXTURE_DIR/logging.yml" pull --quiet >/dev/null
    fi
    for ((repetition = 1; repetition <= PARITY_REPETITIONS; repetition++)); do
        select_lane_order "$repetition"
        if group_enabled lifecycle; then
            for count in 1 10 50; do
                file="$FIXTURE_DIR/services-$count.yml"
                position=0
                for lane in "${LANE_ORDER[@]}"; do
                    ((position += 1))
                    run_lifecycle_lane "$lane" "$repetition" "$position" "$count" "$file"
                done
            done
        fi
        if group_enabled logging-stream; then
            position=0
            for lane in "${LANE_ORDER[@]}"; do
                ((position += 1))
                run_logging_startup_lane "$lane" "$repetition" "$position" "$FIXTURE_DIR/logging.yml"
            done
            position=0
            for lane in "${LANE_ORDER[@]}"; do
                ((position += 1))
                run_logging_attached_startup_lane \
                    "$lane" "$repetition" "$position" "$FIXTURE_DIR/logging.yml"
            done
            for fixture in "${LOGGING_WORKLOADS[@]}"; do
                workload="${fixture#logging-}"
                position=0
                for lane in "${LANE_ORDER[@]}"; do
                    ((position += 1))
                    run_logging_throughput_lane "$lane" "$repetition" "$position" \
                        "$fixture" "$workload" "$FIXTURE_DIR/logging.yml"
                done
            done
            if [[ "$PARITY_INCLUDE_REMOTE_LOGGING" == 1 ]]; then
                position=0
                for lane in "${LANE_ORDER[@]}"; do
                    ((position += 1))
                    run_remote_sink_lane "$lane" "$repetition" "$position" \
                        logging-blocking-slow-sink \
                        "$FIXTURE_DIR/logging-remote-blocking.yml" \
                        "$PARITY_SINK_STALL_SECONDS" exact unused
                done
                for buffer_size in "${LOGGING_NONBLOCKING_BUFFERS[@]}"; do
                    position=0
                    for lane in "${LANE_ORDER[@]}"; do
                        ((position += 1))
                        run_remote_sink_lane "$lane" "$repetition" "$position" \
                            "logging-nonblocking-$buffer_size" \
                            "$FIXTURE_DIR/logging-remote-nonblocking.yml" \
                            "$PARITY_SINK_STALL_SECONDS" dropped "$buffer_size"
                    done
                done
            fi
        fi
        if group_enabled logging-file; then
            for fixture in logging-write-json-compression logging-write-local-rotation; do
                if [[ "$fixture" == logging-write-json-compression ]]; then
                    file="$FIXTURE_DIR/logging-json-compress.yml"
                else
                    file="$FIXTURE_DIR/logging-local.yml"
                fi
                position=0
                for lane in "${LANE_ORDER[@]}"; do
                    ((position += 1))
                    run_file_logging_lane \
                        "$lane" "$repetition" "$position" "$fixture" "$file"
                done
            done
        fi
        if group_enabled logging-read; then
            for lane in "${LANE_ORDER[@]}"; do
                prepare_logging_history "$lane" "$FIXTURE_DIR/logging.yml"
            done
            for tail in 10 1000 all; do
                fixture="logging-read-tail-$tail"
                [[ "$tail" == all ]] && fixture=logging-read-all
                position=0
                for lane in "${LANE_ORDER[@]}"; do
                    ((position += 1))
                    run_logging_read_lane "$lane" "$repetition" "$position" \
                        "$fixture" "$tail" "$FIXTURE_DIR/logging.yml"
                done
            done
            position=0
            for lane in "${LANE_ORDER[@]}"; do
                ((position += 1))
                run_logging_since_until_lane \
                    "$lane" "$repetition" "$position" "$FIXTURE_DIR/logging.yml"
            done
            for lane in docker container-compose; do
                select_lane "$lane"
                down_project "$lane" "cc-perf-$LANE_PREFIX-logging" "$FIXTURE_DIR/logging.yml"
            done
            position=0
            for lane in "${LANE_ORDER[@]}"; do
                ((position += 1))
                run_logging_follow_lane "$lane" "$repetition" "$position" "$FIXTURE_DIR/logging.yml"
            done
            if [[ "$PARITY_INCLUDE_REMOTE_LOGGING" == 1 ]]; then
                position=0
                for lane in "${LANE_ORDER[@]}"; do
                    ((position += 1))
                    run_dual_cache_lane \
                        "$lane" "$repetition" "$position" "$FIXTURE_DIR/logging-remote-cache.yml"
                done
            fi
        fi
        if group_enabled logging-aggregate; then
            for count in 1 10 50; do
                position=0
                for lane in "${LANE_ORDER[@]}"; do
                    ((position += 1))
                    run_logging_aggregate_lane "$lane" "$repetition" "$position" \
                        "$count" "$FIXTURE_DIR/aggregate-$count.yml"
                done
            done
        fi
    done
    if [[ "$PARITY_FINALIZE_EVIDENCE" == 1 ]]; then
        validate_finalize_fingerprint
        finalize_evidence
    fi
}

main() {
    parse_args "$@"
    if ((LIST_FIXTURES == 1)); then
        validate_configuration
        list_fixtures
        return
    fi
    if ((FINALIZE_ONLY == 1)); then
        validate_configuration
        validate_finalize_fingerprint
        finalize_evidence
        return
    fi
    check_tools
    create_fixtures
    trap cleanup EXIT INT TERM
    run_matrix
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
