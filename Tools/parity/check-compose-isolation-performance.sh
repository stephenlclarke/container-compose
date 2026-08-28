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

# Focused, resumable lifecycle comparison for Docker Compose and the
# dedicated-vm/shared-vm apple/container isolation modes.

set -euo pipefail

readonly SELF_PATH="${BASH_SOURCE[0]:-$0}"
REPO_ROOT="$(cd "$(dirname "$SELF_PATH")/../.." && pwd)"
readonly REPO_ROOT
STRICT=0
LIST_FIXTURES=0
FIXTURE_DIR=""
CONTAINER_COMPOSE="${CONTAINER_COMPOSE:-$REPO_ROOT/.build/release/compose}"
CONTAINER_BINARY="${CONTAINER_COMPOSE_CONTAINER:-container}"
NORMALIZER_BINARY="${CONTAINER_COMPOSE_NORMALIZER:-$REPO_ROOT/Tools/compose-normalizer/compose-normalizer}"
ISOLATION_EVIDENCE_DIR="${ISOLATION_EVIDENCE_DIR:-${TMPDIR:-/private/tmp}/container-compose-isolation-evidence}"
ISOLATION_WORK_ROOT="${ISOLATION_WORK_ROOT:-${TMPDIR:-/private/tmp}/container-compose-isolation-work}"
ISOLATION_REPETITIONS="${ISOLATION_REPETITIONS:-6}"
ISOLATION_TIMEOUT_SECONDS="${ISOLATION_TIMEOUT_SECONDS:-300}"
ISOLATION_TIMING_MAX_RATIO="${ISOLATION_TIMING_MAX_RATIO:-10}"
ISOLATION_COMPARABLE_NOISE_PCT="${ISOLATION_COMPARABLE_NOISE_PCT:-5}"
readonly FIXTURE_IMAGE="${ISOLATION_FIXTURE_IMAGE:-alpine:3.20}"
readonly TIMING_TSV="$ISOLATION_EVIDENCE_DIR/timings.tsv"
readonly ASSERTION_TSV="$ISOLATION_EVIDENCE_DIR/assertions.tsv"
readonly SCHEDULE_TSV="$ISOLATION_EVIDENCE_DIR/schedule.tsv"
readonly TIMING_JUNIT="$ISOLATION_EVIDENCE_DIR/timings.junit.xml"
readonly TIMING_MATRIX="$ISOLATION_EVIDENCE_DIR/timing-matrix.md"
readonly FINGERPRINT_JSON="$ISOLATION_EVIDENCE_DIR/fingerprints.json"
readonly ISOLATION_LANES=(docker dedicated-vm shared-vm)
readonly ISOLATION_FIXTURES=(
    startup-1-services teardown-1-services
    startup-10-services teardown-10-services
    startup-50-services teardown-50-services
)
DOCKER_COMPOSE_COMMAND=()
DOCKER_BINARY=""
ACTIVE_COMPOSE=()
LANE_ORDER=()
LANE_PREFIX=""
DOCKER_CONTEXT_NAME=""
DOCKER_ENDPOINT=""
PROJECT_NAMESPACE=""
RUN_LOCK_DIR=""
RUN_LOCK_FD=""
ISOLATION_WORK_ROOT_CANONICAL=""
ISOLATION_WORK_ROOT_DEVICE=""

error() { printf 'error: %s\n' "$*" >&2; }
warning() { printf 'warning: %s\n' "$*" >&2; }

usage() {
    cat <<'EOF'
USAGE:
  check-compose-isolation-performance.sh [options]

OPTIONS:
  --strict         Fail when a required local runtime is unavailable.
  --list-fixtures  Print the retained fixture identifiers without running.
  -h, --help       Show this help.

ENVIRONMENT:
  CONTAINER_COMPOSE             Exact container-compose binary.
  CONTAINER_COMPOSE_CONTAINER   Exact apple/container binary.
  CONTAINER_COMPOSE_NORMALIZER  Exact compose-normalizer binary.
  DOCKER_COMPOSE                Optional `docker compose` selector; wrappers
                                and alternate clients are rejected.
  ISOLATION_EVIDENCE_DIR        Persistent, resumable evidence directory.
  ISOLATION_WORK_ROOT           Internal-storage fixture directory.
  ISOLATION_REPETITIONS         Timed repetitions per lane (default: 6).
  ISOLATION_FIXTURE_IMAGE       Warm image reference shared by both runtimes
                                (default: alpine:3.20).
  ISOLATION_TIMEOUT_SECONDS     Per-operation timeout (default: 300).
  ISOLATION_TIMING_MAX_RATIO    Candidate regression guard (default: 10).
  ISOLATION_COMPARABLE_NOISE_PCT
                                Same-host comparison noise band (default: 5).
  COMPOSE_PARALLEL_LIMIT        Compose engine-operation concurrency setting;
                                its exact value is fingerprinted for resumption.

Both writable directories must be on internal storage. The harness never
pulls images: alpine:3.20 must already be warm in Docker and apple/container.
Successful samples are checkpointed, so an interrupted run resumes at the
first incomplete lifecycle pair.
EOF
}

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

