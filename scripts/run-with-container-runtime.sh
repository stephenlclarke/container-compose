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
container_binary_directory=
container_binary_localization_path=
container_binary_sha256=
runtime_app_root=${CONTAINER_RUNTIME_APP_ROOT:-}
runtime_app_root_localization_path=
runtime_privacy_home=
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
runtime_start_state_root=
runtime_start_deadline_seconds=${CONTAINER_RUNTIME_START_DEADLINE_SECONDS:-300}
runtime_start_sequence_deadline=
runtime_candidate_staging_root=
runtime_candidate_staging_complete=false
runtime_candidate_staging_cleanup_allowed=false
runtime_candidate_staging_created=false
runtime_candidate_staging_lock_held=false
runtime_candidate_is_complete_package=false
runtime_candidate_is_managed_staging_package=false
runtime_candidate_stage_mode=${CONTAINER_RUNTIME_STAGE_CANDIDATE:-auto}
runtime_app_root_localization_mode=${CONTAINER_RUNTIME_LOCALIZE_APP_ROOT:-auto}
runtime_allow_non_macho_test_fixtures=${CONTAINER_RUNTIME_ALLOW_NON_MACHO_TEST_FIXTURES:-0}
runtime_local_execution_root=${CONTAINER_RUNTIME_LOCAL_EXECUTION_ROOT:-}
runtime_local_user_root=
runtime_managed_candidate_root=${CONTAINER_RUNTIME_STAGED_CANDIDATE_ROOT:-}
runtime_managed_package_sha256=${CONTAINER_RUNTIME_PACKAGE_SHA256:-}
runtime_app_root_localized=false
runtime_anonymous_registry_hosts=${CONTAINER_RUNTIME_ANONYMOUS_REGISTRY_HOSTS-ghcr.io}
runtime_launchctl=${CONTAINER_RUNTIME_LAUNCHCTL:-/bin/launchctl}

if [[ -z "$runtime_local_execution_root" ]]; then
    runtime_local_execution_root=/private/tmp
    if [[ ! -d "$runtime_local_execution_root" || ! -w "$runtime_local_execution_root" ]]; then
        runtime_local_execution_root=/tmp
    fi
fi

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
    local deadline="$1"

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
    if [[ -n "$runtime_builder_image_tar" ]]; then
        require_runtime_start_regular_file "$deadline" "$runtime_builder_image_tar" \
            'container runtime builder image archive does not exist'
    fi
    if [[ -n "$runtime_bootstrap_image_tar" ]]; then
        require_runtime_start_regular_file "$deadline" "$runtime_bootstrap_image_tar" \
            'container runtime bootstrap image archive does not exist'
    fi
    if [[ -n "$matched_init_image_tar" ]]; then
        require_runtime_start_regular_file "$deadline" "$matched_init_image_tar" \
            'container runtime init image archive does not exist'
    fi
    if [[ -n "$runtime_init_image_archive" ]]; then
        require_runtime_start_regular_file "$deadline" "$runtime_init_image_archive" \
            'container runtime init-image archive does not exist'
    fi
    if [[ -n "$runtime_init_block_repo" ]]; then
        require_runtime_start_regular_file "$deadline" "$runtime_init_block_repo/Makefile" \
            'container runtime init-block repo does not contain a Makefile'
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
    local requested_source_status=0
    # Resolve the caller-controlled path in the bounded child rather than
    # allowing an unresponsive external mount to block this owner shell.
    # shellcheck disable=SC2016 # Expand $1 in the bounded child shell.
    requested_source_path=$(run_runtime_start_command "$deadline" \
        /bin/bash -c 'cd "$1" && pwd -P' source-root \
        "$containerization_init_source_path") || requested_source_status=$?
    if [[ "$requested_source_status" != "0" ]]; then
        [[ "$requested_source_status" != "124" ]] || return "$requested_source_status"
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
    local reported_source_root="$containerization_init_source_root"
    local canonical_root_status=0
    # shellcheck disable=SC2016 # Expand $1 in the bounded child shell.
    containerization_init_source_root=$(run_runtime_start_command "$deadline" \
        /bin/bash -c 'cd "$1" && pwd -P' source-root \
        "$reported_source_root") || canonical_root_status=$?
    [[ "$canonical_root_status" != "124" ]] || return "$canonical_root_status"
    if [[ "$canonical_root_status" != "0" ]]; then
        printf 'containerization init source root is no longer accessible: %s\n' \
            "$reported_source_root" >&2
        exit 2
    fi
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
    reject_runtime_start_existing_path "$deadline" "$staged_source_path" \
        'refusing to overwrite an existing staged containerization source' \
        "$staged_source_path"

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
    reject_runtime_start_existing_path "$deadline" "$staged_source_path/.build" \
        'staged containerization init source contains ignored Swift build artifacts' \
        "$staged_source_path"
    reject_runtime_start_existing_path "$deadline" "$staged_source_path/vminitd/.build" \
        'staged containerization init source contains ignored Swift build artifacts' \
        "$staged_source_path"

    containerization_init_source_snapshot_path="$staged_source_path"
    containerization_init_source_path="$staged_source_path"
    containerization_init_build_scratch_root="$runtime_app_root/source-build-cache"
    run_runtime_start_command "$deadline" \
        mkdir -p "$containerization_init_build_scratch_root"

    local fingerprints_root="$runtime_app_root/fingerprints"
    run_runtime_start_command "$deadline" mkdir -p "$fingerprints_root"
    local source_fingerprint
    printf -v source_fingerprint \
        'source_root=%s\nsource_head=%s\nstaged_source_root=%s\nstaged_source_head=%s\nbuild_scratch_root=%s\n' \
        "$containerization_init_source_root" \
        "$containerization_init_source_head" \
        "$containerization_init_source_snapshot_path" \
        "$staged_source_head" \
        "$containerization_init_build_scratch_root"
    write_runtime_start_file "$deadline" \
        "$fingerprints_root/containerization-init-source.txt" "$source_fingerprint"
}

# Report whether a source checkout or retained archive can provide the matched init image.
has_matched_init_image_source() {
    [[ -n "$runtime_init_block_repo" ||
        -n "$matched_init_image_tar" ||
        -n "$runtime_init_image_archive" ]]
}

