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
#   check-compose-links.sh [options]
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
# validating source-scoped link aliases, scaled targets, dynamic external
# targets, DNS projection, live target readdressing, and alias isolation.

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
PARITY_TIMING_OUTPUT="${PARITY_TIMING_OUTPUT:-$REPO_ROOT/.build/parity/compose-links-timings.tsv}"
PARITY_TIMING_MAX_RATIO="${PARITY_TIMING_MAX_RATIO:-10}"
DOCKER_COMPOSE_COMMAND=()
ACTIVE_COMPOSE=()
FIXTURE_DIR=""
TIMING_FILE=""
DOCKER_FILE=""
CONTAINER_FILE=""
DOCKER_PROJECT="cc-links-d-$RANDOM-$$"
CONTAINER_PROJECT="cc-links-a-$RANDOM-$$"
DOCKER_EXTERNAL_TARGET="${DOCKER_PROJECT}-external"
CONTAINER_EXTERNAL_TARGET="${CONTAINER_PROJECT}-external"
DOCKER_SUBNET_PREFIX=""
CONTAINER_SUBNET_PREFIX=""

# Writes an informational message.
info() { printf '%s\n' "$*"; }

# Writes a warning message.
warning() { printf 'warning: %s\n' "$*" >&2; }

# Writes an error message.
error() { printf 'error: %s\n' "$*" >&2; }

# Prints command usage.
usage() {
    sed -n '/^# USAGE:/,/^# This local-only/ { /^# This local-only/d; s/^# //; s/^#//; p; }' "$SELF_PATH" |
        sed "s/check-compose-links.sh/$SCRIPT_NAME/"
}

# Parses command-line options.
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

# Fails or skips when a required local dependency is unavailable.
skip_or_fail() {
    local message="$1"
    if ((STRICT == 1)); then
        error "$message"
        return 1
    fi
    warning "$message; skipping Compose links parity check"
    exit 0
}

# Selects an available Docker Compose V2 command.
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

# Validates a positive integer environment value.
validate_positive_integer() {
    local name="$1"
    local value="$2"
    [[ "$value" =~ ^[1-9][0-9]*$ ]] || {
        error "$name must be a positive integer, got '$value'"
        return 2
    }
}

# Validates tools and configured paths.
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

# Writes the scoped-link parity fixture.
write_fixture() {
    local path="$1"
    local subnet_prefix="$2"
    local external_target="$3"

    cat >"$path" <<YAML
services:
  pool:
    image: ${FIXTURE_IMAGE}
    command: ["sh", "-c", "sleep 900"]
    stop_grace_period: 1s
    networks:
      - backend
      - secondary
  linked:
    image: ${FIXTURE_IMAGE}
    command: ["sh", "-c", "sleep 900"]
    stop_grace_period: 1s
    links:
      - pool:database
    networks:
      - backend
      - secondary
  peer:
    image: ${FIXTURE_IMAGE}
    command: ["sh", "-c", "sleep 900"]
    stop_grace_period: 1s
    networks:
      - backend
  external-client:
    image: ${FIXTURE_IMAGE}
    command: ["sh", "-c", "sleep 900"]
    stop_grace_period: 1s
    external_links:
      - ${external_target}:external-db
    networks:
      - backend
      - secondary
  moving:
    image: ${FIXTURE_IMAGE}
    command: ["sh", "-c", "sleep 900"]
    stop_grace_period: 1s
    networks:
      backend:
        ipv4_address: ${subnet_prefix}.10
  watcher:
    image: ${FIXTURE_IMAGE}
    command: ["sh", "-c", "sleep 900"]
    stop_grace_period: 1s
    links:
      - moving:moving-db
    networks:
      - backend
networks:
  backend:
    ipam:
      config:
        - subnet: ${subnet_prefix}.0/24
  secondary: {}
YAML
}

