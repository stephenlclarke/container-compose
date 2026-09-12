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
release_flags+=(--prerelease="${RELEASE_PRERELEASE}")
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
    if [[ "${RELEASE_TAG}" != "current-${PUBLISH_SHA}" ]]; then
      printf 'Current branch releases must use their exact source tag, got: %s\n' \
        "${RELEASE_TAG}" >&2
      exit 2
    fi
    ;;
  tag:true)
    printf 'stable release tags must be immutable: %s\n' "${RELEASE_TAG}" >&2
    exit 2
    ;;
  branch:false)
    printf 'branch releases must explicitly select the Current lane\n' >&2
    exit 2
    ;;
  *)
    printf 'invalid release mutability value: %s\n' "${RELEASE_MUTABLE}" >&2
    exit 2
    ;;
esac

# Every release is created once and becomes immutable. The Current lane uses a
# content-addressed tag and is split into two resumable phases:
#
#   stage    publish the complete exact-SHA prerelease while the existing tap
#            formulae remain usable;
#   finalize verify that immutable release after the matching Homebrew formula
#            pair has been committed.
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
    printf 'Current releases require an explicit stage or finalize phase\n' >&2
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

publish_current_tag() {
  local local_target remote_target
  if [[ "${RELEASE_TAG}" != "current-${PUBLISH_SHA}" ]]; then
    printf 'Current release tag must contain the exact source commit: %s\n' \
      "${RELEASE_TAG}" >&2
    return 1
  fi
  remote_target="$(
    "${GIT}" ls-remote --tags --refs origin "refs/tags/${RELEASE_TAG}" |
      awk '{ print $1 }' | tail -n 1
  )"
  if [[ -n "${remote_target}" && "${remote_target}" != "${PUBLISH_SHA}" ]]; then
    printf 'immutable Current tag %s already targets %s, not %s\n' \
      "${RELEASE_TAG}" "${remote_target}" "${PUBLISH_SHA}" >&2
    return 1
  fi
  local_target="$(
    "${GIT}" rev-parse --verify -q "refs/tags/${RELEASE_TAG}^{commit}" || true
  )"
  if [[ -n "${local_target}" && "${local_target}" != "${PUBLISH_SHA}" ]]; then
    printf 'local immutable Current tag %s already targets %s, not %s\n' \
      "${RELEASE_TAG}" "${local_target}" "${PUBLISH_SHA}" >&2
    return 1
  fi
  if [[ -z "${local_target}" ]]; then
    # Explicitly disable signing so a developer-level tag.gpgSign setting
    # cannot open an annotation editor for this generated identity.
    "${GIT}" tag --no-sign "${RELEASE_TAG}" "${PUBLISH_SHA}"
  fi
  if [[ -z "${remote_target}" ]]; then
    "${GIT}" push origin "refs/tags/${RELEASE_TAG}"
  fi
}

create_release_draft() {
  "${GH}" release create "${RELEASE_TAG}" --repo "${RELEASE_REPOSITORY}" \
    --title "${RELEASE_TITLE}" --notes-file "${RELEASE_NOTES_FILE}" \
    --target "${PUBLISH_SHA}" --verify-tag "${release_flags[@]}" --draft
}

