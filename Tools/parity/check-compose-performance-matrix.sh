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
#   --strict    Fail when a required local runtime is unavailable.
#   -h, --help  Show this help.
#
# ENVIRONMENT:
#   CONTAINER_COMPOSE            Local container-compose binary.
#   CONTAINER_COMPOSE_CONTAINER  Matching Apple container CLI.
#   DOCKER_COMPOSE               Docker Compose command to compare with.
#   PARITY_EVIDENCE_DIR          Raw samples, JUnit, fingerprints, and matrix.
#   PARITY_REPETITIONS           Timed repetitions per lane (default: 5).
#   PARITY_TIMEOUT_SECONDS       Per-operation timeout (default: 300).
#   PARITY_TIMING_MAX_RATIO      Candidate median limit (default: 10).
#
# This local-only comparator records warm-image same-host evidence for the
# first representative matrix lane: detached 1/10/50-service startup and
# teardown. It reports median and P95 and keeps the established 10x regression
# guard. Logs, develop sync, and build-context transfer remain explicit later
# lanes rather than being silently inferred from these results.

set -euo pipefail

readonly SELF_PATH="${BASH_SOURCE[0]:-$0}"
SCRIPT_NAME="$(basename "$SELF_PATH")"
readonly SCRIPT_NAME
REPO_ROOT="$(cd "$(dirname "$SELF_PATH")/../.." && pwd)"
readonly REPO_ROOT
STRICT=0
FIXTURE_DIR=""
CONTAINER_COMPOSE="${CONTAINER_COMPOSE:-$REPO_ROOT/.build/debug/compose}"
CONTAINER_BINARY="${CONTAINER_COMPOSE_CONTAINER:-container}"
PARITY_EVIDENCE_DIR="${PARITY_EVIDENCE_DIR:-$REPO_ROOT/.build/parity/performance-matrix}"
PARITY_REPETITIONS="${PARITY_REPETITIONS:-5}"
PARITY_TIMEOUT_SECONDS="${PARITY_TIMEOUT_SECONDS:-300}"
PARITY_TIMING_MAX_RATIO="${PARITY_TIMING_MAX_RATIO:-10}"
readonly FIXTURE_IMAGE="alpine:3.20"
readonly TIMING_TSV="$PARITY_EVIDENCE_DIR/timings.tsv"
readonly TIMING_JUNIT="$PARITY_EVIDENCE_DIR/timings.junit.xml"
readonly TIMING_MATRIX="$PARITY_EVIDENCE_DIR/timing-matrix.md"
readonly FINGERPRINT_JSON="$PARITY_EVIDENCE_DIR/fingerprints.json"
DOCKER_COMPOSE_COMMAND=()

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
            -h | --help) usage; exit 0 ;;
            *) error "unknown argument: $1"; usage >&2; return 2 ;;
        esac
        shift
    done
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
}

# Remove generated projects and the local fixture directory.
cleanup() {
    local count
    for count in 1 10 50; do
        "${DOCKER_COMPOSE_COMMAND[@]}" -p "cc-perf-d-$count" -f "$FIXTURE_DIR/services-$count.yml" down --volumes --remove-orphans >/dev/null 2>&1 || true
        "$CONTAINER_COMPOSE" --ansi never -p "cc-perf-c-$count" -f "$FIXTURE_DIR/services-$count.yml" down --volumes --remove-orphans >/dev/null 2>&1 || true
    done
    [[ -z "$FIXTURE_DIR" ]] || rm -rf "$FIXTURE_DIR"
}

# Write one otherwise-identical Compose project for each service count.
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
    done
}