# Reject production launch agents that can relaunch while an isolated runtime is measured.
assert_no_competing_container_launch_agents() {
    local label
    local loaded_labels=
    local user_domain
    user_domain="gui/$(id -u)"

    if [[ ! -x "$runtime_launchctl" ]]; then
        printf 'Container runtime launch-agent inspector is not executable: %s\n' \
            "$runtime_launchctl" >&2
        return 2
    fi

    for label in \
        homebrew.mxcl.container \
        homebrew.mxcl.container-current \
        com.apple.container.apiserver; do
        if "$runtime_launchctl" print "$user_domain/$label" >/dev/null 2>&1; then
            loaded_labels="${loaded_labels}${loaded_labels:+, }${label}"
        fi
    done

    if [[ -n "$loaded_labels" ]]; then
        printf 'competing production Container launch agent is loaded: %s\n' \
            "$loaded_labels" >&2
        printf '%s\n' \
            'stop or unload it before starting isolated release validation' >&2
        return 2
    fi
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

# Reject an invalid deadline before its value is used to launch any filesystem work.
validate_runtime_start_deadline_seconds() {
    if ! [[ "$runtime_start_deadline_seconds" =~ ^[1-9][0-9]*$ ]]; then
        printf 'CONTAINER_RUNTIME_START_DEADLINE_SECONDS must be a positive integer: %s\n' \
            "$runtime_start_deadline_seconds" >&2
        exit 2
    fi
}

# Validate the privacy-protection controls before inspecting caller paths.
validate_runtime_localization_modes() {
    case "$runtime_candidate_stage_mode" in
        auto | always | never) ;;
        *)
            printf 'CONTAINER_RUNTIME_STAGE_CANDIDATE must be auto, always, or never: %s\n' \
                "$runtime_candidate_stage_mode" >&2
            exit 2
            ;;
    esac
    case "$runtime_app_root_localization_mode" in
        auto | always | never) ;;
        *)
            printf 'CONTAINER_RUNTIME_LOCALIZE_APP_ROOT must be auto, always, or never: %s\n' \
                "$runtime_app_root_localization_mode" >&2
            exit 2
            ;;
    esac
    case "$runtime_allow_non_macho_test_fixtures" in
        0 | 1) ;;
        *)
            printf 'CONTAINER_RUNTIME_ALLOW_NON_MACHO_TEST_FIXTURES must be 0 or 1: %s\n' \
                "$runtime_allow_non_macho_test_fixtures" >&2
            exit 2
            ;;
    esac
    case "$runtime_local_execution_root" in
        /private/tmp | /tmp) ;;
        *)
            printf 'CONTAINER_RUNTIME_LOCAL_EXECUTION_ROOT must be /private/tmp or /tmp: %s\n' \
                "$runtime_local_execution_root" >&2
            exit 2
            ;;
    esac
    if [[ ! -d "$runtime_local_execution_root" || ! -w "$runtime_local_execution_root" ]]; then
        printf 'container runtime local execution root is not writable: %s\n' \
            "$runtime_local_execution_root" >&2
        exit 2
    fi
}

# Reuse the outer wrapper's immutable staged package for managed nested calls.
# Release gates pass the original source path as a Make command-line variable,
# so environment aliases alone cannot otherwise prevent a recursive wrapper
# from waiting on the staging lock retained by its owner.
select_managed_runtime_candidate() {
    [[ "${CONTAINER_RUNTIME_MANAGED:-0}" == "1" ]] || return 0

    local inherited_cli=${CONTAINER_RUNTIME_CLI:-}
    if [[ -z "$runtime_managed_candidate_root" &&
        -z "$runtime_managed_package_sha256" ]]; then
        return 0
    fi
    if [[ -z "$runtime_managed_candidate_root" ||
        -z "$runtime_managed_package_sha256" ||
        -z "$inherited_cli" ||
        -z "${CONTAINER_RUNTIME_CLI_SHA256:-}" ]]; then
        printf 'managed Container runtime candidate identity is incomplete\n' >&2
        exit 2
    fi
    if [[ "$inherited_cli" != "$runtime_managed_candidate_root/bin/container" ]]; then
        printf 'managed Container runtime CLI does not belong to its staged package: %s\n' \
            "$inherited_cli" >&2
        exit 2
    fi
    case "$runtime_managed_candidate_root" in
        "$runtime_local_user_root"/candidate-[0-9a-f]*) ;;
        *)
            printf 'managed Container runtime candidate is outside the private staging root: %s\n' \
                "$runtime_managed_candidate_root" >&2
            exit 2
            ;;
    esac
    local staged_directory_name=${runtime_managed_candidate_root##*/}
    if ! [[ "$staged_directory_name" =~ ^candidate-[0-9a-f]{16}$ ]]; then
        printf 'managed Container runtime candidate has an invalid staging identity: %s\n' \
            "$runtime_managed_candidate_root" >&2
        exit 2
    fi
    if ! [[ "$runtime_managed_package_sha256" =~ ^[0-9a-f]{64}$ ]]; then
        printf 'managed Container runtime package has an invalid fingerprint\n' >&2
        exit 2
    fi
    container_binary=$inherited_cli
}

# Keep GNU Make's command-line precedence from restoring a mutable source CLI
# through inherited MAKEFLAGS. A final direct assignment replaces every
# inherited definition and is propagated unchanged to recursive makes.
run_with_managed_runtime_candidate() {
    local command_name=${1##*/}
    case "$command_name" in
        make | gmake)
            "$@" "CONTAINER_BIN=$container_binary" \
                "CONTAINER_COMPOSE_CONTAINER=$container_binary" 8>&-
            ;;
        *)
            "$@" 8>&-
            ;;
    esac
}

# Print owner and permission mode in a stable form on both BSD/macOS and GNU
# stat. Hosted Linux checks exercise the same staging boundary as macOS.
runtime_path_owner_and_mode() {
    local path="$1"
    if /usr/bin/stat -f '%u %Lp' "$path" >/dev/null 2>&1; then
        /usr/bin/stat -f '%u %Lp' "$path"
    else
        /usr/bin/stat -c '%u %a' "$path"
    fi
}

