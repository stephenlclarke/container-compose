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
#   check-compose-lifecycle-hooks.sh [options]
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
#                           lifecycle fixture through container-compose.
#   DOCKER_COMPOSE          Docker Compose command to compare with. Defaults to
#                           "docker compose" when available, otherwise docker-compose.
#
# This local parity check proves service-level pre_start ordering, inherited
# mounts/networks/environment/user/workdir, once-per-stopped-service behavior,
# failure gating and cleanup, post_start/pre_stop ordering, and foreground run
# hook/exit-status behavior against Docker Compose V2 and the Apple runtime.

set -euo pipefail

readonly SELF_PATH="${BASH_SOURCE[0]:-$0}"
SCRIPT_NAME="$(basename "$SELF_PATH")"
readonly SCRIPT_NAME
REPO_ROOT="$(cd "$(dirname "$SELF_PATH")/../.." && pwd)"
readonly REPO_ROOT
readonly FIXTURE_DIR="$REPO_ROOT/Tools/parity/fixtures/lifecycle-hooks"
readonly COMPOSE_FILE="$FIXTURE_DIR/compose.yaml"

STRICT=0
CONTAINER_COMPOSE="${CONTAINER_COMPOSE:-$REPO_ROOT/.build/debug/compose}"
CONTAINER_BINARY="${CONTAINER_COMPOSE_CONTAINER:-container}"
CONTAINER_COMPOSE_LIVE="${CONTAINER_COMPOSE_LIVE:-0}"
DOCKER_COMPOSE_COMMAND=()
DOCKER_SUCCESS_PROJECT="cc-lc-ds-$RANDOM-$$"
DOCKER_FAILURE_PROJECT="cc-lc-df-$RANDOM-$$"
DOCKER_RUN_PROJECT="cc-lc-dr-$RANDOM-$$"
CONTAINER_SUCCESS_PROJECT="cc-lc-as-$RANDOM-$$"
CONTAINER_FAILURE_PROJECT="cc-lc-af-$RANDOM-$$"
CONTAINER_RUN_PROJECT="cc-lc-ar-$RANDOM-$$"
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
        | sed "s/check-compose-lifecycle-hooks.sh/$SCRIPT_NAME/"
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

    warning "$message; skipping lifecycle-hook parity check"
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
    [[ -f "$COMPOSE_FILE" ]] || { error "missing lifecycle fixture: $COMPOSE_FILE"; return 1; }
}

# Creates an invocation-private directory for captured output.
prepare_work_dir() {
    WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/container-compose-lifecycle.XXXXXX")"
}

# Runs Docker Compose against the committed lifecycle fixture.
docker_compose() {
    local project_name="$1"
    shift
    "${DOCKER_COMPOSE_COMMAND[@]}" \
        --ansi never \
        --project-directory "$FIXTURE_DIR" \
        --project-name "$project_name" \
        --file "$COMPOSE_FILE" \
        "$@"
}

# Runs container-compose against the committed lifecycle fixture.
container_compose() {
    local project_name="$1"
    shift
    env CONTAINER_BIN="$CONTAINER_BINARY" CONTAINER_COMPOSE_CONTAINER="$CONTAINER_BINARY" \
        "$CONTAINER_COMPOSE" \
        --ansi never \
        --project-directory "$FIXTURE_DIR" \
        --project-name "$project_name" \
        --file "$COMPOSE_FILE" \
        "$@"
}

# Removes only the projects and temporary files created by this invocation.
cleanup() {
    local project_name

    for project_name in \
        "$DOCKER_SUCCESS_PROJECT" \
        "$DOCKER_FAILURE_PROJECT" \
        "$DOCKER_RUN_PROJECT"
    do
        docker_compose "$project_name" --profile '*' down --volumes --remove-orphans >/dev/null 2>&1 || true
    done

    if [[ "$CONTAINER_COMPOSE_LIVE" == "1" ]]; then
        for project_name in \
            "$CONTAINER_SUCCESS_PROJECT" \
            "$CONTAINER_FAILURE_PROJECT" \
            "$CONTAINER_RUN_PROJECT"
        do
            container_compose "$project_name" --profile '*' down --volumes --remove-orphans >/dev/null 2>&1 || true
        done
    fi

    if [[ -n "$WORK_DIR" ]]; then
        rm -rf "$WORK_DIR"
    fi
}