# Initialize raw samples and exact run fingerprints.
initialize_evidence() {
    mkdir -p "$PARITY_EVIDENCE_DIR"
    PARITY_REPETITIONS="$PARITY_REPETITIONS" python3 - "$TIMING_TSV" "$FINGERPRINT_JSON" \
        "$("${DOCKER_COMPOSE_COMMAND[@]}" version --short)" "$(docker version --format '{{json .Server}}')" \
        "$("$CONTAINER_COMPOSE" version)" "$("$CONTAINER_BINARY" system version --format json)" \
        "$(git -C "$REPO_ROOT" rev-parse HEAD)" "$(sysctl -n hw.model)" "$(sysctl -n hw.memsize)" \
        "$(sw_vers -productVersion)" "$(uname -m)" "$(shasum -a 256 "$CONTAINER_COMPOSE" | awk '{print $1}')" \
        "$(shasum -a 256 "$(command -v "$CONTAINER_BINARY")" | awk '{print $1}')" <<'PY'
import json, os, pathlib, sys
from datetime import datetime, timezone
(timing, fingerprints, docker_compose, docker_engine, compose_version, runtime_version, commit, model, memory, macos, architecture, compose_sha, runtime_sha) = sys.argv[1:]
def decode(value):
    try: return json.loads(value)
    except json.JSONDecodeError: return value
pathlib.Path(timing).write_text("fixture\tlane\trepetition\tduration_seconds\toutcome\tcommand\n", encoding="utf-8")
pathlib.Path(fingerprints).write_text(json.dumps({
    "capturedAt": datetime.now(timezone.utc).isoformat(),
    "conditions": {"image": "alpine:3.20", "mode": "warm", "repetitions": int(os.environ["PARITY_REPETITIONS"])},
    "containerCompose": {"commit": commit, "sha256": compose_sha, "version": compose_version},
    "containerRuntime": {"sha256": runtime_sha, "version": decode(runtime_version)},
    "docker": {"composeVersion": docker_compose, "engine": decode(docker_engine)},
    "host": {"architecture": architecture, "hardwareMemoryBytes": int(memory), "hardwareModel": model, "macOSVersion": macos},
}, indent=2, sort_keys=True) + "\n", encoding="utf-8")
PY
}

# Run one command under a monotonic timeout and append the raw outcome.
run_timed() {
    local fixture="$1" lane="$2" repetition="$3"
    shift 3
    python3 - "$TIMING_TSV" "$fixture" "$lane" "$repetition" "$PARITY_TIMEOUT_SECONDS" "$@" <<'PY'
import csv, os, shlex, signal, subprocess, sys, time
timing, fixture, lane, repetition, timeout, *command = sys.argv[1:]
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
    csv.writer(handle, delimiter="\t", lineterminator="\n").writerow([fixture, lane, repetition, f"{duration:.9f}", outcome, shlex.join(command)])
print(f"{fixture} {lane} repetition {repetition}: {duration:.3f}s ({outcome})")
if outcome != "success":
    if stderr: print(stderr, file=sys.stderr, end="" if stderr.endswith("\n") else "\n")
    raise SystemExit(124 if outcome == "timeout" else process.returncode or 1)
PY
}