skip_or_fail() {
    if ((STRICT == 1)); then error "$1"; return 1; fi
    warning "$1; skipping Compose isolation performance matrix"
    exit 0
}

detect_docker_compose() {
    command -v docker >/dev/null 2>&1 || skip_or_fail 'Docker CLI is unavailable'
    DOCKER_BINARY="$(command -v docker)"
    if [[ -n "${DOCKER_COMPOSE:-}" ]]; then
        local requested=() requested_binary=""
        IFS=' ' read -r -a requested <<<"$DOCKER_COMPOSE"
        [[ "${#requested[@]}" == 2 && "${requested[1]}" == compose ]] || {
            error "DOCKER_COMPOSE must select the validated Docker CLI as: docker compose"
            return 2
        }
        requested_binary="$(command -v "${requested[0]}" 2>/dev/null || true)"
        [[ "$requested_binary" == "$DOCKER_BINARY" ]] || {
            error "DOCKER_COMPOSE must use the same Docker CLI validated by the harness"
            return 2
        }
    fi
    if ! "$DOCKER_BINARY" compose version >/dev/null 2>&1; then
        skip_or_fail 'Docker Compose V2 is unavailable'
    fi
    DOCKER_COMPOSE_COMMAND=("$DOCKER_BINARY" compose)
}

