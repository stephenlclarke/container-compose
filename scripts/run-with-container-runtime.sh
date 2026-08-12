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

container_binary=$1
shift
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
    [[ -n "$runtime_init_image_archive" ]] || return 0

    local required_references="$matched_init_image"
    if [[ -n "${CONTAINER_RUNTIME_REQUIRED_INIT_IMAGE_REFERENCES:-}" ]]; then
        required_references+=" ${CONTAINER_RUNTIME_REQUIRED_INIT_IMAGE_REFERENCES}"
    fi

    python3 - "$runtime_init_image_archive" "$required_references" <<'PY'
import json
from pathlib import Path
import sys
import tarfile

archive = Path(sys.argv[1])
required = set(sys.argv[2].split())
try:
    with tarfile.open(archive, "r:*") as bundle:
        member = next(
            (item for item in bundle.getmembers() if item.name.lstrip("./") == "index.json"),
            None,
        )
        if member is None:
            raise ValueError("index.json is missing")
        stream = bundle.extractfile(member)
        if stream is None:
            raise ValueError("index.json is unreadable")
        index = json.load(stream)
except (OSError, tarfile.TarError, ValueError, json.JSONDecodeError) as error:
    raise SystemExit(f"container runtime init-image archive is not a readable OCI archive: {archive} ({error})")

available = {
    manifest.get("annotations", {}).get("org.opencontainers.image.ref.name"): manifest.get("digest")
    for manifest in index.get("manifests", [])
}
missing = sorted(reference for reference in required if reference not in available)
if missing:
    raise SystemExit(
        "container runtime init-image archive is missing required reference(s): "
        + ", ".join(missing)
    )
digests = {available[reference] for reference in required}
if len(digests) != 1 or None in digests:
    raise SystemExit(
        "container runtime init-image archive required references do not resolve to one digest: "
        + ", ".join(f"{reference}={available[reference]}" for reference in sorted(required))
    )
PY
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
    if [[ -n "$containerization_init_source_path" && -z "$runtime_init_block_repo" ]]; then
        printf 'CONTAINERIZATION_INIT_SOURCE_PATH requires CONTAINER_RUNTIME_INIT_BLOCK_REPO\n' >&2
        exit 2
    fi
}

# Resolve a clean, exact source checkout before any candidate service mutation.
validate_containerization_init_source() {
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
    if ! containerization_init_source_root=$(git -C "$requested_source_path" rev-parse --show-toplevel 2>/dev/null); then
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
    if [[ -n "$(git -C "$containerization_init_source_root" status --porcelain --untracked-files=all)" ]]; then
        printf 'containerization init source checkout must be clean before staging: %s\n' \
            "$containerization_init_source_root" >&2
        exit 2
    fi
    if ! containerization_init_source_head=$(git -C "$containerization_init_source_root" rev-parse --verify 'HEAD^{commit}' 2>/dev/null); then
        printf 'containerization init source checkout does not resolve HEAD to a commit: %s\n' \
            "$containerization_init_source_root" >&2
        exit 2
    fi
}

# Clone the validated source input below the disposable candidate root so the
# guest sees only tracked files and a self-contained Git metadata directory.
stage_containerization_init_source() {
    [[ -n "$containerization_init_source_root" ]] || return 0

    local source_inputs_root="$runtime_app_root/source-inputs"
    local staged_source_path="$source_inputs_root/containerization"
    if [[ -e "$staged_source_path" ]]; then
        printf 'refusing to overwrite an existing staged containerization source: %s\n' \
            "$staged_source_path" >&2
        exit 2
    fi

    mkdir -p "$source_inputs_root"
    if ! git clone --quiet --no-local --no-checkout --no-tags \
        "$containerization_init_source_root" "$staged_source_path"; then
        printf 'failed to clone the exact containerization init source into: %s\n' \
            "$staged_source_path" >&2
        exit 2
    fi
    if ! git -C "$staged_source_path" checkout --detach --quiet "$containerization_init_source_head"; then
        printf 'failed to check out the pinned containerization init source commit: %s\n' \
            "$containerization_init_source_head" >&2
        exit 2
    fi

    local staged_source_head
    staged_source_head=$(git -C "$staged_source_path" rev-parse HEAD)
    if [[ "$staged_source_head" != "$containerization_init_source_head" ]]; then
        printf 'staged containerization init source commit mismatch (expected %s, got %s)\n' \
            "$containerization_init_source_head" "$staged_source_head" >&2
        exit 2
    fi
    if [[ -n "$(git -C "$staged_source_path" status --porcelain --untracked-files=all)" ]]; then
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
    mkdir -p "$containerization_init_build_scratch_root"

    local fingerprints_root="$runtime_app_root/fingerprints"
    mkdir -p "$fingerprints_root"
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
    "$container_binary" system stop >/dev/null 2>&1 || true
}

