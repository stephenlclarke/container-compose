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

# Run the sibling stack validation used by local and hosted release gates.
set -euo pipefail

if (($# != 6)); then
  printf 'usage: %s {full|hosted} COMPOSE_REPO BUILDER_REPO CONTAINERIZATION_REPO CONTAINER_REPO HOMEBREW_TAP_REPO\n' "$0" >&2
  exit 2
fi

mode="$1"
compose_repo="$2"
builder_repo="$3"
containerization_repo="$4"
container_repo="$5"
homebrew_tap_repo="$6"

case "${mode}" in
  full)
    # Containerization's integration target requires a kernel, which is not
    # retained in a clean checkout. Provision its documented default here so a
    # full local release gate is self-contained.
    containerization_targets=(check containerization examples docs coverage fetch-default-kernel integration)
    container_targets=(check container dsym docs coverage)
    ;;
  hosted)
    containerization_targets=(check containerization examples docs coverage)
    # The Container `container` target stages an installer and therefore builds
    # Linux service workload images with Colima. GitHub-hosted macOS runners do
    # not expose nested virtualization, so keep this lane on the native macOS
    # application proofs. The full local gate remains responsible for installer
    # staging and live runtime validation before the signed tag is created.
    container_targets=(check build dsym docs coverage-unit)
    ;;
  *)
    printf 'unknown stack release validation mode: %s\n' "${mode}" >&2
    exit 2
    ;;
esac
builder_targets=(check-licenses vet lint coverage build)

for path in "${compose_repo}" "${builder_repo}" "${containerization_repo}" "${container_repo}"; do
  if [[ ! -f "${path}/Makefile" ]]; then
    printf 'required stack checkout is missing a Makefile: %s\n' "${path}" >&2
    exit 2
  fi
done
if [[ ! -f "${homebrew_tap_repo}/Formula/container-compose.rb" ]]; then
  printf 'Homebrew tap formula is required at %s/Formula/container-compose.rb\n' "${homebrew_tap_repo}" >&2
  exit 2
fi