# Pins Docker measurements to a live local Unix-socket context.
require_local_docker_context() {
    [[ -n "$DOCKER_BINARY" ]] || DOCKER_BINARY="$(command -v docker)"
    if [[ -n "${DOCKER_CONTEXT:-}" ]]; then
        DOCKER_CONTEXT_NAME="$DOCKER_CONTEXT"
        DOCKER_ENDPOINT="$("$DOCKER_BINARY" context inspect "$DOCKER_CONTEXT_NAME" --format '{{(index .Endpoints "docker").Host}}')"
    elif [[ -n "${DOCKER_HOST:-}" ]]; then
        DOCKER_CONTEXT_NAME="DOCKER_HOST"
        DOCKER_ENDPOINT="$DOCKER_HOST"
    else
        DOCKER_CONTEXT_NAME="$("$DOCKER_BINARY" context show)"
        DOCKER_ENDPOINT="$("$DOCKER_BINARY" context inspect "$DOCKER_CONTEXT_NAME" --format '{{(index .Endpoints "docker").Host}}')"
    fi
    if [[ "$DOCKER_ENDPOINT" != unix://* ]]; then
        error "Docker context '$DOCKER_CONTEXT_NAME' is not local: $DOCKER_ENDPOINT"
        return 1
    fi
    local socket_path="${DOCKER_ENDPOINT#unix://}"
    if [[ ! -S "$socket_path" ]]; then
        skip_or_fail "Docker context '$DOCKER_CONTEXT_NAME' socket is unavailable: $socket_path"
    fi
}

canonical_path() {
    python3 - "$1" <<'PY'
import os, sys
print(os.path.realpath(os.path.expanduser(sys.argv[1])))
PY
}

storage_backing_device() {
    local path existing_path
    path="$(canonical_path "$1")"
    existing_path="$(python3 - "$path" <<'PY'
import pathlib, sys
path = pathlib.Path(sys.argv[1])
while not path.exists() and path != path.parent:
    path = path.parent
print(path)
PY
)"
    df -P "$existing_path" | awk 'END { print $1 }'
}

require_internal_storage() {
    local label="$1" path device location
    path="$(canonical_path "$2")"
    device="$(storage_backing_device "$path")"
    location="$(diskutil info "$device" 2>/dev/null | awk -F: '$1 ~ /^[[:space:]]*Device Location$/ { value=$2; gsub(/^[[:space:]]+|[[:space:]]+$/, "", value); print value }')"
    if [[ "$location" != Internal ]]; then
        error "$label must be on internal storage, not $path ($device: ${location:-unsupported})"
        return 1
    fi
}

validate_repetitions() {
    [[ "$ISOLATION_REPETITIONS" =~ ^[1-9][0-9]*$ ]] || {
        error "ISOLATION_REPETITIONS must be a positive integer"
        return 2
    }
    if ((ISOLATION_REPETITIONS % 3 != 0)); then
        error "ISOLATION_REPETITIONS must contain complete three-run counterbalance cycles"
        return 2
    fi
}

check_tools() {
    detect_docker_compose
    require_local_docker_context
    "$DOCKER_BINARY" info >/dev/null 2>&1 || skip_or_fail 'Docker Engine is unavailable'
    [[ -x "$CONTAINER_COMPOSE" ]] || skip_or_fail "container-compose binary is not executable: $CONTAINER_COMPOSE"
    command -v "$CONTAINER_BINARY" >/dev/null 2>&1 || skip_or_fail "container runtime is unavailable: $CONTAINER_BINARY"
    CONTAINER_BINARY="$(command -v "$CONTAINER_BINARY")"
    [[ -x "$NORMALIZER_BINARY" ]] || skip_or_fail "compose-normalizer is not executable: $NORMALIZER_BINARY"
    NORMALIZER_BINARY="$(canonical_path "$NORMALIZER_BINARY")"
    command -v python3 >/dev/null 2>&1 || skip_or_fail 'python3 is unavailable'
    command -v diskutil >/dev/null 2>&1 || skip_or_fail 'diskutil is unavailable'
    validate_repetitions
    [[ "$ISOLATION_TIMEOUT_SECONDS" =~ ^[1-9][0-9]*$ ]] || { error "ISOLATION_TIMEOUT_SECONDS must be a positive integer"; return 2; }
    [[ "$ISOLATION_TIMING_MAX_RATIO" =~ ^[1-9][0-9]*(\.[0-9]+)?$ ]] || { error "ISOLATION_TIMING_MAX_RATIO must be positive"; return 2; }
    [[ "$ISOLATION_COMPARABLE_NOISE_PCT" =~ ^[0-9]+(\.[0-9]+)?$ ]] || { error "ISOLATION_COMPARABLE_NOISE_PCT must be zero or positive"; return 2; }
    require_internal_storage ISOLATION_EVIDENCE_DIR "$ISOLATION_EVIDENCE_DIR"
    require_internal_storage ISOLATION_WORK_ROOT "$ISOLATION_WORK_ROOT"
    ISOLATION_WORK_ROOT_CANONICAL="$(canonical_path "$ISOLATION_WORK_ROOT")"
    ISOLATION_WORK_ROOT_DEVICE="$(storage_backing_device "$ISOLATION_WORK_ROOT_CANONICAL")"
    "${DOCKER_COMPOSE_COMMAND[@]}" version >/dev/null
    "$CONTAINER_BINARY" system status >/dev/null || skip_or_fail 'apple/container system is unavailable'
    "$DOCKER_BINARY" image inspect "$FIXTURE_IMAGE" >/dev/null 2>&1 || skip_or_fail "$FIXTURE_IMAGE is not warm in Docker; pull it before quiescing the host"
    "$CONTAINER_BINARY" image inspect "$FIXTURE_IMAGE" >/dev/null 2>&1 || skip_or_fail "$FIXTURE_IMAGE is not warm in apple/container; pull or load it before quiescing the host"
}

# Derives a stable, evidence-specific Compose project namespace.
initialize_run_namespace() {
    local canonical_evidence
    mkdir -p "$ISOLATION_EVIDENCE_DIR"
    canonical_evidence="$(canonical_path "$ISOLATION_EVIDENCE_DIR")"
    PROJECT_NAMESPACE="$(printf '%s' "$canonical_evidence" | shasum -a 256 | cut -c1-12)"
    RUN_LOCK_DIR="$ISOLATION_EVIDENCE_DIR/.run-lock"
}

# Hold an operating-system advisory lock for this shell's lifetime. The empty
# lock file is deliberately retained: ownership is the live file-description
# lock, so crashes, incomplete publication, and PID reuse cannot leave stale
# ownership behind or create a recovery race.
acquire_run_lock() {
    [[ -z "$RUN_LOCK_FD" ]] || return 0
    exec {RUN_LOCK_FD}>"$RUN_LOCK_DIR"
    if ! python3 - "$RUN_LOCK_FD" <<'PY'
import fcntl
import sys

try:
    fcntl.flock(int(sys.argv[1]), fcntl.LOCK_EX | fcntl.LOCK_NB)
except BlockingIOError:
    raise SystemExit(1)
PY
    then
        exec {RUN_LOCK_FD}>&-
        RUN_LOCK_FD=""
        error "another isolation benchmark owns namespace $PROJECT_NAMESPACE"
        return 1
    fi
}

# Closing the owning descriptor releases the lock even after an interrupted
# run. Keep the inode so concurrent contenders never race an unlink/recreate.
release_run_lock() {
    [[ -n "$RUN_LOCK_FD" ]] || return
    exec {RUN_LOCK_FD}>&-
    RUN_LOCK_FD=""
}

select_lane_order() {
    case "$((($1 - 1) % 3))" in
        0) LANE_ORDER=(docker dedicated-vm shared-vm) ;;
        1) LANE_ORDER=(dedicated-vm shared-vm docker) ;;
        2) LANE_ORDER=(shared-vm docker dedicated-vm) ;;
    esac
}

select_lane() {
    case "$1" in
        docker)
            ACTIVE_COMPOSE=("${DOCKER_COMPOSE_COMMAND[@]}" --ansi never --progress quiet)
            LANE_PREFIX=d
            ;;
        dedicated-vm)
            ACTIVE_COMPOSE=(
                env
                "CONTAINER_BIN=$CONTAINER_BINARY"
                "CONTAINER_COMPOSE_CONTAINER=$CONTAINER_BINARY"
                "CONTAINER_COMPOSE_INIT_IMAGE="
                "CONTAINER_COMPOSE_NORMALIZER=$NORMALIZER_BINARY"
                "$CONTAINER_COMPOSE" --ansi never --progress quiet
            )
            LANE_PREFIX=dv
            ;;
        shared-vm)
            ACTIVE_COMPOSE=(
                env
                "CONTAINER_BIN=$CONTAINER_BINARY"
                "CONTAINER_COMPOSE_CONTAINER=$CONTAINER_BINARY"
                "CONTAINER_COMPOSE_INIT_IMAGE="
                "CONTAINER_COMPOSE_NORMALIZER=$NORMALIZER_BINARY"
                "$CONTAINER_COMPOSE" --ansi never --progress quiet
            )
            LANE_PREFIX=sv
            ;;
        *) error "unknown lane: $1"; return 2 ;;
    esac
}

