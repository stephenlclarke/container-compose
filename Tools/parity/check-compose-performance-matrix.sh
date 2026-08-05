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
#   --list-fixtures  Print the retained fixture identifiers without running.
#   -h, --help       Show this help.
#
# ENVIRONMENT:
#   CONTAINER_COMPOSE            Local container-compose binary.
#   CONTAINER_COMPOSE_CONTAINER  Matching Apple container CLI.
#   DOCKER_COMPOSE               Docker Compose command to compare with.
#   PARITY_EVIDENCE_DIR          Raw samples, JUnit, fingerprints, and matrix.
#   PARITY_REPETITIONS           Timed repetitions per lane (default: 5).
#   PARITY_TIMEOUT_SECONDS       Per-operation timeout (default: 300).
#   PARITY_TIMING_MAX_RATIO      Candidate median/P95 limit (default: 10).
#   PARITY_COMPARABLE_NOISE_PCT  Comparable-performance noise band (default: 5).
#
# This local-only comparator records warm-image same-host evidence for the
# representative lifecycle and logging lanes. It covers detached 1/10/50-
# service startup/teardown, startup to first log, fixed stdout/stderr/mixed
# throughput, 16 KiB and 1 MiB records, tail 10/1,000/all, follow across forced
# rotation, and 1/10/50-service foreground aggregation. It reports median/P95,
# keeps the established 10x regression guard, and separately records whether
# both candidate statistics are comparable to or better than Docker outside
# the configured noise band. Develop sync and build-context transfer remain
# explicit non-logging lanes.

set -euo pipefail

readonly SELF_PATH="${BASH_SOURCE[0]:-$0}"
SCRIPT_NAME="$(basename "$SELF_PATH")"
readonly SCRIPT_NAME
REPO_ROOT="$(cd "$(dirname "$SELF_PATH")/../.." && pwd)"
readonly REPO_ROOT
STRICT=0
LIST_FIXTURES=0
FIXTURE_DIR=""
CONTAINER_COMPOSE="${CONTAINER_COMPOSE:-$REPO_ROOT/.build/debug/compose}"
CONTAINER_BINARY="${CONTAINER_COMPOSE_CONTAINER:-container}"
PARITY_EVIDENCE_DIR="${PARITY_EVIDENCE_DIR:-$REPO_ROOT/.build/parity/performance-matrix}"
PARITY_REPETITIONS="${PARITY_REPETITIONS:-5}"
PARITY_TIMEOUT_SECONDS="${PARITY_TIMEOUT_SECONDS:-300}"
PARITY_TIMING_MAX_RATIO="${PARITY_TIMING_MAX_RATIO:-10}"
PARITY_COMPARABLE_NOISE_PCT="${PARITY_COMPARABLE_NOISE_PCT:-5}"
readonly FIXTURE_IMAGE="alpine:3.20"
readonly TIMING_TSV="$PARITY_EVIDENCE_DIR/timings.tsv"
readonly TIMING_JUNIT="$PARITY_EVIDENCE_DIR/timings.junit.xml"
readonly TIMING_MATRIX="$PARITY_EVIDENCE_DIR/timing-matrix.md"
readonly FINGERPRINT_JSON="$PARITY_EVIDENCE_DIR/fingerprints.json"
DOCKER_COMPOSE_COMMAND=()
ACTIVE_COMPOSE=()
LANE_ORDER=()
LANE_PREFIX=""
readonly LOGGING_WORKLOADS=(
    logging-throughput-stdout-small
    logging-throughput-stderr-small
    logging-throughput-mixed-small
    logging-throughput-stdout-16k
    logging-throughput-stdout-1m
)
readonly PERFORMANCE_FIXTURES=(
    startup-1-services teardown-1-services
    startup-10-services teardown-10-services
    startup-50-services teardown-50-services
    logging-startup-first-output
    "${LOGGING_WORKLOADS[@]}"
    logging-read-tail-10
    logging-read-tail-1000
    logging-read-all
    logging-follow-rotation
    logging-aggregate-1-services
    logging-aggregate-10-services
    logging-aggregate-50-services
)

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
            -h | --help) usage; exit 0 ;;
            *) error "unknown argument: $1"; usage >&2; return 2 ;;
        esac
        shift
    done
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
    detect_docker_compose
    docker info >/dev/null 2>&1 || skip_or_fail 'Docker Engine is unavailable'
    [[ -x "$CONTAINER_COMPOSE" ]] || skip_or_fail "container-compose binary is not executable: $CONTAINER_COMPOSE"
    command -v "$CONTAINER_BINARY" >/dev/null 2>&1 || skip_or_fail "container runtime is unavailable: $CONTAINER_BINARY"
    command -v python3 >/dev/null 2>&1 || skip_or_fail 'python3 is unavailable'
    [[ "$PARITY_REPETITIONS" =~ ^[1-9][0-9]*$ ]] || { error "PARITY_REPETITIONS must be a positive integer"; return 2; }
    [[ "$PARITY_TIMEOUT_SECONDS" =~ ^[1-9][0-9]*$ ]] || { error "PARITY_TIMEOUT_SECONDS must be a positive integer"; return 2; }
    [[ "$PARITY_TIMING_MAX_RATIO" =~ ^[1-9][0-9]*(\.[0-9]+)?$ ]] || { error "PARITY_TIMING_MAX_RATIO must be positive"; return 2; }
    [[ "$PARITY_COMPARABLE_NOISE_PCT" =~ ^[0-9]+(\.[0-9]+)?$ ]] || { error "PARITY_COMPARABLE_NOISE_PCT must be zero or positive"; return 2; }
}

