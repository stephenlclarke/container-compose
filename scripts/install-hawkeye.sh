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

readonly HAWKEYE_VERSION=v6.5.1
readonly HAWKEYE_BIN=.local/bin/hawkeye
readonly HAWKEYE_CACHE=.local/cache/hawkeye

case "$(uname -s)/$(uname -m)" in
    Darwin/arm64)
        readonly artifact=hawkeye-aarch64-apple-darwin.tar.xz
        readonly expected_sha256=99777f21e4e56c9946ed93621885532c6a0476377f497565c583f5911f2cbb1f
        ;;
    Darwin/x86_64)
        readonly artifact=hawkeye-x86_64-apple-darwin.tar.xz
        readonly expected_sha256=23d53443fd810df74b21f6f82ccc3d1db7df6c33962239dcefd581cef74b59c1
        ;;
    Linux/x86_64)
        readonly artifact=hawkeye-x86_64-unknown-linux-gnu.tar.xz
        readonly expected_sha256=d6eb0505a45a15244f4f789158aafe5e3f1a7dc86c9dc1d7651f3cb1e1b321e0
        ;;
    Linux/aarch64|Linux/arm64)
        readonly artifact=hawkeye-aarch64-unknown-linux-gnu.tar.xz
        readonly expected_sha256=51962edc7008658d7d44f637ea33582bb441635496c617b2a63ca61ab4ed43b6
        ;;
    *)
        printf 'unsupported Hawkeye platform: %s/%s\n' \
            "$(uname -s)" "$(uname -m)" >&2
        exit 2
        ;;
esac

readonly artifact_url="https://github.com/korandoru/hawkeye/releases/download/${HAWKEYE_VERSION}/${artifact}"
work_directory="$(mktemp -d)"

# Remove only the private directory created above.
cleanup() {
    rm -rf -- "${work_directory}"
}
trap cleanup EXIT HUP INT TERM

# Create a repository-local directory without following an indirect parent.
require_direct_directory() {
    local directory="$1"
    local canonical_directory
    local expected_directory

    if [[ -L "${directory}" ]]; then
        printf 'refusing symlinked Hawkeye directory: %s\n' "${directory}" >&2
        return 1
    fi
    mkdir -p "${directory}"
    canonical_directory="$(cd "${directory}" && pwd -P)"
    expected_directory="$(pwd -P)/${directory}"
    if [[ "${canonical_directory}" != "${expected_directory}" ]]; then
        printf 'refusing indirect Hawkeye directory: %s\n' "${directory}" >&2
        return 1
    fi
}

require_direct_directory "${HAWKEYE_CACHE}"
tarball="${HAWKEYE_CACHE}/${artifact}"
if [[ -L "${tarball}" ]]; then
    printf 'refusing symlinked Hawkeye cache archive: %s\n' "${tarball}" >&2
    exit 1
fi
if [[ ! -f "${tarball}" ]] ||
    ! printf '%s  %s\n' "${expected_sha256}" "${tarball}" |
        shasum -a 256 -c - >/dev/null 2>&1; then
    temporary_tarball="${work_directory}/${artifact}"
    curl --proto '=https' --tlsv1.2 --fail --silent --show-error --location \
        --connect-timeout 20 --max-time 300 --retry 3 --retry-all-errors \
        --output "${temporary_tarball}" "${artifact_url}"
    printf '%s  %s\n' "${expected_sha256}" "${temporary_tarball}" |
        shasum -a 256 -c -
    install -m 0644 "${temporary_tarball}" "${tarball}"
fi

printf 'Installing verified Hawkeye %s under .local/bin\n' "${HAWKEYE_VERSION}"
printf '%s  %s\n' "${expected_sha256}" "${tarball}" | shasum -a 256 -c -
tar -xf "${tarball}" --strip-components 1 -C "${work_directory}"
require_direct_directory "$(dirname "${HAWKEYE_BIN}")"
install -m 0755 "${work_directory}/hawkeye" "${HAWKEYE_BIN}"