create_fixtures() {
    local count index lane isolation_line
    mkdir -p "$ISOLATION_WORK_ROOT"
    FIXTURE_DIR="$(mktemp -d "$ISOLATION_WORK_ROOT/fixtures.XXXXXX")"
    for count in 1 10 50; do
        for lane in "${ISOLATION_LANES[@]}"; do
            isolation_line=""
            [[ "$lane" == docker ]] || isolation_line="    isolation: $lane"
            {
                printf 'services:\n'
                for ((index = 1; index <= count; index++)); do
                    printf '  worker%02d:\n' "$index"
                    printf '    image: %s\n' "$FIXTURE_IMAGE"
                    printf '    network_mode: bridge\n'
                    [[ -z "$isolation_line" ]] || printf '%s\n' "$isolation_line"
                    printf '    command: ["sh", "-c", "trap '\''exit 0'\'' TERM INT; while :; do sleep 0.1; done"]\n'
                    printf '    stop_grace_period: 5s\n'
                done
            } >"$FIXTURE_DIR/services-$count-$lane.yml"
        done
    done
}

cleanup() {
    local count lane project file
    for count in 1 10 50; do
        for lane in "${ISOLATION_LANES[@]}"; do
            select_lane "$lane"
            project="cc-iso-$PROJECT_NAMESPACE-$LANE_PREFIX-$count"
            file="$FIXTURE_DIR/services-$count-$lane.yml"
            [[ -f "$file" ]] && "${ACTIVE_COMPOSE[@]}" -p "$project" -f "$file" down --volumes --remove-orphans >/dev/null 2>&1 || true
        done
    done
    [[ -z "$FIXTURE_DIR" ]] || rm -rf "$FIXTURE_DIR"
    release_run_lock
}

