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

RELEASE_TOOL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly RELEASE_TOOL_DIR

REQUIRED_VARIABLES=(
  GH_TOKEN
  RELEASE_REPOSITORY
  RELEASE_TAG
  RELEASE_PRERELEASE
  RELEASE_LABEL
  ASSET
  FORMULA
  FORMULA_CLASS
  FORMULA_VERSION
  PLUGIN_VERSION
  RUNTIME_ASSET
  RUNTIME_VERSION
  RUNTIME_FORMULA
  CONTAINER_FORMULA
  CONTAINER_FORMULA_CLASS
  CONTAINER_COMPOSE_FORMULA
  COMPOSE_SOURCE_DIR
  CONTAINER_SOURCE_DIR
  TAP_DIR
)

# Print a release-rendering error and terminate the workflow step.
error() {
  printf '%s\n' "$*" >&2
  exit 1
}

# Require a command supplied by the GitHub Actions runner.
need_command() {
  local command_name="$1"
  if ! command -v "${command_name}" >/dev/null 2>&1; then
    error "required command not found: ${command_name}"
  fi
}

# Require every release input before reading or rendering package metadata.
require_release_inputs() {
  local variable
  for variable in "${REQUIRED_VARIABLES[@]}"; do
    if [[ -z "${!variable:-}" ]]; then
      error "required release variable is empty: ${variable}"
    fi
  done

  case "${RELEASE_PRERELEASE}" in
    true|false)
      ;;
    *)
      error "RELEASE_PRERELEASE must be true or false: ${RELEASE_PRERELEASE}"
      ;;
  esac

  if [[ ! -f "${COMPOSE_SOURCE_DIR}/Tools/release/update-homebrew-formula.py" ]]; then
    error "Compose formula updater is missing: ${COMPOSE_SOURCE_DIR}/Tools/release/update-homebrew-formula.py"
  fi
  if [[ ! -f "${COMPOSE_SOURCE_DIR}/Tools/release/container-compose.rb.in" ]]; then
    error "Compose formula template is missing: ${COMPOSE_SOURCE_DIR}/Tools/release/container-compose.rb.in"
  fi
  if [[ ! -f "${RELEASE_TOOL_DIR}/update-homebrew-container-formula.py" ]]; then
    error "container formula updater is missing: ${RELEASE_TOOL_DIR}/update-homebrew-container-formula.py"
  fi
  if [[ ! -f "${CONTAINER_SOURCE_DIR}/Formula/container.rb" ]]; then
    error "container formula template is missing: ${CONTAINER_SOURCE_DIR}/Formula/container.rb"
  fi
  # TAP_DIR is a required environment input validated by the loop above.
  # shellcheck disable=SC2153
  if [[ ! -d "${TAP_DIR}" ]]; then
    error "Homebrew tap checkout is missing: ${TAP_DIR}"
  fi
}

# Wait for the released GitHub object to be visible and match the selected lane.
verify_published_release() {
  local attempt details exit_status actual_tag is_draft is_prerelease
  local max_attempts=6

  for ((attempt = 1; attempt <= max_attempts; attempt++)); do
    if details="$(gh release view "${RELEASE_TAG}" \
      --repo "${RELEASE_REPOSITORY}" \
      --json tagName,isDraft,isPrerelease \
      --jq '[.tagName, .isDraft, .isPrerelease] | @tsv' 2>&1)"; then
      IFS=$'\t' read -r actual_tag is_draft is_prerelease <<<"${details}"
      if [[ "${actual_tag}" != "${RELEASE_TAG}" || "${is_draft}" != "false" || "${is_prerelease}" != "${RELEASE_PRERELEASE}" ]]; then
        error "published release state does not match ${RELEASE_TAG}: tag=${actual_tag:-missing}, draft=${is_draft:-missing}, prerelease=${is_prerelease:-missing}"
      fi
      return 0
    else
      exit_status=$?
    fi

    if (( attempt == max_attempts )); then
      error "could not read published release ${RELEASE_TAG} after ${max_attempts} attempts (gh exit ${exit_status}): ${details}"
    fi
    printf 'Waiting for published release %s (attempt %s/%s)\n' \
      "${RELEASE_TAG}" "${attempt}" "${max_attempts}"
    sleep "$((attempt * 10))"
  done
}

# Download one immutable release asset with bounded retries for transient API failures.
download_release_asset() {
  local asset="$1" attempt exit_status
  local max_attempts=6

  for ((attempt = 1; attempt <= max_attempts; attempt++)); do
    rm -f "${TMP_DIR}/${asset}"
    printf 'Downloading %s from %s (attempt %s/%s)\n' \
      "${asset}" "${RELEASE_TAG}" "${attempt}" "${max_attempts}"
    if gh release download "${RELEASE_TAG}" \
      --repo "${RELEASE_REPOSITORY}" \
      --pattern "${asset}" \
      --dir "${TMP_DIR}"; then
      if [[ -s "${TMP_DIR}/${asset}" ]]; then
        return 0
      fi
      exit_status=1
      printf 'Downloaded release asset is empty: %s\n' "${asset}" >&2
    else
      exit_status=$?
    fi

    if (( attempt == max_attempts )); then
      error "could not download release asset ${asset} after ${max_attempts} attempts (gh exit ${exit_status})"
    fi
    sleep "$((attempt * 10))"
  done
}

