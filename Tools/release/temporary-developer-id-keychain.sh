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

set -Eeuo pipefail

readonly SELF_PATH="${BASH_SOURCE[0]:-$0}"
SELF_DIRECTORY="$(cd "$(dirname "${SELF_PATH}")" && pwd -P)"
readonly SELF_DIRECTORY
readonly DEADLINE_RUNNER="${SELF_DIRECTORY}/../ci/run-command-with-deadline.py"

MODE="${1:-}"
TEMPORARY_ROOT="${DEVELOPER_ID_TEMPORARY_ROOT:-${RUNNER_TEMP:-}}"
KEYCHAIN="${DEVELOPER_ID_KEYCHAIN:-}"
ORIGINAL_KEYCHAINS="${DEVELOPER_ID_ORIGINAL_KEYCHAINS:-}"
ENVIRONMENT_FILE="${DEVELOPER_ID_ENVIRONMENT_FILE:-${GITHUB_ENV:-}}"
TIMEOUT_SECONDS="${DEVELOPER_ID_COMMAND_TIMEOUT_SECONDS:-60}"
KEYCHAIN_TIMEOUT_SECONDS="${DEVELOPER_ID_KEYCHAIN_TIMEOUT_SECONDS:-28800}"

usage() {
  cat <<USAGE
Usage:
  temporary-developer-id-keychain.sh install
  temporary-developer-id-keychain.sh cleanup

Install a Developer ID Application certificate into one operation-scoped
keychain without consulting the login keychain, or remove that keychain and
restore the exact prior user search list.

Required environment for install:
  DEVELOPER_ID_APPLICATION_P12_BASE64
  DEVELOPER_ID_APPLICATION_P12_PASSWORD
  DEVELOPER_ID_TEMPORARY_ROOT
  DEVELOPER_ID_KEYCHAIN
  DEVELOPER_ID_ORIGINAL_KEYCHAINS
  DEVELOPER_ID_ENVIRONMENT_FILE (or GITHUB_ENV)

Required release-authority environment:
  DEVELOPER_ID_EXPECTED_IDENTITY

Optional environment:
  DEVELOPER_ID_COMMAND_TIMEOUT_SECONDS (default: 60)
  DEVELOPER_ID_KEYCHAIN_TIMEOUT_SECONDS (default: 28800)
USAGE
}

fail() {
  printf '%s\n' "$*" >&2
  exit 1
}

select_tools() {
  if [[ "${TEMPORARY_DEVELOPER_ID_KEYCHAIN_TESTING:-0}" == "1" ]]; then
    SECURITY="${DEVELOPER_ID_SECURITY:-security}"
    CODESIGN="${DEVELOPER_ID_CODESIGN:-codesign}"
    OPENSSL="${DEVELOPER_ID_OPENSSL:-openssl}"
    PYTHON="${DEVELOPER_ID_PYTHON:-python3}"
    DEADLINE="${DEVELOPER_ID_DEADLINE_RUNNER:-${DEADLINE_RUNNER}}"
  else
    PATH=/usr/bin:/bin:/usr/sbin:/sbin
    export PATH
    SECURITY=/usr/bin/security
    CODESIGN=/usr/bin/codesign
    OPENSSL=/usr/bin/openssl
    PYTHON=/usr/bin/python3
    DEADLINE="${DEADLINE_RUNNER}"
  fi
  readonly SECURITY CODESIGN OPENSSL PYTHON DEADLINE
}

