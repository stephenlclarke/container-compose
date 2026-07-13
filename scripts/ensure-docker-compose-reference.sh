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

readonly COMPOSE_VERSION="${DOCKER_COMPOSE_REFERENCE_VERSION:-5.3.1}"
readonly INSTALL_DIR="${DOCKER_COMPOSE_REFERENCE_BIN_DIR:-${PWD}/.local/bin}"
readonly COMPOSE_BIN="${INSTALL_DIR}/docker-compose"
readonly COLIMA_CPUS="${DOCKER_COMPOSE_REFERENCE_CPUS:-2}"
readonly COLIMA_MEMORY="${DOCKER_COMPOSE_REFERENCE_MEMORY:-4}"
readonly COLIMA_DISK="${DOCKER_COMPOSE_REFERENCE_DISK:-20}"

need_command() {
    local command_name="$1"
    if ! command -v "$command_name" >/dev/null 2>&1; then
        printf 'required command not found: %s\n' "$command_name" >&2
        exit 1
    fi
}

host_arch() {
    case "$(uname -m)" in
        arm64) printf 'aarch64' ;;
        x86_64) printf 'x86_64' ;;
        *)
            printf 'unsupported macOS architecture for Docker Compose reference: %s\n' "$(uname -m)" >&2
            exit 1
            ;;
    esac
}

compose_sha256() {
    case "$(host_arch)" in
        aarch64) printf '32691ba1196d819fa68cbdc0aad9a5569e730a35ae40c6fdd8458110ecd69488' ;;
        x86_64) printf '56620a2e87e789147b9b1cc5d37eeecec2332e2cdf5c2d58a68f999f2dc416ca' ;;
    esac
}

install_formula() {
    local formula="$1"
    if brew list --formula "$formula" >/dev/null 2>&1; then
        return 0
    fi
    brew install "$formula"
}

install_compose() {
    local arch asset expected tmp actual
    arch="$(host_arch)"
    asset="docker-compose-darwin-${arch}"
    expected="$(compose_sha256)"

    if [[ -x "$COMPOSE_BIN" ]] && "$COMPOSE_BIN" version --short 2>/dev/null | sed 's/^v//' | grep -qx "$COMPOSE_VERSION"; then
        return 0
    fi

    mkdir -p "$INSTALL_DIR"
    tmp="$(mktemp)"
    curl -fsSL \
        "https://github.com/docker/compose/releases/download/v${COMPOSE_VERSION}/${asset}" \
        -o "$tmp"
    actual="$(shasum -a 256 "$tmp" | awk '{print $1}')"
    if [[ "$actual" != "$expected" ]]; then
        printf 'Docker Compose checksum mismatch for %s: expected %s, got %s\n' \
            "$asset" "$expected" "$actual" >&2
        rm -f "$tmp"
        exit 1
    fi
    install -m 0755 "$tmp" "$COMPOSE_BIN"
    rm -f "$tmp"
}

start_colima() {
    if [[ "${DOCKER_COMPOSE_REFERENCE_SKIP_DAEMON:-0}" == "1" ]]; then
        return 0
    fi

    if ! colima status >/dev/null 2>&1; then
        colima start \
            --runtime docker \
            --arch "$(host_arch)" \
            --cpus "$COLIMA_CPUS" \
            --memory "$COLIMA_MEMORY" \
            --disk "$COLIMA_DISK"
    fi

    docker context use colima >/dev/null
    docker info >/dev/null
}

export_github_env() {
    if [[ -n "${GITHUB_PATH:-}" ]]; then
        printf '%s\n' "$INSTALL_DIR" >>"$GITHUB_PATH"
    fi
    if [[ -n "${GITHUB_ENV:-}" ]]; then
        printf 'DOCKER_COMPOSE=%s\n' "$COMPOSE_BIN" >>"$GITHUB_ENV"
    fi
}

main() {
    if [[ "$(uname -s)" != "Darwin" ]]; then
        printf 'Docker Compose reference setup currently supports macOS runners only\n' >&2
        exit 1
    fi

    need_command brew
    need_command curl
    need_command install
    need_command shasum

    install_formula docker
    install_formula colima
    install_compose
    start_colima

    export_github_env
    "$COMPOSE_BIN" version
    if [[ "${DOCKER_COMPOSE_REFERENCE_SKIP_DAEMON:-0}" != "1" ]]; then
        docker version
    fi
}

main "$@"
