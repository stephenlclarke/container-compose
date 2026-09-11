#!/usr/bin/env bash
#===----------------------------------------------------------------------===#
# Copyright © 2026 container-compose project authors.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
# https://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#===----------------------------------------------------------------------===#

# Proves image-volume copy-up and exec using only stock Apple Container, the
# current devcontainer Engine, and the stock container-compose build.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$repo_root/Tools/ci/container-runtime-lock.sh"

container_bin="${CONTAINER_BIN:-/usr/local/bin/container}"
compose_bin="${COMPOSE_BIN:-$repo_root/.build/debug/compose}"
engine_bin="${DEVCONTAINER_ENGINE_BIN:-}"
helper_bin="${VOLUME_INITIALIZER_BIN:-$repo_root/Tools/compose-normalizer/compose-volume-initializer-linux-arm64}"
fixture="$repo_root/Tools/parity/fixtures/stock-engine-image-volume/compose.yaml"

for executable in "$container_bin" "$compose_bin" "$engine_bin" "$helper_bin"; do
    if [[ -z "$executable" || ! -x "$executable" ]]; then
        printf 'required executable is missing: %s\n' "${executable:-DEVCONTAINER_ENGINE_BIN}" >&2
        exit 2
    fi
done

acquire_container_runtime_lock
runtime_root="$(mktemp -d /private/tmp/container-compose-stock-engine.XXXXXX)"
socket="$runtime_root/engine.sock"
project="stock-engine-volume-${RANDOM}-${RANDOM}"
engine_pid=""
succeeded=0

cleanup() {
    CONTAINER_COMPOSE_ENGINE_SOCKET="$socket" \
        CONTAINER_COMPOSE_CONTAINER="$container_bin" \
        CONTAINER_COMPOSE_VOLUME_INITIALIZER="$helper_bin" \
        "$compose_bin" -p "$project" -f "$fixture" down --volumes >/dev/null 2>&1 || true
    if [[ -n "$engine_pid" ]]; then
        kill "$engine_pid" >/dev/null 2>&1 || true
        wait "$engine_pid" >/dev/null 2>&1 || true
    fi
    release_container_runtime_lock
    if [[ "$succeeded" == "1" ]]; then
        find "$runtime_root" -depth -delete
    else
        printf 'preserved failing Engine state at %s\n' "$runtime_root" >&2
    fi
}
trap cleanup EXIT

"$engine_bin" \
    --socket "$socket" \
    --container "$container_bin" \
    --state "$runtime_root/state.sqlite" \
    >"$runtime_root/engine.log" 2>&1 &
engine_pid=$!
for _ in {1..100}; do
    [[ -S "$socket" ]] && break
    kill -0 "$engine_pid" 2>/dev/null || break
    sleep 0.1
done
[[ -S "$socket" ]]

export CONTAINER_COMPOSE_ENGINE_SOCKET="$socket"
export CONTAINER_COMPOSE_CONTAINER="$container_bin"
export CONTAINER_COMPOSE_VOLUME_INITIALIZER="$helper_bin"

"$compose_bin" -p "$project" -f "$fixture" up -d
proof="$(
    "$compose_bin" -p "$project" -f "$fixture" exec -T seed \
        head -n 1 /usr/share/apk/keys/alpine-devel@lists.alpinelinux.org-4a6a0840.rsa.pub
)"
[[ "$proof" == "-----BEGIN PUBLIC KEY-----" ]]
"$compose_bin" -p "$project" -f "$fixture" down --volumes

succeeded=1
printf 'stock-engine-image-volume=pass\n'
