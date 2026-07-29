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

container_binary=$1
shift
runtime_app_root=${CONTAINER_RUNTIME_APP_ROOT:-}
runtime_init_block_repo=${CONTAINER_RUNTIME_INIT_BLOCK_REPO:-}
containerization_init_source_path=${CONTAINERIZATION_INIT_SOURCE_PATH:-}
matched_init_image=${CONTAINER_COMPOSE_INIT_IMAGE:-}
matched_init_image_tar=${CONTAINER_RUNTIME_INIT_IMAGE_TAR:-}
runtime_builder_image=${CONTAINER_RUNTIME_BUILDER_IMAGE:-}
runtime_builder_image_tar=${CONTAINER_RUNTIME_BUILDER_IMAGE_TAR:-}
runtime_bootstrap_image_tar=${CONTAINER_RUNTIME_BOOTSTRAP_IMAGE_TAR:-}
runtime_config_home=
runtime_root_marker=.container-compose-runtime-root
runtime_root_marker_value='container-compose isolated runtime state v1'

validate_runtime_inputs() {
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
    if [[ -n "$runtime_init_block_repo" && ! -f "$runtime_init_block_repo/Makefile" ]]; then
        printf 'container runtime init-block repo does not contain a Makefile: %s\n' "$runtime_init_block_repo" >&2
        exit 2
    fi
}

stop_runtime() {
    "$container_binary" system stop >/dev/null 2>&1 || true
    if [[ -n "${CONTAINER_RUNTIME_STOP_HELPER:-}" && -x "$CONTAINER_RUNTIME_STOP_HELPER" ]]; then
        "$CONTAINER_RUNTIME_STOP_HELPER" >/dev/null
    fi
}

prepare_runtime_root() {
    [[ -n "$runtime_app_root" ]] || return

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
    if [[ -z "$runtime_init_block_repo" && -z "$matched_init_image_tar" ]]; then
        return
    fi

    if [[ -z "$matched_init_image" ]]; then
        matched_init_image="vminit:container-compose"
    fi
}

prepare_runtime_config_home() {
    if [[ -z "$runtime_init_block_repo" && -z "$matched_init_image_tar" ]]; then
        return
    fi
    [[ -n "$runtime_app_root" ]] || return

    runtime_config_home="$runtime_app_root/xdg-config"
    mkdir -p "$runtime_config_home"
    export XDG_CONFIG_HOME="$runtime_config_home"
}

configure_matched_init_image() {
    [[ -n "$runtime_config_home" ]] || return

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
    [[ -n "$runtime_config_home" ]] || return
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
    if [[ -n "$matched_init_image_tar" ]]; then
        if [[ ! -f "$matched_init_image_tar" ]]; then
            printf 'container runtime init image archive does not exist: %s\n' "$matched_init_image_tar" >&2
            exit 2
        fi
        printf 'Installing prebuilt matched container runtime init image...\n'
        "$container_binary" image load -i "$matched_init_image_tar"
        return
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
    env "${init_env[@]}" make -C "$runtime_init_block_repo" init-block
}

validate_runtime_inputs
trap cleanup EXIT

printf 'Stopping stale container services...\n'
stop_runtime
sleep 3
prepare_runtime_root
resolve_matched_init_image
prepare_runtime_config_home
configure_runtime_builder_image

printf 'Starting matched container runtime...\n'
start_arguments=(--debug system start --timeout 60 --enable-kernel-install)
if [[ -n "$runtime_app_root" ]]; then
    start_arguments+=(--app-root "$runtime_app_root")
fi
"$container_binary" "${start_arguments[@]}"
install_runtime_builder_image
install_runtime_bootstrap_image
install_matched_init_image
configure_matched_init_image
if [[ -n "$runtime_config_home" ]]; then
    printf 'Restarting matched container runtime with the installed init image...\n'
    stop_runtime
    sleep 3
    "$container_binary" "${start_arguments[@]}"
fi

"$@"