require_configuration() {
  local keychain_parent original_parent
  [[ "${MODE}" == "install" || "${MODE}" == "cleanup" ]] || {
    usage >&2
    exit 2
  }
  [[ -n "${TEMPORARY_ROOT}" && "${TEMPORARY_ROOT}" == /* ]] ||
    fail "DEVELOPER_ID_TEMPORARY_ROOT must be an absolute path"
  [[ -d "${TEMPORARY_ROOT}" && ! -L "${TEMPORARY_ROOT}" ]] ||
    fail "Developer ID temporary root is missing or unsafe: ${TEMPORARY_ROOT}"
  TEMPORARY_ROOT="$(cd "${TEMPORARY_ROOT}" && pwd -P)"
  keychain_parent="$(cd "$(dirname "${KEYCHAIN}")" 2>/dev/null && pwd -P || true)"
  original_parent="$(cd "$(dirname "${ORIGINAL_KEYCHAINS}")" 2>/dev/null && pwd -P || true)"
  [[ -n "${KEYCHAIN}" && "${keychain_parent}" == "${TEMPORARY_ROOT}" ]] ||
    fail "DEVELOPER_ID_KEYCHAIN must be a direct child of the temporary root"
  [[ -n "${ORIGINAL_KEYCHAINS}" && "${original_parent}" == "${TEMPORARY_ROOT}" ]] ||
    fail "DEVELOPER_ID_ORIGINAL_KEYCHAINS must be a direct child of the temporary root"
  [[ "${KEYCHAIN}" != "${ORIGINAL_KEYCHAINS}" ]] ||
    fail "Developer ID keychain and search-list record must differ"
  [[ "${TIMEOUT_SECONDS}" =~ ^[1-9][0-9]*$ ]] ||
    fail "Developer ID command timeout must be a positive integer"
  [[ "${KEYCHAIN_TIMEOUT_SECONDS}" =~ ^[1-9][0-9]*$ ]] ||
    fail "Developer ID keychain timeout must be a positive integer"
}

run_bounded() {
  "${PYTHON}" "${DEADLINE}" --seconds "${TIMEOUT_SECONDS}" -- "$@" < /dev/null
}

read_original_keychains() {
  local keychain
  ORIGINAL_KEYCHAIN_LIST=()
  if [[ -f "${ORIGINAL_KEYCHAINS}" && ! -L "${ORIGINAL_KEYCHAINS}" ]]; then
    while IFS= read -r keychain; do
      keychain="${keychain#\"}"
      keychain="${keychain%\"}"
      [[ -n "${keychain}" ]] && ORIGINAL_KEYCHAIN_LIST+=("${keychain}")
    done < "${ORIGINAL_KEYCHAINS}"
  fi
}

restore_search_list() {
  read_original_keychains
  if ((${#ORIGINAL_KEYCHAIN_LIST[@]} > 0)); then
    run_bounded "${SECURITY}" list-keychains -d user -s "${ORIGINAL_KEYCHAIN_LIST[@]}"
  else
    run_bounded "${SECURITY}" list-keychains -d user -s
  fi
}

cleanup_keychain() {
  local status=0
  if [[ -f "${ORIGINAL_KEYCHAINS}" && ! -L "${ORIGINAL_KEYCHAINS}" ]]; then
    restore_search_list || status=1
  fi
  if [[ -e "${KEYCHAIN}" && ! -L "${KEYCHAIN}" ]]; then
    run_bounded "${SECURITY}" delete-keychain "${KEYCHAIN}" || status=1
  fi
  if ((status == 0)); then
    rm -f "${ORIGINAL_KEYCHAINS}"
  fi
  return "${status}"
}

install_keychain() {
  local certificate certificate_pem expected_identity identity identity_count
  local identity_name
  local identities keychain_password
  local original_keychains_capture
  local signing_probe

  [[ -n "${DEVELOPER_ID_APPLICATION_P12_BASE64:-}" ]] ||
    fail "DEVELOPER_ID_APPLICATION_P12_BASE64 is required for release signing"
  [[ -n "${DEVELOPER_ID_APPLICATION_P12_PASSWORD:-}" ]] ||
    fail "DEVELOPER_ID_APPLICATION_P12_PASSWORD is required for release signing"
  [[ -n "${DEVELOPER_ID_EXPECTED_IDENTITY:-}" ]] ||
    fail "DEVELOPER_ID_EXPECTED_IDENTITY is required for release signing"
  [[ -n "${ENVIRONMENT_FILE}" && "${ENVIRONMENT_FILE}" == /* ]] ||
    fail "DEVELOPER_ID_ENVIRONMENT_FILE or GITHUB_ENV must be an absolute path"
  [[ ! -e "${KEYCHAIN}" && ! -L "${KEYCHAIN}" ]] ||
    fail "operation-scoped Developer ID keychain already exists: ${KEYCHAIN}"
  [[ ! -e "${ORIGINAL_KEYCHAINS}" && ! -L "${ORIGINAL_KEYCHAINS}" ]] ||
    fail "Developer ID search-list record already exists or is unsafe"

  certificate="$(mktemp "${TEMPORARY_ROOT}/developer-id-application.XXXXXX.p12")"
  certificate_pem="$(mktemp "${TEMPORARY_ROOT}/developer-id-application.XXXXXX.pem")"
  signing_probe="$(mktemp "${TEMPORARY_ROOT}/developer-id-signing-probe.XXXXXX")"
  original_keychains_capture="$(mktemp "${TEMPORARY_ROOT}/developer-id-keychains.XXXXXX")"
  chmod 600 \
    "${certificate}" "${certificate_pem}" "${signing_probe}" \
    "${original_keychains_capture}"
  keychain_password="$(run_bounded "${OPENSSL}" rand -hex 32)"
  [[ "${keychain_password}" =~ ^[0-9a-f]{64}$ ]] ||
    fail "could not generate the operation-scoped keychain password"

  cleanup_failed_install() {
    local exit_status="$1"
    rm -f \
      "${certificate}" "${certificate_pem}" "${signing_probe}" \
      "${original_keychains_capture}"
    if ((exit_status != 0)); then
      cleanup_keychain >/dev/null 2>&1 || true
    fi
    exit "${exit_status}"
  }
  trap 'cleanup_failed_install "$?"' EXIT

  "${PYTHON}" - "${certificate}" <<'PY'
import base64
import os
from pathlib import Path
import sys

encoded = "".join(os.environ["DEVELOPER_ID_APPLICATION_P12_BASE64"].split())
Path(sys.argv[1]).write_bytes(base64.b64decode(encoded, validate=True))
PY

  run_bounded "${SECURITY}" list-keychains -d user |
    sed -E 's/^[[:space:]]*//; s/[[:space:]]*$//' > "${original_keychains_capture}"
  mv "${original_keychains_capture}" "${ORIGINAL_KEYCHAINS}"
  run_bounded "${SECURITY}" create-keychain -p "${keychain_password}" "${KEYCHAIN}"
  run_bounded "${SECURITY}" set-keychain-settings -lut \
    "${KEYCHAIN_TIMEOUT_SECONDS}" "${KEYCHAIN}"
  run_bounded "${SECURITY}" unlock-keychain -p "${keychain_password}" "${KEYCHAIN}"
  read_original_keychains
  run_bounded "${SECURITY}" list-keychains -d user -s \
    "${KEYCHAIN}" "${ORIGINAL_KEYCHAIN_LIST[@]}"
  run_bounded "${SECURITY}" import "${certificate}" \
    -k "${KEYCHAIN}" \
    -P "${DEVELOPER_ID_APPLICATION_P12_PASSWORD}" \
    -f pkcs12 \
    -x \
    -T "${CODESIGN}" \
    -T "${SECURITY}"
  run_bounded "${SECURITY}" set-key-partition-list \
    -S apple-tool:,apple: \
    -s \
    -k "${keychain_password}" \
    "${KEYCHAIN}"

  identities="$(run_bounded "${SECURITY}" find-identity -v -p codesigning "${KEYCHAIN}" |
    grep 'Developer ID Application:' || true)"
  identity_count="$(grep -c . <<<"${identities}" || true)"
  [[ "${identity_count}" == "1" ]] ||
    fail "expected exactly one valid Developer ID Application identity, found ${identity_count}"
  identity="$(awk '{print $2}' <<<"${identities}")"
  [[ "${identity}" =~ ^[0-9A-Fa-f]{40}$ ]] ||
    fail "Developer ID Application identity fingerprint is invalid"
  identity="$(tr '[:lower:]' '[:upper:]' <<<"${identity}")"
  identity_name="$(sed -E 's/^[^"]*"([^"]+)".*$/\1/' <<<"${identities}")"
  expected_identity="${DEVELOPER_ID_EXPECTED_IDENTITY}"
  if [[ "${expected_identity}" =~ ^[0-9A-Fa-f]{40}$ ]]; then
    expected_identity="$(tr '[:lower:]' '[:upper:]' <<<"${expected_identity}")"
    [[ "${identity}" == "${expected_identity}" ]] ||
      fail "Developer ID Application fingerprint does not match the configured authority"
  elif [[ "${identity_name}" != "${expected_identity}" ]]; then
    fail "Developer ID Application name does not match the configured authority"
  fi

  run_bounded "${SECURITY}" find-certificate \
    -c 'Developer ID Application' -p "${KEYCHAIN}" > "${certificate_pem}"
  run_bounded "${OPENSSL}" x509 -in "${certificate_pem}" -checkend 86400 -noout
  cp /usr/bin/true "${signing_probe}"
  run_bounded "${CODESIGN}" \
    --force \
    --keychain "${KEYCHAIN}" \
    --sign "${identity}" \
    --timestamp \
    --options runtime \
    "${signing_probe}"
  run_bounded "${CODESIGN}" --verify --strict --verbose=2 "${signing_probe}"

  {
    printf 'DEVELOPER_ID_APPLICATION_IDENTITY=%s\n' "${identity}"
    printf 'DEVELOPER_ID_KEYCHAIN=%s\n' "${KEYCHAIN}"
    printf 'CONTAINER_RUNTIME_CODESIGN_IDENTITY=%s\n' "${identity}"
  } >> "${ENVIRONMENT_FILE}"
  rm -f "${certificate}" "${certificate_pem}" "${signing_probe}"
  trap - EXIT
}

main() {
  select_tools
  require_configuration
  case "${MODE}" in
    install)
      install_keychain
      ;;
    cleanup)
      cleanup_keychain
      ;;
  esac
}

main
