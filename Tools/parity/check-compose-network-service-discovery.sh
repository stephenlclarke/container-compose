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
#   check-compose-network-service-discovery.sh [options]
#
# OPTIONS:
#   --strict    Fail when Docker Compose V2, Docker Engine, container-compose,
#               or a requested Apple container runtime is unavailable.
#   -h, --help  Show this help.
#
# ENVIRONMENT:
#   CONTAINER_COMPOSE  Path to the container-compose binary. Defaults to the
#                      local SwiftPM debug build at .build/debug/compose.
#   CONTAINER_COMPOSE_CONTAINER
#                      Path to the matching Apple container binary.
#   CONTAINER_COMPOSE_LIVE
#                      Set to 1 to run the live Apple runtime comparison.
#   DOCKER_COMPOSE     Docker Compose command to compare with.
#   PARITY_REPETITIONS Number of timed DNS lookups per scenario. Defaults to 3.
#   PARITY_TIMEOUT_SECONDS
#                      Per-operation hang timeout. Defaults to 300 seconds.
#   PARITY_TIMING_OUTPUT
#                      Timing report path. Defaults below .build/parity.
#   PARITY_TIMING_MAX_RATIO
#                      Material slowdown ratio. Defaults to 10.
#
# This local-only check records Docker and container-compose timings while
# validating network-scoped container names, service names, explicit aliases,
# scaled shared answers, static addresses, alias lifecycle, one-off aliases,
# address changes, and isolation.

set -euo pipefail

readonly SELF_PATH="${BASH_SOURCE[0]:-$0}"
SCRIPT_NAME="$(basename "$SELF_PATH")"
readonly SCRIPT_NAME
REPO_ROOT="$(cd "$(dirname "$SELF_PATH")/../.." && pwd)"
readonly REPO_ROOT

readonly FIXTURE_IMAGE="alpine:3.20"
STRICT=0
CONTAINER_COMPOSE="${CONTAINER_COMPOSE:-$REPO_ROOT/.build/debug/compose}"
CONTAINER_BINARY="${CONTAINER_COMPOSE_CONTAINER:-container}"
CONTAINER_COMPOSE_LIVE="${CONTAINER_COMPOSE_LIVE:-0}"
PARITY_REPETITIONS="${PARITY_REPETITIONS:-3}"
PARITY_TIMEOUT_SECONDS="${PARITY_TIMEOUT_SECONDS:-300}"
PARITY_TIMING_OUTPUT="${PARITY_TIMING_OUTPUT:-$REPO_ROOT/.build/parity/network-service-discovery-timings.tsv}"
PARITY_TIMING_MAX_RATIO="${PARITY_TIMING_MAX_RATIO:-10}"
DOCKER_COMPOSE_COMMAND=()
ACTIVE_COMPOSE=()
FIXTURE_DIR=""
TIMING_FILE=""
DOCKER_FILE=""
CONTAINER_FILE=""
DOCKER_SUBNET_PREFIX=""
CONTAINER_SUBNET_PREFIX=""
DOCKER_PROJECT="cc-dns-d-$RANDOM-$$"
CONTAINER_PROJECT="cc-dns-a-$RANDOM-$$"

info() { printf '%s\n' "$*"; }
warning() { printf 'warning: %s\n' "$*" >&2; }
error() { printf 'error: %s\n' "$*" >&2; }

usage() {
    sed -n '/^# USAGE:/,/^# This local-only/ { /^# This local-only/d; s/^# //; s/^#//; p; }' "$SELF_PATH" |
        sed "s/check-compose-network-service-discovery.sh/$SCRIPT_NAME/"
}

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

skip_or_fail() {
    local message="$1"
    if ((STRICT == 1)); then
        error "$message"
        return 1
    fi
    warning "$message; skipping network service-discovery parity check"
    exit 0
}

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

validate_positive_integer() {
    local name="$1"
    local value="$2"
    [[ "$value" =~ ^[1-9][0-9]*$ ]] || {
        error "$name must be a positive integer, got '$value'"
        return 2
    }
}

