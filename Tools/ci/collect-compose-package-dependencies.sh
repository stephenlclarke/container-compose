#!/bin/bash
##===----------------------------------------------------------------------===##
## Copyright © 2026 container-compose project authors.
##
## Licensed under the Apache License, Version 2.0 (the "License");
## you may not use this file except in compliance with the License.
## You may obtain a copy of the License at
##
##   https://www.apache.org/licenses/LICENSE-2.0
##
## Unless required by applicable law or agreed to in writing, software
## distributed under the License is distributed on an "AS IS" BASIS,
## WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
## See the License for the specific language governing permissions and
## limitations under the License.
##===----------------------------------------------------------------------===##

set -euo pipefail
exec </dev/null

fail() {
  printf '%s\n' "$1" >&2
  exit 2
}

[[ "${1:-}" == true ]] || fail 'Compose package validation gate is not ready'
/bin/mkdir compose-package-dependencies || fail 'Could not create dependency closure'
expected_stages=',compose-release-build,compose-go-validation,'
observed_stages=,
observed_count=0
for receipt in *.receipt.tsv; do
  [[ -f "${receipt}" ]] || continue
  stage="$(/usr/bin/awk -F '\t' '$1 == "stage" { print $2 }' "${receipt}")"
  case "${expected_stages}" in
    *,"${stage}",*) ;;
    *)
      printf 'unexpected Compose package dependency: %s\n' "${stage}" >&2
      exit 2
      ;;
  esac
  case "${observed_stages}" in
    *,"${stage}",*)
      printf 'duplicate Compose package dependency: %s\n' "${stage}" >&2
      exit 2
      ;;
  esac
  archive="${stage}.artifacts.tar"
  manifest="${stage}.artifacts.tsv"
  [[ -s "${archive}" ]] || fail "Missing dependency archive: ${stage}"
  [[ -s "${manifest}" ]] || fail "Missing dependency manifest: ${stage}"
  expected_archive_sha256="$(/usr/bin/awk -F '\t' \
    '$1 == "artifact-archive-sha256" { print $2 }' "${receipt}")"
  expected_manifest_sha256="$(/usr/bin/awk -F '\t' \
    '$1 == "artifact-manifest-sha256" { print $2 }' "${receipt}")"
  source_payload_sha256="$(/usr/bin/awk -F '\t' \
    '$1 == "source-payload-sha256" { print $2 }' "${receipt}")"
  [[ "${source_payload_sha256}" =~ ^[0-9a-f]{64}$ ]] || \
    fail "Invalid dependency source payload: ${stage}"
  [[ "$(/usr/bin/shasum -a 256 "${archive}" | /usr/bin/awk '{ print $1 }')" == \
    "${expected_archive_sha256}" ]] || \
    fail "Dependency archive digest changed: ${stage}"
  [[ "$(/usr/bin/shasum -a 256 "${manifest}" | /usr/bin/awk '{ print $1 }')" == \
    "${expected_manifest_sha256}" ]] || \
    fail "Dependency manifest digest changed: ${stage}"
  [[ "$(/usr/bin/awk -F '\t' '$1 == "artifact-count" { print $2 }' \
    "${manifest}")" == 1 ]] || \
    fail "Dependency manifest has the wrong artifact count: ${stage}"
  artifact_path="$(/usr/bin/awk -F '\t' '$1 == "artifact" { print $2 }' \
    "${manifest}")"
  case "${stage}" in
    compose-release-build) expected_artifact='.build/release/compose' ;;
    compose-go-validation)
      expected_artifact='Tools/compose-normalizer/compose-normalizer'
      ;;
  esac
  [[ "${artifact_path}" == "${expected_artifact}" ]] || \
    fail "Dependency manifest has the wrong artifact: ${stage}"
  /bin/cp "${receipt}" "${archive}" "${manifest}" \
    compose-package-dependencies/ || fail "Could not collect dependency: ${stage}"
  observed_stages="${observed_stages}${stage},"
  ((observed_count += 1))
done
[[ "${observed_count}" -eq 2 ]] || fail 'Compose package dependency count is incomplete'
for stage in compose-release-build compose-go-validation; do
  case "${observed_stages}" in
    *,"${stage}",*) ;;
    *) fail "Missing Compose package dependency: ${stage}" ;;
  esac
done
[[ "$(/usr/bin/find compose-package-dependencies -maxdepth 1 -type f \
  \( -name '*.receipt.tsv' -o -name '*.artifacts.tar' \
  -o -name '*.artifacts.tsv' \) | /usr/bin/wc -l | /usr/bin/tr -d ' ')" -eq 6 ]] || \
  fail 'Compose package dependency evidence has unmatched files'