# Creates fixtures and initial timing metadata.
create_fixtures() {
    local selector=$((RANDOM % 150 + 50))
    FIXTURE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/compose-links.XXXXXX")"
    TIMING_FILE="$FIXTURE_DIR/timings.tsv"
    DOCKER_FILE="$FIXTURE_DIR/docker-compose.yml"
    CONTAINER_FILE="$FIXTURE_DIR/container-compose.yml"
    DOCKER_SUBNET_PREFIX="10.243.$selector"
    CONTAINER_SUBNET_PREFIX="10.244.$selector"
    write_fixture "$DOCKER_FILE" "$DOCKER_SUBNET_PREFIX" "$DOCKER_EXTERNAL_TARGET"
    write_fixture "$CONTAINER_FILE" "$CONTAINER_SUBNET_PREFIX" "$CONTAINER_EXTERNAL_TARGET"
    {
        printf '# generated_at=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        printf '# workload=startup,scaled-link-lookup,scaled-link-isolation,readdress-link-isolation,scaled-link-hosts,readdress-link-hosts,external-absent-lookup,external-alias-hosts,external-secondary-create,external-secondary-lookup,external-remove,external-post-remove-lookup,external-backend-create,external-backend-lookup,readdress,post-readdress-lookup\n'
        printf '# repetitions=%s\n' "$PARITY_REPETITIONS"
        printf '# comparison=median elapsed monotonic seconds by matching operation\n'
        printf '# timeout_seconds=%s\n' "$PARITY_TIMEOUT_SECONDS"
        printf '# material_slowdown=max_ratio:%s\n' "$PARITY_TIMING_MAX_RATIO"
        printf '# fixture_image=%s\n' "$FIXTURE_IMAGE"
        printf '# image_preparation=pulled outside the timed startup workload\n'
        printf 'implementation\toperation\trepetition\tseconds\n'
    } >"$TIMING_FILE"
}

# Runs a command with a supplied hard timeout and terminates its process group on expiry.
run_bounded_for() {
    local timeout="$1"
    shift
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
' "$timeout" "$@"
}

# Runs a command with the configured per-operation timeout.
run_bounded() {
    run_bounded_for "$PARITY_TIMEOUT_SECONDS" "$@"
}

# Prints the current monotonic timestamp in nanoseconds.
monotonic_nanoseconds() {
    python3 -c 'import time; print(time.monotonic_ns())'
}

# Appends one elapsed measurement to the timing report.
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

# Runs and times one command while preserving its standard output.
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

# Selects the active implementation command.
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

# Extracts unique IPv4 addresses from getent output.
ipv4_addresses() {
    awk '$2 == "STREAM" { print $1 }' | sort -u
}

# Waits for an alias to return an exact number of addresses.
wait_for_address_count() {
    local service="$1"
    local hostname="$2"
    local expected="$3"
    local output
    local count
    local status
    local deadline=$((SECONDS + (PARITY_TIMEOUT_SECONDS < 30 ? PARITY_TIMEOUT_SECONDS : 30)))
    local remaining
    local attempt_timeout

    while ((SECONDS < deadline)); do
        remaining=$((deadline - SECONDS))
        attempt_timeout=$((remaining < 5 ? remaining : 5))
        set +e
        output="$(run_bounded_for "$attempt_timeout" \
            "${ACTIVE_COMPOSE[@]}" exec -T "$service" getent ahostsv4 "$hostname" 2>/dev/null)"
        status=$?
        set -e
        if ((status == 0)); then
            count="$(printf '%s\n' "$output" | ipv4_addresses | wc -l | tr -d ' ')"
            if [[ "$count" == "$expected" ]]; then
                return 0
            fi
        fi
        if ((SECONDS < deadline)); then
            sleep 1
        fi
    done
    error "timed out after $((PARITY_TIMEOUT_SECONDS < 30 ? PARITY_TIMEOUT_SECONDS : 30))s waiting for '$hostname' to resolve to $expected IPv4 address(es)"
    return 1
}

# Times and validates repeated alias lookups.
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

