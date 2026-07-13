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

GH="${GH:-gh}"

required_variables=(
  RELEASE_REPOSITORY
  RELEASE_TAG
  RELEASE_TITLE
  RELEASE_NOTES_FILE
  RELEASE_LATEST
  RELEASE_PRERELEASE
  PUBLISH_REF_TYPE
  PUBLISH_SHA
  RELEASE_ASSET_PATH
  RELEASE_CHECKSUM_PATH
)

for variable in "${required_variables[@]}"; do
  if [[ -z "${!variable:-}" ]]; then
    printf 'required release variable is empty: %s\n' "${variable}" >&2
    exit 2
  fi
done

for variable in RELEASE_NOTES_FILE RELEASE_ASSET_PATH RELEASE_CHECKSUM_PATH; do
  if [[ ! -f "${!variable}" ]]; then
    printf 'required release file is missing: %s\n' "${!variable}" >&2
    exit 2
  fi
done

if [[ -n "${RELEASE_HIGHLIGHTS_PATH:-}" && ! -f "${RELEASE_HIGHLIGHTS_PATH}" ]]; then
  printf 'release highlights manifest is missing: %s\n' "${RELEASE_HIGHLIGHTS_PATH}" >&2
  exit 2
fi

release_flags=()
if [[ "${RELEASE_PRERELEASE}" == "true" ]]; then
  release_flags+=(--prerelease)
fi
if [[ "${RELEASE_LATEST}" == "true" ]]; then
  release_flags+=(--latest)
else
  release_flags+=(--latest=false)
fi

# Return whether the requested release exists without treating API failures as absence.
release_state() {
  local output status
  set +e
  output="$("${GH}" api --silent "repos/${RELEASE_REPOSITORY}/releases/tags/${RELEASE_TAG}" 2>&1)"
  status=$?
  set -e

  if (( status == 0 )); then
    printf 'exists\n'
    return 0
  fi
  if [[ "${output}" == *"HTTP 404"* ]]; then
    printf 'missing\n'
    return 0
  fi

  printf 'could not determine whether release %s exists:\n%s\n' \
    "${RELEASE_TAG}" "${output}" >&2
  return 1
}

published_release_state="$(release_state)"

if [[ "${PUBLISH_REF_TYPE}" != "tag" && "${PUBLISH_REF_TYPE}" != "branch" ]]; then
  printf 'unsupported release publish ref type: %s\n' "${PUBLISH_REF_TYPE}" >&2
  exit 2
fi

if [[ "${published_release_state}" == "exists" ]]; then
  printf 'release %s already exists; published releases are immutable\n' \
    "${RELEASE_TAG}" >&2
  exit 1
fi

create_args=(
  "${RELEASE_ASSET_PATH}" \
  "${RELEASE_CHECKSUM_PATH}" \
  --repo "${RELEASE_REPOSITORY}"
  --title "${RELEASE_TITLE}"
  --notes-file "${RELEASE_NOTES_FILE}"
)
if [[ -n "${RELEASE_HIGHLIGHTS_PATH:-}" ]]; then
  create_args+=("${RELEASE_HIGHLIGHTS_PATH}")
fi
if [[ "${PUBLISH_REF_TYPE}" == "tag" ]]; then
  create_args+=(--verify-tag)
else
  create_args+=(--target "${PUBLISH_SHA}")
fi
create_args+=("${release_flags[@]}")

exec "${GH}" release create "${RELEASE_TAG}" "${create_args[@]}"
