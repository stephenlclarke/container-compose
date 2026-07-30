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
#   check-compose-cp-stdio-archive-streams.sh [options]
#
# OPTIONS:
#   --strict    Fail when Docker Compose V2, Docker Engine, container-compose,
#               or the Apple container runtime is unavailable.
#   -h, --help  Show this help.
#
# ENVIRONMENT:
#   CONTAINER_COMPOSE  Path to the container-compose binary. Defaults to the
#                      local SwiftPM debug build at .build/debug/compose.
#   CONTAINER_COMPOSE_CONTAINER
#                      Path to the Apple container binary used by container-compose.
#   DOCKER_COMPOSE     Docker Compose command to compare with. Defaults to
#                      "docker compose" when available, otherwise docker-compose.
#   TAR                GNU tar binary used to create metadata fixtures. Defaults
#                      to tar.
#   PARITY_TIMING_OUTPUT
#                      Optional path for a tab-separated timing report.
#   PARITY_TIMEOUT_SECONDS
#                      Per-copy hang timeout. Defaults to 120 seconds.
#   PARITY_TIMING_MAX_RATIO
#                      Material slowdown ratio. Defaults to 10.
#   PARITY_TIMING_MIN_DELTA_SECONDS
#                      Minimum absolute slowdown before ratio enforcement.
#                      Defaults to 5 seconds.
#
# This script is intentionally local-only and is not part of CI. It verifies
# Docker Compose V2 and container-compose `cp -` archive stream behavior for
# stdin-to-service and service-to-stdout content copies, archive metadata, hard
# links, sparse files, and direct-stream timing.

set -euo pipefail

readonly SELF_PATH="${BASH_SOURCE[0]:-$0}"
SCRIPT_NAME="$(basename "$SELF_PATH")"
readonly SCRIPT_NAME
REPO_ROOT="$(cd "$(dirname "$SELF_PATH")/../.." && pwd)"
readonly REPO_ROOT

STRICT=0
CONTAINER_COMPOSE="${CONTAINER_COMPOSE:-$REPO_ROOT/.build/debug/compose}"
CONTAINER_BINARY="${CONTAINER_COMPOSE_CONTAINER:-container}"
TAR_BINARY="${TAR:-tar}"
PARITY_TIMING_OUTPUT="${PARITY_TIMING_OUTPUT:-}"
PARITY_TIMEOUT_SECONDS="${PARITY_TIMEOUT_SECONDS:-120}"
PARITY_TIMING_MAX_RATIO="${PARITY_TIMING_MAX_RATIO:-10}"
PARITY_TIMING_MIN_DELTA_SECONDS="${PARITY_TIMING_MIN_DELTA_SECONDS:-5}"
DOCKER_COMPOSE_COMMAND=()
FIXTURE_DIR=""
LONG_ARCHIVE_PATH=""
TIMING_FILE=""
DOCKER_PROJECT_NAME="container-compose-cp-stdio-docker-$RANDOM-$$"
CONTAINER_PROJECT_NAME="container-compose-cp-stdio-runtime-$RANDOM-$$"

info() {
    printf '%s\n' "$*"
}

warning() {
    printf 'warning: %s\n' "$*" >&2
}

error() {
    printf 'error: %s\n' "$*" >&2
}

