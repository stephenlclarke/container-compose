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

set -euo pipefail

if [[ $# -lt 2 ]]; then
    printf 'usage: %s CONTAINER_BINARY COMMAND [ARGUMENT ...]\n' "$(basename "$0")" >&2
    exit 2
fi

SCRIPT_DIRECTORY="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIRECTORY
# shellcheck disable=SC1091
source "$SCRIPT_DIRECTORY/../Tools/ci/container-runtime-lock.sh"

requested_container_binary=$1
container_binary=$requested_container_binary
shift
if [[ "$container_binary" != */* ]]; then
    if ! container_binary=$(command -v "$container_binary"); then
        printf 'candidate container command was not found on PATH: %s\n' \
            "$requested_container_binary" >&2
        exit 2
    fi
fi
if [[ ! -x "$container_binary" ]]; then
    printf 'candidate container binary is not executable: %s\n' "$container_binary" >&2
    exit 2
fi
container_binary_directory=$(cd "$(dirname "$container_binary")" && pwd -P)
container_binary="$container_binary_directory/$(basename "$container_binary")"
container_binary_sha256=$(shasum -a 256 "$container_binary" | awk '{print $1}')
if [[ -n "${CONTAINER_RUNTIME_CLI_SHA256:-}" &&
    "${CONTAINER_RUNTIME_CLI_SHA256}" != "$container_binary_sha256" ]]; then
    printf 'candidate container binary digest mismatch (expected %s, got %s): %s\n' \
        "${CONTAINER_RUNTIME_CLI_SHA256}" "$container_binary_sha256" "$container_binary" >&2
    exit 2
fi
# Every nested Makefile and helper must resolve the same candidate CLI that
# owns the isolated runtime. Otherwise a host-installed `container` earlier in
# PATH can silently target the default service namespace mid-validation.
export PATH="$container_binary_directory${PATH:+:$PATH}"
export CONTAINER_RUNTIME_CLI="$container_binary"
export CONTAINER_RUNTIME_CLI_SHA256="$container_binary_sha256"
runtime_app_root=${CONTAINER_RUNTIME_APP_ROOT:-}
runtime_service_namespace=${CONTAINER_RUNTIME_SERVICE_NAMESPACE:-}
runtime_run_id=${CONTAINER_RUNTIME_RUN_ID:-}
runtime_init_block_repo=${CONTAINER_RUNTIME_INIT_BLOCK_REPO:-}
runtime_init_image_archive=${CONTAINER_RUNTIME_INIT_IMAGE_ARCHIVE:-}
containerization_init_source_path=${CONTAINERIZATION_INIT_SOURCE_PATH:-}
containerization_init_source_root=
containerization_init_source_head=
containerization_init_source_snapshot_path=
containerization_init_build_scratch_root=
matched_init_image=${CONTAINER_COMPOSE_INIT_IMAGE:-}
matched_init_image_tar=${CONTAINER_RUNTIME_INIT_IMAGE_TAR:-}
runtime_builder_image=${CONTAINER_RUNTIME_BUILDER_IMAGE:-}
runtime_builder_image_tar=${CONTAINER_RUNTIME_BUILDER_IMAGE_TAR:-}
runtime_bootstrap_image_tar=${CONTAINER_RUNTIME_BOOTSTRAP_IMAGE_TAR:-}
runtime_config_home=
runtime_docker_socket=
runtime_docker_host=
initial_start_init_image_archive=
initial_start_image_is_matched=false
runtime_root_marker=.container-compose-runtime-root
runtime_root_marker_value='container-compose isolated runtime state v1'
provider_socket_path_limit=103
runtime_service_inputs_root=
runtime_start_deadline_seconds=${CONTAINER_RUNTIME_START_DEADLINE_SECONDS:-300}
runtime_start_sequence_deadline=

# Derive and export the one non-default namespace used by this candidate.
configure_runtime_namespace() {
    local namespace_root_digest
    local socket_directory_digest

    if [[ -z "$runtime_run_id" ]]; then
        runtime_run_id="$(id -u)-$$-${RANDOM}-${SECONDS}"
    fi
    export CONTAINER_RUNTIME_RUN_ID="$runtime_run_id"

    if [[ -z "$runtime_service_namespace" ]]; then
        namespace_root_digest=$(LC_ALL=C printf '%s' "${runtime_app_root}:$(id -u):${runtime_run_id}" \
            | shasum -a 256 | awk '{print substr($1, 1, 24)}')
        runtime_service_namespace="io.github.stephenlclarke.container-compose.runtime.${namespace_root_digest}"
    fi

    if ! [[ "$runtime_service_namespace" =~ ^[A-Za-z0-9_-]+(\.[A-Za-z0-9_-]+)*$ ]] ||
        (( $(LC_ALL=C printf '%s' "$runtime_service_namespace" | wc -c | tr -d '[:space:]') > 192 )); then
        printf 'CONTAINER_RUNTIME_SERVICE_NAMESPACE must contain at most 192 bytes of dot-separated launchd-label components: %s\n' \
            "$runtime_service_namespace" >&2
        exit 2
    fi
    if [[ "$runtime_service_namespace" != io.github.stephenlclarke.container-compose.runtime.* ]]; then
        printf 'CONTAINER_RUNTIME_SERVICE_NAMESPACE must stay in the container-compose isolated namespace: %s\n' \
            "$runtime_service_namespace" >&2
        exit 2
    fi

    socket_directory_digest=$(LC_ALL=C printf '%s' "$runtime_service_namespace" \
        | shasum -a 256 | awk '{print substr($1, 1, 24)}')
    runtime_docker_socket="/tmp/container-engine-$(id -u)-${socket_directory_digest}/docker.sock"
    runtime_docker_host="unix://${runtime_docker_socket}"

    export CONTAINER_APP_ROOT="$runtime_app_root"
    export CONTAINER_SERVICE_NAMESPACE="$runtime_service_namespace"
    export CONTAINER_RUNTIME_DOCKER_SOCKET="$runtime_docker_socket"
    export CONTAINER_RUNTIME_DOCKER_HOST="$runtime_docker_host"
}

# Fail before acquiring the host runtime lock or touching launchd when a
# retained OCI archive cannot satisfy every image reference needed by this
# validation run. The outer stable-release gate supplies both Compose's local
# alias and Container's immutable Containerization reference.
validate_runtime_init_image_archive() {
    local deadline="$1"

    [[ -n "$runtime_init_image_archive" ]] || return 0

    local required_references="$matched_init_image"
    if [[ -n "${CONTAINER_RUNTIME_REQUIRED_INIT_IMAGE_REFERENCES:-}" ]]; then
        required_references+=" ${CONTAINER_RUNTIME_REQUIRED_INIT_IMAGE_REFERENCES}"
    fi
    local references=()
    read -r -a references <<<"$required_references"
    run_runtime_start_command "$deadline" \
        "$SCRIPT_DIRECTORY/../Tools/release/validate-oci-image-layout.py" \
        "$runtime_init_image_archive" "${references[@]}"
}

validate_runtime_inputs() {
    if [[ -z "$runtime_app_root" || "$runtime_app_root" != /* ]]; then
        printf 'CONTAINER_RUNTIME_APP_ROOT must be an absolute marker-protected candidate root\n' >&2
        exit 2
    fi
    runtime_app_root=${runtime_app_root%/}
    if [[ -z "$runtime_app_root" ]]; then
        runtime_app_root=/
    fi
    if [[ "$runtime_app_root" == / ]]; then
        printf 'CONTAINER_RUNTIME_APP_ROOT must not be /\n' >&2
        exit 2
    fi
    local provider_socket_path="$runtime_app_root/engine-provider/provider.sock"
    local provider_socket_path_bytes
    provider_socket_path_bytes=$(LC_ALL=C printf '%s' "$provider_socket_path" | wc -c | tr -d '[:space:]')
    # Darwin's sockaddr_un reserves one byte in its 104-byte sun_path for
    # the terminating NUL. Fail before launchd starts an API server that
    # would immediately exit with an opaque XPC timeout.
    if ((provider_socket_path_bytes > provider_socket_path_limit)); then
        printf 'container runtime app root exceeds the provider Unix socket path limit (%s > %s bytes): %s\n' \
            "$provider_socket_path_bytes" "$provider_socket_path_limit" "$provider_socket_path" >&2
        exit 2
    fi
    if [[ -n "${CONTAINER_RUNTIME_STOP_HELPER:-}" ]]; then
        printf 'CONTAINER_RUNTIME_STOP_HELPER is unsafe with isolated candidates; use the namespace-scoped system stop only\n' >&2
        exit 2
    fi
    if [[ -n "$runtime_builder_image" && -z "$runtime_builder_image_tar" ]] ||
        [[ -z "$runtime_builder_image" && -n "$runtime_builder_image_tar" ]]; then
        printf 'CONTAINER_RUNTIME_BUILDER_IMAGE and CONTAINER_RUNTIME_BUILDER_IMAGE_TAR must be set together\n' >&2
        exit 2
    fi
    if [[ -n "$runtime_builder_image_tar" && ! -f "$runtime_builder_image_tar" ]]; then
        printf 'container runtime builder image archive does not exist: %s\n' "$runtime_builder_image_tar" >&2
        exit 2
    fi
    if [[ -n "$runtime_bootstrap_image_tar" && ! -f "$runtime_bootstrap_image_tar" ]]; then
        printf 'container runtime bootstrap image archive does not exist: %s\n' "$runtime_bootstrap_image_tar" >&2
        exit 2
    fi
    if [[ -n "$matched_init_image_tar" && ! -f "$matched_init_image_tar" ]]; then
        printf 'container runtime init image archive does not exist: %s\n' "$matched_init_image_tar" >&2
        exit 2
    fi
    if [[ -n "$runtime_init_image_archive" && ! -f "$runtime_init_image_archive" ]]; then
        printf 'container runtime init-image archive does not exist: %s\n' \
            "$runtime_init_image_archive" >&2
        exit 2
    fi
    if [[ -n "$runtime_init_block_repo" && ! -f "$runtime_init_block_repo/Makefile" ]]; then
        printf 'container runtime init-block repo does not contain a Makefile: %s\n' "$runtime_init_block_repo" >&2
        exit 2
    fi
    if ! [[ "$runtime_start_deadline_seconds" =~ ^[1-9][0-9]*$ ]]; then
        printf 'CONTAINER_RUNTIME_START_DEADLINE_SECONDS must be a positive integer: %s\n' \
            "$runtime_start_deadline_seconds" >&2
        exit 2
    fi
    if [[ -n "$containerization_init_source_path" && -z "$runtime_init_block_repo" ]]; then
        printf 'CONTAINERIZATION_INIT_SOURCE_PATH requires CONTAINER_RUNTIME_INIT_BLOCK_REPO\n' >&2
        exit 2
    fi
}

# Resolve a clean, exact source checkout before any candidate service mutation.
validate_containerization_init_source() {
    local deadline="$1"

    [[ -n "$containerization_init_source_path" ]] || return 0

    if ! command -v git >/dev/null 2>&1; then
        printf 'git is required to stage CONTAINERIZATION_INIT_SOURCE_PATH\n' >&2
        exit 2
    fi

    local requested_source_path
    if ! requested_source_path=$(cd "$containerization_init_source_path" && pwd -P); then
        printf 'containerization init source path does not exist: %s\n' \
            "$containerization_init_source_path" >&2
        exit 2
    fi
    local source_root_status=0
    containerization_init_source_root=$(run_runtime_start_command "$deadline" \
        git -C "$requested_source_path" rev-parse --show-toplevel 2>/dev/null) || \
        source_root_status=$?
    if [[ "$source_root_status" != "0" ]]; then
        [[ "$source_root_status" != "124" ]] || return "$source_root_status"
        printf 'containerization init source path is not a Git checkout: %s\n' \
            "$requested_source_path" >&2
        exit 2
    fi
    containerization_init_source_root=$(cd "$containerization_init_source_root" && pwd -P)
    if [[ "$requested_source_path" != "$containerization_init_source_root" ]]; then
        printf 'CONTAINERIZATION_INIT_SOURCE_PATH must name the checkout root, not a subdirectory: %s\n' \
            "$requested_source_path" >&2
        exit 2
    fi
    local source_status
    source_status=$(run_runtime_start_command "$deadline" \
        git -C "$containerization_init_source_root" status --porcelain --untracked-files=all) || return "$?"
    if [[ -n "$source_status" ]]; then
        printf 'containerization init source checkout must be clean before staging: %s\n' \
            "$containerization_init_source_root" >&2
        exit 2
    fi
    local source_head_status=0
    containerization_init_source_head=$(run_runtime_start_command "$deadline" \
        git -C "$containerization_init_source_root" rev-parse --verify 'HEAD^{commit}' 2>/dev/null) || \
        source_head_status=$?
    if [[ "$source_head_status" != "0" ]]; then
        [[ "$source_head_status" != "124" ]] || return "$source_head_status"
        printf 'containerization init source checkout does not resolve HEAD to a commit: %s\n' \
            "$containerization_init_source_root" >&2
        exit 2
    fi
}

# Clone the validated source input below the disposable candidate root so the
# guest sees only tracked files and a self-contained Git metadata directory.
stage_containerization_init_source() {
    local deadline="$1"

    [[ -n "$containerization_init_source_root" ]] || return 0

    local source_inputs_root="$runtime_app_root/source-inputs"
    local staged_source_path="$source_inputs_root/containerization"
    if [[ -e "$staged_source_path" ]]; then
        printf 'refusing to overwrite an existing staged containerization source: %s\n' \
            "$staged_source_path" >&2
        exit 2
    fi

    run_runtime_start_command "$deadline" mkdir -p "$source_inputs_root"
    local clone_status=0
    run_runtime_start_command "$deadline" \
        git clone --quiet --no-local --no-checkout --no-tags \
        "$containerization_init_source_root" "$staged_source_path" || clone_status=$?
    if [[ "$clone_status" != "0" ]]; then
        [[ "$clone_status" != "124" ]] || return "$clone_status"
        printf 'failed to clone the exact containerization init source into: %s\n' \
            "$staged_source_path" >&2
        exit 2
    fi
    local checkout_status=0
    run_runtime_start_command "$deadline" \
        git -C "$staged_source_path" checkout --detach --quiet "$containerization_init_source_head" || \
        checkout_status=$?
    if [[ "$checkout_status" != "0" ]]; then
        [[ "$checkout_status" != "124" ]] || return "$checkout_status"
        printf 'failed to check out the pinned containerization init source commit: %s\n' \
            "$containerization_init_source_head" >&2
        exit 2
    fi

    local staged_source_head
    staged_source_head=$(run_runtime_start_command "$deadline" \
        git -C "$staged_source_path" rev-parse HEAD) || return "$?"
    if [[ "$staged_source_head" != "$containerization_init_source_head" ]]; then
        printf 'staged containerization init source commit mismatch (expected %s, got %s)\n' \
            "$containerization_init_source_head" "$staged_source_head" >&2
        exit 2
    fi
    local staged_source_status
    staged_source_status=$(run_runtime_start_command "$deadline" \
        git -C "$staged_source_path" status --porcelain --untracked-files=all) || return "$?"
    if [[ -n "$staged_source_status" ]]; then
        printf 'staged containerization init source checkout is unexpectedly dirty: %s\n' \
            "$staged_source_path" >&2
        exit 2
    fi
    if [[ -e "$staged_source_path/.build" || -e "$staged_source_path/vminitd/.build" ]]; then
        printf 'staged containerization init source contains ignored Swift build artifacts: %s\n' \
            "$staged_source_path" >&2
        exit 2
    fi

    containerization_init_source_snapshot_path="$staged_source_path"
    containerization_init_source_path="$staged_source_path"
    containerization_init_build_scratch_root="$runtime_app_root/source-build-cache"
    run_runtime_start_command "$deadline" \
        mkdir -p "$containerization_init_build_scratch_root"

    local fingerprints_root="$runtime_app_root/fingerprints"
    run_runtime_start_command "$deadline" mkdir -p "$fingerprints_root"
    printf 'source_root=%s\nsource_head=%s\nstaged_source_root=%s\nstaged_source_head=%s\nbuild_scratch_root=%s\n' \
        "$containerization_init_source_root" \
        "$containerization_init_source_head" \
        "$containerization_init_source_snapshot_path" \
        "$staged_source_head" \
        "$containerization_init_build_scratch_root" \
        >"$fingerprints_root/containerization-init-source.txt"
}

# Report whether a source checkout or retained archive can provide the matched init image.
has_matched_init_image_source() {
    [[ -n "$runtime_init_block_repo" ||
        -n "$matched_init_image_tar" ||
        -n "$runtime_init_image_archive" ]]
}

stop_runtime() {
    local deadline="${1:-}"
    if [[ -n "$deadline" ]]; then
        local stop_status=0
        run_runtime_start_command "$deadline" \
            "$container_binary" system stop >/dev/null 2>&1 || stop_status=$?
        if [[ "$stop_status" == "124" ]]; then
            return "$stop_status"
        fi
        return 0
    fi

    "$SCRIPT_DIRECTORY/../Tools/ci/run-command-with-deadline.py" \
        --seconds 10 --grace-seconds 0 --ignore-parent-signals -- \
        "$container_binary" system stop >/dev/null 2>&1 || true
}

# Fail before any service mutation unless this binary exposes this candidate's
# namespace-derived Docker socket through the read-only status command.
verify_runtime_namespace_support() {
    local deadline="$1"
    local status_output
    local reported_socket

    local status=0
    status_output=$(run_runtime_start_command "$deadline" \
        "$container_binary" system status --format json 2>/dev/null) || status=$?
    if [[ "$status" == "124" ]]; then
        return "$status"
    fi
    if ! reported_socket=$(printf '%s' "$status_output" | python3 -c '
import json
import sys

payload = json.load(sys.stdin)
socket = payload.get("engineSocket")
if not isinstance(socket, str) or not socket:
    raise SystemExit(1)
print(socket)
'); then
        printf 'candidate container binary does not expose a JSON engineSocket for namespace verification\n' >&2
        exit 2
    fi
    if [[ "$reported_socket" != "$runtime_docker_socket" ]]; then
        printf 'candidate container binary did not select the isolated Docker socket (expected %s, got %s)\n' \
            "$runtime_docker_socket" "$reported_socket" >&2
        exit 2
    fi
}

# Recognize only the bounded set of startup failures that are known to be
# transient while the per-user Container XPC service is registering.  Keep
# other start failures visible rather than turning the runtime wrapper into a
# general retry loop.
is_transient_xpc_start_failure() {
    local start_log="$1"

    grep -Eq \
        'XPC connection error: Connection (interrupted|invalid)|XPC timeout for request to [[:alnum:]_.-]+/ping' \
        "$start_log"
}

# Return an absolute monotonic deadline for the complete runtime-start sequence.
runtime_start_deadline() {
    python3 - "$runtime_start_deadline_seconds" <<'PY'
import sys
import time

print(f"{time.monotonic() + float(sys.argv[1]):.9f}")
PY
}

# Print the positive wall-clock budget remaining before a runtime-start deadline.
runtime_start_remaining_seconds() {
    local deadline="$1"

    python3 - "$deadline" <<'PY'
import sys
import time

remaining = float(sys.argv[1]) - time.monotonic()
if remaining <= 0:
    raise SystemExit(1)
print(f"{remaining:.6f}")
PY
}

# Run one startup-side operation with only the budget left for the complete
# startup flow. This keeps image loads and source builds inside the same bound
# as service start and readiness.
run_runtime_start_command() {
    local deadline="$1"
    shift
    local remaining_seconds

    remaining_seconds=$(runtime_start_remaining_seconds "$deadline") || return 124
    "$SCRIPT_DIRECTORY/../Tools/ci/run-command-with-deadline.py" \
        --seconds "$remaining_seconds" --grace-seconds 0 -- "$@"
}

# Clamp the host runtime lock wait to the budget left for startup.
runtime_start_lock_timeout_seconds() {
    local deadline="$1"
    local configured_timeout=${CONTAINER_RUNTIME_LOCK_TIMEOUT_SECONDS:-10800}

    python3 - "$deadline" "$configured_timeout" <<'PY'
import math
import sys
import time

if not sys.argv[2].isdigit() or int(sys.argv[2]) <= 0:
    print(
        "CONTAINER_RUNTIME_LOCK_TIMEOUT_SECONDS must be a positive integer: "
        + sys.argv[2],
        file=sys.stderr,
    )
    raise SystemExit(2)
remaining = float(sys.argv[1]) - time.monotonic()
if remaining <= 0:
    raise SystemExit(124)
print(max(1, min(int(sys.argv[2]), math.ceil(remaining))))
PY
}

# Print a retry delay that never extends beyond the runtime-start deadline.
runtime_start_retry_delay() {
    local deadline="$1"

    python3 - "$deadline" <<'PY'
import sys
import time

remaining = float(sys.argv[1]) - time.monotonic()
if remaining <= 0:
    raise SystemExit(1)
print(f"{min(3.0, remaining):.6f}")
PY
}

# Stop the runtime and wait to retry without exceeding a startup deadline.
prepare_runtime_restart() {
    local deadline="$1"
    local remaining_seconds
    local retry_delay

    remaining_seconds=$(runtime_start_remaining_seconds "$deadline") || return 124
    "$SCRIPT_DIRECTORY/../Tools/ci/run-command-with-deadline.py" \
        --seconds "$remaining_seconds" --grace-seconds 0 -- \
        "$container_binary" system stop >/dev/null 2>&1 || true
    retry_delay=$(runtime_start_retry_delay "$deadline") || return 124
    sleep "$retry_delay"
}

# Start Container and verify an API round-trip, recovering once from transient XPC startup failure.
start_runtime() {
    local attempt
    local remaining_seconds
    local sequence_deadline="${1:-}"
    local start_completed
    local start_log
    local start_state_root
    local start_status

    if [[ -z "$sequence_deadline" ]]; then
        sequence_deadline=$(runtime_start_deadline)
    fi
    for attempt in 1 2; do
        if ! remaining_seconds=$(runtime_start_remaining_seconds "$sequence_deadline"); then
            return 124
        fi
        start_state_root=$(mktemp -d "${TMPDIR:-/tmp}/container-compose-runtime-start.XXXXXX")
        start_completed="$start_state_root/completed"
        start_log="$start_state_root/start.log"
        # The inner shell receives all values positionally; expansion here would be unsafe.
        # shellcheck disable=SC2016
        if "$SCRIPT_DIRECTORY/../Tools/ci/run-command-with-deadline.py" \
            --seconds "$remaining_seconds" --grace-seconds 0 -- \
            /bin/bash -c '
                container_binary=$1
                start_completed=$2
                shift 2
                "$container_binary" "$@" || exit "$?"
                touch "$start_completed"
                "$container_binary" list --all --format json >/dev/null
            ' runtime-start "$container_binary" "$start_completed" \
            "${start_arguments[@]}" 2>&1 | tee "$start_log"; then
            rm -rf "$start_state_root"
            return
        else
            start_status=$?
            if [[ ! -f "$start_completed" ]] &&
                ! is_transient_xpc_start_failure "$start_log"; then
                rm -rf "$start_state_root"
                return "$start_status"
            fi
        fi
        rm -rf "$start_state_root"

        if [[ "$attempt" == "2" ]]; then
            return "$start_status"
        fi
        printf 'Container API was not ready; restarting the matched runtime once...\n' >&2
        prepare_runtime_restart "$sequence_deadline" || return "$?"
    done
}

# A nested release target inherits the outer harness's lock and runtime
# ownership. Recheck the API before trusting that ownership because a matched
# CLI rebuild can replace the installed service binaries after the outer
# runtime was started. Recover the same namespace/root once without taking a
# second lock or stopping the owner.
ensure_managed_runtime_ready() {
    local remaining_seconds
    local sequence_deadline="${1:-}"
    local start_log
    local start_status

    if [[ -z "$sequence_deadline" ]]; then
        sequence_deadline=$(runtime_start_deadline)
    fi
    remaining_seconds=$(runtime_start_remaining_seconds "$sequence_deadline") || return 124
    if "$SCRIPT_DIRECTORY/../Tools/ci/run-command-with-deadline.py" \
        --seconds "$remaining_seconds" --grace-seconds 0 -- \
        "$container_binary" list --all --format json >/dev/null; then
        return
    fi
    start_status=$?
    if [[ "$start_status" == "124" ]]; then
        return "$start_status"
    fi

    remaining_seconds=$(runtime_start_remaining_seconds "$sequence_deadline") || return 124
    printf 'Managed Container API is not ready; re-establishing the owner runtime...\n' >&2
    start_log=$(mktemp "${TMPDIR:-/tmp}/container-compose-runtime-managed-start.XXXXXX")
    start_arguments=(--debug system start --timeout 60 --enable-kernel-install)
    if [[ -n "$runtime_app_root" ]]; then
        start_arguments+=(--app-root "$runtime_app_root")
    fi
    # The inner shell receives all values positionally; expansion here would be unsafe.
    # shellcheck disable=SC2016
    if "$SCRIPT_DIRECTORY/../Tools/ci/run-command-with-deadline.py" \
        --seconds "$remaining_seconds" --grace-seconds 0 -- \
        /bin/bash -c '
            container_binary=$1
            shift
            "$container_binary" "$@" || exit "$?"
            "$container_binary" list --all --format json >/dev/null
        ' runtime-recovery "$container_binary" "${start_arguments[@]}" \
        2>&1 | tee "$start_log"; then
        start_status=0
    else
        start_status=${PIPESTATUS[0]}
        rm -f "$start_log"
        return "$start_status"
    fi
    rm -f "$start_log"
}

prepare_runtime_root() {
    local deadline="$1"

    run_runtime_start_command "$deadline" mkdir -p "$runtime_app_root"
    local marker_path="$runtime_app_root/$runtime_root_marker"
    if [[ -f "$marker_path" ]]; then
        local marker_value
        IFS= read -r marker_value <"$marker_path" || true
        if [[ "$marker_value" != "$runtime_root_marker_value" ]]; then
            printf 'refusing to clear container runtime root with an invalid marker: %s\n' "$runtime_app_root" >&2
            exit 2
        fi
    else
        local existing_entry
        existing_entry=$(find "$runtime_app_root" -mindepth 1 -maxdepth 1 -print -quit)
        if [[ -n "$existing_entry" ]]; then
            printf 'refusing to clear unmarked container runtime root: %s\n' "$runtime_app_root" >&2
            exit 2
        fi
        printf '%s\n' "$runtime_root_marker_value" >"$marker_path"
    fi

    run_runtime_start_command "$deadline" \
        find "$runtime_app_root" -mindepth 1 -maxdepth 1 \
        ! -name "$runtime_root_marker" ! -name kernels -exec rm -rf {} +
}

# launchd-managed Container services do not necessarily inherit the caller's
# privacy access to removable volumes, Documents, or other user-controlled
# locations. Copy every archive that a service may open into a private local
# staging root before taking the host runtime lock. This turns a host-policy
# mismatch into a bounded local copy instead of an opaque service-side open(2)
# hang while the global lock is held.
stage_runtime_service_inputs() {
    local deadline="$1"
    local trusted_temporary_root=/private/tmp
    if [[ ! -d "$trusted_temporary_root" ]]; then
        trusted_temporary_root=/tmp
    fi
    runtime_service_inputs_root=$(run_runtime_start_command "$deadline" mktemp -d \
        "$trusted_temporary_root/container-compose-service-inputs.XXXXXX")

    stage_runtime_service_archive "$deadline" runtime_builder_image_tar builder-image.oci.tar
    stage_runtime_service_archive "$deadline" runtime_bootstrap_image_tar bootstrap-image.oci.tar
    stage_runtime_service_archive "$deadline" matched_init_image_tar matched-init-image.oci.tar
    stage_runtime_service_archive "$deadline" runtime_init_image_archive retained-init-image.oci.tar

    # Nested release validation must inherit the service-readable copies, not
    # the caller's original paths on a removable or privacy-controlled volume.
    export CONTAINER_RUNTIME_BUILDER_IMAGE_TAR="$runtime_builder_image_tar"
    export CONTAINER_RUNTIME_BOOTSTRAP_IMAGE_TAR="$runtime_bootstrap_image_tar"
    export CONTAINER_RUNTIME_INIT_IMAGE_TAR="$matched_init_image_tar"
    export CONTAINER_RUNTIME_INIT_IMAGE_ARCHIVE="$runtime_init_image_archive"
}

stage_runtime_service_archive() {
    local deadline="$1"
    local variable_name="$2"
    local destination_name="$3"
    local source_path="${!variable_name}"
    [[ -n "$source_path" ]] || return 0

    local destination_path="$runtime_service_inputs_root/$destination_name"
    local temporary_path="$destination_path.partial"
    local install_status=0
    run_runtime_start_command "$deadline" \
        /usr/bin/install -m 0600 "$source_path" "$temporary_path" || install_status=$?
    if [[ "$install_status" != "0" ]]; then
        rm -f "$temporary_path"
        [[ "$install_status" != "124" ]] || return "$install_status"
        printf 'failed to stage container runtime service archive: %s\n' "$source_path" >&2
        exit 2
    fi
    run_runtime_start_command "$deadline" \
        mv -f "$temporary_path" "$destination_path"
    printf -v "$variable_name" '%s' "$destination_path"
}

cleanup_runtime_service_inputs() {
    [[ -n "$runtime_service_inputs_root" ]] || return 0
    case "$runtime_service_inputs_root" in
        /private/tmp/container-compose-service-inputs.* | /tmp/container-compose-service-inputs.*) ;;
        *)
            printf 'refusing to clear unexpected runtime service-input staging root: %s\n' \
                "$runtime_service_inputs_root" >&2
            return 1
            ;;
    esac
    find "$runtime_service_inputs_root" -depth -delete 2>/dev/null || true
    runtime_service_inputs_root=
}

resolve_matched_init_image() {
    has_matched_init_image_source || return 0

    if [[ -z "$matched_init_image" ]]; then
        matched_init_image="vminit:container-compose"
    fi
}

# A retained OCI archive can be loaded by `container system start` before its
# normal initial-filesystem pull. A bootstrap archive is only used to bring up
# the local image builder; the subsequent source build must still replace it
# with the exact matched guest image before the candidate command runs.
resolve_initial_start_init_image_archive() {
    if [[ -n "$matched_init_image_tar" ]]; then
        initial_start_init_image_archive=$matched_init_image_tar
        initial_start_image_is_matched=true
    elif [[ -n "$runtime_init_image_archive" ]]; then
        initial_start_init_image_archive=$runtime_init_image_archive
        initial_start_image_is_matched=true
    elif [[ -n "$runtime_bootstrap_image_tar" ]]; then
        initial_start_init_image_archive=$runtime_bootstrap_image_tar
    fi
}

prepare_runtime_config_home() {
    local deadline="$1"

    has_matched_init_image_source || return 0
    [[ -n "$runtime_app_root" ]] || return 0

    runtime_config_home="$runtime_app_root/xdg-config"
    run_runtime_start_command "$deadline" mkdir -p "$runtime_config_home"
    export XDG_CONFIG_HOME="$runtime_config_home"
}

configure_matched_init_image() {
    local deadline="$1"

    [[ -n "$runtime_config_home" ]] || return 0

    local container_config_dir="$runtime_config_home/container"
    run_runtime_start_command "$deadline" mkdir -p "$container_config_dir"
    {
        if [[ -n "$runtime_builder_image" ]]; then
            printf '[build]\nimage = "%s"\n\n' "$runtime_builder_image"
        fi
        printf '[vminit]\nimage = "%s"\n' "$matched_init_image"
    } >"$container_config_dir/config.toml"

    local runtime_config_dir="$runtime_app_root/config"
    local runtime_config_path="$runtime_config_dir/config.toml"
    local runtime_config_temp
    run_runtime_start_command "$deadline" mkdir -p "$runtime_config_dir"
    runtime_config_temp=$(mktemp "$runtime_config_dir/.config.toml.XXXXXX")
    run_runtime_start_command "$deadline" \
        cp "$container_config_dir/config.toml" "$runtime_config_temp"
    run_runtime_start_command "$deadline" chmod 0444 "$runtime_config_temp"
    run_runtime_start_command "$deadline" \
        mv -f "$runtime_config_temp" "$runtime_config_path"

    export CONTAINER_COMPOSE_INIT_IMAGE="$matched_init_image"
}

configure_runtime_builder_image() {
    local deadline="$1"

    [[ -n "$runtime_config_home" ]] || return 0
    if [[ -z "$runtime_builder_image" ]]; then
        return 0
    fi

    local container_config_dir="$runtime_config_home/container"
    run_runtime_start_command "$deadline" mkdir -p "$container_config_dir"
    printf '[build]\nimage = "%s"\n' "$runtime_builder_image" \
        >"$container_config_dir/config.toml"
}

install_runtime_builder_image() {
    local deadline="$1"

    if [[ -z "$runtime_builder_image" && -z "$runtime_builder_image_tar" ]]; then
        return
    fi
    if [[ -z "$runtime_builder_image" || -z "$runtime_builder_image_tar" ]]; then
        printf 'CONTAINER_RUNTIME_BUILDER_IMAGE and CONTAINER_RUNTIME_BUILDER_IMAGE_TAR must be set together\n' >&2
        exit 2
    fi
    if [[ ! -f "$runtime_builder_image_tar" ]]; then
        printf 'container runtime builder image archive does not exist: %s\n' "$runtime_builder_image_tar" >&2
        exit 2
    fi

    printf 'Installing matched container runtime builder image...\n'
    run_runtime_start_command "$deadline" \
        "$container_binary" image load -i "$runtime_builder_image_tar"
}

install_runtime_bootstrap_image() {
    local deadline="$1"

    [[ -n "$runtime_bootstrap_image_tar" ]] || return 0
    [[ "$initial_start_init_image_archive" != "$runtime_bootstrap_image_tar" ]] || return 0
    if [[ ! -f "$runtime_bootstrap_image_tar" ]]; then
        printf 'container runtime bootstrap image archive does not exist: %s\n' "$runtime_bootstrap_image_tar" >&2
        exit 2
    fi

    printf 'Installing container runtime bootstrap image...\n'
    run_runtime_start_command "$deadline" \
        "$container_binary" image load -i "$runtime_bootstrap_image_tar"
}

cleanup() {
    local status=$?
    trap - EXIT
    trap '' INT TERM
    printf 'Stopping matched container runtime...\n'
    stop_runtime || true
    release_container_runtime_lock
    cleanup_runtime_service_inputs || true
    exit "$status"
}

# Install a guest init image built from the same source lane as the host runtime.
install_matched_init_image() {
    local deadline="$1"

    # The startup command has already loaded and unpacked this archive before
    # its registry fallback. Do not load it a second time after startup.
    [[ "$initial_start_image_is_matched" == true ]] && return 0

    if [[ -n "$matched_init_image_tar" ]]; then
        printf 'Installing prebuilt matched container runtime init image...\n'
        run_runtime_start_command "$deadline" \
            "$container_binary" image load -i "$matched_init_image_tar"
        return 0
    fi

    if [[ -n "$runtime_init_image_archive" ]]; then
        printf 'Loading matched container runtime init image archive...\n'
        run_runtime_start_command "$deadline" \
            "$container_binary" image load --input "$runtime_init_image_archive"
        return 0
    fi

    [[ -n "$runtime_init_block_repo" ]] || return 0

    if [[ ! -f "$runtime_init_block_repo/Makefile" ]]; then
        printf 'container runtime init-block repo does not contain a Makefile: %s\n' "$runtime_init_block_repo" >&2
        exit 2
    fi

    local init_env=()
    init_env+=(
        BASH_ENV=/dev/null
        CONTAINER_INIT_CLI="$container_binary"
        PATH="$(dirname "$container_binary"):$PATH"
    )
    if [[ -n "$runtime_app_root" ]]; then
        init_env+=(APP_ROOT="$runtime_app_root")
    fi
    if [[ -n "$containerization_init_source_path" ]]; then
        init_env+=(CONTAINERIZATION_INIT_SOURCE_PATH="$containerization_init_source_path")
    fi
    if [[ -n "$containerization_init_build_scratch_root" ]]; then
        init_env+=(CONTAINERIZATION_INIT_BUILD_SCRATCH_ROOT="$containerization_init_build_scratch_root")
    fi
    if [[ -n "$matched_init_image" ]]; then
        init_env+=(CONTAINER_INIT_IMAGE_NAME="$matched_init_image")
    fi

    printf 'Installing matched container runtime init image...\n'
    # The initial runtime only hosts the local image build. It must not fetch
    # the default guest before this source-pinned image is available.
    run_runtime_start_command "$deadline" env "${init_env[@]}" \
        make -C "$runtime_init_block_repo" KERNEL_INSTALL=false init-block
}

validate_runtime_inputs
runtime_start_sequence_deadline=$(runtime_start_deadline)
validate_containerization_init_source "$runtime_start_sequence_deadline"
resolve_matched_init_image
validate_runtime_init_image_archive "$runtime_start_sequence_deadline"
configure_runtime_namespace
verify_runtime_namespace_support "$runtime_start_sequence_deadline"

if [[ "${CONTAINER_RUNTIME_MANAGED:-0}" == "1" ]]; then
    ensure_managed_runtime_ready "$runtime_start_sequence_deadline"
    "$@"
    exit
fi

trap cleanup_runtime_service_inputs EXIT
stage_runtime_service_inputs "$runtime_start_sequence_deadline"
runtime_lock_timeout=$(runtime_start_lock_timeout_seconds \
    "$runtime_start_sequence_deadline")
CONTAINER_RUNTIME_LOCK_TIMEOUT_SECONDS="$runtime_lock_timeout" \
    acquire_container_runtime_lock
trap 'exit 130' INT
trap 'exit 143' TERM
trap cleanup EXIT

printf 'Stopping stale container services...\n'
stop_runtime "$runtime_start_sequence_deadline"
run_runtime_start_command "$runtime_start_sequence_deadline" sleep 3
prepare_runtime_root "$runtime_start_sequence_deadline"
stage_containerization_init_source "$runtime_start_sequence_deadline"
resolve_initial_start_init_image_archive
prepare_runtime_config_home "$runtime_start_sequence_deadline"
configure_runtime_builder_image "$runtime_start_sequence_deadline"
if [[ -n "$initial_start_init_image_archive" ]]; then
    configure_matched_init_image "$runtime_start_sequence_deadline"
fi

printf 'Starting matched container runtime...\n'
# Service startup only installs the host-side kernel; it does not materialize
# a guest init image. A source-built init image invokes `container build`
# before the harness's final restart, so it needs that kernel in the isolated
# root. Keep the image configuration unset until after the exact guest image
# is built, but let this first startup provision the matching kernel. A
# retained exact init archive retains the prior no-download bootstrap path.
kernel_install_option=--enable-kernel-install
if [[ "$initial_start_image_is_matched" == true ]]; then
    kernel_install_option=--disable-kernel-install
fi
start_arguments=(--debug system start --timeout 60 "$kernel_install_option")
if [[ -n "$runtime_app_root" ]]; then
    start_arguments+=(--app-root "$runtime_app_root")
fi
if [[ -n "$initial_start_init_image_archive" ]]; then
    start_arguments+=(--init-image-archive "$initial_start_init_image_archive")
fi
start_runtime "$runtime_start_sequence_deadline"
install_runtime_builder_image "$runtime_start_sequence_deadline"
install_runtime_bootstrap_image "$runtime_start_sequence_deadline"
install_matched_init_image "$runtime_start_sequence_deadline"
if [[ -z "$initial_start_init_image_archive" ]]; then
    configure_matched_init_image "$runtime_start_sequence_deadline"
fi
if [[ -n "$runtime_config_home" ]]; then
    printf 'Restarting matched container runtime with the installed init image...\n'
    prepare_runtime_restart "$runtime_start_sequence_deadline"
    start_arguments=(--debug system start --timeout 60 --enable-kernel-install)
    if [[ -n "$runtime_app_root" ]]; then
        start_arguments+=(--app-root "$runtime_app_root")
    fi
    start_runtime "$runtime_start_sequence_deadline"
fi
runtime_start_remaining_seconds "$runtime_start_sequence_deadline" >/dev/null || exit 124

export CONTAINER_RUNTIME_MANAGED=1
"$@"