# Verify a downloaded asset against its paired SHA-256 file and print its digest.
verify_release_checksum() {
  local asset="$1" expected_sha actual_sha
  expected_sha="$(awk 'NR == 1 { print $1; exit }' "${TMP_DIR}/${asset}.sha256")"
  if [[ ! "${expected_sha}" =~ ^[0-9a-f]{64}$ ]]; then
    error "release checksum is invalid for ${asset}: ${expected_sha:-missing}"
  fi
  actual_sha="$(shasum -a 256 "${TMP_DIR}/${asset}" | awk '{ print $1 }')"
  if [[ "${actual_sha}" != "${expected_sha}" ]]; then
    error "release checksum mismatch for ${asset}: expected ${expected_sha}, got ${actual_sha}"
  fi
  printf '%s\n' "${actual_sha}"
}

# Require a complete package archive and a binary at its expected stable path.
verify_archive_entry() {
  local asset="$1" entry="$2" label="$3"
  if ! tar -tzf "${TMP_DIR}/${asset}" >/dev/null; then
    error "published ${label} package archive is corrupt: ${asset}"
  fi
  if ! tar -tzf "${TMP_DIR}/${asset}" | grep -Fx "${entry}" >/dev/null; then
    error "published ${label} package is missing ${entry}: ${asset}"
  fi
}

# Render both tap-owned formulae from the verified immutable release assets.
main() {
  local compose_sha runtime_sha compose_url runtime_url

  require_release_inputs
  need_command gh
  need_command git
  need_command python3
  need_command ruby
  need_command shasum
  need_command tar
  need_command grep
  need_command awk
  verify_published_release

  TMP_DIR="$(mktemp -d)"
  readonly TMP_DIR
  trap 'rm -rf "${TMP_DIR}"' EXIT

  # ASSET is a required environment input validated before this function runs.
  # shellcheck disable=SC2153
  download_release_asset "${ASSET}"
  download_release_asset "${ASSET}.sha256"
  download_release_asset "${RUNTIME_ASSET}"
  download_release_asset "${RUNTIME_ASSET}.sha256"

  compose_sha="$(verify_release_checksum "${ASSET}")"
  runtime_sha="$(verify_release_checksum "${RUNTIME_ASSET}")"
  verify_archive_entry "${ASSET}" "compose/bin/compose" "Compose"
  verify_archive_entry "${RUNTIME_ASSET}" "./bin/container" "runtime"

  compose_url="https://github.com/${RELEASE_REPOSITORY}/releases/download/${RELEASE_TAG}/${ASSET}"
  runtime_url="https://github.com/${RELEASE_REPOSITORY}/releases/download/${RELEASE_TAG}/${RUNTIME_ASSET}"

  python3 "${COMPOSE_SOURCE_DIR}/Tools/release/update-homebrew-formula.py" \
    --formula "${TAP_DIR}/Formula/${FORMULA}" \
    --template "${COMPOSE_SOURCE_DIR}/Tools/release/container-compose.rb.in" \
    --formula-class "${FORMULA_CLASS}" \
    --runtime-formula "${RUNTIME_FORMULA}" \
    --url "${compose_url}" \
    --version "${FORMULA_VERSION}" \
    --plugin-version "${PLUGIN_VERSION}" \
    --asset "${ASSET}" \
    --label "${RELEASE_LABEL}" \
    --sha256 "${compose_sha}"

  python3 "${RELEASE_TOOL_DIR}/update-homebrew-container-formula.py" \
    --formula "${TAP_DIR}/Formula/${CONTAINER_FORMULA}" \
    --template "${CONTAINER_SOURCE_DIR}/Formula/container.rb" \
    --formula-class "${CONTAINER_FORMULA_CLASS}" \
    --compose-formula "${CONTAINER_COMPOSE_FORMULA}" \
    --url "${runtime_url}" \
    --sha256 "${runtime_sha}" \
    --version "${RUNTIME_VERSION}" \
    --label "${RELEASE_LABEL}" \
    --asset "${RUNTIME_ASSET}"

  ruby -c "${TAP_DIR}/Formula/${FORMULA}"
  ruby -c "${TAP_DIR}/Formula/${CONTAINER_FORMULA}"
  git -C "${TAP_DIR}" diff -- "Formula/${FORMULA}" "Formula/${CONTAINER_FORMULA}"
}

main "$@"