# Render JUnit and Markdown evidence and enforce the 10x regression guard.
finalize_evidence() {
    python3 - "$TIMING_TSV" "$TIMING_JUNIT" "$TIMING_MATRIX" "$PARITY_TIMING_MAX_RATIO" <<'PY'
import csv, math, pathlib, statistics, sys, xml.etree.ElementTree as ET
from collections import defaultdict
timing, junit, matrix = map(pathlib.Path, sys.argv[1:4])
threshold = float(sys.argv[4])
rows = list(csv.DictReader(timing.open(encoding="utf-8"), delimiter="\t")); grouped = defaultdict(lambda: defaultdict(list))
for row in rows: grouped[row["fixture"]][row["lane"]].append(row)
def p95(samples): return sorted(samples)[math.ceil(len(samples) * .95) - 1]
failures = []; table = []; suite = ET.Element("testsuite", name="compose-performance-matrix", tests=str(len(grouped)))
for fixture in sorted(grouped):
    docker = grouped[fixture].get("docker", []); candidate = grouped[fixture].get("container-compose", [])
    testcase = ET.SubElement(suite, "testcase", classname="parity.performance", name=fixture)
    ET.SubElement(testcase, "system-out").text = "\n".join(f"{r['lane']} repetition={r['repetition']} duration={r['duration_seconds']} outcome={r['outcome']}" for r in docker + candidate)
    if not docker or not candidate or any(r["outcome"] != "success" for r in docker + candidate):
        reason = "fixture did not complete successfully in both lanes"; ET.SubElement(testcase, "failure", message=reason).text = reason; failures.append(f"{fixture}: {reason}"); table.append((fixture, "n/a", "n/a", "n/a", "n/a", "n/a", "FAIL")); continue
    d = [float(r["duration_seconds"]) for r in docker]; c = [float(r["duration_seconds"]) for r in candidate]
    dm = statistics.median(d); cm = statistics.median(c); ratio = cm / dm if dm else float("inf"); result = "PASS"
    if ratio >= threshold:
        reason = f"candidate median is {ratio:.2f}x the Docker reference; threshold is <{threshold:g}x"; ET.SubElement(testcase, "failure", message=reason).text = reason; failures.append(f"{fixture}: {reason}"); result = "FAIL"
    testcase.set("time", f"{cm:.9f}"); table.append((fixture, f"{dm:.3f}", f"{p95(d):.3f}", f"{cm:.3f}", f"{p95(c):.3f}", f"{ratio:.2f}x", result))
suite.set("failures", str(len(failures))); ET.ElementTree(suite).write(junit, encoding="utf-8", xml_declaration=True)
lines = ["# Compose Performance Matrix", "", "Warm-image same-host samples. The executable rule is timeout, incomplete execution, or a candidate median at least 10x Docker; this is evidence, not a comparable-performance claim.", "", "| Fixture | Docker median (s) | Docker P95 (s) | container-compose median (s) | container-compose P95 (s) | Candidate/reference | Result |", "| --- | ---: | ---: | ---: | ---: | ---: | --- |"]
lines += [f"| {' | '.join(row)} |" for row in table]; lines += ["", "Raw repetitions are in `timings.tsv`; exact host and runtime fingerprints are in `fingerprints.json`.", ""]
matrix.write_text("\n".join(lines), encoding="utf-8"); print("\n".join(lines))
if failures: raise SystemExit("\n".join(failures))
PY
}

# Warm each image and compare startup then teardown across both engines.
run_matrix() {
    local count repetition file
    for count in 1 10 50; do
        file="$FIXTURE_DIR/services-$count.yml"
        "${DOCKER_COMPOSE_COMMAND[@]}" -p "cc-perf-d-$count" -f "$file" pull --quiet >/dev/null
        "$CONTAINER_COMPOSE" --ansi never -p "cc-perf-c-$count" -f "$file" pull --quiet >/dev/null
    done
    initialize_evidence
    for ((repetition = 1; repetition <= PARITY_REPETITIONS; repetition++)); do
        for count in 1 10 50; do
            file="$FIXTURE_DIR/services-$count.yml"
            run_timed "startup-$count-services" docker "$repetition" "${DOCKER_COMPOSE_COMMAND[@]}" -p "cc-perf-d-$count" -f "$file" up -d --pull never
            run_timed "teardown-$count-services" docker "$repetition" "${DOCKER_COMPOSE_COMMAND[@]}" -p "cc-perf-d-$count" -f "$file" down --volumes --remove-orphans
            run_timed "startup-$count-services" container-compose "$repetition" "$CONTAINER_COMPOSE" --ansi never -p "cc-perf-c-$count" -f "$file" up -d --pull never
            run_timed "teardown-$count-services" container-compose "$repetition" "$CONTAINER_COMPOSE" --ansi never -p "cc-perf-c-$count" -f "$file" down --volumes --remove-orphans
        done
    done
    finalize_evidence
}

main() {
    parse_args "$@"; check_tools; create_fixtures; trap cleanup EXIT INT TERM; run_matrix
}

main "$@"