# A private draft is staging state, not immutable release authority. If an
# interrupted signing attempt left any conflicting or foreign bytes, replace
# only that draft object after a final exact-state check. Never ask GitHub CLI
# to clean up the source tag: both Current and stable tags are immutable input.
recreate_release_draft() {
  local snapshot remote_tag_sha
  snapshot="$("${GH}" release view "${RELEASE_TAG}" \
    --repo "${RELEASE_REPOSITORY}" \
    --json isDraft,tagName,targetCommitish)"
  if [[ "$(jq -r '.isDraft' <<<"${snapshot}")" != true ||
        "$(jq -r '.tagName' <<<"${snapshot}")" != "${RELEASE_TAG}" ||
        "$(jq -r '.targetCommitish' <<<"${snapshot}")" != "${PUBLISH_SHA}" ]]; then
    printf 'release draft changed before bounded replacement: %s\n' \
      "${RELEASE_TAG}" >&2
    return 1
  fi
  remote_tag_sha="$(
    "${GIT}" ls-remote --tags "https://github.com/${RELEASE_REPOSITORY}.git" \
      "refs/tags/${RELEASE_TAG}" "refs/tags/${RELEASE_TAG}^{}" |
      awk '$2 ~ /\^\{\}$/ { peeled = $1 } $2 !~ /\^\{\}$/ { direct = $1 } END { print peeled ? peeled : direct }'
  )"
  if [[ "${remote_tag_sha}" != "${PUBLISH_SHA}" ]]; then
    printf 'release draft tag changed before bounded replacement: %s\n' \
      "${RELEASE_TAG}" >&2
    return 1
  fi
  "${GH}" release delete "${RELEASE_TAG}" --repo "${RELEASE_REPOSITORY}" --yes
  remote_tag_sha="$(
    "${GIT}" ls-remote --tags "https://github.com/${RELEASE_REPOSITORY}.git" \
      "refs/tags/${RELEASE_TAG}" "refs/tags/${RELEASE_TAG}^{}" |
      awk '$2 ~ /\^\{\}$/ { peeled = $1 } $2 !~ /\^\{\}$/ { direct = $1 } END { print peeled ? peeled : direct }'
  )"
  if [[ "${remote_tag_sha}" != "${PUBLISH_SHA}" ]]; then
    printf 'bounded draft replacement changed immutable tag %s\n' \
      "${RELEASE_TAG}" >&2
    return 1
  fi
  create_release_draft
}

validate_release_draft_asset_names() {
  local remote_names="$1" expected_names="$2" require_complete="$3" name count
  while IFS= read -r name; do
    [[ -n "${name}" ]] || continue
    if ! grep -Fqx -- "${name}" <<<"${expected_names}"; then
      printf 'release draft contains an unexpected asset: %s\n' "${name}" >&2
      return 1
    fi
    count="$(grep -Fxc -- "${name}" <<<"${remote_names}" || true)"
    if (( count != 1 )); then
      printf 'release draft contains a duplicate asset name: %s\n' "${name}" >&2
      return 1
    fi
  done <<<"${remote_names}"
  if [[ "${require_complete}" == "true" ]]; then
    while IFS= read -r name; do
      [[ -n "${name}" ]] || continue
      if ! grep -Fqx -- "${name}" <<<"${remote_names}"; then
        printf 'release draft is missing an uploaded asset: %s\n' "${name}" >&2
        return 1
      fi
    done <<<"${expected_names}"
  fi
}

# Verify GitHub's final asset inventory and server-computed digests immediately
# before making an immutable stable release public.
validate_release_draft_asset_digests() {
  local remote_assets="$1" asset name expected_digest remote_digest count
  for asset in "${release_assets[@]}"; do
    name="$(basename "${asset}")"
    count="$(awk -F '\t' -v name="${name}" '$1 == name { count += 1 } END { print count + 0 }' \
      <<<"${remote_assets}")"
    if (( count != 1 )); then
      printf 'release draft final inventory changed for asset: %s\n' "${name}" >&2
      return 1
    fi
    remote_digest="$(awk -F '\t' -v name="${name}" '$1 == name { print $2 }' \
      <<<"${remote_assets}")"
    expected_digest="sha256:$(shasum -a 256 "${asset}" | awk '{print $1}')"
    if [[ "${remote_digest}" != "${expected_digest}" ]]; then
      printf 'release draft final digest changed for asset: %s\n' "${name}" >&2
      return 1
    fi
  done
}