# Remove generated projects and the local fixture directory.
cleanup() {
    local count
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
    mkdir -p "$REPO_ROOT/.build/parity"
    FIXTURE_DIR="$(mktemp -d "$REPO_ROOT/.build/parity/performance-matrix.XXXXXX")"
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
            '          *)' \
            '            printf '\''unknown logging workload: %s\n'\'' "$${LOG_WORKLOAD}" >&2' \
            '            exit 64' \
            '            ;;' \
            '        esac' \
            '    logging:' \
            '      driver: json-file' \
            '      options:' \
            '        max-size: "${LOG_MAX_SIZE:-64m}"' \
            '        max-file: "3"'
    } >"$FIXTURE_DIR/logging.yml"
}

# Initialize raw samples and exact run fingerprints.
initialize_evidence() {
    mkdir -p "$PARITY_EVIDENCE_DIR"
    PARITY_REPETITIONS="$PARITY_REPETITIONS" python3 - "$TIMING_TSV" "$FINGERPRINT_JSON" \
        "$("${DOCKER_COMPOSE_COMMAND[@]}" version --short)" "$(docker version --format '{{json .Server}}')" \
        "$("$CONTAINER_COMPOSE" version)" "$("$CONTAINER_BINARY" system version --format json)" \
        "$(git -C "$REPO_ROOT" rev-parse HEAD)" "$(sysctl -n hw.model)" "$(sysctl -n hw.memsize)" \
        "$(sw_vers -productVersion)" "$(uname -m)" "$(shasum -a 256 "$CONTAINER_COMPOSE" | awk '{print $1}')" \
        "$(shasum -a 256 "$(command -v "$CONTAINER_BINARY")" | awk '{print $1}')" \
        "$PARITY_COMPARABLE_NOISE_PCT" <<'PY'
import json, os, pathlib, sys
from datetime import datetime, timezone
(timing, fingerprints, docker_compose, docker_engine, compose_version, runtime_version, commit, model, memory, macos, architecture, compose_sha, runtime_sha, noise) = sys.argv[1:]
def decode(value):
    try: return json.loads(value)
    except json.JSONDecodeError: return value
pathlib.Path(timing).write_text("fixture\tlane\trepetition\tschedule_position\tdirection\tduration_seconds\toutcome\tcommand\n", encoding="utf-8")
pathlib.Path(fingerprints).write_text(json.dumps({
    "capturedAt": datetime.now(timezone.utc).isoformat(),
    "conditions": {
        "comparableNoisePercent": float(noise),
        "image": "alpine:3.20",
        "mode": "warm",
        "repetitions": int(os.environ["PARITY_REPETITIONS"]),
        "schedule": "Docker-first on odd repetitions; candidate-first on even repetitions",
        "timingDirection": "lower-is-better fixed-work duration",
    },
    "containerCompose": {"commit": commit, "sha256": compose_sha, "version": compose_version},
    "containerRuntime": {"sha256": runtime_sha, "version": decode(runtime_version)},
    "docker": {"composeVersion": docker_compose, "engine": decode(docker_engine)},
    "host": {"architecture": architecture, "hardwareMemoryBytes": int(memory), "hardwareModel": model, "macOSVersion": macos},
}, indent=2, sort_keys=True) + "\n", encoding="utf-8")
PY
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

# Populate one deterministic history corpus outside the timed read interval.
prepare_logging_history() {
    local lane="$1" file="$2" project
    select_lane "$lane"
    project="cc-perf-$LANE_PREFIX-logging"
    down_project "$lane" "$project" "$file"
    env LOG_WORKLOAD=history LOG_MAX_SIZE=64m \
        "${ACTIVE_COMPOSE[@]}" -p "$project" -f "$file" up \
        --abort-on-container-exit --exit-code-from logger --pull never >/dev/null
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

# Render JUnit and Markdown evidence and enforce the 10x regression guard.
finalize_evidence() {
    python3 - "$TIMING_TSV" "$TIMING_JUNIT" "$TIMING_MATRIX" "$PARITY_TIMING_MAX_RATIO" \
        "$PARITY_COMPARABLE_NOISE_PCT" "$PARITY_REPETITIONS" "${PERFORMANCE_FIXTURES[@]}" <<'PY'
import csv, math, pathlib, statistics, sys, xml.etree.ElementTree as ET
from collections import defaultdict
timing, junit, matrix = map(pathlib.Path, sys.argv[1:4])
threshold = float(sys.argv[4])
noise_ratio = 1 + float(sys.argv[5]) / 100
repetitions = int(sys.argv[6])
expected = sys.argv[7:]
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
        ET.SubElement(testcase, "failure", message=reason).text = reason; failures.append(f"{fixture}: {reason}"); result = "FAIL"
    testcase.set("time", f"{cm:.9f}"); table.append((fixture, f"{dm:.3f}", f"{dp:.3f}", f"{cm:.3f}", f"{cp:.3f}", f"{median_ratio:.2f}x", f"{p95_ratio:.2f}x", comparable, result))
suite.set("failures", str(len(failures))); ET.ElementTree(suite).write(junit, encoding="utf-8", xml_declaration=True)
lines = ["# Compose Performance Matrix", "", f"Warm-image same-host fixed-work samples. Timeout, incomplete execution, or a candidate median/P95 at least {threshold:g}x Docker fails the regression guard. Comparable-or-better requires both candidate statistics to be within {(noise_ratio - 1) * 100:g}% of Docker.", "", "| Fixture | Docker median (s) | Docker P95 (s) | container-compose median (s) | container-compose P95 (s) | Median ratio | P95 ratio | Comparable or better | Guard |", "| --- | ---: | ---: | ---: | ---: | ---: | ---: | --- | --- |"]
lines += [f"| {' | '.join(row)} |" for row in table]; lines += ["", "Raw repetitions are in `timings.tsv`; exact host and runtime fingerprints are in `fingerprints.json`.", ""]
matrix.write_text("\n".join(lines), encoding="utf-8"); print("\n".join(lines))
if failures: raise SystemExit("\n".join(failures))
PY
}

# Warm each image and run counterbalanced lifecycle and logging samples.
run_matrix() {
    local count repetition file lane position fixture workload tail
    for count in 1 10 50; do
        file="$FIXTURE_DIR/services-$count.yml"
        "${DOCKER_COMPOSE_COMMAND[@]}" -p "cc-perf-d-$count" -f "$file" pull --quiet >/dev/null
        "$CONTAINER_COMPOSE" --ansi never -p "cc-perf-c-$count" -f "$file" pull --quiet >/dev/null
    done
    "${DOCKER_COMPOSE_COMMAND[@]}" -p cc-perf-d-logging -f "$FIXTURE_DIR/logging.yml" pull --quiet >/dev/null
    "$CONTAINER_COMPOSE" --ansi never -p cc-perf-c-logging -f "$FIXTURE_DIR/logging.yml" pull --quiet >/dev/null
    initialize_evidence
    for ((repetition = 1; repetition <= PARITY_REPETITIONS; repetition++)); do
        select_lane_order "$repetition"
        for count in 1 10 50; do
            file="$FIXTURE_DIR/services-$count.yml"
            position=0
            for lane in "${LANE_ORDER[@]}"; do
                ((position += 1))
                run_lifecycle_lane "$lane" "$repetition" "$position" "$count" "$file"
            done
        done
        position=0
        for lane in "${LANE_ORDER[@]}"; do
            ((position += 1))
            run_logging_startup_lane "$lane" "$repetition" "$position" "$FIXTURE_DIR/logging.yml"
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
        for lane in docker container-compose; do
            select_lane "$lane"
            down_project "$lane" "cc-perf-$LANE_PREFIX-logging" "$FIXTURE_DIR/logging.yml"
        done
        position=0
        for lane in "${LANE_ORDER[@]}"; do
            ((position += 1))
            run_logging_follow_lane "$lane" "$repetition" "$position" "$FIXTURE_DIR/logging.yml"
        done
        for count in 1 10 50; do
            position=0
            for lane in "${LANE_ORDER[@]}"; do
                ((position += 1))
                run_logging_aggregate_lane "$lane" "$repetition" "$position" \
                    "$count" "$FIXTURE_DIR/aggregate-$count.yml"
            done
        done
    done
    finalize_evidence
}

main() {
    parse_args "$@"
    if ((LIST_FIXTURES == 1)); then
        list_fixtures
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
