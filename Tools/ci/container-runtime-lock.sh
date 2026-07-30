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

# Acquire the one host-wide lock protecting Container's launchd service.
#
# Container state can use an isolated app root, but the apiserver and plugin
# services still occupy one launchd namespace for the current macOS user. Keep
# every long-running repository workflow from stopping or replacing another
# workflow's service while it owns that namespace.
acquire_container_runtime_lock() {
    if [[ "${CONTAINER_RUNTIME_LOCK_HELD:-0}" == "1" ]]; then
        return
    fi

    local lock_file="${CONTAINER_RUNTIME_LOCK_FILE:-/tmp/container-compose-runtime-${UID}.lock}"
    local timeout_seconds="${CONTAINER_RUNTIME_LOCK_TIMEOUT_SECONDS:-10800}"

    if ! [[ "$timeout_seconds" =~ ^[1-9][0-9]*$ ]]; then
        printf 'CONTAINER_RUNTIME_LOCK_TIMEOUT_SECONDS must be a positive integer: %s\n' \
            "$timeout_seconds" >&2
        return 2
    fi
    local lock_backend
    if command -v lockf >/dev/null 2>&1; then
        lock_backend="lockf"
    elif command -v flock >/dev/null 2>&1; then
        lock_backend="flock"
    else
        printf 'lockf or flock is required to serialize access to the macOS Container runtime\n' >&2
        return 2
    fi

    printf 'Waiting for macOS Container runtime lock: %s\n' "$lock_file"
    exec 9>>"$lock_file"
    local lock_acquired=0
    case "$lock_backend" in
        lockf)
            if lockf -t "$timeout_seconds" 9; then
                lock_acquired=1
            fi
            ;;
        flock)
            if flock -w "$timeout_seconds" 9; then
                lock_acquired=1
            fi
            ;;
    esac
    if [[ "$lock_acquired" != "1" ]]; then
        printf 'timed out after %ss waiting for macOS Container runtime lock: %s\n' \
            "$timeout_seconds" "$lock_file" >&2
        return 1
    fi

    export CONTAINER_RUNTIME_LOCK_HELD=1
    printf 'Acquired macOS Container runtime lock: %s\n' "$lock_file"
}