write_fingerprint_candidate() {
    local candidate="$1" docker_compose_version
    docker_compose_version="$("${DOCKER_COMPOSE_COMMAND[@]}" version)"
    python3 - "$candidate" "$SELF_PATH" "$CONTAINER_COMPOSE" "$CONTAINER_BINARY" "$NORMALIZER_BINARY" \
        "$ISOLATION_REPETITIONS" "$ISOLATION_TIMEOUT_SECONDS" \
        "$ISOLATION_COMPARABLE_NOISE_PCT" "$ISOLATION_TIMING_MAX_RATIO" \
        "$FIXTURE_IMAGE" "$docker_compose_version" "$DOCKER_BINARY" \
        "$DOCKER_CONTEXT_NAME" "$DOCKER_ENDPOINT" "$PROJECT_NAMESPACE" \
        "$ISOLATION_WORK_ROOT_CANONICAL" "$ISOLATION_WORK_ROOT_DEVICE" \
        "${COMPOSE_PARALLEL_LIMIT-<unset>}" <<'PY'
import hashlib, json, platform, subprocess, sys
from pathlib import Path
(
    output, harness, compose, container, normalizer, repetitions, timeout, noise,
    maximum_ratio, fixture_image, docker_compose_version, docker_binary,
    docker_context, docker_endpoint, project_namespace, work_root, work_device,
    compose_parallel_limit,
) = sys.argv[1:]
def sha256(path):
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()
def command(*arguments):
    return subprocess.run(arguments, check=False, capture_output=True, text=True).stdout.strip()
def required_json_command(*arguments):
    completed = subprocess.run(arguments, check=False, capture_output=True, text=True)
    if completed.returncode != 0:
        raise SystemExit(f"{' '.join(arguments)} failed: {completed.stderr.strip()}")
    return json.loads(completed.stdout)
def canonical_json_sha256(value):
    encoded = json.dumps(value, separators=(",", ":"), sort_keys=True).encode()
    return hashlib.sha256(encoded).hexdigest()
docker_images = required_json_command(docker_binary, "image", "inspect", fixture_image)
container_images = required_json_command(container, "image", "inspect", fixture_image)
docker_info = required_json_command(docker_binary, "info", "--format", "{{json .}}")
container_status = required_json_command(container, "system", "status", "--format", "json")
container_properties = required_json_command(
    container, "system", "property", "list", "--format", "json"
)
if len(docker_images) != 1 or len(container_images) != 1:
    raise SystemExit("fixture image inspection must resolve exactly one image per runtime")
docker_image, container_image = docker_images[0], container_images[0]
docker_repo_digests = sorted(
    item.rsplit("@", 1)[-1]
    for item in docker_image.get("RepoDigests", [])
    if "@" in item
)
docker_resolved_digests = set(docker_repo_digests)
if docker_image.get("Id"):
    docker_resolved_digests.add(docker_image["Id"])
container_descriptor = container_image["configuration"]["descriptor"]["digest"]
container_variant_digests = sorted(
    variant["digest"] for variant in container_image.get("variants", [])
)
container_resolved_digests = {container_descriptor, *container_variant_digests}
common_image_digests = sorted(docker_resolved_digests & container_resolved_digests)
if not common_image_digests:
    raise SystemExit(
        "Docker and apple/container fixture images do not share a resolved digest"
    )
payload = {
    "schemaVersion": 3,
    "harness": {"path": str(Path(harness).resolve()), "sha256": sha256(harness)},
    "compose": {"path": str(Path(compose).resolve()), "sha256": sha256(compose), "version": command(compose, "version")},
    "container": {"path": str(Path(container).resolve()), "sha256": sha256(container), "version": command(container, "--version")},
    "normalizer": {"path": str(Path(normalizer).resolve()), "sha256": sha256(normalizer)},
    "dockerCLI": {"path": str(Path(docker_binary).resolve()), "sha256": sha256(docker_binary)},
    "dockerCompose": docker_compose_version,
    "dockerEngine": command(docker_binary, "version", "--format", "{{.Server.Version}}"),
    "dockerAuthority": {
        key: docker_info[key]
        for key in (
            "ID", "Name", "Driver", "DockerRootDir", "NCPU", "MemTotal",
            "OperatingSystem", "OSType", "Architecture", "KernelVersion",
            "SecurityOptions", "CgroupDriver", "CgroupVersion", "ServerVersion",
        )
        if key in docker_info
    },
    "containerAuthority": {
        "status": container_status,
        "properties": container_properties,
    },
    "dockerReference": {
        "context": docker_context,
        "endpoint": docker_endpoint,
    },
    "fixtureImage": {
        "reference": fixture_image,
        "commonDigests": common_image_digests,
        "docker": {
            "id": docker_image.get("Id", ""),
            "repoDigests": docker_repo_digests,
            "inspectionSha256": canonical_json_sha256(docker_image),
        },
        "container": {
            "descriptor": container_descriptor,
            "variantDigests": container_variant_digests,
            "inspectionSha256": canonical_json_sha256(container_image),
        },
    },
    "host": {"machine": platform.machine(), "macOS": platform.mac_ver()[0], "model": command("sysctl", "-n", "hw.model")},
    "settings": {
        "repetitions": int(repetitions),
        "timeoutSeconds": int(timeout),
        "comparableNoisePercent": float(noise),
        "maximumRatio": float(maximum_ratio),
        "composeParallelLimit": compose_parallel_limit,
        "projectNamespace": project_namespace,
        "workRoot": {"path": work_root, "device": work_device},
    },
}
Path(output).write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")
PY
}

initialize_evidence() {
    local candidate
    mkdir -p "$ISOLATION_EVIDENCE_DIR"
    candidate="$(mktemp "$ISOLATION_EVIDENCE_DIR/fingerprints.XXXXXX")"
    write_fingerprint_candidate "$candidate"
    if [[ -f "$FINGERPRINT_JSON" ]] && ! cmp -s "$candidate" "$FINGERPRINT_JSON"; then
        rm -f "$candidate"
        error "evidence fingerprints changed; choose a new ISOLATION_EVIDENCE_DIR instead of mixing runs"
        return 1
    fi
    mv "$candidate" "$FINGERPRINT_JSON"
    if [[ ! -f "$TIMING_TSV" ]]; then
        printf 'fixture\tlane\trepetition\tschedule_position\tdirection\tduration_seconds\toutcome\tcommand\n' >"$TIMING_TSV"
    fi
    if [[ ! -f "$ASSERTION_TSV" ]]; then
        printf 'fixture\tlane\trepetition\tassertion\tobserved\toutcome\n' >"$ASSERTION_TSV"
    fi
    printf 'repetition\tschedule_position\tlane\n' >"$SCHEDULE_TSV"
    local repetition position lane
    for ((repetition = 1; repetition <= ISOLATION_REPETITIONS; repetition++)); do
        select_lane_order "$repetition"
        position=0
        for lane in "${LANE_ORDER[@]}"; do
            ((position += 1))
            printf '%s\t%s\t%s\n' "$repetition" "$position" "$lane" >>"$SCHEDULE_TSV"
        done
    done
}