validate_private_runtime_directory() {
    local path="$1"
    local description="$2"
    local owner
    local mode

    if [[ -L "$path" || ! -d "$path" ]]; then
        printf 'refusing to use an indirect %s: %s\n' "$description" "$path" >&2
        return 2
    fi
    read -r owner mode < <(runtime_path_owner_and_mode "$path")
    if [[ "$owner" != "$(id -u)" ]] || (( (8#$mode & 077) != 0 )); then
        printf 'refusing to use an unowned or accessible %s: %s\n' \
            "$description" "$path" >&2
        return 2
    fi
}

prepare_local_user_root() {
    local deadline="$1"

    if [[ ! -e "$runtime_local_user_root" && ! -L "$runtime_local_user_root" ]]; then
        run_runtime_start_command "$deadline" mkdir -m 0700 \
            "$runtime_local_user_root" || return "$?"
    fi
    validate_private_runtime_directory \
        "$runtime_local_user_root" 'local Container runtime root'
}

# Return success for locations that launchd or TCC can classify as removable
# or user-controlled. Services launched from these paths can block behind a
# GUI approval dialog that an unattended build cannot answer.
runtime_path_requires_localization() {
    local path="$1"
    local normalized_path
    local normalized_home
    normalized_path=$(LC_ALL=C printf '%s' "$path" | tr '[:upper:]' '[:lower:]')
    normalized_home=$(LC_ALL=C printf '%s' "$runtime_privacy_home" | tr '[:upper:]' '[:lower:]')
    case "$normalized_path" in
        /volumes | /volumes/* | "$normalized_home"/desktop | "$normalized_home"/desktop/* | "$normalized_home"/documents | "$normalized_home"/documents/* | "$normalized_home"/downloads | "$normalized_home"/downloads/*)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

runtime_app_root_requires_localization() {
    case "$runtime_app_root_localization_mode" in
        always) return 0 ;;
        auto) runtime_path_requires_localization "$runtime_app_root_localization_path" ;;
        never) return 1 ;;
    esac
}

runtime_candidate_requires_staging() {
    if [[ "$runtime_candidate_is_managed_staging_package" == true ]]; then
        return 1
    fi
    case "$runtime_candidate_stage_mode" in
        always) return 0 ;;
        auto)
            if [[ "$runtime_candidate_is_complete_package" == true ]]; then
                return 0
            fi
            runtime_path_requires_localization "$container_binary_localization_path"
            ;;
        never) return 1 ;;
    esac
}

runtime_requires_local_user_root() {
    runtime_app_root_requires_localization || runtime_candidate_requires_staging
}

# Keep marker-protected runtime state on the local system volume whenever the
# configured build root lives on removable or privacy-controlled storage.
localize_runtime_app_root() {
    runtime_app_root_requires_localization || return 0

    local requested_root="$runtime_app_root"
    local requested_root_digest
    requested_root_digest=$(LC_ALL=C printf '%s' "$requested_root" \
        | shasum -a 256 | awk '{print substr($1, 1, 16)}')
    runtime_app_root="$runtime_local_user_root/state-$requested_root_digest"
    runtime_app_root_localized=true
    printf 'Relocating Container runtime state from privacy-controlled storage: %s -> %s\n' \
        "$requested_root" "$runtime_app_root"
}

# Validate the caller-provided root before localization replaces it with a
# generated local path. Otherwise an empty or relative input can be hidden by
# the generated path and multiple unrelated runs can share one state root.
validate_requested_runtime_app_root() {
    local deadline="$1"
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
    local canonical_root
    local status=0
    canonical_root=$(run_runtime_start_command "$deadline" python3 -c \
        'import os, sys; print(os.path.realpath(sys.argv[1]))' \
        "$runtime_app_root") || status=$?
    if [[ "$status" != "0" ]]; then
        [[ "$status" != "124" ]] || return "$status"
        printf 'could not resolve CONTAINER_RUNTIME_APP_ROOT: %s\n' \
            "$runtime_app_root" >&2
        exit 2
    fi
    runtime_app_root_localization_path="$canonical_root"
    status=0
    runtime_privacy_home=$(run_runtime_start_command "$deadline" python3 -c \
        'import os, sys; print(os.path.realpath(sys.argv[1]))' \
        "${HOME:-/nonexistent}") || status=$?
    if [[ "$status" != "0" ]]; then
        [[ "$status" != "124" ]] || return "$status"
        printf 'could not resolve the home directory for runtime privacy classification\n' >&2
        exit 2
    fi
}

# Fingerprint the complete packaged runtime closure rather than only the main
# CLI. The pre-copy, staged, and post-copy fingerprints must agree so a source
# rebuild cannot produce a validly signed but mixed-generation candidate.
fingerprint_runtime_package() {
    local deadline="$1"
    local package_root="$2"
    local fingerprint
    local status=0

    fingerprint=$(run_runtime_start_command "$deadline" python3 -c '
import hashlib
import os
import stat
import sys

package_root = os.fsencode(sys.argv[1])
entries = []

def add_path(path):
    relative_path = os.path.relpath(path, package_root)
    metadata = os.lstat(path)
    mode = stat.S_IMODE(metadata.st_mode)
    if stat.S_ISLNK(metadata.st_mode):
        raise SystemExit(
            f"runtime package contains an indirect entry: {os.fsdecode(path)}"
        )
    if stat.S_ISDIR(metadata.st_mode):
        entries.append((relative_path, b"d", mode, b""))
        return
    if not stat.S_ISREG(metadata.st_mode):
        raise SystemExit(
            f"runtime package contains a non-regular entry: {os.fsdecode(path)}"
        )
    digest = hashlib.sha256()
    with open(path, "rb") as source:
        for block in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(block)
    entries.append((relative_path, b"f", mode, digest.hexdigest().encode()))

for binary_name in (b"container", b"container-apiserver", b"container-engine"):
    add_path(os.path.join(package_root, b"bin", binary_name))

libexec_root = os.path.join(package_root, b"libexec/container")
if not os.path.isdir(libexec_root) or os.path.islink(libexec_root):
    raise SystemExit(f"invalid runtime package root: {os.fsdecode(libexec_root)}")
for current_root, directories, files in os.walk(libexec_root, followlinks=False):
    for name in sorted(directories + files):
        add_path(os.path.join(current_root, name))

manifest = hashlib.sha256(b"container-runtime-package-v1\0")
for relative_path, kind, mode, digest in sorted(entries):
    manifest.update(kind + b"\0")
    manifest.update(relative_path + b"\0")
    manifest.update(f"{mode:04o}".encode() + b"\0")
    manifest.update(digest + b"\0")
print(manifest.hexdigest())
' "$package_root") || status=$?
    if [[ "$status" != "0" ]]; then
        [[ "$status" != "124" ]] || return "$status"
        printf 'could not fingerprint complete Container runtime package: %s\n' \
            "$package_root" >&2
        return 2
    fi
    if ! [[ "$fingerprint" =~ ^[0-9a-f]{64}$ ]]; then
        printf 'Container runtime package produced an invalid fingerprint: %s\n' \
            "$package_root" >&2
        return 2
    fi
    printf '%s\n' "$fingerprint"
}

# Reject ad-hoc Mach-O signatures before macOS can treat every rebuild as a
# new Local Network or Keychain client.
validate_runtime_candidate_signatures() {
    local deadline="$1"
    local source_package_root="$2"

    # shellcheck disable=SC2016 # Expand positional values in the bounded child.
    run_runtime_start_command "$deadline" /bin/bash -c '
set -euo pipefail
source_package_root=$1
allow_non_macho_test_fixtures=$2
indirect_executable=$(find \
    "$source_package_root/bin" "$source_package_root/libexec/container" \
    -type l -print -quit)
if [[ -n "$indirect_executable" ]]; then
    printf "Container runtime package contains an indirect executable: %s\n" \
        "$indirect_executable" >&2
    exit 2
fi

trusted_temporary_root=/private/tmp
if [[ ! -d "$trusted_temporary_root" || ! -w "$trusted_temporary_root" ]]; then
    trusted_temporary_root=/tmp
fi
executable_list=$(mktemp "$trusted_temporary_root/container-runtime-signatures.XXXXXX")
trap '\''rm -f "$executable_list"'\'' EXIT
find "$source_package_root/bin" "$source_package_root/libexec/container" \
    -type f -print0 >"$executable_list"

for binary_name in container container-apiserver container-engine; do
    executable="$source_package_root/bin/$binary_name"
    file_description=$(/usr/bin/file -b "$executable")
    if [[ "$file_description" != *Mach-O* ]]; then
        if [[ "$allow_non_macho_test_fixtures" == 1 ]]; then
            continue
        fi
        printf "Container runtime packaged binary must be Mach-O: %s\n" \
            "$executable" >&2
        exit 2
    fi
done

while IFS= read -r -d "" executable; do
    [[ -x "$executable" ]] || continue
    file_description=$(/usr/bin/file -b "$executable")
    if [[ "$file_description" != *Mach-O* ]]; then
        case "$executable" in
            "$source_package_root"/libexec/container/plugins/*/bin/* | \
                "$source_package_root"/libexec/container/helpers/*)
                printf "Container runtime launchable executable must be Mach-O: %s\n" \
                    "$executable" >&2
                exit 2
                ;;
        esac
        continue
    fi
    if ! /usr/bin/codesign --verify --strict "$executable" >/dev/null 2>&1; then
        printf "Container runtime executable has an invalid code signature: %s\n" \
            "$executable" >&2
        exit 2
    fi
    if ! signature_description=$(/usr/bin/codesign --display --verbose=4 "$executable" 2>&1); then
        printf "Container runtime executable has no valid code signature: %s\n" \
            "$executable" >&2
        exit 2
    fi
    if grep -Fqx "Signature=adhoc" <<<"$signature_description" ||
        ! grep -Eq "^Authority=Developer ID Application:" <<<"$signature_description"; then
        printf "Container runtime executable lacks a stable Developer ID signature: %s\n" \
            "$executable" >&2
        printf "rebuild it through make container-stack-build before running unattended runtime tests\n" >&2
        exit 2
    fi
done <"$executable_list"
' runtime-signatures "$source_package_root" \
        "$runtime_allow_non_macho_test_fixtures"
}

select_staged_runtime_candidate() {
    local package_sha256="$1"

    container_binary="$runtime_candidate_staging_root/bin/container"
    container_binary_directory="$runtime_candidate_staging_root/bin"
    export PATH="$container_binary_directory${PATH:+:$PATH}"
    export CONTAINER_RUNTIME_CLI="$container_binary"
    export CONTAINER_BIN="$container_binary"
    export CONTAINER_COMPOSE_CONTAINER="$container_binary"
    export CONTAINER_RUNTIME_STAGED_CANDIDATE_ROOT="$runtime_candidate_staging_root"
    export CONTAINER_RUNTIME_PACKAGE_SHA256="$package_sha256"
    runtime_candidate_staging_cleanup_allowed=true
    runtime_candidate_staging_complete=true
}

acquire_runtime_candidate_staging_lock() {
    local deadline="$1"
    local lock_file="${runtime_candidate_staging_root}.lock"
    local lock_backend
    local remaining_seconds

    if command -v lockf >/dev/null 2>&1; then
        lock_backend=lockf
    elif command -v flock >/dev/null 2>&1; then
        lock_backend=flock
    else
        printf 'lockf or flock is required to serialize local Container candidate staging\n' >&2
        return 2
    fi
    remaining_seconds=$(runtime_start_lock_timeout_seconds "$deadline") || return "$?"
    exec 8>>"$lock_file"
    case "$lock_backend" in
        lockf) lockf -t "$remaining_seconds" 8 ;;
        flock) flock -w "$remaining_seconds" 8 ;;
    esac || {
        exec 8>&-
        printf 'timed out waiting for local Container candidate staging lock: %s\n' \
            "$lock_file" >&2
        return 124
    }
    runtime_candidate_staging_lock_held=true
}

release_runtime_candidate_staging_lock() {
    [[ "$runtime_candidate_staging_lock_held" == true ]] || return 0
    exec 8>&-
    runtime_candidate_staging_lock_held=false
}

# Validate every complete source package regardless of whether its path needs
# relocation. A package under ~/github is local but an ad-hoc rebuild there is
# still a new privacy identity.
validate_packaged_runtime_candidate_signatures() {
    local deadline="$1"
    local source_bin_directory="${container_binary%/*}"
    local source_package_root="${source_bin_directory%/*}"
    local package_layout_state

    # shellcheck disable=SC2016 # Expand positional values in the bounded child.
    package_layout_state=$(run_runtime_start_command "$deadline" /bin/bash -c '
if [[ "$1" == bin ]] && [[ -x "$2/bin/container-apiserver" ]] &&
    [[ -x "$2/bin/container-engine" ]] && [[ -d "$2/libexec/container" ]]; then
    printf complete
elif [[ "$1" == bin ]] &&
    { [[ -e "$2/bin/container-apiserver" || -L "$2/bin/container-apiserver" ]] ||
        [[ -e "$2/bin/container-engine" || -L "$2/bin/container-engine" ]] ||
        [[ -e "$2/libexec/container" || -L "$2/libexec/container" ]]; }; then
    printf incomplete
else
    printf standalone
fi
' runtime-package-layout "${source_bin_directory##*/}" \
        "$source_package_root") || return "$?"
    if [[ "$package_layout_state" == incomplete ]]; then
        printf 'Container runtime candidate has an incomplete packaged layout: %s\n' \
            "$container_binary" >&2
        exit 2
    fi
    if [[ "$package_layout_state" != complete ]]; then
        if [[ -n "$runtime_managed_candidate_root" ]]; then
            printf 'managed Container runtime candidate is not a complete package: %s\n' \
                "$container_binary" >&2
            exit 2
        fi
        return 0
    fi
    runtime_candidate_is_complete_package=true
    validate_runtime_candidate_signatures "$deadline" "$source_package_root"

    [[ -n "$runtime_managed_candidate_root" ]] || return 0
    if [[ "$source_package_root" != "$runtime_managed_candidate_root" ]]; then
        printf 'managed Container runtime candidate root changed during resolution: %s\n' \
            "$source_package_root" >&2
        exit 2
    fi
    validate_private_runtime_directory \
        "$runtime_local_user_root" 'local Container runtime root' || exit "$?"
    validate_private_runtime_directory \
        "$source_package_root" 'local Container candidate' || exit "$?"
    local marker="$source_package_root/.container-compose-runtime-candidate-staging"
    local marker_value
    local marker_status=0
    # shellcheck disable=SC2016 # Expand positional values in the bounded child.
    marker_value=$(run_runtime_start_command "$deadline" /bin/bash -c '
if [[ -L "$1" || ! -f "$1" ]]; then
    exit 2
fi
IFS= read -r value <"$1"
printf "%s\n" "$value"
' managed-candidate-marker "$marker") || marker_status=$?
    if [[ "$marker_status" != "0" ]] ||
        [[ "$marker_value" != "container-compose runtime candidate staging v1 $container_binary_sha256" ]]; then
        [[ "$marker_status" != "124" ]] || return "$marker_status"
        printf 'managed Container runtime candidate has an invalid recovery marker: %s\n' \
            "$source_package_root" >&2
        exit 2
    fi
    local package_sha256
    package_sha256=$(fingerprint_runtime_package \
        "$deadline" "$source_package_root") || return "$?"
    if [[ "$package_sha256" != "$runtime_managed_package_sha256" ]]; then
        printf 'managed Container runtime package fingerprint mismatch (expected %s, got %s)\n' \
            "$runtime_managed_package_sha256" "$package_sha256" >&2
        exit 2
    fi
    runtime_candidate_is_managed_staging_package=true
}

# Copy a source-built packaged runtime onto the local system volume before any
# launchd plist refers to it. Installed system candidates and candidates
# already staged under /tmp are left in place.
stage_runtime_candidate_if_needed() {
    local deadline="$1"
    runtime_candidate_requires_staging || return 0

    local source_bin_directory="${container_binary%/*}"
    local source_package_root="${source_bin_directory%/*}"
    if [[ "$runtime_candidate_is_complete_package" != true ]]; then
        printf 'privacy-safe staging requires a packaged Container bin/ and libexec/container/ layout: %s\n' \
            "$container_binary" >&2
        exit 2
    fi
    local source_package_root_digest
    source_package_root_digest=$(LC_ALL=C printf '%s' "$source_package_root" \
        | shasum -a 256 | awk '{print substr($1, 1, 16)}')
    runtime_candidate_staging_root="$runtime_local_user_root/candidate-$source_package_root_digest"
    acquire_runtime_candidate_staging_lock "$deadline" || return "$?"
    local source_package_sha256_before
    source_package_sha256_before=$(fingerprint_runtime_package \
        "$deadline" "$source_package_root") || return "$?"
    local marker="$runtime_candidate_staging_root/.container-compose-runtime-candidate-staging"
    local existing_marker_value=
    if [[ -e "$runtime_candidate_staging_root" ]]; then
        if [[ -L "$runtime_candidate_staging_root" ]] || [[ ! -d "$runtime_candidate_staging_root" ]]; then
            printf 'refusing to use an indirect local Container candidate: %s\n' \
                "$runtime_candidate_staging_root" >&2
            exit 2
        fi
        validate_private_runtime_directory \
            "$runtime_candidate_staging_root" 'local Container candidate' || exit "$?"
        if [[ -L "$marker" ]] || [[ -e "$marker" && ! -f "$marker" ]]; then
            printf 'refusing to use an indirect local Container candidate marker: %s\n' \
                "$marker" >&2
            exit 2
        fi
        if [[ -f "$marker" ]]; then
            IFS= read -r existing_marker_value <"$marker" || true
        fi
        if ! [[ "$existing_marker_value" =~ ^container-compose\ runtime\ candidate\ staging\ v1\ [0-9a-f]{64}$ ]]; then
            printf 'refusing to replace an unmarked local Container candidate: %s\n' \
                "$runtime_candidate_staging_root" >&2
            exit 2
        fi
        local existing_package_sha256=
        local existing_package_status=0
        if [[ "$existing_marker_value" == "container-compose runtime candidate staging v1 $container_binary_sha256" ]]; then
            existing_package_sha256=$(fingerprint_runtime_package \
                "$deadline" "$runtime_candidate_staging_root") || \
                existing_package_status=$?
            [[ "$existing_package_status" != "124" ]] || return "$existing_package_status"
            if [[ "$existing_package_status" != "0" ]]; then
                existing_package_sha256=
            fi
        fi
        if [[ -n "$existing_package_sha256" &&
            "$existing_package_sha256" == "$source_package_sha256_before" ]]; then
            validate_runtime_candidate_signatures \
                "$deadline" "$runtime_candidate_staging_root"
            select_staged_runtime_candidate "$existing_package_sha256"
            printf 'Reusing unchanged staged Container runtime candidate: %s\n' \
                "$container_binary"
            return 0
        fi
        if pgrep -f -- "$runtime_candidate_staging_root/" >/dev/null 2>&1; then
            printf 'refusing to replace a local Container candidate while it is running: %s\n' \
                "$runtime_candidate_staging_root" >&2
            exit 2
        fi
        runtime_candidate_staging_cleanup_allowed=true
        run_runtime_start_command "$deadline" find \
            "$runtime_candidate_staging_root" -mindepth 1 -maxdepth 1 \
            ! -name '.container-compose-runtime-candidate-staging' \
            -exec rm -rf {} +
    else
        runtime_candidate_staging_cleanup_allowed=true
        runtime_candidate_staging_created=true
        run_runtime_start_command "$deadline" mkdir -m 0700 \
            "$runtime_candidate_staging_root"
    fi
    run_runtime_start_command "$deadline" chmod 0700 \
        "$runtime_candidate_staging_root"
    if [[ "$runtime_candidate_staging_created" == true ]]; then
        write_runtime_start_file_atomic "$deadline" "$marker" \
            "container-compose runtime candidate staging v1 $container_binary_sha256"$'\n'
    fi
    run_runtime_start_command "$deadline" mkdir -p \
        "$runtime_candidate_staging_root/bin" "$runtime_candidate_staging_root/libexec"
    run_runtime_start_command "$deadline" /bin/cp -p \
        "$source_package_root/bin/container" \
        "$source_package_root/bin/container-apiserver" \
        "$source_package_root/bin/container-engine" \
        "$runtime_candidate_staging_root/bin/"
    run_runtime_start_command "$deadline" /bin/cp -a \
        "$source_package_root/libexec/container" \
        "$runtime_candidate_staging_root/libexec/container"
    local staged_symlink
    staged_symlink=$(run_runtime_start_command "$deadline" find \
        "$runtime_candidate_staging_root" -type l -print -quit) || return "$?"
    if [[ -n "$staged_symlink" ]]; then
        printf 'privacy-safe Container staging does not permit symlinks: %s\n' \
            "$staged_symlink" >&2
        exit 2
    fi

    local staged_digest_output
    local staged_container_sha256
    staged_digest_output=$(run_runtime_start_command "$deadline" \
        /usr/bin/shasum -a 256 "$runtime_candidate_staging_root/bin/container") || \
        return "$?"
    read -r staged_container_sha256 _ <<<"$staged_digest_output"
    if [[ "$staged_container_sha256" != "$container_binary_sha256" ]]; then
        printf 'staged Container runtime CLI changed during copy (expected %s, got %s)\n' \
            "$container_binary_sha256" "${staged_container_sha256:-invalid}" >&2
        exit 2
    fi
    local staged_package_sha256
    local source_package_sha256_after
    staged_package_sha256=$(fingerprint_runtime_package \
        "$deadline" "$runtime_candidate_staging_root") || return "$?"
    source_package_sha256_after=$(fingerprint_runtime_package \
        "$deadline" "$source_package_root") || return "$?"
    if [[ "$staged_package_sha256" != "$source_package_sha256_before" ]] ||
        [[ "$source_package_sha256_after" != "$source_package_sha256_before" ]]; then
        printf 'complete Container runtime package changed during staging (expected %s, staged %s, source %s)\n' \
            "$source_package_sha256_before" "$staged_package_sha256" \
            "$source_package_sha256_after" >&2
        exit 2
    fi
    validate_runtime_candidate_signatures \
        "$deadline" "$runtime_candidate_staging_root"
    write_runtime_start_file_atomic "$deadline" "$marker" \
        "container-compose runtime candidate staging v1 $container_binary_sha256"$'\n'

    select_staged_runtime_candidate "$staged_package_sha256"
    printf 'Staged Container runtime candidate at its persistent local path: %s\n' \
        "$container_binary"
}

cleanup_runtime_candidate_staging() {
    if [[ "$runtime_candidate_staging_cleanup_allowed" != true ]]; then
        release_runtime_candidate_staging_lock
        return 0
    fi
    [[ -n "$runtime_candidate_staging_root" ]] || return 0
    if [[ "$runtime_candidate_staging_complete" == true ]]; then
        release_runtime_candidate_staging_lock
        return 0
    fi
    case "$runtime_candidate_staging_root" in
        "$runtime_local_user_root"/candidate-[0-9a-f]*) ;;
        *)
            printf 'refusing to clear unexpected runtime candidate staging root: %s\n' \
                "$runtime_candidate_staging_root" >&2
            release_runtime_candidate_staging_lock
            return 1
            ;;
    esac
    if ! validate_private_runtime_directory \
        "$runtime_candidate_staging_root" 'local Container candidate'; then
        release_runtime_candidate_staging_lock
        return 1
    fi
    local marker="$runtime_candidate_staging_root/.container-compose-runtime-candidate-staging"
    local marker_value=
    if [[ -f "$marker" ]]; then
        IFS= read -r marker_value <"$marker" || true
    fi
    if [[ "$runtime_candidate_staging_created" != true ]] &&
        [[ "$marker_value" =~ ^container-compose\ runtime\ candidate\ staging\ v1\ [0-9a-f]{64}$ ]] &&
        [[ "$marker_value" != "container-compose runtime candidate staging v1 $container_binary_sha256" ]]; then
        printf 'preserving recoverable interrupted Container candidate staging root: %s\n' \
            "$runtime_candidate_staging_root" >&2
        release_runtime_candidate_staging_lock
        return 0
    fi
    if [[ "$runtime_candidate_staging_created" != true ]] &&
        [[ "$marker_value" != "container-compose runtime candidate staging v1 $container_binary_sha256" ]]; then
        printf 'refusing to clear unmarked runtime candidate staging root: %s\n' \
            "$runtime_candidate_staging_root" >&2
        release_runtime_candidate_staging_lock
        return 1
    fi
    find "$runtime_candidate_staging_root" -depth -delete 2>/dev/null || true
    runtime_candidate_staging_root=
    release_runtime_candidate_staging_lock
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
        --seconds "$remaining_seconds" --grace-seconds 0 -- "$@" 8>&-
}

# Create short-lived startup evidence on trusted local storage while charging
# even the directory creation to the one complete runtime-start deadline.  An
# inherited TMPDIR can name removable, privacy-controlled, or stalled storage
# and therefore cannot participate in runtime readiness.
create_runtime_start_state_root() {
    local deadline="$1"
    local prefix="$2"
    local trusted_temporary_root=/private/tmp

    case "$prefix" in
        container-compose-runtime-start | container-compose-runtime-managed-start) ;;
        *)
            printf 'refusing unexpected runtime-start state prefix: %s\n' "$prefix" >&2
            return 2
            ;;
    esac
    if [[ ! -d "$trusted_temporary_root" || ! -w "$trusted_temporary_root" ]]; then
        trusted_temporary_root=/tmp
    fi
    runtime_start_state_root=$(run_runtime_start_command "$deadline" \
        mktemp -d "$trusted_temporary_root/$prefix.XXXXXX") || return "$?"
}