check_tools() {
    detect_docker_compose
    command -v python3 >/dev/null 2>&1 || skip_or_fail 'python3 is unavailable'
    docker info >/dev/null 2>&1 || skip_or_fail 'Docker Engine is unavailable'
    [[ -x "$CONTAINER_COMPOSE" ]] || skip_or_fail "container-compose binary is not executable: $CONTAINER_COMPOSE"
    validate_positive_integer PARITY_REPETITIONS "$PARITY_REPETITIONS"
    validate_positive_integer PARITY_TIMEOUT_SECONDS "$PARITY_TIMEOUT_SECONDS"
    if [[ "$CONTAINER_COMPOSE_LIVE" == "1" ]] &&
        [[ ! -x "$CONTAINER_BINARY" ]] &&
        ! command -v "$CONTAINER_BINARY" >/dev/null 2>&1; then
        skip_or_fail "matching Apple container binary is unavailable: $CONTAINER_BINARY"
    fi
}

write_fixture() {
    local path="$1"
    local subnet_prefix="$2"

    cat >"$path" <<YAML
services:
  api:
    image: ${FIXTURE_IMAGE}
    command: ["sh", "-c", "sleep 900"]
    stop_grace_period: 1s
    networks:
      backend:
        aliases:
          - api.internal
          - shared.internal
  worker:
    image: ${FIXTURE_IMAGE}
    command: ["sh", "-c", "sleep 900"]
    stop_grace_period: 1s
    networks:
      backend:
        aliases:
          - shared.internal
  fixed:
    image: ${FIXTURE_IMAGE}
    command: ["sh", "-c", "sleep 900"]
    stop_grace_period: 1s
    networks:
      backend:
        aliases:
          - fixed.internal
        ipv4_address: ${subnet_prefix}.10
  client:
    image: ${FIXTURE_IMAGE}
    command: ["sh", "-c", "sleep 900"]
    stop_grace_period: 1s
    networks:
      - backend
  isolated:
    image: ${FIXTURE_IMAGE}
    command: ["sh", "-c", "sleep 900"]
    stop_grace_period: 1s
    networks:
      - frontend
  job:
    image: ${FIXTURE_IMAGE}
    command: ["sh", "-c", "sleep 900"]
    stop_grace_period: 1s
    networks:
      backend:
        aliases:
          - job.internal
networks:
  backend:
    ipam:
      config:
        - subnet: ${subnet_prefix}.0/24
  frontend:
    ipam:
      config:
        - subnet: ${subnet_prefix%.*}.250.0/24
YAML
}

create_fixtures() {
    local selector=$((RANDOM % 150 + 50))
    FIXTURE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/compose-network-dns.XXXXXX")"
    TIMING_FILE="$FIXTURE_DIR/timings.tsv"
    DOCKER_FILE="$FIXTURE_DIR/docker-compose.yml"
    CONTAINER_FILE="$FIXTURE_DIR/container-compose.yml"
    DOCKER_SUBNET_PREFIX="10.241.$selector"
    CONTAINER_SUBNET_PREFIX="10.242.$selector"
    write_fixture "$DOCKER_FILE" "$DOCKER_SUBNET_PREFIX"
    write_fixture "$CONTAINER_FILE" "$CONTAINER_SUBNET_PREFIX"
    {
        printf '# generated_at=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        printf '# workload=service-name,explicit-alias,scaled-shared-alias,container-name,static-ip,recreate,teardown,run-use-aliases,network-isolation\n'
        printf '# repetitions=%s\n' "$PARITY_REPETITIONS"
        printf '# comparison=median elapsed monotonic seconds by matching operation\n'
        printf '# timeout_seconds=%s\n' "$PARITY_TIMEOUT_SECONDS"
        printf '# material_slowdown=max_ratio:%s\n' "$PARITY_TIMING_MAX_RATIO"
        printf '# fixture_image=%s\n' "$FIXTURE_IMAGE"
        printf '# image_preparation=pulled outside the timed startup workload\n'
        printf 'implementation\toperation\trepetition\tseconds\n'
    } >"$TIMING_FILE"
}

run_bounded() {
    python3 -c '
import os
import signal
import subprocess
import sys

timeout = float(sys.argv[1])
process = subprocess.Popen(sys.argv[2:], start_new_session=True)
try:
    raise SystemExit(process.wait(timeout=timeout))
except subprocess.TimeoutExpired:
    os.killpg(process.pid, signal.SIGTERM)
    try:
        process.wait(timeout=5)
    except subprocess.TimeoutExpired:
        os.killpg(process.pid, signal.SIGKILL)
        process.wait()
    raise SystemExit(124)
' "$PARITY_TIMEOUT_SECONDS" "$@"
}