# Waits for an alias to resolve to one exact IPv4 address.
wait_for_address() {
    local service="$1"
    local hostname="$2"
    local expected="$3"
    local output
    local status
    local deadline=$((SECONDS + (PARITY_TIMEOUT_SECONDS < 30 ? PARITY_TIMEOUT_SECONDS : 30)))
    local remaining
    local attempt_timeout

    while ((SECONDS < deadline)); do
        remaining=$((deadline - SECONDS))
        attempt_timeout=$((remaining < 5 ? remaining : 5))
        set +e
        output="$(run_bounded_for "$attempt_timeout" \
            "${ACTIVE_COMPOSE[@]}" exec -T "$service" getent ahostsv4 "$hostname" 2>/dev/null)"
        status=$?
        set -e
        if ((status == 0)) && [[ "$(printf '%s\n' "$output" | ipv4_addresses)" == "$expected" ]]; then
            return 0
        fi
        if ((SECONDS < deadline)); then
            sleep 1
        fi
    done
    error "timed out after $((PARITY_TIMEOUT_SECONDS < 30 ? PARITY_TIMEOUT_SECONDS : 30))s waiting for '$hostname' to resolve to $expected"
    return 1
}

# Verifies that an unlinked same-network peer cannot resolve a link alias.
assert_alias_unavailable() {
    local implementation="$1"
    local service="$2"
    local hostname="$3"
    local operation="$4"
    local output

    for ((repetition = 1; repetition <= PARITY_REPETITIONS; repetition++)); do
        # shellcheck disable=SC2016
        output="$(measure_capture "$implementation" "$operation" "$repetition" \
            "${ACTIVE_COMPOSE[@]}" exec -T "$service" sh -c '
                command -v getent >/dev/null 2>&1 || {
                    printf "probe-error:getent-unavailable\n"
                    exit 0
                }
                getent ahostsv4 "$1" >/dev/null 2>&1
                probe_status=$?
                case "$probe_status" in
                    0) printf "resolved\n" ;;
                    2) printf "unresolved\n" ;;
                    *) printf "probe-error:getent-status-%s\n" "$probe_status" ;;
                esac
            ' sh "$hostname" 2>&1)"
        if grep -Fx 'resolved' <<<"$output" >/dev/null; then
            error "'$hostname' resolved from unlinked service '$service'"
            return 1
        fi
        if ! grep -Fx 'unresolved' <<<"$output" >/dev/null; then
            error "lookup of unavailable alias '$hostname' from '$service' returned no valid probe result"
            printf '%s\n' "$output" >&2
            return 1
        fi
    done
}

# Verifies that a link alias is provided by DNS rather than /etc/hosts.
assert_alias_not_in_hosts() {
    local implementation="$1"
    local service="$2"
    local hostname="$3"
    local operation="$4"
    local output

    for ((repetition = 1; repetition <= PARITY_REPETITIONS; repetition++)); do
        # shellcheck disable=SC2016
        output="$(measure_capture "$implementation" "$operation" "$repetition" \
            "${ACTIVE_COMPOSE[@]}" exec -T "$service" sh -c '
                command -v grep >/dev/null 2>&1 || {
                    printf "probe-error:grep-unavailable\n"
                    exit 0
                }
                grep -E "(^|[[:space:]])${1}([[:space:]]|$)" /etc/hosts >/dev/null 2>&1
                probe_status=$?
                case "$probe_status" in
                    0) printf "present\n" ;;
                    1) printf "absent\n" ;;
                    *) printf "probe-error:grep-status-%s\n" "$probe_status" ;;
                esac
            ' sh "$hostname" 2>&1)"
        if grep -Fx 'present' <<<"$output" >/dev/null; then
            error "'$hostname' was written to /etc/hosts for service '$service'"
            return 1
        fi
        if ! grep -Fx 'absent' <<<"$output" >/dev/null; then
            error "checking /etc/hosts for '$hostname' in '$service' returned no valid probe result"
            printf '%s\n' "$output" >&2
            return 1
        fi
    done
}

# Replaces the fixture's one static target address.
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