# GitHub does not support conditional PATCH requests for the release update
# endpoint. The workflow's repository-wide concurrency group is therefore the
# exclusive writer for supported publication and recovery runs. Verify the
# server's immutable post-publication snapshot so a privileged out-of-band
# mutation or a lost publish response can never be reported as success.
validate_published_release_identity() {
  local snapshot="$1"
  local field actual expected
  while IFS=$'\t' read -r field actual expected; do
    if [[ "${actual}" != "${expected}" ]]; then
      printf 'published release %s mismatch: expected %s, got %s\n' \
        "${field}" "${expected}" "${actual}" >&2
      return 1
    fi
  done < <(
    jq -r --arg tag "${RELEASE_TAG}" --arg target "${PUBLISH_SHA}" \
      --arg name "${RELEASE_TITLE}" \
      --argjson prerelease "${RELEASE_PRERELEASE}" \
      '["draft state", .isDraft, false], ["immutability", .isImmutable, true], ["prerelease state", .isPrerelease, $prerelease], ["tag", .tagName, $tag], ["target", .targetCommitish, $target], ["title", .name, $name] | @tsv' \
      <<<"${snapshot}"
  )
}

validate_published_release_metadata() {
  local snapshot="$1"
  local actual_body expected_body
  validate_published_release_identity "${snapshot}"
  actual_body="$(jq -er '.body | strings' <<<"${snapshot}")"
  expected_body="$(<"${RELEASE_NOTES_FILE}")"
  if [[ "${actual_body}" != "${expected_body}" ]]; then
    printf 'published release notes mismatch\n' >&2
    return 1
  fi
}

reconstruct_published_release_notes() {
  local snapshot="$1" remote_assets="$2" destination="$3"
  local body expected_body asset name digest
  local -a replacements=()
  for asset in "${release_assets[@]}"; do
    name="$(basename "${asset}")"
    if [[ "${asset}" != "${RELEASE_ASSET_PATH}" &&
          ! "${name}" =~ ^container-(current-[0-9a-f]{12}|release)-arm64[.]tar[.]gz$ ]]; then
      continue
    fi
    digest="$(awk -F '\t' -v name="${name}" '$1 == name { sub(/^sha256:/, "", $2); print $2 }' \
      <<<"${remote_assets}")"
    if [[ ! "${digest}" =~ ^[0-9a-f]{64}$ ]]; then
      printf 'published release notes asset has no trusted digest: %s\n' \
        "${name}" >&2
      return 1
    fi
    replacements+=("${name}=${digest}")
  done
  python3 - "${RELEASE_NOTES_FILE}" "${destination}" "${replacements[@]}" <<'PY'
import re
import sys
from pathlib import Path

source = Path(sys.argv[1])
destination = Path(sys.argv[2])
notes = source.read_text(encoding="utf-8")
for value in sys.argv[3:]:
    name, digest = value.split("=", 1)
    pattern = re.compile(
        rf"(- `{re.escape(name)}` SHA-256:\n  `)[0-9a-f]{{64}}(`\.)"
    )
    notes, count = pattern.subn(rf"\g<1>{digest}\g<2>", notes)
    if count != 1:
        raise SystemExit(f"release notes do not contain one SHA-256 block for: {name}")
destination.write_text(notes, encoding="utf-8")
PY
  body="$(jq -er '.body | strings' <<<"${snapshot}")"
  expected_body="$(<"${destination}")"
  if [[ "${body}" != "${expected_body}" ]]; then
    printf 'published release notes differ from reconstructed candidate authority\n' >&2
    return 1
  fi
}