cleanup_runtime_start_state_root() {
    [[ -n "$runtime_start_state_root" ]] || return 0
    case "$runtime_start_state_root" in
        /private/tmp/container-compose-runtime-start.*|/private/tmp/container-compose-runtime-managed-start.*|/tmp/container-compose-runtime-start.*|/tmp/container-compose-runtime-managed-start.*) ;;
        *)
            printf 'refusing to clear unexpected runtime-start state root: %s\n' \
                "$runtime_start_state_root" >&2
            return 1
            ;;
    esac
    find "$runtime_start_state_root" -depth -delete 2>/dev/null || true
    runtime_start_state_root=
}

# Check a caller-controlled filesystem input without letting its mount outlive
# the complete startup deadline.
runtime_start_regular_file_status() {
    local deadline="$1"
    local path="$2"

    run_runtime_start_command "$deadline" /bin/test -f "$path"
}

# Read an optional marker while keeping its type checks and contents inside
# the complete startup deadline. Status 1 means absent and status 2 means an
# indirect or non-regular marker.
read_optional_runtime_start_marker() {
    local deadline="$1"
    local path="$2"

    # shellcheck disable=SC2016 # Expand $1 in the bounded child shell.
    run_runtime_start_command "$deadline" /bin/bash -c '
if [[ -L "$1" ]]; then
    exit 2
fi
if [[ ! -e "$1" ]]; then
    exit 1
fi
if [[ ! -f "$1" ]]; then
    exit 2
fi
IFS= read -r value <"$1" || true
printf "%s" "$value"
' runtime-marker "$path"
}