# Runs the complete behavioural and timed suite for one implementation.
run_live_suite() {
    local implementation="$1"
    local project="$2"
    local file="$3"
    local subnet_prefix="$4"
    local external_target
    local external_client_id
    local external_client_id_after
    local watcher_id
    local watcher_id_after

    if [[ "$implementation" == "docker" ]]; then
        external_target="$DOCKER_EXTERNAL_TARGET"
    else
        external_target="$CONTAINER_EXTERNAL_TARGET"
    fi
    set_active_compose "$implementation" "$project" "$file"
    measure_capture "$implementation" startup 1 \
        "${ACTIVE_COMPOSE[@]}" up --detach --scale pool=2 \
        pool linked peer external-client moving watcher >/dev/null

    assert_timed_address_count "$implementation" linked database 1 scaled_link_lookup
    assert_alias_unavailable "$implementation" peer database scaled_link_isolation
    assert_alias_unavailable "$implementation" peer moving-db readdress_link_isolation
    assert_alias_not_in_hosts "$implementation" linked database scaled_link_hosts
    assert_alias_not_in_hosts "$implementation" watcher moving-db readdress_link_hosts
    assert_alias_unavailable "$implementation" external-client external-db external_absent_lookup
    assert_alias_not_in_hosts "$implementation" external-client external-db external_alias_hosts
    wait_for_address watcher moving-db "${subnet_prefix}.10"

    external_client_id="$(run_bounded "${ACTIVE_COMPOSE[@]}" ps --quiet external-client)"
    [[ -n "$external_client_id" ]] || {
        error "$implementation did not report an external-client container ID"
        return 1
    }
    if [[ "$implementation" == "docker" ]]; then
        measure_capture "$implementation" external_secondary_create 1 \
            docker run --detach --name "$external_target" --network "${project}_secondary" \
            "$FIXTURE_IMAGE" sh -c 'sleep 900' >/dev/null
    else
        measure_capture "$implementation" external_secondary_create 1 \
            "$CONTAINER_BINARY" run --detach --name "$external_target" \
            --network "${project}_secondary" "$FIXTURE_IMAGE" sh -c 'sleep 900' >/dev/null
    fi
    assert_timed_address_count "$implementation" external-client external-db 1 external_secondary_lookup
    if [[ "$implementation" == "docker" ]]; then
        measure_capture "$implementation" external_remove 1 \
            docker rm --force "$external_target" >/dev/null
    else
        measure_capture "$implementation" external_remove 1 \
            "$CONTAINER_BINARY" delete --force "$external_target" >/dev/null
    fi
    assert_alias_unavailable "$implementation" external-client external-db external_post_remove_lookup
    if [[ "$implementation" == "docker" ]]; then
        measure_capture "$implementation" external_backend_create 1 \
            docker run --detach --name "$external_target" --network "${project}_backend" \
            "$FIXTURE_IMAGE" sh -c 'sleep 900' >/dev/null
    else
        measure_capture "$implementation" external_backend_create 1 \
            "$CONTAINER_BINARY" run --detach --name "$external_target" \
            --network "${project}_backend" "$FIXTURE_IMAGE" sh -c 'sleep 900' >/dev/null
    fi
    assert_timed_address_count "$implementation" external-client external-db 1 external_backend_lookup
    external_client_id_after="$(run_bounded "${ACTIVE_COMPOSE[@]}" ps --quiet external-client)"
    if [[ "$external_client_id_after" != "$external_client_id" ]]; then
        error "$implementation recreated external-client while its external link target changed"
        return 1
    fi
    if [[ "$implementation" == "docker" ]]; then
        run_bounded docker rm --force "$external_target" >/dev/null
    else
        run_bounded "$CONTAINER_BINARY" delete --force "$external_target" >/dev/null
    fi

    watcher_id="$(run_bounded "${ACTIVE_COMPOSE[@]}" ps --quiet watcher)"
    [[ -n "$watcher_id" ]] || {
        error "$implementation did not report a watcher container ID"
        return 1
    }
    replace_static_address "$file" "${subnet_prefix}.10" "${subnet_prefix}.20"
    measure_capture "$implementation" target_readdress 1 \
        "${ACTIVE_COMPOSE[@]}" up --detach --force-recreate moving >/dev/null
    wait_for_address watcher moving-db "${subnet_prefix}.20"
    for ((repetition = 1; repetition <= PARITY_REPETITIONS; repetition++)); do
        measure_capture "$implementation" post_readdress_lookup "$repetition" \
            "${ACTIVE_COMPOSE[@]}" exec -T watcher getent ahostsv4 moving-db >/dev/null
    done
    watcher_id_after="$(run_bounded "${ACTIVE_COMPOSE[@]}" ps --quiet watcher)"
    if [[ "$watcher_id_after" != "$watcher_id" ]]; then
        error "$implementation recreated the watching source while readdressing its link target"
        return 1
    fi

    run_bounded "${ACTIVE_COMPOSE[@]}" down --remove-orphans >/dev/null
}