monotonic_nanoseconds() {
    python3 -c 'import time; print(time.monotonic_ns())'
}

record_elapsed() {
    local implementation="$1"
    local operation="$2"
    local repetition="$3"
    local start_ns="$4"
    local end_ns="$5"
    python3 - "$implementation" "$operation" "$repetition" "$start_ns" "$end_ns" >>"$TIMING_FILE" <<'PY'
import sys

elapsed = (int(sys.argv[5]) - int(sys.argv[4])) / 1_000_000_000
print(f"{sys.argv[1]}\t{sys.argv[2]}\t{sys.argv[3]}\t{elapsed:.6f}")
PY
}

measure_capture() {
    local implementation="$1"
    local operation="$2"
    local repetition="$3"
    shift 3
    local start_ns
    local end_ns
    local output
    local status

    start_ns="$(monotonic_nanoseconds)"
    set +e
    output="$(run_bounded "$@")"
    status=$?
    set -e
    end_ns="$(monotonic_nanoseconds)"
    record_elapsed "$implementation" "$operation" "$repetition" "$start_ns" "$end_ns"

    if ((status == 124)); then
        error "$implementation $operation exceeded ${PARITY_TIMEOUT_SECONDS}s and was terminated"
        return 124
    fi
    if ((status != 0)); then
        error "$implementation $operation failed with status $status"
        return "$status"
    fi
    printf '%s' "$output"
}

set_active_compose() {
    local implementation="$1"
    local project="$2"
    local file="$3"
    if [[ "$implementation" == "docker" ]]; then
        ACTIVE_COMPOSE=("${DOCKER_COMPOSE_COMMAND[@]}" --project-name "$project" --file "$file")
    else
        ACTIVE_COMPOSE=(
            env
            "CONTAINER_BIN=$CONTAINER_BINARY"
            "CONTAINER_COMPOSE_CONTAINER=$CONTAINER_BINARY"
            "$CONTAINER_COMPOSE"
            --ansi never
            --project-name "$project"
            --file "$file"
        )
    fi
}

ipv4_addresses() {
    awk '$2 == "STREAM" { print $1 }' | sort -u
}

wait_for_address_count() {
    local service="$1"
    local hostname="$2"
    local expected="$3"
    local output
    local count

    for _ in {1..30}; do
        set +e
        output="$(run_bounded "${ACTIVE_COMPOSE[@]}" exec -T "$service" getent ahostsv4 "$hostname" 2>/dev/null)"
        local status=$?
        set -e
        if ((status == 0)); then
            count="$(printf '%s\n' "$output" | ipv4_addresses | wc -l | tr -d ' ')"
            if [[ "$count" == "$expected" ]]; then
                return 0
            fi
        fi
        sleep 1
    done
    error "timed out waiting for '$hostname' to resolve to $expected IPv4 address(es)"
    return 1
}

assert_timed_address_count() {
    local implementation="$1"
    local service="$2"
    local hostname="$3"
    local expected="$4"
    local operation="$5"
    local output
    local count

    wait_for_address_count "$service" "$hostname" "$expected"
    for ((repetition = 1; repetition <= PARITY_REPETITIONS; repetition++)); do
        output="$(measure_capture "$implementation" "$operation" "$repetition" \
            "${ACTIVE_COMPOSE[@]}" exec -T "$service" getent ahostsv4 "$hostname")"
        count="$(printf '%s\n' "$output" | ipv4_addresses | wc -l | tr -d ' ')"
        if [[ "$count" != "$expected" ]]; then
            error "$implementation '$hostname' returned $count IPv4 addresses, want $expected"
            printf '%s\n' "$output" >&2
            return 1
        fi
    done
}

assert_static_address() {
    local service="$1"
    local hostname="$2"
    local expected="$3"
    local output
    output="$(run_bounded "${ACTIVE_COMPOSE[@]}" exec -T "$service" getent ahostsv4 "$hostname")"
    if [[ "$(printf '%s\n' "$output" | ipv4_addresses)" != "$expected" ]]; then
        error "'$hostname' did not resolve to static address $expected"
        printf '%s\n' "$output" >&2
        return 1
    fi
}