# A retry after immutable publication must use the published bytes as its
# authority. Signed/notarized archives can legitimately differ when rebuilt,
# even from identical source, so comparing a fresh build to the immutable
# release would strand a transaction before its Homebrew update. Validate the
# immutable identity and server digests first, then replace local candidates
# with authenticated downloads for all downstream verification and rendering.
restore_published_release_assets() {
  local expected_names="$1"
  local snapshot remote_assets remote_names temporary asset name downloaded
  local remote_digest actual_digest replacement index staged reconstructed_notes
  local -a staged_replacements=()
  local -a staged_destinations=()
  snapshot="$("${GH}" release view "${RELEASE_TAG}" \
    --repo "${RELEASE_REPOSITORY}" \
    --json isDraft,isImmutable,isPrerelease,tagName,targetCommitish,name,body,assets)"
  validate_published_release_identity "${snapshot}"
  remote_assets="$(jq -r '.assets[] | [.name, (.digest // "")] | @tsv' \
    <<<"${snapshot}")"
  remote_names="$(cut -f 1 <<<"${remote_assets}")"
  validate_release_draft_asset_names "${remote_names}" "${expected_names}" true

  temporary="$(mktemp -d \
    "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/published-release-assets.XXXXXX")"
  replacement=""
  trap '
    find "${temporary}" -depth -delete >/dev/null 2>&1 || true
    for staged in "${staged_replacements[@]}"; do
      [[ -n "${staged}" ]] || continue
      find "${staged}" -depth -delete >/dev/null 2>&1 || true
    done
  ' RETURN
  reconstructed_notes="${temporary}/release-notes.md"
  reconstruct_published_release_notes \
    "${snapshot}" "${remote_assets}" "${reconstructed_notes}"
  for asset in "${release_assets[@]}"; do
    name="$(basename "${asset}")"
    remote_digest="$(awk -F '\t' -v name="${name}" '$1 == name { print $2 }' \
      <<<"${remote_assets}")"
    if [[ ! "${remote_digest}" =~ ^sha256:[0-9a-f]{64}$ ]]; then
      printf 'published release asset has no trusted SHA-256 digest: %s\n' \
        "${name}" >&2
      return 1
    fi
    "${GH}" release download "${RELEASE_TAG}" --repo "${RELEASE_REPOSITORY}" \
      --pattern "${name}" --dir "${temporary}"
    downloaded="${temporary}/${name}"
    if [[ ! -f "${downloaded}" ]]; then
      printf 'published release download is missing: %s\n' "${name}" >&2
      return 1
    fi
    actual_digest="sha256:$(shasum -a 256 "${downloaded}" | awk '{print $1}')"
    if [[ "${actual_digest}" != "${remote_digest}" ]]; then
      printf 'published release download digest mismatch: %s\n' "${name}" >&2
      return 1
    fi
  done
  for asset in "${release_assets[@]}"; do
    name="$(basename "${asset}")"
    replacement="$(mktemp "$(dirname "${asset}")/.${name}.published.XXXXXX")"
    cp "${temporary}/${name}" "${replacement}"
    staged_replacements+=("${replacement}")
    staged_destinations+=("${asset}")
  done
  replacement="$(mktemp \
    "$(dirname "${RELEASE_NOTES_FILE}")/.release-notes.published.XXXXXX")"
  cp "${reconstructed_notes}" "${replacement}"
  staged_replacements+=("${replacement}")
  staged_destinations+=("${RELEASE_NOTES_FILE}")

  for index in "${!staged_replacements[@]}"; do
    mv -f "${staged_replacements[${index}]}" "${staged_destinations[${index}]}"
    staged_replacements[${index}]=""
  done
  find "${temporary}" -depth -delete
  trap - RETURN
}

