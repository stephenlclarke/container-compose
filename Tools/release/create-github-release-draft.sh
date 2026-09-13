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
RETRY_ATTEMPTS="${RELEASE_GITHUB_RETRY_ATTEMPTS:-5}"
RETRY_DELAY_SECONDS="${RELEASE_GITHUB_RETRY_DELAY_SECONDS:-5}"
RELEASE_TARGET_COMMITISH="${RELEASE_TARGET_COMMITISH:-main}"

required_variables=(
  PUBLISH_SHA
  RELEASE_LATEST
  RELEASE_NOTES_FILE
  RELEASE_PRERELEASE
  RELEASE_REPOSITORY
  RELEASE_TAG
  RELEASE_TITLE
)
for variable in "${required_variables[@]}"; do
  if [[ -z "${!variable:-}" ]]; then
    printf '%s is required\n' "${variable}" >&2
    exit 2
  fi
done
if [[ ! -f "${RELEASE_NOTES_FILE}" || -L "${RELEASE_NOTES_FILE}" ]]; then
  printf 'release notes file is missing or unsafe: %s\n' \
    "${RELEASE_NOTES_FILE}" >&2
  exit 2
fi
if [[ ! "${PUBLISH_SHA}" =~ ^[0-9a-f]{40}$ ]]; then
  printf 'release target must be a lowercase 40-character commit SHA\n' >&2
  exit 2
fi
if [[ "${RELEASE_TARGET_COMMITISH}" != main ]]; then
  printf 'release target commitish must be the protected default branch\n' >&2
  exit 2
fi
if [[ ! "${RETRY_ATTEMPTS}" =~ ^[1-9][0-9]*$ ]] || \
  ((RETRY_ATTEMPTS > 10)); then
  printf 'release GitHub retry attempts must be between 1 and 10\n' >&2
  exit 2
fi
if [[ ! "${RETRY_DELAY_SECONDS}" =~ ^[0-9]+$ ]] || \
  ((RETRY_DELAY_SECONDS > 60)); then
  printf 'release GitHub retry delay must be between 0 and 60 seconds\n' >&2
  exit 2
fi
case "${RELEASE_LATEST}:${RELEASE_PRERELEASE}" in
  true:true|true:false|false:true|false:false) ;;
  *)
    printf 'release latest and prerelease values must be true or false\n' >&2
    exit 2
    ;;
esac

release_flags=(--prerelease="${RELEASE_PRERELEASE}")
if [[ "${RELEASE_LATEST}" == true ]]; then
  release_flags+=(--latest)
else
  release_flags+=(--latest=false)
fi

matching_draft_exists() {
  local snapshot
  snapshot="$(
    "${GH}" release view "${RELEASE_TAG}" \
      --repo "${RELEASE_REPOSITORY}" \
      --json isDraft,isPrerelease,tagName,targetCommitish,name 2>/dev/null
  )" || return 1
  jq -e \
    --argjson prerelease "${RELEASE_PRERELEASE}" \
    --arg tag "${RELEASE_TAG}" \
    --arg target "${RELEASE_TARGET_COMMITISH}" \
    --arg title "${RELEASE_TITLE}" \
    '(
      .isDraft == true and
      .isPrerelease == $prerelease and
      .tagName == $tag and
      .targetCommitish == $target and
      .name == $title
    )' <<<"${snapshot}" >/dev/null
}

attempt=1
while true; do
  set +e
  create_output="$(
    "${GH}" release create "${RELEASE_TAG}" \
      --repo "${RELEASE_REPOSITORY}" \
      --title "${RELEASE_TITLE}" \
      --notes-file "${RELEASE_NOTES_FILE}" \
      --target "${RELEASE_TARGET_COMMITISH}" \
      --verify-tag \
      "${release_flags[@]}" \
      --draft 2>&1
  )"
  create_status=$?
  set -e
  if ((create_status == 0)); then
    exit 0
  fi

  # A failed response is ambiguous: GitHub may have committed the draft before
  # returning a transient 5xx. Accept only the exact draft identity requested.
  if matching_draft_exists; then
    exit 0
  fi
  if ((attempt >= RETRY_ATTEMPTS)); then
    printf 'could not create exact release draft after %s attempts:\n%s\n' \
      "${RETRY_ATTEMPTS}" "${create_output}" >&2
    exit "${create_status}"
  fi
  printf 'GitHub release creation attempt %s/%s failed; retrying exact draft\n' \
    "${attempt}" "${RETRY_ATTEMPTS}" >&2
  if ((RETRY_DELAY_SECONDS > 0)); then
    sleep "${RETRY_DELAY_SECONDS}"
  fi
  ((attempt += 1))
done