replace_static_address() {
    local file="$1"
    local old_address="$2"
    local new_address="$3"
    python3 - "$file" "$old_address" "$new_address" <<'PY'
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
text = path.read_text(encoding="utf-8")
old = f"ipv4_address: {sys.argv[2]}"
new = f"ipv4_address: {sys.argv[3]}"
if text.count(old) != 1:
    raise SystemExit(f"expected one {old!r} entry, found {text.count(old)}")
path.write_text(text.replace(old, new), encoding="utf-8")
PY
}

assert_isolated_alias_unavailable() {
    if run_bounded "${ACTIVE_COMPOSE[@]}" exec -T isolated getent ahostsv4 api.internal >/dev/null 2>&1; then
        error 'api.internal resolved from a container attached only to the isolated network'
        return 1
    fi
}

run_live_suite() {
    local implementation="$1"
    local project="$2"
    local file="$3"
    local subnet_prefix="$4"
    local generated_name="${project}-api-1"

    set_active_compose "$implementation" "$project" "$file"
    measure_capture "$implementation" startup 1 \
        "${ACTIVE_COMPOSE[@]}" up --detach --scale api=2 api worker fixed client isolated >/dev/null

    assert_timed_address_count "$implementation" client api 2 service_name_lookup
    assert_timed_address_count "$implementation" client api.internal 2 explicit_alias_lookup
    assert_timed_address_count "$implementation" client shared.internal 3 shared_alias_lookup
    assert_timed_address_count "$implementation" client "$generated_name" 1 container_name_lookup
    assert_static_address client fixed.internal "${subnet_prefix}.10"
    assert_isolated_alias_unavailable

    measure_capture "$implementation" oneoff_alias_start 1 \
        "${ACTIVE_COMPOSE[@]}" run --detach --use-aliases job >/dev/null
    assert_timed_address_count "$implementation" client job.internal 1 oneoff_alias_lookup

    run_bounded "${ACTIVE_COMPOSE[@]}" rm --stop --force worker >/dev/null
    assert_timed_address_count "$implementation" client shared.internal 2 alias_teardown_lookup

    replace_static_address "$file" "${subnet_prefix}.10" "${subnet_prefix}.20"
    measure_capture "$implementation" recreate_static_address 1 \
        "${ACTIVE_COMPOSE[@]}" up --detach --force-recreate fixed >/dev/null
    wait_for_address_count client fixed.internal 1
    assert_static_address client fixed.internal "${subnet_prefix}.20"

    run_bounded "${ACTIVE_COMPOSE[@]}" down --remove-orphans >/dev/null
}

assert_model_projection() {
    local output
    output="$("$CONTAINER_COMPOSE" --ansi never --project-name model-dns --file "$CONTAINER_FILE" config --format json)"
    python3 -c '
import json
import sys

project = json.load(sys.stdin)
aliases = project["services"]["api"]["networkAliases"]["backend"]
expected = ["api", "api.internal", "shared.internal"]
if aliases != expected:
    raise SystemExit(f"normalized api aliases = {aliases!r}, want {expected!r}")
' <<<"$output"

    output="$("$CONTAINER_COMPOSE" --ansi never --dry-run --project-name model-dns --file "$CONTAINER_FILE" up api)"
    grep -F 'alias=api,alias=api.internal,alias=shared.internal' <<<"$output" >/dev/null || {
        error 'up dry-run did not render the implicit service name and explicit aliases'
        return 1
    }

    output="$("$CONTAINER_COMPOSE" --ansi never --dry-run --project-name model-dns --file "$CONTAINER_FILE" run --use-aliases --rm job true)"
    grep -F 'alias=job,alias=job.internal' <<<"$output" >/dev/null || {
        error 'run --use-aliases dry-run did not render service aliases'
        return 1
    }
}

prepare_fixture_images() {
    info "Preparing fixture image outside the timed workload: $FIXTURE_IMAGE"
    run_bounded docker image pull "$FIXTURE_IMAGE" >/dev/null
    if [[ "$CONTAINER_COMPOSE_LIVE" == "1" ]]; then
        run_bounded "$CONTAINER_BINARY" image pull "$FIXTURE_IMAGE" >/dev/null
    fi
}