# Validates normalized lifecycle-hook metadata for one implementation.
assert_config() {
    local implementation="$1"
    local config_file="$2"

    python3 - "$implementation" "$config_file" <<'PY'
import json
import pathlib
import sys

implementation, config_file = sys.argv[1:3]
model = json.loads(pathlib.Path(config_file).read_text(encoding="utf-8"))
services = model.get("services", {})
app = services.get("app", {})
failure = services.get("failure", {})
runner = services.get("runner", {})

def hooks(service, snake, camel):
    return service.get(snake, service.get(camel, []))

pre_start = hooks(app, "pre_start", "preStart")
if len(pre_start) != 2:
    raise SystemExit(f"{implementation}: app pre_start count = {len(pre_start)}, want 2")
first = pre_start[0]
if first.get("image") != "alpine:3.20":
    raise SystemExit(f"{implementation}: explicit pre_start image = {first.get('image')!r}")
working_dir = first.get("working_dir", first.get("workingDir"))
if first.get("user") != "0:0" or working_dir != "/tmp":
    raise SystemExit(f"{implementation}: pre_start user/workdir were not preserved: {first!r}")
if first.get("environment", {}).get("BASE") != "hook":
    raise SystemExit(f"{implementation}: pre_start environment override was not preserved")
if len(hooks(app, "post_start", "postStart")) != 1 or len(hooks(app, "pre_stop", "preStop")) != 1:
    raise SystemExit(f"{implementation}: app post_start/pre_stop hooks were not preserved")
if len(hooks(failure, "pre_start", "preStart")) != 1:
    raise SystemExit(f"{implementation}: failure pre_start hook was not preserved")
if len(hooks(runner, "post_start", "postStart")) != 1 or len(hooks(runner, "pre_stop", "preStop")) != 1:
    raise SystemExit(f"{implementation}: runner lifecycle hooks were not preserved")
PY
}

# Compares normalized model and service-image projections.
check_config_parity() {
    local docker_config="$WORK_DIR/docker-config.json"
    local container_config="$WORK_DIR/container-config.json"
    local docker_images
    local container_images

    docker_compose "$DOCKER_SUCCESS_PROJECT" \
        --profile success --profile failure --profile run \
        config --format json >"$docker_config"
    assert_config 'Docker Compose V2' "$docker_config"

    container_compose "$CONTAINER_SUCCESS_PROJECT" \
        --profile success --profile failure --profile run \
        config --format json >"$container_config"
    assert_config 'container-compose' "$container_config"

    docker_images="$(docker_compose "$DOCKER_SUCCESS_PROJECT" \
        --profile success --profile failure --profile run config --images | sort -u)"
    container_images="$(container_compose "$CONTAINER_SUCCESS_PROJECT" \
        --profile success --profile failure --profile run config --images | sort -u)"
    if [[ "$container_images" != "$docker_images" ]]; then
        error 'container-compose config --images differs from Docker Compose V2'
        printf 'Docker: %q\nApple:  %q\n' "$docker_images" "$container_images" >&2
        return 1
    fi
}

# Validates hook order, inherited metadata, and execution count.
assert_pre_start_metadata() {
    local implementation="$1"
    local content="$2"
    local expected_repetitions="$3"

    python3 - "$implementation" "$expected_repetitions" "$content" <<'PY'
import sys

implementation, expected_repetitions, content = sys.argv[1], int(sys.argv[2]), sys.argv[3]
lines = content.splitlines()
expected_count = expected_repetitions * 2
if len(lines) != expected_count:
    raise SystemExit(
        f"{implementation}: pre_start log has {len(lines)} lines, want {expected_count}: {lines!r}"
    )
for offset in range(0, len(lines), 2):
    fields = lines[offset].split("|")
    if len(fields) != 6:
        raise SystemExit(f"{implementation}: malformed pre_start metadata: {lines[offset]!r}")
    marker, base, inherited, uid, workdir, address = fields
    if (marker, base, inherited, uid, workdir) != (
        "first",
        "hook",
        "inherited",
        "0",
        "/tmp",
    ):
        raise SystemExit(f"{implementation}: wrong inherited pre_start metadata: {fields!r}")
    if not address.strip():
        raise SystemExit(f"{implementation}: pre_start helper had no inherited network address")
    if lines[offset + 1] != "second":
        raise SystemExit(f"{implementation}: pre_start hooks ran out of order: {lines!r}")
PY
}

# Exercises successful pre-start behavior across scale and start transitions.
run_success_lifecycle() {
    local implementation="$1"
    local project_name="$2"
    local pre_start_log
    shift 2

    "$@" "$project_name" --profile success up --detach --scale app=2 app >/dev/null
    pre_start_log="$("$@" "$project_name" --profile success exec -T app cat /shared/pre-start.log)"
    assert_pre_start_metadata "$implementation" "$pre_start_log" 1

    "$@" "$project_name" --profile success up --detach --scale app=2 app >/dev/null
    "$@" "$project_name" --profile success up --detach --scale app=3 app >/dev/null
    "$@" "$project_name" --profile success restart app >/dev/null
    pre_start_log="$("$@" "$project_name" --profile success exec -T app cat /shared/pre-start.log)"
    assert_pre_start_metadata "$implementation" "$pre_start_log" 1

    "$@" "$project_name" --profile success stop app >/dev/null
    "$@" "$project_name" --profile success start app >/dev/null
    pre_start_log="$("$@" "$project_name" --profile success exec -T app cat /shared/pre-start.log)"
    assert_pre_start_metadata "$implementation" "$pre_start_log" 2
}

