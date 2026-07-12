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
runtime_config_home=
runtime_root_marker=.container-compose-runtime-root
runtime_root_marker_value='container-compose isolated runtime state v1'

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

configure_matched_init_image() {
    [[ -n "$runtime_init_block_repo" ]] || return
    [[ -n "$runtime_app_root" ]] || return

    if [[ -z "$matched_init_image" ]]; then
        matched_init_image="vminit:container-compose"
    fi
    runtime_config_home="$runtime_app_root/xdg-config"
    local container_config_dir="$runtime_config_home/container"
    mkdir -p "$container_config_dir"
    cat >"$container_config_dir/config.toml" <<EOF
[vminit]
image = "$matched_init_image"
EOF
    export XDG_CONFIG_HOME="$runtime_config_home"
    export CONTAINER_COMPOSE_INIT_IMAGE="$matched_init_image"
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
    [[ -n "$runtime_init_block_repo" ]] || return

    if [[ ! -f "$runtime_init_block_repo/Makefile" ]]; then
        printf 'container runtime init-block repo does not contain a Makefile: %s\n' "$runtime_init_block_repo" >&2
        exit 2
    fi

    local init_env=()
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

trap cleanup EXIT

printf 'Stopping stale container services...\n'
stop_runtime
sleep 3
prepare_runtime_root
configure_matched_init_image

printf 'Starting matched container runtime...\n'
start_arguments=(--debug system start --timeout 60 --enable-kernel-install)
if [[ -n "$runtime_app_root" ]]; then
    start_arguments+=(--app-root "$runtime_app_root")
fi
"$container_binary" "${start_arguments[@]}"
install_matched_init_image

"$@"