# Fail before any service mutation unless this binary exposes this candidate's
# namespace-derived Docker socket through the read-only status command.
verify_runtime_namespace_support() {
    local status_output
    local reported_socket

    status_output=$("$container_binary" system status --format json 2>/dev/null) || true
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

# Start Container and verify an API round-trip, recovering once from transient XPC startup failure.
start_runtime() {
    local attempt
    local start_log
    local start_status

    for attempt in 1 2; do
        start_log=$(mktemp "${TMPDIR:-/tmp}/container-compose-runtime-start.XXXXXX")
        if "$container_binary" "${start_arguments[@]}" 2>&1 | tee "$start_log"; then
            if "$container_binary" list --all --format json >/dev/null; then
                rm -f "$start_log"
                return
            else
                start_status=$?
            fi
        else
            start_status=$?
            if ! is_transient_xpc_start_failure "$start_log"; then
                rm -f "$start_log"
                return "$start_status"
            fi
        fi
        rm -f "$start_log"

        if [[ "$attempt" == "2" ]]; then
            return "$start_status"
        fi
        printf 'Container API was not ready; restarting the matched runtime once...\n' >&2
        stop_runtime
        sleep 3
    done
}

prepare_runtime_root() {
    mkdir -p "$runtime_app_root"
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
    local trusted_temporary_root=/private/tmp
    if [[ ! -d "$trusted_temporary_root" ]]; then
        trusted_temporary_root=/tmp
    fi
    runtime_service_inputs_root=$(mktemp -d \
        "$trusted_temporary_root/container-compose-service-inputs.XXXXXX")

    stage_runtime_service_archive runtime_builder_image_tar builder-image.oci.tar
    stage_runtime_service_archive runtime_bootstrap_image_tar bootstrap-image.oci.tar
    stage_runtime_service_archive matched_init_image_tar matched-init-image.oci.tar
    stage_runtime_service_archive runtime_init_image_archive retained-init-image.oci.tar
}

stage_runtime_service_archive() {
    local variable_name="$1"
    local destination_name="$2"
    local source_path="${!variable_name}"
    [[ -n "$source_path" ]] || return 0

    local destination_path="$runtime_service_inputs_root/$destination_name"
    local temporary_path="$destination_path.partial"
    if ! /usr/bin/install -m 0600 "$source_path" "$temporary_path"; then
        rm -f "$temporary_path"
        printf 'failed to stage container runtime service archive: %s\n' "$source_path" >&2
        exit 2
    fi
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
    has_matched_init_image_source || return 0
    [[ -n "$runtime_app_root" ]] || return 0

    runtime_config_home="$runtime_app_root/xdg-config"
    mkdir -p "$runtime_config_home"
    export XDG_CONFIG_HOME="$runtime_config_home"
}

configure_matched_init_image() {
    [[ -n "$runtime_config_home" ]] || return 0

    local container_config_dir="$runtime_config_home/container"
    mkdir -p "$container_config_dir"
    {
        if [[ -n "$runtime_builder_image" ]]; then
            printf '[build]\nimage = "%s"\n\n' "$runtime_builder_image"
        fi
        printf '[vminit]\nimage = "%s"\n' "$matched_init_image"
    } >"$container_config_dir/config.toml"

    local runtime_config_dir="$runtime_app_root/config"
    local runtime_config_path="$runtime_config_dir/config.toml"
    local runtime_config_temp
    mkdir -p "$runtime_config_dir"
    runtime_config_temp=$(mktemp "$runtime_config_dir/.config.toml.XXXXXX")
    cp "$container_config_dir/config.toml" "$runtime_config_temp"
    chmod 0444 "$runtime_config_temp"
    mv -f "$runtime_config_temp" "$runtime_config_path"

    export CONTAINER_COMPOSE_INIT_IMAGE="$matched_init_image"
}

configure_runtime_builder_image() {
    [[ -n "$runtime_config_home" ]] || return 0
    if [[ -z "$runtime_builder_image" ]]; then
        return 0
    fi

    local container_config_dir="$runtime_config_home/container"
    mkdir -p "$container_config_dir"
    printf '[build]\nimage = "%s"\n' "$runtime_builder_image" \
        >"$container_config_dir/config.toml"
}

install_runtime_builder_image() {
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
    "$container_binary" image load -i "$runtime_builder_image_tar"
}

install_runtime_bootstrap_image() {
    [[ -n "$runtime_bootstrap_image_tar" ]] || return 0
    [[ "$initial_start_init_image_archive" != "$runtime_bootstrap_image_tar" ]] || return 0
    if [[ ! -f "$runtime_bootstrap_image_tar" ]]; then
        printf 'container runtime bootstrap image archive does not exist: %s\n' "$runtime_bootstrap_image_tar" >&2
        exit 2
    fi

    printf 'Installing container runtime bootstrap image...\n'
    "$container_binary" image load -i "$runtime_bootstrap_image_tar"
}

cleanup() {
    local status=$?
    trap - EXIT
    printf 'Stopping matched container runtime...\n'
    stop_runtime || true
    release_container_runtime_lock
    cleanup_runtime_service_inputs || true
    exit "$status"
}

# Install a guest init image built from the same source lane as the host runtime.
install_matched_init_image() {
    # The startup command has already loaded and unpacked this archive before
    # its registry fallback. Do not load it a second time after startup.
    [[ "$initial_start_image_is_matched" == true ]] && return 0

    if [[ -n "$matched_init_image_tar" ]]; then
        printf 'Installing prebuilt matched container runtime init image...\n'
        "$container_binary" image load -i "$matched_init_image_tar"
        return 0
    fi

    if [[ -n "$runtime_init_image_archive" ]]; then
        printf 'Loading matched container runtime init image archive...\n'
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
    env "${init_env[@]}" make -C "$runtime_init_block_repo" \
        KERNEL_INSTALL=false init-block
}

validate_runtime_inputs
validate_containerization_init_source
resolve_matched_init_image
validate_runtime_init_image_archive
configure_runtime_namespace
verify_runtime_namespace_support

if [[ "${CONTAINER_RUNTIME_MANAGED:-0}" == "1" ]]; then
    "$@"
    exit
fi

trap cleanup_runtime_service_inputs EXIT
stage_runtime_service_inputs
acquire_container_runtime_lock
trap cleanup EXIT

printf 'Stopping stale container services...\n'
stop_runtime
sleep 3
prepare_runtime_root
stage_containerization_init_source
resolve_initial_start_init_image_archive
prepare_runtime_config_home
configure_runtime_builder_image
if [[ -n "$initial_start_init_image_archive" ]]; then
    configure_matched_init_image
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
start_runtime
install_runtime_builder_image
install_runtime_bootstrap_image
install_matched_init_image
if [[ -z "$initial_start_init_image_archive" ]]; then
    configure_matched_init_image
fi
if [[ -n "$runtime_config_home" ]]; then
    printf 'Restarting matched container runtime with the installed init image...\n'
    stop_runtime
    sleep 3
    start_arguments=(--debug system start --timeout 60 --enable-kernel-install)
    if [[ -n "$runtime_app_root" ]]; then
        start_arguments+=(--app-root "$runtime_app_root")
    fi
    start_runtime
fi

export CONTAINER_RUNTIME_MANAGED=1
"$@"
