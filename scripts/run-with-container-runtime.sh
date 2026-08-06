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
runtime_init_block_repo=${CONTAINER_RUNTIME_INIT_BLOCK_REPO:-}
runtime_init_image_archive=${CONTAINER_RUNTIME_INIT_IMAGE_ARCHIVE:-}
containerization_init_source_path=${CONTAINERIZATION_INIT_SOURCE_PATH:-}
matched_init_image=${CONTAINER_COMPOSE_INIT_IMAGE:-}
matched_init_image_tar=${CONTAINER_RUNTIME_INIT_IMAGE_TAR:-}
runtime_builder_image=${CONTAINER_RUNTIME_BUILDER_IMAGE:-}
runtime_builder_image_tar=${CONTAINER_RUNTIME_BUILDER_IMAGE_TAR:-}
runtime_bootstrap_image_tar=${CONTAINER_RUNTIME_BOOTSTRAP_IMAGE_TAR:-}
runtime_config_home=
initial_start_init_image_archive=
initial_start_image_is_matched=false
runtime_root_marker=.container-compose-runtime-root
runtime_root_marker_value='container-compose isolated runtime state v1'
provider_socket_path_limit=103

validate_runtime_inputs() {
    if [[ -n "$runtime_app_root" ]]; then
        local normalized_runtime_root=${runtime_app_root%/}
        if [[ -z "$normalized_runtime_root" ]]; then
            normalized_runtime_root=/
        fi
        local provider_socket_path
        if [[ "$normalized_runtime_root" == / ]]; then
            provider_socket_path=/engine-provider/provider.sock
        else
            provider_socket_path="$normalized_runtime_root/engine-provider/provider.sock"
        fi
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
}

# Report whether a source checkout or retained archive can provide the matched init image.
has_matched_init_image_source() {
    [[ -n "$runtime_init_block_repo" ||
        -n "$matched_init_image_tar" ||
        -n "$runtime_init_image_archive" ]]
}

stop_runtime() {
    "$container_binary" system stop >/dev/null 2>&1 || true
    if [[ -n "${CONTAINER_RUNTIME_STOP_HELPER:-}" && -x "$CONTAINER_RUNTIME_STOP_HELPER" ]]; then
        "$CONTAINER_RUNTIME_STOP_HELPER" >/dev/null
    fi
}

# Recognize only the bounded set of startup failures that are known to be
# transient while the per-user Container XPC service is registering.  Keep
# other start failures visible rather than turning the runtime wrapper into a
# general retry loop.
is_transient_xpc_start_failure() {
    local start_log="$1"

    grep -Eq \
        'XPC connection error: Connection (interrupted|invalid)|XPC timeout for request to com\.apple\.container\.apiserver/ping' \
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
    [[ -n "$runtime_app_root" ]] || return 0

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
acquire_container_runtime_lock
trap cleanup EXIT

printf 'Stopping stale container services...\n'
stop_runtime
sleep 3
prepare_runtime_root
resolve_matched_init_image
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

"$@"