# Check whether a caller-controlled path exists inside the complete startup deadline.
runtime_start_path_exists_status() {
    local deadline="$1"
    local path="$2"

    run_runtime_start_command "$deadline" /bin/test -e "$path"
}

# Reject an existing runtime path without inspecting its filesystem in the owner shell.
reject_runtime_start_existing_path() {
    local deadline="$1"
    local path="$2"
    local error_message="$3"
    local reported_path="$4"
    local status=0

    runtime_start_path_exists_status "$deadline" "$path" || status=$?
    [[ "$status" != "124" ]] || return "$status"
    if [[ "$status" == "0" ]]; then
        printf '%s: %s\n' "$error_message" "$reported_path" >&2
        exit 2
    fi
}

# Write one runtime-owned file without letting its backing filesystem outlive
# the complete startup deadline.
write_runtime_start_file() {
    local deadline="$1"
    local path="$2"
    local content="$3"

    # shellcheck disable=SC2016 # Expand positional values in the bounded child shell.
    run_runtime_start_command "$deadline" \
        /bin/bash -c 'printf "%s" "$2" >"$1"' runtime-file "$path" "$content"
}

# Replace one marker without exposing a truncated value. If the bounded child
# is interrupted, an existing recovery marker remains authoritative and the
# next staging attempt can remove the abandoned `.next` file and continue.
write_runtime_start_file_atomic() {
    local deadline="$1"
    local path="$2"
    local content="$3"

    # shellcheck disable=SC2016 # Expand positional values in the bounded child shell.
    run_runtime_start_command "$deadline" /bin/bash -c '
set -euo pipefail
temporary_path="$1.next.$$"
trap '\''rm -f "$temporary_path"'\'' EXIT
umask 077
printf "%s" "$2" >"$temporary_path"
mv -f "$temporary_path" "$1"
trap - EXIT
' runtime-atomic-file "$path" "$content"
}