sample_is_complete() {
    python3 - "$TIMING_TSV" "$ASSERTION_TSV" "$1" "$2" "$3" <<'PY'
import csv, sys
path, assertion_path, lane, repetition, count = sys.argv[1:]
wanted = {f"startup-{count}-services", f"teardown-{count}-services"}
with open(path, encoding="utf-8", newline="") as handle:
    rows = [row for row in csv.DictReader(handle, delimiter="\t") if row["lane"] == lane and row["repetition"] == repetition and row["outcome"] == "success"]
with open(assertion_path, encoding="utf-8", newline="") as handle:
    assertions = [row for row in csv.DictReader(handle, delimiter="\t") if row["lane"] == lane and row["repetition"] == repetition and row["outcome"] == "pass"]
actual = {(row["fixture"], row["assertion"]) for row in assertions}
required = {
    (f"startup-{count}-services", "running-service-count"),
    (f"startup-{count}-services", "bridge-ipv4"),
    (f"teardown-{count}-services", "remaining-service-count"),
}
if lane != "docker":
    required.add((f"startup-{count}-services", "effective-isolation"))
raise SystemExit(0 if {row["fixture"] for row in rows} >= wanted and actual >= required else 1)
PY
}

remove_incomplete_sample() {
    python3 - "$TIMING_TSV" "$ASSERTION_TSV" "$1" "$2" "$3" <<'PY'
import csv, pathlib, sys
timing, assertions = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])
lane, repetition, count = sys.argv[3:]
wanted = {f"startup-{count}-services", f"teardown-{count}-services"}
def rewrite(path, predicate):
    with path.open(encoding="utf-8", newline="") as handle:
        reader = csv.DictReader(handle, delimiter="\t")
        fields = reader.fieldnames
        rows = [row for row in reader if not predicate(row)]
    with path.open("w", encoding="utf-8", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=fields, delimiter="\t", lineterminator="\n")
        writer.writeheader(); writer.writerows(rows)
rewrite(timing, lambda row: row["lane"] == lane and row["repetition"] == repetition and row["fixture"] in wanted)
rewrite(assertions, lambda row: row["lane"] == lane and row["repetition"] == repetition and row["fixture"].endswith(f"-{count}-services"))
PY
}

run_timed() {
    local fixture="$1" lane="$2" repetition="$3" schedule_position="$4"
    shift 4
    python3 - "$TIMING_TSV" "$fixture" "$lane" "$repetition" "$schedule_position" \
        "$ISOLATION_TIMEOUT_SECONDS" "$@" <<'PY'
import csv, pathlib, shlex, subprocess, sys, time
timing, fixture, lane, repetition, position, timeout, *command = sys.argv[1:]
log_directory = pathlib.Path(timing).parent / "logs"
log_directory.mkdir(parents=True, exist_ok=True)
log_path = log_directory / f"{fixture}--{lane}--r{repetition}.log"
started = time.monotonic(); outcome = "success"; diagnostic = ""
try:
    with log_path.open("wb") as log:
        completed = subprocess.run(command, timeout=float(timeout), check=False, stdout=log, stderr=subprocess.STDOUT)
    if completed.returncode != 0:
        outcome = f"exit-{completed.returncode}"
        diagnostic = log_path.read_text(encoding="utf-8", errors="replace")[-4000:]
except subprocess.TimeoutExpired as error:
    outcome = "timeout"; diagnostic = str(error)
duration = time.monotonic() - started
with open(timing, "a", encoding="utf-8", newline="") as handle:
    csv.writer(handle, delimiter="\t", lineterminator="\n").writerow([fixture, lane, repetition, position, "lower-is-better", f"{duration:.9f}", outcome, shlex.join(command)])
print(f"{fixture} {lane} repetition {repetition}: {duration:.3f}s ({outcome})")
if outcome != "success":
    if diagnostic: print(diagnostic, file=sys.stderr)
    raise SystemExit(124 if outcome == "timeout" else 1)
PY
}

record_assertion() {
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" "$5" "$6" >>"$ASSERTION_TSV"
}

assert_running_services() {
    local fixture="$1" lane="$2" repetition="$3" project="$4" file="$5" expected="$6" output observed container_id inspection network_summary effective_isolation ipv4_address
    # Every fixture requests network_mode: bridge, which Container projects onto its built-in default network.
    local expected_network="default"
    local invalid_isolation=0 missing_ipv4=0 failed=0
    output="$("${ACTIVE_COMPOSE[@]}" -p "$project" -f "$file" ps -q)"
    observed="$(printf '%s\n' "$output" | awk 'NF { count += 1 } END { print count + 0 }')"
    if [[ "$observed" != "$expected" ]]; then
        record_assertion "$fixture" "$lane" "$repetition" running-service-count "$observed" fail
        error "$fixture $lane retained $observed running services; expected $expected"
        return 1
    fi
    record_assertion "$fixture" "$lane" "$repetition" running-service-count "$observed" pass
    while IFS= read -r container_id; do
        [[ -n "$container_id" ]] || continue
        if [[ "$lane" == docker ]]; then
            ipv4_address="$("$DOCKER_BINARY" inspect "$container_id" --format '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}')"
        else
            inspection="$("$CONTAINER_BINARY" inspect "$container_id")"
            network_summary="$(printf '%s' "$inspection" | python3 -c 'import json,sys; expected=sys.argv[1]; item=json.load(sys.stdin)[0]; networks=item["status"].get("networks", []); ipv4=next((entry.get("ipv4Address", "") for entry in networks if entry.get("network") == expected), ""); print(item["configuration"].get("effectiveIsolation", "") + "\t" + ipv4)' "$expected_network")"
            IFS=$'\t' read -r effective_isolation ipv4_address <<<"$network_summary"
            if [[ "$effective_isolation" != "$lane" ]]; then
                ((invalid_isolation += 1))
                error "$fixture $lane container $container_id reported effective isolation '$effective_isolation'"
            fi
        fi
        if [[ -z "$ipv4_address" ]]; then
            ((missing_ipv4 += 1))
            error "$fixture $lane container $container_id has no global bridge IPv4 address"
        fi
    done <<<"$output"
    if [[ "$lane" != docker ]]; then
        if ((invalid_isolation > 0)); then
            record_assertion "$fixture" "$lane" "$repetition" effective-isolation "$invalid_isolation invalid of $observed" fail
            failed=1
        else
            record_assertion "$fixture" "$lane" "$repetition" effective-isolation "$observed of $observed valid" pass
        fi
    fi
    if ((missing_ipv4 > 0)); then
        record_assertion "$fixture" "$lane" "$repetition" bridge-ipv4 "$missing_ipv4 missing of $observed" fail
        failed=1
    else
        record_assertion "$fixture" "$lane" "$repetition" bridge-ipv4 "$observed of $observed present" pass
    fi
    return "$failed"
}