report_timings() {
    mkdir -p "$(dirname "$PARITY_TIMING_OUTPUT")"
    cp "$TIMING_FILE" "$PARITY_TIMING_OUTPUT"
    python3 - "$TIMING_FILE" "$PARITY_TIMING_MAX_RATIO" "$REPO_ROOT" <<'PY'
import pathlib
import statistics
import sys

sys.path.insert(0, sys.argv[3])

from Tools.parity.timing_policy import exceeds_slowdown_boundary, slowdown_ratio

path = pathlib.Path(sys.argv[1])
max_ratio = float(sys.argv[2])
measurements = {}
for line in path.read_text(encoding="utf-8").splitlines():
    if not line or line.startswith("#") or line.startswith("implementation\t"):
        continue
    implementation, operation, _repetition, raw_seconds = line.split("\t")
    measurements.setdefault(operation, {}).setdefault(implementation, []).append(float(raw_seconds))

failed = False
print("Network service-discovery parity timings (median seconds):")
for operation in sorted(measurements):
    values = measurements[operation]
    medians = {name: statistics.median(samples) for name, samples in values.items()}
    line = f"  {operation}: " + " ".join(
        f"{name}={value:.6f}" for name, value in sorted(medians.items())
    )
    if "docker" in medians and "container-compose" in medians:
        reference = medians["docker"]
        implementation = medians["container-compose"]
        ratio = slowdown_ratio(reference, implementation)
        delta = implementation - reference
        line += f" ratio={ratio:.2f}x delta={delta:+.6f}"
        if exceeds_slowdown_boundary(reference, implementation, max_ratio):
            print(
                f"error: {operation} exceeds the material slowdown boundary: "
                f"{ratio:.2f}x (threshold is <{max_ratio:g}x)",
                file=sys.stderr,
            )
            failed = True
    print(line)
raise SystemExit(1 if failed else 0)
PY
    info "Timing evidence written to $PARITY_TIMING_OUTPUT"
}

cleanup() {
    local status=$?
    if [[ -n "$FIXTURE_DIR" ]]; then
        if [[ -f "$DOCKER_FILE" ]]; then
            "${DOCKER_COMPOSE_COMMAND[@]}" --project-name "$DOCKER_PROJECT" --file "$DOCKER_FILE" \
                down --remove-orphans >/dev/null 2>&1 || true
        fi
        if [[ "$CONTAINER_COMPOSE_LIVE" == "1" && -f "$CONTAINER_FILE" ]]; then
            env "CONTAINER_BIN=$CONTAINER_BINARY" "CONTAINER_COMPOSE_CONTAINER=$CONTAINER_BINARY" \
                "$CONTAINER_COMPOSE" --ansi never --project-name "$CONTAINER_PROJECT" --file "$CONTAINER_FILE" \
                down --remove-orphans >/dev/null 2>&1 || true
        fi
        rm -rf "$FIXTURE_DIR"
    fi
    exit "$status"
}

main() {
    parse_args "$@"
    check_tools
    create_fixtures
    trap cleanup EXIT

    info "Network service-discovery workload: repetitions=$PARITY_REPETITIONS timeout=${PARITY_TIMEOUT_SECONDS}s comparison=median"
    info "Reference: $("${DOCKER_COMPOSE_COMMAND[@]}" version --short 2>/dev/null || "${DOCKER_COMPOSE_COMMAND[@]}" version)"
    {
        printf '# host=%s %s\n' "$(uname -s)" "$(uname -m)"
        printf '# docker_engine=%s\n' "$(docker version --format '{{.Server.Version}}')"
        printf '# docker_compose=%s\n' "$("${DOCKER_COMPOSE_COMMAND[@]}" version --short 2>/dev/null || "${DOCKER_COMPOSE_COMMAND[@]}" version)"
        printf '# container_compose=%s\n' "$("$CONTAINER_COMPOSE" version --short)"
    } >>"$TIMING_FILE"
    assert_model_projection
    prepare_fixture_images
    run_live_suite docker "$DOCKER_PROJECT" "$DOCKER_FILE" "$DOCKER_SUBNET_PREFIX"
    if [[ "$CONTAINER_COMPOSE_LIVE" == "1" ]]; then
        run_live_suite container-compose "$CONTAINER_PROJECT" "$CONTAINER_FILE" "$CONTAINER_SUBNET_PREFIX"
    else
        info 'live Apple runtime validation not requested; Docker reference and Compose model projection passed'
    fi
    report_timings
    info 'Docker Compose V2 and container-compose network service-discovery parity passed.'
}

main "$@"