# Require one caller-controlled regular file without allowing an unresponsive
# mount to outlive the complete startup deadline.
require_runtime_start_regular_file() {
    local deadline="$1"
    local path="$2"
    local error_message="$3"
    local status=0

    runtime_start_regular_file_status "$deadline" "$path" || status=$?
    [[ "$status" != "124" ]] || return "$status"
    if [[ "$status" != "0" ]]; then
        printf '%s: %s\n' "$error_message" "$path" >&2
        exit 2
    fi
}

# Resolve and fingerprint the caller-selected runtime CLI within the same
# deadline as every other startup input. A candidate on an unresponsive mount
# must not block the release gate before its liveness owner starts.
resolve_container_binary() {
    local deadline="$1"
    local binary_directory_input
    local binary_name
    local digest_output
    local status=0

    if [[ "$container_binary" != */* ]]; then
        # shellcheck disable=SC2016 # Expand $1 in the bounded child shell.
        container_binary=$(run_runtime_start_command "$deadline" \
            /bin/bash -c 'command -v "$1"' container-command \
            "$container_binary") || status=$?
        if [[ "$status" != "0" ]]; then
            [[ "$status" != "124" ]] || return "$status"
            printf 'candidate container command was not found on PATH: %s\n' \
                "$requested_container_binary" >&2
            exit 2
        fi
    fi

    status=0
    run_runtime_start_command "$deadline" /bin/test -x "$container_binary" || \
        status=$?
    if [[ "$status" != "0" ]]; then
        [[ "$status" != "124" ]] || return "$status"
        printf 'candidate container binary is not executable: %s\n' "$container_binary" >&2
        exit 2
    fi

    binary_name=${container_binary##*/}
    binary_directory_input=${container_binary%/*}
    [[ -n "$binary_directory_input" ]] || binary_directory_input=/
    status=0
    # shellcheck disable=SC2016 # Expand $1 in the bounded child shell.
    container_binary_directory=$(run_runtime_start_command "$deadline" \
        /bin/bash -c 'cd "$1" && pwd -P' container-binary-directory \
        "$binary_directory_input") || status=$?
    if [[ "$status" != "0" ]]; then
        [[ "$status" != "124" ]] || return "$status"
        printf 'candidate container binary directory is not accessible: %s\n' \
            "$binary_directory_input" >&2
        exit 2
    fi
    container_binary="$container_binary_directory/$binary_name"

    status=0
    container_binary_localization_path=$(run_runtime_start_command "$deadline" \
        python3 -c 'import os, sys; print(os.path.realpath(sys.argv[1]))' \
        "$container_binary") || status=$?
    if [[ "$status" != "0" ]]; then
        [[ "$status" != "124" ]] || return "$status"
        printf 'could not resolve candidate Container binary: %s\n' \
            "$container_binary" >&2
        exit 2
    fi

    status=0
    digest_output=$(run_runtime_start_command "$deadline" \
        /usr/bin/shasum -a 256 "$container_binary") || status=$?
    if [[ "$status" != "0" ]]; then
        [[ "$status" != "124" ]] || return "$status"
        printf 'could not fingerprint candidate container binary: %s\n' \
            "$container_binary" >&2
        exit 2
    fi
    read -r container_binary_sha256 _ <<<"$digest_output"
    if ! [[ "$container_binary_sha256" =~ ^[0-9a-f]{64}$ ]]; then
        printf 'candidate container binary produced an invalid SHA-256 digest: %s\n' \
            "$container_binary" >&2
        exit 2
    fi
    if [[ -n "${CONTAINER_RUNTIME_CLI_SHA256:-}" &&
        "${CONTAINER_RUNTIME_CLI_SHA256}" != "$container_binary_sha256" ]]; then
        printf 'candidate container binary digest mismatch (expected %s, got %s): %s\n' \
            "${CONTAINER_RUNTIME_CLI_SHA256}" "$container_binary_sha256" "$container_binary" >&2
        exit 2
    fi

    # Every nested Makefile and helper must resolve the same candidate CLI that
    # owns the isolated runtime. Otherwise a host-installed `container` earlier
    # in PATH can silently target the default service namespace mid-validation.
    export PATH="$container_binary_directory${PATH:+:$PATH}"
    export CONTAINER_RUNTIME_CLI="$container_binary"
    export CONTAINER_BIN="$container_binary"
    export CONTAINER_COMPOSE_CONTAINER="$container_binary"
    export CONTAINER_RUNTIME_CLI_SHA256="$container_binary_sha256"
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
    local start_status

    if [[ -z "$sequence_deadline" ]]; then
        sequence_deadline=$(runtime_start_deadline)
    fi
    for attempt in 1 2; do
        create_runtime_start_state_root \
            "$sequence_deadline" container-compose-runtime-start || return "$?"
        start_completed="$runtime_start_state_root/completed"
        start_log="$runtime_start_state_root/start.log"
        if ! remaining_seconds=$(runtime_start_remaining_seconds "$sequence_deadline"); then
            cleanup_runtime_start_state_root
            return 124
        fi
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
            cleanup_runtime_start_state_root
            return
        else
            start_status=$?
            if [[ ! -f "$start_completed" ]] &&
                ! is_transient_xpc_start_failure "$start_log"; then
                cleanup_runtime_start_state_root
                return "$start_status"
            fi
        fi
        cleanup_runtime_start_state_root

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

    printf 'Managed Container API is not ready; re-establishing the owner runtime...\n' >&2
    create_runtime_start_state_root \
        "$sequence_deadline" container-compose-runtime-managed-start || return "$?"
    start_log="$runtime_start_state_root/start.log"
    remaining_seconds=$(runtime_start_remaining_seconds "$sequence_deadline") || {
        cleanup_runtime_start_state_root
        return 124
    }
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
        cleanup_runtime_start_state_root
        return "$start_status"
    fi
    cleanup_runtime_start_state_root
}

prepare_runtime_root() {
    local deadline="$1"

    if [[ "$runtime_app_root_localized" == true ]]; then
        if [[ ! -e "$runtime_app_root" && ! -L "$runtime_app_root" ]]; then
            run_runtime_start_command "$deadline" mkdir -m 0700 \
                "$runtime_app_root" || return "$?"
        fi
        validate_private_runtime_directory \
            "$runtime_app_root" 'localized Container runtime state root' || exit "$?"
    else
        run_runtime_start_command "$deadline" mkdir -p "$runtime_app_root"
    fi
    local marker_path="$runtime_app_root/$runtime_root_marker"
    local marker_value=
    local marker_status=0
    marker_value=$(read_optional_runtime_start_marker \
        "$deadline" "$marker_path") || marker_status=$?
    case "$marker_status" in
        0) ;;
        1) ;;
        2)
            printf 'refusing to use an indirect container runtime root marker: %s\n' \
                "$marker_path" >&2
            exit 2
            ;;
        124) return "$marker_status" ;;
        *) return "$marker_status" ;;
    esac
    if [[ "$marker_status" == "0" ]]; then
        if [[ "$marker_value" != "$runtime_root_marker_value" ]]; then
            printf 'refusing to clear container runtime root with an invalid marker: %s\n' "$runtime_app_root" >&2
            exit 2
        fi
    else
        local existing_entry
        existing_entry=$(run_runtime_start_command "$deadline" \
            find "$runtime_app_root" -mindepth 1 -maxdepth 1 -print -quit) || return "$?"
        if [[ -n "$existing_entry" ]]; then
            printf 'refusing to clear unmarked container runtime root: %s\n' "$runtime_app_root" >&2
            exit 2
        fi
        write_runtime_start_file "$deadline" "$marker_path" \
            "$runtime_root_marker_value"$'\n'
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

cleanup_runtime_temporary_state() {
    cleanup_runtime_start_state_root || true
    cleanup_runtime_service_inputs || true
    cleanup_runtime_candidate_staging || true
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
    local config_content=
    if [[ -n "$runtime_builder_image" ]]; then
        printf -v config_content '[build]\nimage = "%s"\n\n' "$runtime_builder_image"
    fi
    printf -v config_content '%s[vminit]\nimage = "%s"\n' \
        "$config_content" "$matched_init_image"
    write_runtime_start_file "$deadline" "$container_config_dir/config.toml" \
        "$config_content"

    local runtime_config_dir="$runtime_app_root/config"
    local runtime_config_path="$runtime_config_dir/config.toml"
    local runtime_config_temp
    run_runtime_start_command "$deadline" mkdir -p "$runtime_config_dir"
    runtime_config_temp=$(run_runtime_start_command "$deadline" \
        mktemp "$runtime_config_dir/.config.toml.XXXXXX") || return "$?"
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
    local config_content
    printf -v config_content '[build]\nimage = "%s"\n' "$runtime_builder_image"
    write_runtime_start_file "$deadline" "$container_config_dir/config.toml" \
        "$config_content"
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
    require_runtime_start_regular_file "$deadline" "$runtime_builder_image_tar" \
        'container runtime builder image archive does not exist'

    printf 'Installing matched container runtime builder image...\n'
    run_runtime_start_command "$deadline" \
        "$container_binary" image load -i "$runtime_builder_image_tar"
}

install_runtime_bootstrap_image() {
    local deadline="$1"

    [[ -n "$runtime_bootstrap_image_tar" ]] || return 0
    [[ "$initial_start_init_image_archive" != "$runtime_bootstrap_image_tar" ]] || return 0
    require_runtime_start_regular_file "$deadline" "$runtime_bootstrap_image_tar" \
        'container runtime bootstrap image archive does not exist'

    printf 'Installing container runtime bootstrap image...\n'
    run_runtime_start_command "$deadline" \
        "$container_binary" image load -i "$runtime_bootstrap_image_tar"
}

cleanup() {
    local status=$?
    trap - EXIT
    trap '' HUP INT QUIT TERM
    printf 'Stopping matched container runtime...\n'
    stop_runtime || true
    release_container_runtime_lock
    cleanup_runtime_temporary_state
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

    require_runtime_start_regular_file "$deadline" "$runtime_init_block_repo/Makefile" \
        'container runtime init-block repo does not contain a Makefile'

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

validate_runtime_start_deadline_seconds
validate_runtime_localization_modes
assert_no_competing_container_launch_agents
runtime_local_user_root="$runtime_local_execution_root/container-compose-runtime-$(id -u)"
select_managed_runtime_candidate
runtime_start_sequence_deadline=$(runtime_start_deadline)
trap cleanup_runtime_temporary_state EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 131' QUIT
trap 'exit 143' TERM
resolve_container_binary "$runtime_start_sequence_deadline"
validate_packaged_runtime_candidate_signatures "$runtime_start_sequence_deadline"
validate_requested_runtime_app_root "$runtime_start_sequence_deadline"
if runtime_requires_local_user_root; then
    prepare_local_user_root "$runtime_start_sequence_deadline"
fi
localize_runtime_app_root
stage_runtime_candidate_if_needed "$runtime_start_sequence_deadline"
if [[ -n "$runtime_anonymous_registry_hosts" ]]; then
    export CONTAINER_REGISTRY_ANONYMOUS_HOSTS="$runtime_anonymous_registry_hosts"
else
    unset CONTAINER_REGISTRY_ANONYMOUS_HOSTS
fi
validate_runtime_inputs "$runtime_start_sequence_deadline"
validate_containerization_init_source "$runtime_start_sequence_deadline"
resolve_matched_init_image
validate_runtime_init_image_archive "$runtime_start_sequence_deadline"
configure_runtime_namespace
verify_runtime_namespace_support "$runtime_start_sequence_deadline"

if [[ "${CONTAINER_RUNTIME_MANAGED:-0}" == "1" ]]; then
    ensure_managed_runtime_ready "$runtime_start_sequence_deadline"
    # The parent retains the staging lock; commands must not inherit its fd.
    run_with_managed_runtime_candidate "$@"
    exit
fi

stage_runtime_service_inputs "$runtime_start_sequence_deadline"
runtime_lock_timeout=$(runtime_start_lock_timeout_seconds \
    "$runtime_start_sequence_deadline")
CONTAINER_RUNTIME_LOCK_TIMEOUT_SECONDS="$runtime_lock_timeout" \
    acquire_container_runtime_lock 8>&-
trap cleanup EXIT

printf 'Stopping stale container services...\n'
stop_runtime "$runtime_start_sequence_deadline"
run_runtime_start_command "$runtime_start_sequence_deadline" sleep 3
prepare_runtime_root "$runtime_start_sequence_deadline"
stage_containerization_init_source "$runtime_start_sequence_deadline"
resolve_initial_start_init_image_archive
prepare_runtime_config_home "$runtime_start_sequence_deadline"
configure_runtime_builder_image "$runtime_start_sequence_deadline"
if has_matched_init_image_source && [[ -n "$initial_start_init_image_archive" ]]; then
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
if has_matched_init_image_source && [[ -z "$initial_start_init_image_archive" ]]; then
    configure_matched_init_image "$runtime_start_sequence_deadline"
fi
if has_matched_init_image_source && [[ -n "$runtime_config_home" ]]; then
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
# Keep the candidate immutable for this invocation without leaking the lock to
# the caller's command or any long-lived descendant it may create.
run_with_managed_runtime_candidate "$@"