verify_published_release() {
  local expected_names="$1"
  local snapshot remote_assets remote_names latest_tag remote_tag_sha
  snapshot="$("${GH}" release view "${RELEASE_TAG}" \
    --repo "${RELEASE_REPOSITORY}" \
    --json isDraft,isImmutable,isPrerelease,tagName,targetCommitish,name,body,assets)"
  validate_published_release_metadata "${snapshot}"

  remote_assets="$(jq -r '.assets[] | [.name, (.digest // "")] | @tsv' \
    <<<"${snapshot}")"
  remote_names="$(cut -f 1 <<<"${remote_assets}")"
  validate_release_draft_asset_names "${remote_names}" "${expected_names}" true
  validate_release_draft_asset_digests "${remote_assets}"

  latest_tag="$("${GH}" api "repos/${RELEASE_REPOSITORY}/releases/latest" \
    --jq '.tag_name')"
  if [[ "${RELEASE_LATEST}" == "true" && "${latest_tag}" != "${RELEASE_TAG}" ]]; then
    printf 'published release is not latest: expected %s, got %s\n' \
      "${RELEASE_TAG}" "${latest_tag}" >&2
    return 1
  fi
  if [[ "${RELEASE_LATEST}" != "true" && "${latest_tag}" == "${RELEASE_TAG}" ]]; then
    printf 'published release unexpectedly became latest: %s\n' \
      "${RELEASE_TAG}" >&2
    return 1
  fi

  remote_tag_sha="$(
    "${GIT}" ls-remote --tags "https://github.com/${RELEASE_REPOSITORY}.git" \
      "refs/tags/${RELEASE_TAG}" "refs/tags/${RELEASE_TAG}^{}" |
      awk '$2 ~ /\^\{\}$/ { peeled = $1 } $2 !~ /\^\{\}$/ { direct = $1 } END { print peeled ? peeled : direct }'
  )"
  if [[ "${remote_tag_sha}" != "${PUBLISH_SHA}" ]]; then
    printf 'published release tag target mismatch: expected %s, got %s\n' \
      "${PUBLISH_SHA}" "${remote_tag_sha:-missing}" >&2
    return 1
  fi
}