assert_stopped_services() {
    local fixture="$1" lane="$2" repetition="$3" project="$4" file="$5" output observed
    output="$("${ACTIVE_COMPOSE[@]}" -p "$project" -f "$file" ps --all -q)"
    observed="$(printf '%s\n' "$output" | awk 'NF { count += 1 } END { print count + 0 }')"
    if [[ "$observed" != 0 ]]; then
        record_assertion "$fixture" "$lane" "$repetition" remaining-service-count "$observed" fail
        error "$fixture $lane retained $observed services after down"
        return 1
    fi
    record_assertion "$fixture" "$lane" "$repetition" remaining-service-count "$observed" pass
}

run_lifecycle_lane() {
    local lane="$1" repetition="$2" position="$3" count="$4" file project
    if sample_is_complete "$lane" "$repetition" "$count"; then
        printf 'resume: %s repetition %s %s services already complete\n' "$lane" "$repetition" "$count"
        return
    fi
    remove_incomplete_sample "$lane" "$repetition" "$count"
    select_lane "$lane"
    project="cc-iso-$PROJECT_NAMESPACE-$LANE_PREFIX-$count"
    file="$FIXTURE_DIR/services-$count-$lane.yml"
    "${ACTIVE_COMPOSE[@]}" -p "$project" -f "$file" down --volumes --remove-orphans >/dev/null 2>&1 || true
    run_timed "startup-$count-services" "$lane" "$repetition" "$position" \
        "${ACTIVE_COMPOSE[@]}" -p "$project" -f "$file" up -d --pull never
    assert_running_services "startup-$count-services" "$lane" "$repetition" "$project" "$file" "$count"
    run_timed "teardown-$count-services" "$lane" "$repetition" "$position" \
        "${ACTIVE_COMPOSE[@]}" -p "$project" -f "$file" down --volumes --remove-orphans
    assert_stopped_services "teardown-$count-services" "$lane" "$repetition" "$project" "$file"
}

