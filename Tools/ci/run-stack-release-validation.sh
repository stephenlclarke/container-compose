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
    containerization_targets=(check containerization examples docs coverage integration)
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

# Phase 5 owns Docker Compose-compatible external Dockerfile handling. macOS
# canonicalises /tmp to /private/tmp, and the current Builder path bridge
# rejects that otherwise-valid external Dockerfile path. The only sanctioned
# pre-Phase-5 release exception is the documented 0.7.0 promotion. It retains
# all other integration coverage and cannot be used by the hosted gate.
container_make_args=()
phase5_exception_reason="${CONTAINER_STACK_RELEASE_PHASE5_EXTERNAL_DOCKERFILE_EXCEPTION_REASON:-}"
if [[ -n "${phase5_exception_reason}" ]]; then
  if [[ "${mode}" != "full" ]]; then
    printf 'the Phase 5 external-Dockerfile exception is permitted only for full local validation\n' >&2
    exit 2
  fi
  serial_test_suites="$(find "${container_repo}/Tests/IntegrationTests" -name 'Test*Serial.swift' ! -name 'TestCLIBuilderSerial.swift' -exec basename {} .swift \; | sort | sed 's|$|/|' | paste -sd' ' -)"
  if [[ -z "${serial_test_suites}" ]]; then
    printf 'could not derive the non-Phase-5 Container serial integration suites\n' >&2
    exit 2
  fi
  container_make_args+=("SERIAL_TEST_SUITES=${serial_test_suites}")
  printf 'Phase 5 external-Dockerfile exception: excluding TestCLIBuilderSerial only; reason: %s\n' \
    "${phase5_exception_reason}"
fi

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

printf 'running %s stack release validation\n' "${mode}"
make -C "${builder_repo}" check-licenses vet lint coverage build
make -C "${containerization_repo}" "${containerization_targets[@]}"
make -C "${container_repo}" "${container_make_args[@]}" "${container_targets[@]}"
ruby -c "${homebrew_tap_repo}/Formula/container-compose.rb"