# Container integration is VM-backed and the CLI otherwise defaults to the
# developer's persistent Application Support directory.  A stable-release gate
# must never inherit stale machines, images, or networks from an earlier local
# run, nor leave its own state behind for the next gate. Build scratch may live
# on an external volume, but launchd-managed helpers can block while opening
# their log files there and reject service plists or executables there. Keep all
# launchd-facing state under the independently configurable runtime root so the
# stable-release helper can bind it to its marker-protected internal lifecycle.
# Resolve symlinks: Container's protected state deliberately rejects persistence
# roots whose canonical path differs from the supplied path.
if [[ -n "${CONTAINER_STACK_VALIDATION_SCRATCH_ROOT:-}" ]]; then
  container_scratch_root="${CONTAINER_STACK_VALIDATION_SCRATCH_ROOT}"
  if [[ "${container_scratch_root}" != /* || "${container_scratch_root}" == / ]]; then
    printf 'CONTAINER_STACK_VALIDATION_SCRATCH_ROOT must be an absolute path other than /: %s\n' \
      "${container_scratch_root}" >&2
    exit 2
  fi
else
  container_scratch_root="$(cd "${container_repo}" && pwd -P)/.test-scratch"
fi
mkdir -p "${container_scratch_root}"
container_scratch_root="$(cd "${container_scratch_root}" && pwd -P)"
if [[ "${container_scratch_root}" == / ]]; then
  printf 'CONTAINER_STACK_VALIDATION_SCRATCH_ROOT must not resolve to /\n' >&2
  exit 2
fi
container_validation_suffix=""
if [[ "${mode}" == "full" ]]; then
  container_revision="$(git -C "${container_repo}" rev-parse --verify HEAD 2>/dev/null || printf 'fixture')"
  container_validation_suffix="$(printf '%s' "${container_revision}" | tr -cd '[:alnum:]' | cut -c1-12)"
fi
if [[ -n "${CONTAINER_STACK_VALIDATION_RUNTIME_ROOT:-}" ]]; then
  container_runtime_root="${CONTAINER_STACK_VALIDATION_RUNTIME_ROOT}"
  if [[ "${container_runtime_root}" != /* || "${container_runtime_root}" == / ]]; then
    printf 'CONTAINER_STACK_VALIDATION_RUNTIME_ROOT must be an absolute path other than /: %s\n' \
      "${container_runtime_root}" >&2
    exit 2
  fi
else
  if [[ "${mode}" == "full" ]]; then
    # Full validation launches services. Keep its safe default short and on the
    # internal volume; hosted validation never launches them and may stay with
    # the checkout-backed scratch root.
    container_runtime_parent_base=/private/tmp
    if [[ ! -d "${container_runtime_parent_base}" || ! -w "${container_runtime_parent_base}" ]]; then
      container_runtime_parent_base=/tmp
    fi
    container_runtime_root="${container_runtime_parent_base}/ccsv.${container_validation_suffix}"
  else
    container_runtime_root="${container_scratch_root}/runtime"
  fi
fi
mkdir -p "${container_runtime_root}"
container_runtime_root="$(cd "${container_runtime_root}" && pwd -P)"
if [[ "${container_runtime_root}" == / ]]; then
  printf 'CONTAINER_STACK_VALIDATION_RUNTIME_ROOT must not resolve to /\n' >&2
  exit 2
fi
container_app_root="${container_runtime_root}/stack-release-app-root"
container_log_root="${container_runtime_root}/stack-release-log-root"
container_provider_socket="${container_app_root}/engine-provider/provider.sock"
container_provider_socket_bytes=$(LC_ALL=C printf '%s' "${container_provider_socket}" \
  | wc -c | tr -d '[:space:]')
if [[ "${mode}" == "full" ]] && ((container_provider_socket_bytes > 103)); then
  printf 'CONTAINER_STACK_VALIDATION_RUNTIME_ROOT exceeds the provider Unix socket path limit (%s > 103 bytes): %s\n' \
    "${container_provider_socket_bytes}" "${container_provider_socket}" >&2
  exit 2
fi
container_make_args=(
  "APP_ROOT=${container_app_root}"
  "LOG_ROOT=${container_log_root}"
)
if [[ "${mode}" == "full" ]]; then
  container_make_args+=(
    "INTEGRATION_SERVICE_NAMESPACE=io.github.container.stack-validation.${container_validation_suffix}"
  )
fi

checkpoint_directory=${CONTAINER_STACK_VALIDATION_CHECKPOINT_DIR:-}
builder_validation_fingerprint=""
containerization_validation_fingerprint=""
container_validation_fingerprint=""
homebrew_validation_fingerprint=""
runtime_cli=${CONTAINER_RUNTIME_CLI:-}
runtime_cli_directory=""
runtime_path=${PATH}
runtime_cli_fingerprint="unset"
runtime_cli_sha256="unset"
runtime_candidate_sha256=${CONTAINER_RUNTIME_CANDIDATE_SHA256:-}
validation_environment_path=${PATH}
runtime_make_args=()
if [[ "${mode}" == "full" ]]; then
  if [[ -z "${runtime_cli}" ]]; then
    printf 'full stack validation requires an executable CONTAINER_RUNTIME_CLI: %s\n' \
      "${runtime_cli:-unset}" >&2
    exit 2
  fi
  if [[ "${runtime_cli}" != */* ]]; then
    if ! runtime_cli=$(command -v "${runtime_cli}"); then
      printf 'full stack validation Container CLI was not found on PATH: %s\n' \
        "${CONTAINER_RUNTIME_CLI}" >&2
      exit 2
    fi
  elif [[ "${runtime_cli}" != /* ]]; then
    runtime_cli="$(cd "$(dirname "${runtime_cli}")" && pwd -P)/$(basename "${runtime_cli}")"
  fi
  if [[ ! -x "${runtime_cli}" ]]; then
    printf 'full stack validation requires an executable CONTAINER_RUNTIME_CLI: %s\n' \
      "${runtime_cli}" >&2
    exit 2
  fi
  runtime_cli_directory=$(cd "$(dirname "${runtime_cli}")" && pwd -P)
  runtime_cli="${runtime_cli_directory}/$(basename "${runtime_cli}")"
  runtime_path="${runtime_cli_directory}${PATH:+:${PATH}}"
  runtime_cli_sha256="$(shasum -a 256 "${runtime_cli}" | awk '{print $1}')"
  if [[ -n "${CONTAINER_RUNTIME_CLI_SHA256:-}" &&
    "${CONTAINER_RUNTIME_CLI_SHA256}" != "${runtime_cli_sha256}" ]]; then
    printf 'full stack validation Container CLI digest mismatch (expected %s, got %s): %s\n' \
      "${CONTAINER_RUNTIME_CLI_SHA256}" "${runtime_cli_sha256}" "${runtime_cli}" >&2
    exit 2
  fi
  if [[ -n "${runtime_candidate_sha256}" ]]; then
    if ! [[ "${runtime_candidate_sha256}" =~ ^[0-9a-f]{64}$ ]]; then
      printf 'CONTAINER_RUNTIME_CANDIDATE_SHA256 must be a lowercase SHA-256 digest: %s\n' \
        "${runtime_candidate_sha256}" >&2
      exit 2
    fi
    if ! runtime_cli_mode=$(python3 - "${runtime_cli}" <<'PY'
import os
import sys

print(f"{os.stat(sys.argv[1]).st_mode & 0o777:o}")
PY
    ); then
      printf 'could not determine packaged Container runtime candidate CLI mode: %s\n' \
        "${runtime_cli}" >&2
      exit 2
    fi
    if ((8#${runtime_cli_mode} & 8#222)); then
      printf 'packaged Container runtime candidate CLI must be read-only during validation: %s\n' \
        "${runtime_cli}" >&2
      exit 2
    fi
  else
    runtime_candidate_sha256="unpackaged"
  fi
  if [[ "${runtime_candidate_sha256}" == "unpackaged" ]]; then
    runtime_cli_fingerprint="unpackaged:${runtime_cli}:${runtime_cli_sha256}"
  else
    runtime_cli_fingerprint="packaged:${runtime_candidate_sha256}:${runtime_cli_sha256}"
    # The runtime wrapper may prepend the same fresh extraction more than once.
    # Its content identity is already captured by runtime_cli_fingerprint, so
    # remove every matching PATH entry before hashing the environment. Otherwise
    # a retry gets a different checkpoint solely because mktemp chose a new path.
    normalized_validation_path=""
    IFS=: read -r -a validation_path_entries <<<"${validation_environment_path}"
    for validation_path_entry in "${validation_path_entries[@]}"; do
      validation_path_entry_resolved=""
      if [[ -d "${validation_path_entry}" ]]; then
        validation_path_entry_resolved=$(cd "${validation_path_entry}" && pwd -P)
      fi
      if [[ "${validation_path_entry_resolved}" == "${runtime_cli_directory}" ]]; then
        continue
      fi
      if [[ -n "${normalized_validation_path}" ]]; then
        normalized_validation_path+=:
      fi
      normalized_validation_path+="${validation_path_entry}"
    done
    validation_environment_path="${normalized_validation_path}"
  fi
  runtime_make_args+=("PATH=${runtime_path}")
fi

# The full gate owns one namespace-scoped Container candidate. Pin PATH as a
# make command-line variable so recursive sibling Makefiles cannot fall back
# to a Homebrew/default-namespace CLI after their expensive unit suites.
verify_runtime_cli_identity() {
  [[ "${mode}" == "full" ]] || return 0

  local resolved
  if ! resolved=$(PATH="${runtime_path}" command -v container); then
    printf 'full stack validation could not resolve container on its pinned PATH\n' >&2
    return 2
  fi
  local resolved_directory
  resolved_directory=$(cd "$(dirname "${resolved}")" && pwd -P)
  resolved="${resolved_directory}/$(basename "${resolved}")"
  if [[ "${resolved}" != "${runtime_cli}" ]]; then
    printf 'full stack validation container path drifted (expected %s, got %s)\n' \
      "${runtime_cli}" "${resolved}" >&2
    return 2
  fi

  local current_sha256
  current_sha256="$(shasum -a 256 "${runtime_cli}" | awk '{print $1}')"
  if [[ "${current_sha256}" != "${runtime_cli_sha256}" ]]; then
    printf 'full stack validation Container CLI content drifted (expected %s, got %s): %s\n' \
      "${runtime_cli_sha256}" "${current_sha256}" "${runtime_cli}" >&2
    return 2
  fi
}

if [[ -n "${checkpoint_directory}" ]]; then
  common_validation_fingerprint=$(
    {
      printf 'mode=%s\n' "${mode}"
      printf 'validator=%s\n' "$(shasum -a 256 "$0" | awk '{print $1}')"
      printf 'environment=PATH=%s\n' "${validation_environment_path}"
      printf 'environment=DEVELOPER_DIR=%s\n' "${DEVELOPER_DIR:-}"
      printf 'environment=SDKROOT=%s\n' "${SDKROOT:-}"
      printf 'environment=CC=%s\n' "${CC:-}"
      printf 'environment=CXX=%s\n' "${CXX:-}"
      printf 'environment=RELEASE_GATE_STACK_TIMEOUT_SECONDS=%s\n' \
        "${RELEASE_GATE_STACK_TIMEOUT_SECONDS:-}"
      printf 'environment=RELEASE_GATE_INHERITED_ENVIRONMENT_FINGERPRINT=%s\n' \
        "${RELEASE_GATE_INHERITED_ENVIRONMENT_FINGERPRINT:-}"
      printf 'environment=RELEASE_GATE_TOOL_FINGERPRINT=%s\n' \
        "${RELEASE_GATE_TOOL_FINGERPRINT:-}"
      for tool_name in git make swift clang go ruby python3 docker hawkeye shellcheck xcodebuild; do
        tool_path=$(command -v "${tool_name}" 2>/dev/null || true)
        printf 'tool=%s:path=%s\n' "${tool_name}" "${tool_path:-missing}"
        if [[ -n "${tool_path}" && -f "${tool_path}" ]]; then
          printf 'tool=%s:sha256=%s\n' "${tool_name}" \
            "$(shasum -a 256 "${tool_path}" | awk '{print $1}')"
        fi
        if [[ -z "${tool_path}" ]]; then
          tool_version=missing
        else
          case "${tool_name}" in
            go)
              tool_version=$(go version 2>&1 || true)
              ;;
            xcodebuild)
              tool_version=$(xcodebuild -version 2>&1 || true)
              ;;
            *)
              tool_version=$("${tool_name}" --version 2>&1 || true)
              ;;
          esac
        fi
        printf 'tool=%s:version=%s\n' "${tool_name}" "${tool_version}"
      done
      printf 'docker:buildx=%s\n' "$(docker buildx version 2>&1 || true)"
      printf 'docker:compose=%s\n' "$(docker compose version 2>&1 || true)"
      uname -a
    } | shasum -a 256 | awk '{print $1}'
  )
  if [[ -n "${CONTAINER_RUNTIME_INIT_IMAGE_ARCHIVE:-}" ]]; then
    if [[ -f "${CONTAINER_RUNTIME_INIT_IMAGE_ARCHIVE}" ]]; then
      init_archive_fingerprint=$(shasum -a 256 \
        "${CONTAINER_RUNTIME_INIT_IMAGE_ARCHIVE}" | awk '{print $1}')
    else
      init_archive_fingerprint="missing:${CONTAINER_RUNTIME_INIT_IMAGE_ARCHIVE}"
    fi
  else
    init_archive_fingerprint="unset"
  fi
  builder_tree=$(git -C "${builder_repo}" rev-parse 'HEAD^{tree}' 2>/dev/null || printf 'fixture')
  containerization_tree=$(git -C "${containerization_repo}" rev-parse 'HEAD^{tree}' 2>/dev/null || printf 'fixture')
  container_tree=$(git -C "${container_repo}" rev-parse 'HEAD^{tree}' 2>/dev/null || printf 'fixture')
  homebrew_tree=$(git -C "${homebrew_tap_repo}" rev-parse 'HEAD^{tree}' 2>/dev/null || printf 'fixture')
  builder_validation_fingerprint=$(
    {
      printf 'common=%s\n' "${common_validation_fingerprint}"
      printf 'stage=builder\n'
      printf 'tree=%s\n' "${builder_tree}"
    } | shasum -a 256 | awk '{print $1}'
  )
  containerization_validation_fingerprint=$(
    {
      printf 'common=%s\n' "${common_validation_fingerprint}"
      printf 'stage=containerization\n'
      printf 'targets=%s\n' "${containerization_targets[*]}"
      printf 'tree=%s\n' "${containerization_tree}"
      printf 'required_init_references=%s\n' \
        "${CONTAINER_RUNTIME_REQUIRED_INIT_IMAGE_REFERENCES:-}"
      printf 'init_archive=%s\n' "${init_archive_fingerprint}"
      printf 'runtime_cli=%s\n' "${runtime_cli_fingerprint}"
    } | shasum -a 256 | awk '{print $1}'
  )
  container_validation_fingerprint=$(
    {
      printf 'common=%s\n' "${common_validation_fingerprint}"
      printf 'stage=container\n'
      printf 'targets=%s\n' "${container_targets[*]}"
      printf 'tree=%s\n' "${container_tree}"
      printf 'init_archive=%s\n' "${init_archive_fingerprint}"
      printf 'runtime_cli=%s\n' "${runtime_cli_fingerprint}"
    } | shasum -a 256 | awk '{print $1}'
  )
  homebrew_validation_fingerprint=$(
    {
      printf 'common=%s\n' "${common_validation_fingerprint}"
      printf 'stage=homebrew\n'
      printf 'tree=%s\n' "${homebrew_tree}"
    } | shasum -a 256 | awk '{print $1}'
  )
fi

# Returns the exact-input fingerprint for one independently validated stage.
validation_fingerprint_for_stage() {
  local stage="$1"
  local base_fingerprint
  case "${stage}" in
    builder-*)
      base_fingerprint="${builder_validation_fingerprint}"
      ;;
    containerization-*)
      base_fingerprint="${containerization_validation_fingerprint}"
      ;;
    container-*)
      base_fingerprint="${container_validation_fingerprint}"
      ;;
    homebrew-*)
      base_fingerprint="${homebrew_validation_fingerprint}"
      ;;
    *)
      printf 'unknown stack validation checkpoint stage: %s\n' "${stage}" >&2
      return 2
      ;;
  esac
  {
    printf 'base=%s\n' "${base_fingerprint}"
    printf 'stage=%s\n' "${stage}"
  } | shasum -a 256 | awk '{print $1}'
}

# Runs one stage unless its own exact inputs already have a successful stamp.
run_checkpointed() {
  local stage=$1
  shift
  verify_runtime_cli_identity
  if [[ -z "${checkpoint_directory}" ]]; then
    "$@"
    verify_runtime_cli_identity
    return
  fi

  mkdir -p "${checkpoint_directory}"
  local stamp="${checkpoint_directory}/${mode}-${stage}.sha256"
  local expected
  expected="$(validation_fingerprint_for_stage "${stage}"):${stage}"
  local actual=""
  if [[ -f "${stamp}" ]]; then
    IFS= read -r actual <"${stamp}" || true
  fi
  if [[ "${actual}" == "${expected}" ]]; then
    printf 'reusing exact-input validation checkpoint: %s\n' "${stage}"
    verify_runtime_cli_identity
    return
  fi

  "$@"
  verify_runtime_cli_identity
  local temporary_stamp
  temporary_stamp=$(mktemp "${checkpoint_directory}/.${mode}-${stage}.XXXXXX")
  printf '%s\n' "${expected}" >"${temporary_stamp}"
  mv -f "${temporary_stamp}" "${stamp}"
}

# Run each top-level Make target as an independently resumable DAG stage.
run_checkpointed_make_targets() {
  local stage_prefix="$1"
  local repository="$2"
  shift 2
  local target
  for target in "$@"; do
    run_checkpointed "${stage_prefix}-${target//_/-}" \
      make -C "${repository}" "${runtime_make_args[@]}" "${target}"
  done
}

printf 'running %s stack release validation\n' "${mode}"
if [[ -n "${checkpoint_directory}" ]]; then
  printf 'stack validation exact-input fingerprint: builder=%s\n' \
    "${builder_validation_fingerprint}"
  printf 'stack validation exact-input fingerprint: containerization=%s\n' \
    "${containerization_validation_fingerprint}"
  printf 'stack validation exact-input fingerprint: container=%s\n' \
    "${container_validation_fingerprint}"
  printf 'stack validation exact-input fingerprint: homebrew=%s\n' \
    "${homebrew_validation_fingerprint}"
fi
run_checkpointed_make_targets builder "${builder_repo}" "${builder_targets[@]}"
run_checkpointed_make_targets containerization "${containerization_repo}" \
  "${containerization_targets[@]}"
# The outer stable gate may select an already-running isolated runtime for
# Containerization's image build. Container's unit tests exercise their own
# default namespace contract, so do not let that selector rewrite the expected
# launchd labels and engine socket paths. The explicit APP_ROOT/LOG_ROOT make
# arguments still isolate Container's VM-backed integration state.
for target in "${container_targets[@]}"; do
  run_checkpointed "container-${target//_/-}" \
    env -u CONTAINER_APP_ROOT -u CONTAINER_SERVICE_NAMESPACE \
      CONTAINER_INIT_BOOTSTRAP_IMAGE_ARCHIVE="${CONTAINER_RUNTIME_INIT_IMAGE_ARCHIVE:-}" \
      CONTAINER_INIT_BUILDER_IMAGE_ARCHIVE="${CONTAINER_RUNTIME_BUILDER_IMAGE_TAR:-}" \
      make -C "${container_repo}" "${runtime_make_args[@]}" \
        "${container_make_args[@]}" "${target}"
done
run_checkpointed homebrew-formula \
  ruby -c "${homebrew_tap_repo}/Formula/container-compose.rb"
