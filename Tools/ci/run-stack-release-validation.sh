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
    container_targets=(check container dsym docs coverage-unit)
    ;;
  *)
    printf 'unknown stack release validation mode: %s\n' "${mode}" >&2
    exit 2
    ;;
esac

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
# run, nor leave its own state behind for the next gate.  Keep the default under
# Container's already-ignored test scratch directory, resolving relative hosted
# checkout paths before passing the application root through make.
if [[ -n "${CONTAINER_STACK_VALIDATION_SCRATCH_ROOT:-}" ]]; then
  container_scratch_root="${CONTAINER_STACK_VALIDATION_SCRATCH_ROOT}"
  if [[ "${container_scratch_root}" != /* || "${container_scratch_root}" == / ]]; then
    printf 'CONTAINER_STACK_VALIDATION_SCRATCH_ROOT must be an absolute path other than /: %s\n' \
      "${container_scratch_root}" >&2
    exit 2
  fi
else
  container_scratch_root="$(cd "${container_repo}" && pwd -L)/.test-scratch"
fi
container_app_root="${container_scratch_root}/stack-release-app-root"
container_log_root="${container_scratch_root}/stack-release-log-root"
container_make_args=(
  "APP_ROOT=${container_app_root}"
  "LOG_ROOT=${container_log_root}"
)
if [[ "${mode}" == "full" ]]; then
  container_revision="$(git -C "${container_repo}" rev-parse --verify HEAD 2>/dev/null || printf 'fixture')"
  container_validation_suffix="$(printf '%s' "${container_revision}" | tr -cd '[:alnum:]' | cut -c1-12)"
  container_make_args+=(
    "INTEGRATION_SERVICE_NAMESPACE=io.github.container.stack-validation.${container_validation_suffix}"
  )
fi

printf 'running %s stack release validation\n' "${mode}"
make -C "${builder_repo}" check-licenses vet lint coverage build
make -C "${containerization_repo}" "${containerization_targets[@]}"
# The outer stable gate may select an already-running isolated runtime for
# Containerization's image build. Container's unit tests exercise their own
# default namespace contract, so do not let that selector rewrite the expected
# launchd labels and engine socket paths. The explicit APP_ROOT/LOG_ROOT make
# arguments still isolate Container's VM-backed integration state.
env -u CONTAINER_APP_ROOT -u CONTAINER_SERVICE_NAMESPACE \
  CONTAINER_INIT_BOOTSTRAP_IMAGE_ARCHIVE="${CONTAINER_RUNTIME_INIT_IMAGE_ARCHIVE:-}" \
  make -C "${container_repo}" "${container_make_args[@]}" "${container_targets[@]}"
ruby -c "${homebrew_tap_repo}/Formula/container-compose.rb"
