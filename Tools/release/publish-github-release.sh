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
GIT="${GIT:-git}"
RELEASE_MUTABLE="${RELEASE_MUTABLE:-false}"

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
if [[ -n "${RELEASE_EXTRA_ASSETS_FILE:-}" && ! -f "${RELEASE_EXTRA_ASSETS_FILE}" ]]; then
  printf 'release extra-assets manifest is missing: %s\n' "${RELEASE_EXTRA_ASSETS_FILE}" >&2
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

case "${PUBLISH_REF_TYPE}:${RELEASE_MUTABLE}" in
  tag:false)
    ;;
  branch:true)
    if [[ "${RELEASE_TAG}" != "current" ]]; then
      printf 'mutable branch releases must use the current tag, got: %s\n' "${RELEASE_TAG}" >&2
      exit 2
    fi
    ;;
  tag:true)
    printf 'stable release tags must be immutable: %s\n' "${RELEASE_TAG}" >&2
    exit 2
    ;;
  branch:false)
    printf 'branch releases must explicitly opt into the mutable current tag\n' >&2
    exit 2
    ;;
  *)
    printf 'invalid release mutability value: %s\n' "${RELEASE_MUTABLE}" >&2
    exit 2
    ;;
esac

release_assets=(
  "${RELEASE_ASSET_PATH}"
  "${RELEASE_CHECKSUM_PATH}"
)
if [[ -n "${RELEASE_HIGHLIGHTS_PATH:-}" ]]; then
  release_assets+=("${RELEASE_HIGHLIGHTS_PATH}")
fi
if [[ -n "${RELEASE_EXTRA_ASSETS_FILE:-}" ]]; then
  while IFS= read -r asset_path; do
    [[ -n "${asset_path}" ]] || continue
    if [[ ! -f "${asset_path}" ]]; then
      printf 'release extra asset is missing: %s\n' "${asset_path}" >&2
      exit 2
    fi
    release_assets+=("${asset_path}")
  done < "${RELEASE_EXTRA_ASSETS_FILE}"
fi

if [[ "${published_release_state}" == "exists" ]]; then
  if [[ "${RELEASE_MUTABLE}" != "true" ]]; then
    printf 'release %s already exists; published releases are immutable\n' \
      "${RELEASE_TAG}" >&2
    exit 1
  fi

  # Keep the current release continuously available. Upload and edit it in
  # place, then advance the mutable tag only after the new assets and notes are
  # visible. Stable release tags never use this path.
  "${GH}" release upload "${RELEASE_TAG}" "${release_assets[@]}" \
    --repo "${RELEASE_REPOSITORY}" --clobber
  "${GH}" release edit "${RELEASE_TAG}" \
    --repo "${RELEASE_REPOSITORY}" \
    --title "${RELEASE_TITLE}" \
    --notes-file "${RELEASE_NOTES_FILE}" \
    --target "${PUBLISH_SHA}" \
    --prerelease

  # `current` is a lightweight, mutable pointer. Explicitly disable signing so
  # a developer-level tag.gpgSign setting cannot open an annotation editor.
  "${GIT}" tag --no-sign --force "${RELEASE_TAG}" "${PUBLISH_SHA}"
  "${GIT}" push --force origin "refs/tags/${RELEASE_TAG}"
  exit 0
fi

if [[ "${PUBLISH_REF_TYPE}" == "branch" ]]; then
  # Create the explicit current tag before the first prerelease. This avoids a
  # GitHub release with only an implicit target and makes the mutable lane
  # visible and verifiable in the tag list from its first publication.
  "${GIT}" tag --no-sign --force "${RELEASE_TAG}" "${PUBLISH_SHA}"
  "${GIT}" push --force origin "refs/tags/${RELEASE_TAG}"
fi

create_args=(
  "${release_assets[@]}" \
  --repo "${RELEASE_REPOSITORY}"
  --title "${RELEASE_TITLE}"
  --notes-file "${RELEASE_NOTES_FILE}"
)
if [[ "${PUBLISH_REF_TYPE}" == "tag" || "${PUBLISH_REF_TYPE}" == "branch" ]]; then
  create_args+=(--verify-tag)
else
  create_args+=(--target "${PUBLISH_SHA}")
fi
create_args+=("${release_flags[@]}")

exec "${GH}" release create "${RELEASE_TAG}" "${create_args[@]}"