reconcile_release_draft() {
  local temporary verification final_snapshot remote_names remote_assets
  local expected_names asset name downloaded
  local missing_assets=()
  local draft_recreated=false
  if [[ "$("${GIT}" rev-list -n 1 "refs/tags/${RELEASE_TAG}")" != "${PUBLISH_SHA}" ]]; then
    printf 'release draft tag no longer resolves to the requested candidate: %s\n' \
      "${RELEASE_TAG}" >&2
    return 1
  fi
  remote_names="$("${GH}" release view "${RELEASE_TAG}" \
    --repo "${RELEASE_REPOSITORY}" --json assets --jq '.assets[].name')"
  expected_names=""
  for asset in "${release_assets[@]}"; do
    name="$(basename "${asset}")"
    if grep -Fqx -- "${name}" <<<"${expected_names}"; then
      printf 'release draft candidate contains a duplicate asset name: %s\n' \
        "${name}" >&2
      return 1
    fi
    expected_names+="${name}"$'\n'
  done
  if ! validate_release_draft_asset_names \
    "${remote_names}" "${expected_names}" false; then
    recreate_release_draft
    remote_names=""
    draft_recreated=true
  fi
  temporary="$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/release-draft-assets.XXXXXX")"
  verification=""
  trap 'find "${temporary}" -depth -delete >/dev/null 2>&1 || true; if [[ -n "${verification:-}" ]]; then find "${verification}" -depth -delete >/dev/null 2>&1 || true; fi' RETURN
  for asset in "${release_assets[@]}"; do
    name="$(basename "${asset}")"
    if grep -Fqx "${name}" <<<"${remote_names}"; then
      "${GH}" release download "${RELEASE_TAG}" --repo "${RELEASE_REPOSITORY}" \
        --pattern "${name}" --dir "${temporary}"
      downloaded="${temporary}/${name}"
      if [[ ! -f "${downloaded}" ]] || \
        [[ "$(shasum -a 256 "${downloaded}" | awk '{print $1}')" != \
          "$(shasum -a 256 "${asset}" | awk '{print $1}')" ]]; then
        if [[ "${draft_recreated}" == true ]]; then
          printf 'replacement release draft asset conflicts with candidate: %s\n' \
            "${name}" >&2
          return 1
        fi
        find "${temporary}" -depth -delete
        trap - RETURN
        recreate_release_draft
        temporary="$(mktemp -d \
          "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/release-draft-assets.XXXXXX")"
        trap 'find "${temporary}" -depth -delete >/dev/null 2>&1 || true; if [[ -n "${verification:-}" ]]; then find "${verification}" -depth -delete >/dev/null 2>&1 || true; fi' RETURN
        missing_assets=("${release_assets[@]}")
        remote_names=""
        draft_recreated=true
        break
      fi
    else
      missing_assets+=("${asset}")
    fi
  done
  for asset in "${missing_assets[@]}"; do
    "${GH}" release upload "${RELEASE_TAG}" "${asset}" \
      --repo "${RELEASE_REPOSITORY}"
  done
  remote_names="$("${GH}" release view "${RELEASE_TAG}" \
    --repo "${RELEASE_REPOSITORY}" --json assets --jq '.assets[].name')"
  validate_release_draft_asset_names "${remote_names}" "${expected_names}" true
  verification="$(mktemp -d \
    "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/release-draft-final.XXXXXX")"
  for asset in "${release_assets[@]}"; do
    name="$(basename "${asset}")"
    "${GH}" release download "${RELEASE_TAG}" --repo "${RELEASE_REPOSITORY}" \
      --pattern "${name}" --dir "${verification}"
    downloaded="${verification}/${name}"
    if [[ ! -f "${downloaded}" ]] || \
      [[ "$(shasum -a 256 "${downloaded}" | awk '{print $1}')" != \
        "$(shasum -a 256 "${asset}" | awk '{print $1}')" ]]; then
      printf 'release draft asset changed before publication: %s\n' "${name}" >&2
      return 1
    fi
  done
  final_snapshot="$("${GH}" release view "${RELEASE_TAG}" \
    --repo "${RELEASE_REPOSITORY}" --json isDraft,assets)"
  if [[ "$(jq -r '.isDraft' <<<"${final_snapshot}")" != true ]]; then
    printf 'release is no longer a draft before publication: %s\n' \
      "${RELEASE_TAG}" >&2
    return 1
  fi
  remote_assets="$(jq -r '.assets[] | [.name, (.digest // "")] | @tsv' \
    <<<"${final_snapshot}")"
  remote_names="$(cut -f 1 <<<"${remote_assets}")"
  validate_release_draft_asset_names "${remote_names}" "${expected_names}" true
  validate_release_draft_asset_digests "${remote_assets}"
  "${GH}" release edit "${RELEASE_TAG}" --repo "${RELEASE_REPOSITORY}" \
    --target "${PUBLISH_SHA}" --title "${RELEASE_TITLE}" \
    --notes-file "${RELEASE_NOTES_FILE}" \
    --draft=false "${release_flags[@]}"
  verify_published_release "${expected_names}"
}

if [[ "${published_release_state}" == "draft" ]]; then
  reconcile_release_draft
  exit 0
fi

if [[ "${published_release_state}" == "exists" ]]; then
  if [[ "${RELEASE_MUTABLE}" != "true" ]]; then
    expected_names=""
    for asset in "${release_assets[@]}"; do
      name="$(basename "${asset}")"
      if grep -Fqx -- "${name}" <<<"${expected_names}"; then
        printf 'stable release candidate contains a duplicate asset name: %s\n' \
          "${name}" >&2
        exit 1
      fi
      expected_names+="${name}"$'\n'
    done
    restore_published_release_assets "${expected_names}"
    verify_published_release "${expected_names}"
    exit 0
  fi
  expected_names=""
  for asset in "${release_assets[@]}"; do
    name="$(basename "${asset}")"
    if grep -Fqx -- "${name}" <<<"${expected_names}"; then
      printf 'Current release candidate contains a duplicate asset name: %s\n' \
        "${name}" >&2
      exit 1
    fi
    expected_names+="${name}"$'\n'
  done
  restore_published_release_assets "${expected_names}"
  verify_published_release "${expected_names}"
  exit 0
fi

if [[ "${PUBLISH_REF_TYPE}" == "branch" ]]; then
  publish_current_tag
fi

create_release_draft
reconcile_release_draft
