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
RELEASE_PHASE="${RELEASE_PHASE:-publish}"

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
  output="$("${GH}" api "repos/${RELEASE_REPOSITORY}/releases/tags/${RELEASE_TAG}" 2>&1)"
  status=$?
  set -e

  if (( status == 0 )); then
    if [[ -n "${output}" ]] && \
      [[ "$(jq -r 'if .draft == true then "draft" else "published" end' \
        <<<"${output}" 2>/dev/null || true)" == draft ]]; then
      printf 'draft\n'
    else
      printf 'exists\n'
    fi
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
    if [[ -z "${RELEASE_RETAINED_COMPLETE_MANIFEST:-}" || \
      ! -f "${RELEASE_RETAINED_COMPLETE_MANIFEST}" || \
      -L "${RELEASE_RETAINED_COMPLETE_MANIFEST}" ]]; then
      printf 'stable publication requires a durable retained-complete manifest\n' >&2
      exit 2
    fi
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

# A stable release is created once. The mutable current lane is deliberately
# split into two resumable phases:
#
#   stage    upload immutable, commit-addressed assets while the existing tap
#            formulae and current tag remain usable;
#   finalize advance the current tag and edit the existing mutable release
#            after the matching Homebrew formula pair has been committed. The
#            release object remains available throughout interruption recovery;
#            build freshness is carried by explicit metadata, not published_at.
#
# GitHub releases and the Homebrew tap are separate repositories, so this is
# not a distributed transaction. It does guarantee that an interrupted current
# publication leaves the previously installed package valid and can be resumed
# without rebuilding or replacing its candidate assets.
case "${PUBLISH_REF_TYPE}:${RELEASE_PHASE}" in
  tag:publish)
    ;;
  tag:stage|tag:finalize)
    printf 'stable releases support only the publish phase, got: %s\n' "${RELEASE_PHASE}" >&2
    exit 2
    ;;
  branch:stage|branch:finalize)
    ;;
  branch:publish)
    printf 'mutable current releases require an explicit stage or finalize phase\n' >&2
    exit 2
    ;;
  *)
    printf 'unsupported release publish phase: %s for %s\n' \
      "${RELEASE_PHASE}" "${PUBLISH_REF_TYPE}" >&2
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

move_current_tag() {
  # `current` is a lightweight, mutable pointer. Explicitly disable signing so
  # a developer-level tag.gpgSign setting cannot open an annotation editor.
  "${GIT}" tag --no-sign --force "${RELEASE_TAG}" "${PUBLISH_SHA}"
  "${GIT}" push --force origin "refs/tags/${RELEASE_TAG}"
}

create_release() {
  "${GH}" release create "${RELEASE_TAG}" "${create_args[@]}"
}

create_stable_draft() {
  "${GH}" release create "${RELEASE_TAG}" --repo "${RELEASE_REPOSITORY}" \
    --title "${RELEASE_TITLE}" --notes-file "${RELEASE_NOTES_FILE}" \
    --verify-tag "${release_flags[@]}" --draft
}