# Proves a failed pre-start hook gates startup and remains observable.
run_failure_lifecycle() {
    local implementation="$1"
    local project_name="$2"
    local output_file="$3"
    local failure_log
    local running_ids
    shift 3

    set +e
    "$@" "$project_name" --profile failure up --detach failure >"$output_file" 2>&1
    local actual_status=$?
    set -e
    if ((actual_status == 0)); then
        error "$implementation pre_start failure unexpectedly succeeded"
        sed -n '1,160p' "$output_file" >&2
        return 1
    fi

    running_ids="$("$@" "$project_name" --profile failure ps --status running -q failure)"
    if [[ -n "$running_ids" ]]; then
        error "$implementation started the service after its pre_start hook failed"
        printf '%s\n' "$running_ids" >&2
        return 1
    fi

    failure_log="$("$@" "$project_name" --profile failure run --no-deps --rm -T failure-reader cat /shared/failure.log)"
    if [[ "$failure_log" != "failure" ]]; then
        error "$implementation pre_start failure did not retain the committed-volume marker"
        printf 'actual: %q\n' "$failure_log" >&2
        return 1
    fi
}

# Proves foreground output, post-start execution, cleanup, and exact status.
run_foreground_lifecycle() {
    local implementation="$1"
    local project_name="$2"
    local output_file="$3"
    local hook_log
    shift 3

    set +e
    "$@" "$project_name" --profile run run --rm -T runner \
        sh -c 'printf "run-main\n"; sleep 2; exit 7' >"$output_file" 2>&1
    local actual_status=$?
    set -e
    if ((actual_status != 7)); then
        error "$implementation lifecycle-managed run exited $actual_status, expected 7"
        sed -n '1,160p' "$output_file" >&2
        return 1
    fi
    if ! grep -q 'run-main' "$output_file"; then
        error "$implementation lifecycle-managed run lost foreground output"
        sed -n '1,160p' "$output_file" >&2
        return 1
    fi
    if grep -q '^Error:' "$output_file"; then
        error "$implementation lifecycle-managed run added non-Docker error output"
        sed -n '1,160p' "$output_file" >&2
        return 1
    fi

    hook_log="$("$@" "$project_name" --profile run run --no-deps --rm -T reader cat /shared/run-hooks.log)"
    if [[ "$hook_log" != "run-post-start" ]]; then
        error "$implementation lifecycle-managed run did not execute post_start once"
        printf 'actual: %q\n' "$hook_log" >&2
        return 1
    fi
}

# Runs the Docker Compose V2 lifecycle reference.
check_docker_runtime() {
    run_success_lifecycle \
        'Docker Compose V2' \
        "$DOCKER_SUCCESS_PROJECT" \
        docker_compose
    run_failure_lifecycle \
        'Docker Compose V2' \
        "$DOCKER_FAILURE_PROJECT" \
        "$WORK_DIR/docker-failure.log" \
        docker_compose
    run_foreground_lifecycle \
        'Docker Compose V2' \
        "$DOCKER_RUN_PROJECT" \
        "$WORK_DIR/docker-run.log" \
        docker_compose
}

# Runs the matching Apple runtime lifecycle implementation when requested.
check_container_runtime() {
    if [[ "$CONTAINER_COMPOSE_LIVE" != "1" ]]; then
        info 'live Apple runtime validation not requested; Docker Compose V2 reference and model parity passed'
        return
    fi
    if [[ ! -x "$CONTAINER_BINARY" ]] && ! command -v "$CONTAINER_BINARY" >/dev/null 2>&1; then
        error "matching Apple runtime binary is unavailable: $CONTAINER_BINARY"
        return 1
    fi
    "$CONTAINER_BINARY" system status >/dev/null

    run_success_lifecycle \
        'container-compose' \
        "$CONTAINER_SUCCESS_PROJECT" \
        container_compose
    run_failure_lifecycle \
        'container-compose' \
        "$CONTAINER_FAILURE_PROJECT" \
        "$WORK_DIR/container-failure.log" \
        container_compose
    run_foreground_lifecycle \
        'container-compose' \
        "$CONTAINER_RUN_PROJECT" \
        "$WORK_DIR/container-run.log" \
        container_compose
}

# Runs focused unit contracts without inheriting a live-runtime override.
check_unit_contracts() {
    env -u CONTAINER_BIN -u CONTAINER_COMPOSE_CONTAINER \
        swift test --disable-automatic-resolution \
        --filter 'ComposeOrchestratorTests/(preStart|upCreatesEveryReplicaBeforeOnePreStart|runForeground|runReattachesInteractive|interactiveRunDetachKeys|runInterruption)'
}

# Coordinates prerequisite, model, live-runtime, and unit validation.
main() {
    parse_args "$@"
    detect_docker_compose
    check_tools
    prepare_work_dir
    trap cleanup EXIT

    check_config_parity
    check_docker_runtime
    check_container_runtime
    check_unit_contracts

    info 'Docker Compose V2 and container-compose lifecycle-hook parity passed.'
}

main "$@"