usage() {
    sed -n '/^# USAGE:/,/^# This script/ { /^# This script/d; s/^# //; s/^#//; p; }' "$SELF_PATH" | sed "s/check-compose-cp-stdio-archive-streams.sh/$SCRIPT_NAME/"
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

    warning "$message; skipping Docker/container-compose cp stdio archive parity check"
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

check_tools() {
    detect_docker_compose
    if ! command -v "$TAR_BINARY" >/dev/null 2>&1 && [[ ! -x "$TAR_BINARY" ]]; then
        skip_or_fail "tar binary is not executable: $TAR_BINARY"
    fi
    if ! "$TAR_BINARY" --version 2>/dev/null | grep -q 'GNU tar'; then
        skip_or_fail 'GNU tar is required for deterministic sparse and ownership fixtures'
    fi
    if ! command -v python3 >/dev/null 2>&1; then
        skip_or_fail 'python3 is required for bounded timing capture'
    fi
    if ! docker info >/dev/null 2>&1; then
        skip_or_fail 'Docker Engine is not available'
    fi
    if [[ ! -x "$CONTAINER_COMPOSE" ]]; then
        skip_or_fail "container-compose binary is not executable: $CONTAINER_COMPOSE"
    fi
    if ! command -v "$CONTAINER_BINARY" >/dev/null 2>&1 && [[ ! -x "$CONTAINER_BINARY" ]]; then
        skip_or_fail "container binary is not executable: $CONTAINER_BINARY"
    fi
}

create_fixture() {
    FIXTURE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/compose-cp-stdio.XXXXXX")"
    TIMING_FILE="$FIXTURE_DIR/timings.tsv"
    cat >"$FIXTURE_DIR/compose.yml" <<'YAML'
services:
  app:
    image: alpine:3.20
    command: ["sh", "-c", "sleep 120"]
YAML
    printf 'from stdin archive\n' >"$FIXTURE_DIR/payload.txt"
    "$TAR_BINARY" -C "$FIXTURE_DIR" -cf "$FIXTURE_DIR/payload.tar" payload.txt
    printf 'from stdout archive\n' >"$FIXTURE_DIR/stdout-source.txt"

    local archive_root="$FIXTURE_DIR/archive-input"
    local long_component
    long_component="$(printf 'a%.0s' {1..180})"
    LONG_ARCHIVE_PATH="metadata/long/$long_component/long-name.txt"
    mkdir -p "$archive_root/metadata/long/$long_component" "$archive_root/hardlinks"
    printf 'metadata fidelity\n' >"$archive_root/metadata/metadata.txt"
    chmod 0640 "$archive_root/metadata/metadata.txt"
    ln -s metadata.txt "$archive_root/metadata/metadata-link"
    printf 'long path fidelity\n' >"$archive_root/$LONG_ARCHIVE_PATH"
    truncate -s 16777216 "$archive_root/metadata/sparse.bin"
    printf 'sparse-start\n' | dd of="$archive_root/metadata/sparse.bin" conv=notrunc 2>/dev/null
    printf 'sparse-end\n' | dd of="$archive_root/metadata/sparse.bin" bs=1 seek=16777200 conv=notrunc 2>/dev/null
    dd if=/dev/zero of="$archive_root/metadata/large.bin" bs=1048576 count=4 2>/dev/null
    printf 'hard-link fidelity\n' >"$archive_root/hardlinks/source.txt"
    ln "$archive_root/hardlinks/source.txt" "$archive_root/hardlinks/target.txt"

    "$TAR_BINARY" \
        --format=pax \
        --sparse \
        --numeric-owner \
        --owner=1234 \
        --group=2345 \
        --mtime=@1700000000 \
        -C "$archive_root" \
        -cf "$FIXTURE_DIR/metadata.tar" \
        metadata
    "$TAR_BINARY" \
        --format=pax \
        --numeric-owner \
        --owner=1234 \
        --group=2345 \
        --mtime=@1700000000 \
        -C "$archive_root" \
        -cf "$FIXTURE_DIR/hardlinks.tar" \
        hardlinks/source.txt \
        hardlinks/target.txt
}

monotonic_nanoseconds() {
    python3 -c 'import time; print(time.monotonic_ns())'
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

measure_copy() {
    local implementation="$1"
    local operation="$2"
    shift 2
    local start_ns
    local end_ns
    local status

    start_ns="$(monotonic_nanoseconds)"
    set +e
    run_bounded "$@"
    status=$?
    set -e
    end_ns="$(monotonic_nanoseconds)"

    python3 -c '
import sys
print(f"{sys.argv[1]}\t{sys.argv[2]}\t{(int(sys.argv[4]) - int(sys.argv[3])) / 1_000_000_000:.6f}")
' "$implementation" "$operation" "$start_ns" "$end_ns" >>"$TIMING_FILE"

    if ((status == 124)); then
        error "$implementation $operation copy exceeded ${PARITY_TIMEOUT_SECONDS}s and was terminated"
        return 124
    fi
    return "$status"
}

report_timing_metrics() {
    python3 - "$TIMING_FILE" "$PARITY_TIMING_MAX_RATIO" "$PARITY_TIMING_MIN_DELTA_SECONDS" <<'PY'
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
max_ratio = float(sys.argv[2])
min_delta = float(sys.argv[3])
measurements = {}
for line in path.read_text(encoding="utf-8").splitlines():
    implementation, operation, raw_seconds = line.split("\t")
    measurements.setdefault(operation, {})[implementation] = float(raw_seconds)

failed = False
print("Compose cp parity timings (seconds):")
for operation in sorted(measurements):
    values = measurements[operation]
    docker = values["docker"]
    container = values["container-compose"]
    ratio = container / docker if docker > 0 else float("inf")
    delta = container - docker
    print(
        f"  {operation}: docker={docker:.6f} "
        f"container-compose={container:.6f} ratio={ratio:.2f}x delta={delta:+.6f}"
    )
    if ratio > max_ratio and delta > min_delta:
        print(
            f"error: {operation} exceeds the material slowdown boundary: "
            f"{ratio:.2f}x and {delta:.3f}s slower",
            file=sys.stderr,
        )
        failed = True
raise SystemExit(1 if failed else 0)
PY

    if [[ -n "$PARITY_TIMING_OUTPUT" ]]; then
        mkdir -p "$(dirname "$PARITY_TIMING_OUTPUT")"
        cp "$TIMING_FILE" "$PARITY_TIMING_OUTPUT"
        info "Timing report written to $PARITY_TIMING_OUTPUT"
    fi
}

cleanup() {
    local status=$?

    if [[ -n "$FIXTURE_DIR" ]]; then
        "${DOCKER_COMPOSE_COMMAND[@]}" -p "$DOCKER_PROJECT_NAME" -f "$FIXTURE_DIR/compose.yml" down --remove-orphans >/dev/null 2>&1 || true
        CONTAINER_BIN="$CONTAINER_BINARY" CONTAINER_COMPOSE_CONTAINER="$CONTAINER_BINARY" \
            "$CONTAINER_COMPOSE" --ansi never -p "$CONTAINER_PROJECT_NAME" -f "$FIXTURE_DIR/compose.yml" down --remove-orphans >/dev/null 2>&1 || true
        rm -rf "$FIXTURE_DIR"
    fi

    exit "$status"
}

assert_file_equals() {
    local expected="$1"
    local actual="$2"
    local label="$3"

    if ! cmp -s "$expected" "$actual"; then
        error "$label did not match expected content"
        printf 'expected:\n' >&2
        cat "$expected" >&2
        printf '\nactual:\n' >&2
        cat "$actual" >&2
        return 1
    fi
}

extract_stdout_archive() {
    local archive="$1"
    local destination="$2"

    mkdir -p "$destination"
    "$TAR_BINARY" -C "$destination" -xf "$archive"
}

docker_compose_exec() {
    "${DOCKER_COMPOSE_COMMAND[@]}" -p "$DOCKER_PROJECT_NAME" -f "$FIXTURE_DIR/compose.yml" exec -T app "$@"
}

container_compose_exec() {
    CONTAINER_BIN="$CONTAINER_BINARY" CONTAINER_COMPOSE_CONTAINER="$CONTAINER_BINARY" \
        "$CONTAINER_COMPOSE" --ansi never -p "$CONTAINER_PROJECT_NAME" -f "$FIXTURE_DIR/compose.yml" exec -T app "$@"
}

capture_metadata_fixture() {
    local executor="$1"
    local prefix="$2"
    local label="$3"
    local archive_root="$FIXTURE_DIR/archive-input"
    local expected_hash
    local actual_hash

    expected_hash="$(shasum -a 256 "$archive_root/metadata/metadata.txt" | awk '{print $1}')"
    actual_hash="$("$executor" sha256sum /tmp/metadata/metadata.txt | awk '{print $1}')"
    [[ "$actual_hash" == "$expected_hash" ]] || {
        error "$label metadata fixture content hash = $actual_hash, want $expected_hash"
        return 1
    }

    expected_hash="$(shasum -a 256 "$archive_root/$LONG_ARCHIVE_PATH" | awk '{print $1}')"
    actual_hash="$("$executor" sha256sum "/tmp/$LONG_ARCHIVE_PATH" | awk '{print $1}')"
    [[ "$actual_hash" == "$expected_hash" ]] || {
        error "$label long-path fixture content hash = $actual_hash, want $expected_hash"
        return 1
    }

    expected_hash="$(shasum -a 256 "$archive_root/metadata/large.bin" | awk '{print $1}')"
    actual_hash="$("$executor" sha256sum /tmp/metadata/large.bin | awk '{print $1}')"
    [[ "$actual_hash" == "$expected_hash" ]] || {
        error "$label large-stream fixture content hash = $actual_hash, want $expected_hash"
        return 1
    }

    expected_hash="$(shasum -a 256 "$archive_root/metadata/sparse.bin" | awk '{print $1}')"
    actual_hash="$("$executor" sha256sum /tmp/metadata/sparse.bin | awk '{print $1}')"
    [[ "$actual_hash" == "$expected_hash" ]] || {
        error "$label sparse fixture content hash = $actual_hash, want $expected_hash"
        return 1
    }

    local link_target
    link_target="$("$executor" readlink /tmp/metadata/metadata-link)"
    [[ "$link_target" == "metadata.txt" ]] || {
        error "$label symlink target = $link_target, want metadata.txt"
        return 1
    }

    "$executor" stat -c '%u:%g:%a:%Y' /tmp/metadata/metadata.txt >"$FIXTURE_DIR/$prefix-metadata.txt"
    "$executor" stat -c '%s:%b' /tmp/metadata/sparse.bin >"$FIXTURE_DIR/$prefix-sparse.txt"
}

assert_metadata_parity() {
    local docker_metadata
    local container_metadata
    local docker_sparse
    local container_sparse

    docker_metadata="$(<"$FIXTURE_DIR/docker-metadata.txt")"
    container_metadata="$(<"$FIXTURE_DIR/container-metadata.txt")"
    docker_sparse="$(<"$FIXTURE_DIR/docker-sparse.txt")"
    container_sparse="$(<"$FIXTURE_DIR/container-sparse.txt")"

    [[ "$docker_metadata" == "1234:2345:640:1700000000" ]] || {
        error "Docker Compose metadata baseline = $docker_metadata, want 1234:2345:640:1700000000"
        return 1
    }
    [[ "$container_metadata" == "$docker_metadata" ]] || {
        error "container-compose metadata = $container_metadata, want Docker baseline $docker_metadata"
        return 1
    }
    [[ "${docker_sparse%%:*}" == "16777216" ]] || {
        error "Docker Compose sparse fixture size = $docker_sparse, want 16777216 bytes"
        return 1
    }
    [[ "${container_sparse%%:*}" == "16777216" ]] || {
        error "container-compose sparse fixture size = $container_sparse, want 16777216 bytes"
        return 1
    }
    [[ "$container_sparse" == "$docker_sparse" ]] || {
        error "container-compose sparse allocation = $container_sparse, want Docker baseline $docker_sparse"
        return 1
    }

    info "Archive metadata parity confirmed: $container_metadata"
    info "Sparse allocation parity confirmed: $container_sparse"
}

check_docker_compose_cp_streams() {
    "${DOCKER_COMPOSE_COMMAND[@]}" -p "$DOCKER_PROJECT_NAME" -f "$FIXTURE_DIR/compose.yml" up -d --quiet-pull app >/dev/null
    measure_copy docker stdin-content \
        "${DOCKER_COMPOSE_COMMAND[@]}" -p "$DOCKER_PROJECT_NAME" -f "$FIXTURE_DIR/compose.yml" cp - app:/tmp \
        <"$FIXTURE_DIR/payload.tar"
    "${DOCKER_COMPOSE_COMMAND[@]}" -p "$DOCKER_PROJECT_NAME" -f "$FIXTURE_DIR/compose.yml" cp app:/tmp/payload.txt "$FIXTURE_DIR/docker-payload.txt"
    assert_file_equals "$FIXTURE_DIR/payload.txt" "$FIXTURE_DIR/docker-payload.txt" "Docker Compose stdin archive copy"

    "${DOCKER_COMPOSE_COMMAND[@]}" -p "$DOCKER_PROJECT_NAME" -f "$FIXTURE_DIR/compose.yml" cp "$FIXTURE_DIR/stdout-source.txt" app:/tmp/stdout-source.txt
    measure_copy docker stdout-content \
        "${DOCKER_COMPOSE_COMMAND[@]}" -p "$DOCKER_PROJECT_NAME" -f "$FIXTURE_DIR/compose.yml" cp app:/tmp/stdout-source.txt - \
        >"$FIXTURE_DIR/docker-stdout.tar"
    extract_stdout_archive "$FIXTURE_DIR/docker-stdout.tar" "$FIXTURE_DIR/docker-stdout"
    assert_file_equals "$FIXTURE_DIR/stdout-source.txt" "$FIXTURE_DIR/docker-stdout/stdout-source.txt" "Docker Compose stdout archive copy"

    measure_copy docker stdin-metadata \
        "${DOCKER_COMPOSE_COMMAND[@]}" -p "$DOCKER_PROJECT_NAME" -f "$FIXTURE_DIR/compose.yml" cp -a - app:/tmp \
        <"$FIXTURE_DIR/metadata.tar"
    capture_metadata_fixture docker_compose_exec docker "Docker Compose"
    measure_copy docker stdin-hardlinks \
        "${DOCKER_COMPOSE_COMMAND[@]}" -p "$DOCKER_PROJECT_NAME" -f "$FIXTURE_DIR/compose.yml" cp -a - app:/tmp \
        <"$FIXTURE_DIR/hardlinks.tar"
    local source_inode
    local target_inode
    source_inode="$(docker_compose_exec stat -c '%i' /tmp/hardlinks/source.txt)"
    target_inode="$(docker_compose_exec stat -c '%i' /tmp/hardlinks/target.txt)"
    [[ "$source_inode" == "$target_inode" ]] || {
        error "Docker Compose hard-link fixture used different inodes: $source_inode != $target_inode"
        return 1
    }
}

check_container_compose_cp_streams() {
    CONTAINER_BIN="$CONTAINER_BINARY" CONTAINER_COMPOSE_CONTAINER="$CONTAINER_BINARY" \
        "$CONTAINER_COMPOSE" --ansi never -p "$CONTAINER_PROJECT_NAME" -f "$FIXTURE_DIR/compose.yml" up -d app >/dev/null
    CONTAINER_BIN="$CONTAINER_BINARY" CONTAINER_COMPOSE_CONTAINER="$CONTAINER_BINARY" \
        measure_copy container-compose stdin-content \
        "$CONTAINER_COMPOSE" --ansi never -p "$CONTAINER_PROJECT_NAME" -f "$FIXTURE_DIR/compose.yml" cp - app:/tmp \
        <"$FIXTURE_DIR/payload.tar"
    CONTAINER_BIN="$CONTAINER_BINARY" CONTAINER_COMPOSE_CONTAINER="$CONTAINER_BINARY" \
        "$CONTAINER_COMPOSE" --ansi never -p "$CONTAINER_PROJECT_NAME" -f "$FIXTURE_DIR/compose.yml" cp app:/tmp/payload.txt "$FIXTURE_DIR/container-payload.txt"
    assert_file_equals "$FIXTURE_DIR/payload.txt" "$FIXTURE_DIR/container-payload.txt" "container-compose stdin archive copy"

    CONTAINER_BIN="$CONTAINER_BINARY" CONTAINER_COMPOSE_CONTAINER="$CONTAINER_BINARY" \
        "$CONTAINER_COMPOSE" --ansi never -p "$CONTAINER_PROJECT_NAME" -f "$FIXTURE_DIR/compose.yml" cp "$FIXTURE_DIR/stdout-source.txt" app:/tmp/stdout-source.txt
    CONTAINER_BIN="$CONTAINER_BINARY" CONTAINER_COMPOSE_CONTAINER="$CONTAINER_BINARY" \
        measure_copy container-compose stdout-content \
        "$CONTAINER_COMPOSE" --ansi never -p "$CONTAINER_PROJECT_NAME" -f "$FIXTURE_DIR/compose.yml" cp app:/tmp/stdout-source.txt - \
        >"$FIXTURE_DIR/container-stdout.tar"
    extract_stdout_archive "$FIXTURE_DIR/container-stdout.tar" "$FIXTURE_DIR/container-stdout"
    assert_file_equals "$FIXTURE_DIR/stdout-source.txt" "$FIXTURE_DIR/container-stdout/stdout-source.txt" "container-compose stdout archive copy"

    CONTAINER_BIN="$CONTAINER_BINARY" CONTAINER_COMPOSE_CONTAINER="$CONTAINER_BINARY" \
        measure_copy container-compose stdin-metadata \
        "$CONTAINER_COMPOSE" --ansi never -p "$CONTAINER_PROJECT_NAME" -f "$FIXTURE_DIR/compose.yml" cp -a - app:/tmp \
        <"$FIXTURE_DIR/metadata.tar"
    capture_metadata_fixture container_compose_exec container "container-compose"

    CONTAINER_BIN="$CONTAINER_BINARY" CONTAINER_COMPOSE_CONTAINER="$CONTAINER_BINARY" \
        measure_copy container-compose stdin-hardlinks \
        "$CONTAINER_COMPOSE" --ansi never -p "$CONTAINER_PROJECT_NAME" -f "$FIXTURE_DIR/compose.yml" cp -a - app:/tmp \
        <"$FIXTURE_DIR/hardlinks.tar"
    local source_inode
    local target_inode
    source_inode="$(container_compose_exec stat -c '%i' /tmp/hardlinks/source.txt)"
    target_inode="$(container_compose_exec stat -c '%i' /tmp/hardlinks/target.txt)"
    [[ "$source_inode" == "$target_inode" ]] || {
        error "container-compose hard-link fixture used different inodes: $source_inode != $target_inode"
        return 1
    }
    info "Hard-link parity confirmed: inode $source_inode"
}

main() {
    parse_args "$@"
    check_tools
    trap cleanup EXIT
    create_fixture
    check_docker_compose_cp_streams
    check_container_compose_cp_streams
    assert_metadata_parity
    report_timing_metrics
    info 'Docker Compose cp stdio content, metadata, sparse-allocation, and hard-link parity passed.'
}

main "$@"