# Verifies the Compose model and dry-run runtime projection.
assert_model_projection() {
    local output
    output="$("$CONTAINER_COMPOSE" --ansi never --dry-run --project-name model-links \
        --file "$CONTAINER_FILE" up linked peer external-client)"
    grep -F 'dns-alias=database:model-links-pool-1' <<<"$output" >/dev/null || {
        error 'up dry-run did not render the link alias mapping'
        return 1
    }
    if grep -F -- '--network model-links_secondary,dns-alias=database:model-links-pool-1' \
        <<<"$output" >/dev/null; then
        error 'up dry-run projected the link alias onto more than the first shared network'
        return 1
    fi
    if grep -F -- '--add-host database' <<<"$output" >/dev/null; then
        error 'up dry-run retained the legacy static link host mapping'
        return 1
    fi
    grep -F -- "--network model-links_backend,alias=external-client,dns-alias=external-db:${CONTAINER_EXTERNAL_TARGET}" \
        <<<"$output" >/dev/null || {
        error 'up dry-run did not project external_links onto the first source network'
        return 1
    }
    grep -F -- "--network model-links_secondary,alias=external-client,dns-alias=external-db:${CONTAINER_EXTERNAL_TARGET}" \
        <<<"$output" >/dev/null || {
        error 'up dry-run did not project external_links onto the second source network'
        return 1
    }
    if grep -F -- '--add-host external-db' <<<"$output" >/dev/null; then
        error 'up dry-run retained the legacy static external_links host mapping'
        return 1
    fi
    if grep -F 'peer' <<<"$output" | grep -F 'dns-alias=database:model-links-pool-1' >/dev/null; then
        error 'up dry-run projected the link alias onto the unlinked peer'
        return 1
    fi
}

# Pulls fixture images outside the timed workload.
prepare_fixture_images() {
    info "Preparing fixture image outside the timed workload: $FIXTURE_IMAGE"
    run_bounded docker image pull "$FIXTURE_IMAGE" >/dev/null
    if [[ "$CONTAINER_COMPOSE_LIVE" == "1" ]]; then
        run_bounded "$CONTAINER_BINARY" image pull "$FIXTURE_IMAGE" >/dev/null
    fi
}

# Publishes median timings and enforces the material slowdown boundary.
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
print("Compose links parity timings (median seconds):")
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

# Removes runtime resources and temporary fixtures.
cleanup() {
    local status=$?
    if [[ -n "$FIXTURE_DIR" ]]; then
        docker rm --force "$DOCKER_EXTERNAL_TARGET" >/dev/null 2>&1 || true
        if [[ -f "$DOCKER_FILE" ]]; then
            "${DOCKER_COMPOSE_COMMAND[@]}" --project-name "$DOCKER_PROJECT" --file "$DOCKER_FILE" \
                down --remove-orphans >/dev/null 2>&1 || true
        fi
        if [[ "$CONTAINER_COMPOSE_LIVE" == "1" && -f "$CONTAINER_FILE" ]]; then
            "$CONTAINER_BINARY" delete --force "$CONTAINER_EXTERNAL_TARGET" >/dev/null 2>&1 || true
            env "CONTAINER_BIN=$CONTAINER_BINARY" "CONTAINER_COMPOSE_CONTAINER=$CONTAINER_BINARY" \
                "$CONTAINER_COMPOSE" --ansi never --project-name "$CONTAINER_PROJECT" --file "$CONTAINER_FILE" \
                down --remove-orphans >/dev/null 2>&1 || true
        fi
        rm -rf "$FIXTURE_DIR"
    fi
    exit "$status"
}

# Runs model, Docker reference, optional matched runtime, and timing checks.
main() {
    parse_args "$@"
    check_tools
    create_fixtures
    trap cleanup EXIT

    info "Compose links workload: repetitions=$PARITY_REPETITIONS timeout=${PARITY_TIMEOUT_SECONDS}s comparison=median"
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
    info 'Docker Compose V2 and container-compose links parity passed.'
}

main "$@"