reconcile_stable_draft() {
  local temporary remote_names expected_names asset name downloaded count
  if [[ "$("${GIT}" rev-list -n 1 "refs/tags/${RELEASE_TAG}")" != "${PUBLISH_SHA}" ]]; then
    printf 'stable draft tag no longer resolves to the requested candidate: %s\n' \
      "${RELEASE_TAG}" >&2
    return 1
  fi
  remote_names="$("${GH}" release view "${RELEASE_TAG}" \
    --repo "${RELEASE_REPOSITORY}" --json assets --jq '.assets[].name')"
  expected_names=""
  for asset in "${release_assets[@]}"; do
    name="$(basename "${asset}")"
    if grep -Fqx -- "${name}" <<<"${expected_names}"; then
      printf 'stable draft candidate contains a duplicate asset name: %s\n' \
        "${name}" >&2
      return 1
    fi
    expected_names+="${name}"$'\n'
  done
  while IFS= read -r name; do
    [[ -n "${name}" ]] || continue
    if ! grep -Fqx -- "${name}" <<<"${expected_names}"; then
      printf 'stable draft contains an unexpected asset: %s\n' "${name}" >&2
      return 1
    fi
    count="$(grep -Fxc -- "${name}" <<<"${remote_names}" || true)"
    if (( count != 1 )); then
      printf 'stable draft contains a duplicate asset name: %s\n' "${name}" >&2
      return 1
    fi
  done <<<"${remote_names}"
  temporary="$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/stable-draft-assets.XXXXXX")"
  trap 'find "${temporary}" -depth -delete >/dev/null 2>&1 || true' RETURN
  for asset in "${release_assets[@]}"; do
    name="$(basename "${asset}")"
    if grep -Fqx "${name}" <<<"${remote_names}"; then
      "${GH}" release download "${RELEASE_TAG}" --repo "${RELEASE_REPOSITORY}" \
        --pattern "${name}" --dir "${temporary}"
      downloaded="${temporary}/${name}"
      if [[ ! -f "${downloaded}" ]] || \
        [[ "$(shasum -a 256 "${downloaded}" | awk '{print $1}')" != \
          "$(shasum -a 256 "${asset}" | awk '{print $1}')" ]]; then
        printf 'stable draft asset conflicts with retained candidate: %s\n' \
          "${name}" >&2
        return 1
      fi
    else
      "${GH}" release upload "${RELEASE_TAG}" "${asset}" \
        --repo "${RELEASE_REPOSITORY}"
    fi
  done
  "${GH}" release edit "${RELEASE_TAG}" --repo "${RELEASE_REPOSITORY}" \
    --draft=false "${release_flags[@]}"
}

if [[ "${published_release_state}" == "draft" ]]; then
  if [[ "${RELEASE_MUTABLE}" == "true" ]]; then
    printf 'mutable current release unexpectedly exists as a draft\n' >&2
    exit 1
  fi
  reconcile_stable_draft
  exit 0
fi

if [[ "${published_release_state}" == "exists" ]]; then
  if [[ "${RELEASE_MUTABLE}" != "true" ]]; then
    printf 'release %s already exists; published releases are immutable\n' \
      "${RELEASE_TAG}" >&2
    exit 1
  fi

  if [[ "${RELEASE_PHASE}" == "stage" ]]; then
    "${GH}" release upload "${RELEASE_TAG}" "${release_assets[@]}" \
      --repo "${RELEASE_REPOSITORY}" --clobber
    exit 0
  fi

  move_current_tag
  # Re-uploading is idempotent and makes finalization recover from a partially
  # staged asset set without creating an availability window.
  "${GH}" release upload "${RELEASE_TAG}" "${release_assets[@]}" \
    --repo "${RELEASE_REPOSITORY}" --clobber
  "${GH}" release edit "${RELEASE_TAG}" \
    --repo "${RELEASE_REPOSITORY}" \
    --target "${PUBLISH_SHA}" \
    --title "${RELEASE_TITLE}" \
    --notes-file "${RELEASE_NOTES_FILE}" \
    "${release_flags[@]}"
  exit 0
fi

if [[ "${PUBLISH_REF_TYPE}" == "branch" ]]; then
  # Create the explicit current tag before the first prerelease or a recovered
  # finalization. This avoids an implicit target and keeps the lane verifiable.
  move_current_tag
fi

if [[ "${PUBLISH_REF_TYPE}" == "tag" ]]; then
  create_stable_draft
  reconcile_stable_draft
else
  create_release
fi

if [[ "${PUBLISH_REF_TYPE}" == "branch" && "${RELEASE_PHASE}" == "finalize" ]]; then
  "${GH}" release edit "${RELEASE_TAG}" \
    --repo "${RELEASE_REPOSITORY}" \
    --target "${PUBLISH_SHA}" \
    --prerelease
fi