finalize_evidence() {
    python3 - "$TIMING_TSV" "$ASSERTION_TSV" "$TIMING_JUNIT" "$TIMING_MATRIX" \
        "$ISOLATION_TIMING_MAX_RATIO" "$ISOLATION_COMPARABLE_NOISE_PCT" \
        "$ISOLATION_REPETITIONS" "${ISOLATION_FIXTURES[@]}" <<'PY'
import csv, math, pathlib, statistics, sys, xml.etree.ElementTree as ET
from collections import defaultdict
timing, assertion, junit, matrix = map(pathlib.Path, sys.argv[1:5])
threshold, noise = float(sys.argv[5]), 1 + float(sys.argv[6]) / 100
repetitions, expected = int(sys.argv[7]), sys.argv[8:]
lanes = ("docker", "dedicated-vm", "shared-vm")
rows = list(csv.DictReader(timing.open(encoding="utf-8"), delimiter="\t"))
assertions = list(csv.DictReader(assertion.open(encoding="utf-8"), delimiter="\t"))
grouped = defaultdict(lambda: defaultdict(list))
for row in rows: grouped[row["fixture"]][row["lane"]].append(row)
def p95(values): return sorted(values)[math.ceil(len(values) * .95) - 1]
def expected_position(lane, repetition):
    order = lanes[(repetition - 1) % 3:] + lanes[:(repetition - 1) % 3]
    return order.index(lane) + 1
failures, failed_test_cases, table = [], 0, []
suite = ET.Element("testsuite", name="compose-isolation-performance", tests=str(len(expected) * 2))
for fixture in expected:
    lane_rows = {lane: grouped[fixture].get(lane, []) for lane in lanes}
    all_rows = [row for lane in lanes for row in lane_rows[lane]]
    valid = all(len(lane_rows[lane]) == repetitions for lane in lanes)
    valid = valid and all(row["outcome"] == "success" and row["direction"] == "lower-is-better" for row in all_rows)
    valid = valid and all(row["schedule_position"] == str(expected_position(row["lane"], int(row["repetition"]))) for row in all_rows)
    fixture_assertions = [row for row in assertions if row["fixture"] == fixture]
    actual_assertions = {
        (row["lane"], int(row["repetition"]), row["assertion"])
        for row in fixture_assertions
        if row["outcome"] == "pass"
    }
    required_assertions = {
        (lane, repetition, name)
        for lane in lanes
        for repetition in range(1, repetitions + 1)
        for name in (
            ({"running-service-count", "bridge-ipv4"} | ({"effective-isolation"} if lane != "docker" else set()))
            if fixture.startswith("startup-")
            else {"remaining-service-count"}
        )
    }
    valid = valid and actual_assertions >= required_assertions
    valid = valid and all(row["outcome"] == "pass" for row in fixture_assertions)
    if not valid:
        reason = "missing, failed, non-counterbalanced, or functionally unasserted samples"
        failures.append(f"{fixture}: {reason}")
        for candidate in lanes[1:]:
            case = ET.SubElement(suite, "testcase", classname="parity.isolation", name=f"{fixture}-{candidate}")
            ET.SubElement(case, "failure", message=reason).text = reason
            failed_test_cases += 1
        table.append((fixture, *("n/a",) * 12, "FAIL"))
        continue
    stats = {}
    for lane in lanes:
        values = [float(row["duration_seconds"]) for row in lane_rows[lane]]
        stats[lane] = (statistics.median(values), p95(values))
    dm, dp = stats["docker"]
    row = [fixture, f"{dm:.3f}", f"{dp:.3f}"]
    guard = "PASS"
    for candidate in lanes[1:]:
        cm, cp = stats[candidate]
        mr, pr = (cm / dm if dm else float("inf")), (cp / dp if dp else float("inf"))
        comparable = "MET" if mr <= noise and pr <= noise else "NOT MET"
        case = ET.SubElement(suite, "testcase", classname="parity.isolation", name=f"{fixture}-{candidate}", time=f"{cm:.9f}")
        ET.SubElement(case, "system-out").text = "\n".join(f"repetition={sample['repetition']} position={sample['schedule_position']} duration={sample['duration_seconds']}" for sample in lane_rows[candidate])
        if mr >= threshold or pr >= threshold:
            reason = f"median/P95 ratios are {mr:.2f}x/{pr:.2f}x; threshold is <{threshold:g}x"
            ET.SubElement(case, "failure", message=reason).text = reason
            failures.append(f"{fixture} {candidate}: {reason}")
            failed_test_cases += 1
            guard = "FAIL"
        row.extend((f"{cm:.3f}", f"{cp:.3f}", f"{mr:.2f}x", f"{pr:.2f}x", comparable))
    row.append(guard); table.append(tuple(row))
suite.set("failures", str(failed_test_cases))
ET.ElementTree(suite).write(junit, encoding="utf-8", xml_declaration=True)
lines = ["# Compose Isolation Performance Matrix", "", "Warm-image same-host lifecycle samples using explicit built-in bridge networking. Successful rows include service-count and guest IPv4 assertions. Ratios are relative to Docker; lower is better.", "", "| Fixture | Docker median | Docker P95 | Dedicated median | Dedicated P95 | Dedicated median ratio | Dedicated P95 ratio | Dedicated comparable | Shared median | Shared P95 | Shared median ratio | Shared P95 ratio | Shared comparable | Guard |", "| --- | ---: | ---: | ---: | ---: | ---: | ---: | --- | ---: | ---: | ---: | ---: | --- | --- |"]
lines += ["| " + " | ".join(row) + " |" for row in table]
lines += ["", "Raw timings, functional assertions, the counterbalanced schedule, and exact fingerprints are retained beside this summary.", ""]
matrix.write_text("\n".join(lines), encoding="utf-8")
print("\n".join(lines))
if failures: raise SystemExit("\n".join(failures))
PY
}

run_matrix() {
    local repetition count lane position
    initialize_evidence
    for ((repetition = 1; repetition <= ISOLATION_REPETITIONS; repetition++)); do
        select_lane_order "$repetition"
        for count in 1 10 50; do
            position=0
            for lane in "${LANE_ORDER[@]}"; do
                ((position += 1))
                run_lifecycle_lane "$lane" "$repetition" "$position" "$count"
            done
        done
    done
    finalize_evidence
}

main() {
    parse_args "$@"
    if ((LIST_FIXTURES == 1)); then
        printf '%s\n' "${ISOLATION_FIXTURES[@]}"
        return
    fi
    check_tools
    initialize_run_namespace
    acquire_run_lock
    trap cleanup EXIT
    trap 'exit 129' HUP
    trap 'exit 130' INT
    trap 'exit 131' QUIT
    trap 'exit 143' TERM
    create_fixtures
    run_matrix
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
