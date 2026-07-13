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

readonly SELF_PATH="${BASH_SOURCE[0]:-$0}"
SCRIPT_NAME="$(basename "${SELF_PATH}")"
readonly SCRIPT_NAME
readonly SCRIPT_USAGE="scripts/${SCRIPT_NAME}"

usage() {
  cat <<USAGE
Usage:
  ${SCRIPT_USAGE} plan
  ${SCRIPT_USAGE} release VERSION_SELECTOR [--execute]

Purpose:
  Coordinate releases for the four local stephenlclarke source repositories
  and the Homebrew tap without touching Apple upstream repositories.

Modes:
  plan
      Inspect the four local source main branches and print the next release
      plan, including the Homebrew tap workflow boundary.
      This mode never mutates repositories.

  release VERSION_SELECTOR
      Deterministically promote the four source repositories and Homebrew tap
      to the next stable release. The version selector is resolved from the
      latest local semantic container-compose tag, not from mutable
      working-tree state. The helper bumps container-compose on main when
      needed, commits that bump, promotes the stephenlclarke source main
      branches, creates and pushes the stable container-compose source tag,
      dispatches the hosted Stable Release Gate, then dispatches the stable
      package workflow only after the gate succeeds. That workflow publishes
      immutable release assets and atomically updates the matching Homebrew
      formula pair. container-compose main promotions use an automated
      short-lived PR by default so pull-request checks and review state remain
      visible before tagging. The Homebrew tap is the only owner of live
      formulae.

      Version selectors:
        9.0.2  use the explicit 9.0.2 stable release version
        --+    increment patch from the latest semantic release tag
        -+-    increment minor and reset patch to 0
        +--    increment major and reset minor and patch to 0

  Source tags are bare MAJOR.MINOR.PATCH for Apple compatibility.

Options:
  --execute
      Run mutating git commands. Without this flag the script is a dry run.

Local source checkout layout expected:
  ~/github/container-builder-shim
  ~/github/containerization
  ~/github/container
  ~/github/container-compose

Rules enforced:
  - Apple remotes are read-only and must not be push targets.
  - stephenlclarke-owned remotes are the only push targets.
  - Worktrees must be clean before release changes.
  - Stable container-compose release tags are SSH-signed and point at the validated main commit.
  - GitHub must verify each stable tag signature before the release gate starts.
  - The hosted Stable Release Gate runs after the signed tag and before stable package publication.
  - Stable package and Homebrew tap updates are explicitly dispatched and waited for.
  - Stable package assets and the Homebrew tap SHA are verified before success.
  - Published stable releases are immutable; only the latest GitHub-verified signed tag may resume before publication.
  - container-compose main updates use pull-request promotion by default.
  - An equivalent tree already squash-merged on main is reconciled before tagging.
  - Long-lived release branches are not used.

Environment:
  CONTAINER_STACK_RELEASE_COMPOSE_MAIN_PROMOTION_MODE=pr|direct
      Use "pr" by default. Use "direct" only for emergency maintenance on
      stephenlclarke/container-compose when branch protection intentionally
      permits direct pushes.

  CONTAINER_STACK_RELEASE_COMPOSE_MAIN_MERGE_MODE=checked-admin|strict
      Use "checked-admin" by default. The helper waits for PR checks, tries a
      normal merge, then uses an admin merge only when GitHub blocks the merge
      on the solo-maintainer review requirement. Use "strict" to fail instead.

  CONTAINER_STACK_RELEASE_PROMOTION_WAIT_SECONDS
  CONTAINER_STACK_RELEASE_PROMOTION_POLL_SECONDS
      Override the default one-hour PR promotion wait and 30-second poll.

  CONTAINER_STACK_STABLE_GATE_WAIT_SECONDS
      Override the default three-hour wait for the hosted Stable Release Gate.
      The default exceeds the gate's 120-minute workflow timeout so a valid
      queued or long-running gate does not prematurely end the local release.

  CONTAINER_STACK_COMPOSE_PACKAGE_WAIT_SECONDS
  CONTAINER_STACK_COMPOSE_PACKAGE_POLL_SECONDS
      Override the default one-hour package workflow wait and 30-second poll.

  CONTAINER_STACK_RELEASE_ROOT
      Override the parent directory containing the four source checkouts and
      the Homebrew tap. Defaults to ~/github. Use an isolated stack root for
      release validation without touching another local workspace.
USAGE
}

MODE=""
VERSION_SELECTOR=""
EXECUTE=0

parse_arguments() {
  MODE="${1:-}"
  if [[ -z "${MODE}" || "${MODE}" == "-h" || "${MODE}" == "--help" ]]; then
    usage
    exit 0
  fi
  shift || true

  VERSION_SELECTOR=""
  EXECUTE=0
  case "${MODE}" in
    plan)
      ;;
    release)
      VERSION_SELECTOR="${1:-}"
      if [[ -z "${VERSION_SELECTOR}" ]]; then
        printf '%s requires VERSION_SELECTOR, for example --+, -+-, +--, or 9.0.2\n' "${MODE}" >&2
        exit 2
      fi
      shift || true
      ;;
    *)
      printf 'unknown mode: %s\n' "${MODE}" >&2
      usage >&2
      exit 2
      ;;
  esac

  while (($#)); do
    case "$1" in
      --execute)
        EXECUTE=1
        shift
        ;;
      *)
        printf 'unknown option: %s\n' "$1" >&2
        usage >&2
        exit 2
        ;;
    esac
  done
}

ROOT="${CONTAINER_STACK_RELEASE_ROOT:-${HOME}/github}"
COMPOSE_REPO="container-compose"
CONTAINER_REPO="container"
COMPOSE_PACKAGE_WAIT_SECONDS="${CONTAINER_STACK_COMPOSE_PACKAGE_WAIT_SECONDS:-3600}"
COMPOSE_PACKAGE_POLL_SECONDS="${CONTAINER_STACK_COMPOSE_PACKAGE_POLL_SECONDS:-30}"
STABLE_RELEASE_GATE_WAIT_SECONDS="${CONTAINER_STACK_STABLE_GATE_WAIT_SECONDS:-10800}"
PROMOTION_WAIT_SECONDS="${CONTAINER_STACK_RELEASE_PROMOTION_WAIT_SECONDS:-3600}"
PROMOTION_POLL_SECONDS="${CONTAINER_STACK_RELEASE_PROMOTION_POLL_SECONDS:-30}"
COMPOSE_MAIN_PROMOTION_MODE="${CONTAINER_STACK_RELEASE_COMPOSE_MAIN_PROMOTION_MODE:-pr}"
COMPOSE_MAIN_MERGE_MODE="${CONTAINER_STACK_RELEASE_COMPOSE_MAIN_MERGE_MODE:-checked-admin}"
HOMEBREW_TAP_REPO="${ROOT}/homebrew-tap"
REPOS=(
  "container-builder-shim"
  "containerization"
  "container"
  "container-compose"
)

# Map local checkout names to their stephenlclarke-owned GitHub repositories.
github_repo() {
  case "$1" in
    container-builder-shim) printf 'stephenlclarke/container-builder-shim' ;;
    containerization) printf 'stephenlclarke/containerization' ;;
    container) printf 'stephenlclarke/container' ;;
    container-compose) printf 'stephenlclarke/container-compose' ;;
  esac
}

# Return the writable stephenlclarke-owned remote for each checkout.
push_remote() {
  case "$1" in
    container|container-builder-shim) printf 'fork' ;;
    *) printf 'origin' ;;
  esac
}

ensure_compose_promotion_mode() {
  case "${COMPOSE_MAIN_PROMOTION_MODE}" in
    pr|direct)
      ;;
    *)
      printf 'invalid CONTAINER_STACK_RELEASE_COMPOSE_MAIN_PROMOTION_MODE: %s\n' "${COMPOSE_MAIN_PROMOTION_MODE}" >&2
      printf 'expected pr or direct\n' >&2
      exit 2
      ;;
  esac
  case "${COMPOSE_MAIN_MERGE_MODE}" in
    checked-admin|strict)
      ;;
    *)
      printf 'invalid CONTAINER_STACK_RELEASE_COMPOSE_MAIN_MERGE_MODE: %s\n' "${COMPOSE_MAIN_MERGE_MODE}" >&2
      printf 'expected checked-admin or strict\n' >&2
      exit 2
      ;;
  esac

  if [[ "${EXECUTE}" == "1" && "${COMPOSE_MAIN_PROMOTION_MODE}" == "pr" ]]; then
    need_command gh
  fi
}

# Print and optionally execute a command.
run() {
  if [[ "${EXECUTE}" == "1" ]]; then
    printf '+ %s\n' "$*"
    "$@"
  else
    printf 'would run: %s\n' "$*"
  fi
}

stephen_https_url() {
  local url="$1"
  case "${url}" in
    git@github.com:stephenlclarke/*)
      printf 'https://github.com/stephenlclarke/%s\n' "${url#git@github.com:stephenlclarke/}"
      ;;
    *)
      return 1
      ;;
  esac
}

fetch_release_remote() {
  local repo="$1" path remote url fallback_url
  path="$(repo_path "${repo}")"
  remote="$(push_remote "${repo}")"
  url="$(git -C "${path}" remote get-url "${remote}")"

  if [[ "${EXECUTE}" != "1" ]]; then
    printf 'would run: git -C %s fetch --prune --tags %s\n' "${path}" "${remote}"
    return 0
  fi

  if fallback_url="$(stephen_https_url "${url}")"; then
    printf 'normalizing %s release remote for %s from %s to %s\n' "${remote}" "${repo}" "${url}" "${fallback_url}" >&2
    git -C "${path}" remote set-url "${remote}" "${fallback_url}"
    url="${fallback_url}"
  fi

  printf '+ git -C %s fetch --prune --tags %s\n' "${path}" "${remote}"
  if git -C "${path}" fetch --prune --tags "${remote}"; then
    return 0
  fi

  if fallback_url="$(stephen_https_url "${url}")"; then
    printf 'fetch from %s failed for %s; switching %s to %s and retrying\n' "${url}" "${repo}" "${remote}" "${fallback_url}" >&2
    git -C "${path}" remote set-url "${remote}" "${fallback_url}"
    printf '+ git -C %s fetch --prune --tags %s\n' "${path}" "${remote}"
    git -C "${path}" fetch --prune --tags "${remote}"
    return 0
  fi

  return 1
}

# Return an absolute checkout path.
repo_path() {
  printf '%s/%s' "${ROOT}" "$1"
}

# Print the builder image repository, tag, and digest compiled by container.
container_builder_image_metadata() {
  local package
  package="$(repo_path "${CONTAINER_REPO}")/Package.swift"
  python3 - "${package}" <<'PY'
from pathlib import Path
import re
import sys

package = Path(sys.argv[1])
text = package.read_text(encoding="utf-8")

def read_default(name: str) -> str:
    match = re.search(rf'let {name} = .*?\?\? "([^"]*)"', text)
    if not match:
        raise SystemExit(f"missing {name} default in {package}")
    return match.group(1)

print(read_default("builderShimRepository"))
print(read_default("builderShimVersion"))
print(read_default("builderShimDigest"))
PY
}

# Emit a visible section header.
print_header() {
  printf '\n== %s ==\n' "$1"
}

# Verify that a checkout exists.
ensure_repo_exists() {
  local repo="$1" path
  path="$(repo_path "${repo}")"
  if [[ ! -d "${path}/.git" ]]; then
    printf 'missing checkout: %s\n' "${path}" >&2
    exit 1
  fi
}

# Refuse to operate on dirty working trees.
ensure_clean() {
  local repo="$1" path status
  path="$(repo_path "${repo}")"
  status="$(git -C "${path}" status --short)"
  if [[ -n "${status}" ]]; then
    printf 'dirty worktree blocks release for %s:\n%s\n' "${repo}" "${status}" >&2
    exit 1
  fi
}

# Run the full release gate locally before any source branch is promoted.
run_local_release_gate() {
  local path repository
  path="$(repo_path "${COMPOSE_REPO}")"
  if [[ ! -f "${HOMEBREW_TAP_REPO}/Formula/container-compose.rb" ]]; then
    printf 'Homebrew tap checkout is required at %s\n' "${HOMEBREW_TAP_REPO}" >&2
    exit 1
  fi

  print_header "run local release gate"
  for repository in "${path}" \
    "$(repo_path "container-builder-shim")" \
    "$(repo_path "containerization")" \
    "$(repo_path "container")"; do
    if [[ "${EXECUTE}" != "1" ]]; then
      printf 'would install Hawkeye in %s\n' "${repository}"
      continue
    fi
    (
      cd "${repository}"
      if [[ "${repository}" == "${path}" ]]; then
        HAWKEYE_AUTO_INSTALL=1 ./scripts/install-hawkeye.sh --auto-install
      else
        ./scripts/install-hawkeye.sh
      fi
    )
  done
  run make -C "$(repo_path "containerization")" fetch-default-kernel
  run env HAWKEYE_AUTO_INSTALL=1 \
    make -C "${path}" release-gate "HOMEBREW_TAP_REPO=${HOMEBREW_TAP_REPO}"
}

# Verify that Apple remotes cannot be pushed and stephenlclarke remotes are the target.
ensure_push_boundary() {
  local repo="$1" path remote url remote_name push_url
  path="$(repo_path "${repo}")"
  remote="$(push_remote "${repo}")"
  url="$(git -C "${path}" remote get-url "${remote}")"
  case "${url}" in
    *github.com/stephenlclarke/*|git@github.com:stephenlclarke/*)
      ;;
    *)
      printf 'push remote for %s is not stephenlclarke-owned: %s %s\n' "${repo}" "${remote}" "${url}" >&2
      exit 1
      ;;
  esac

  while read -r remote_name; do
    while read -r push_url; do
      case "${push_url}" in
        no_push)
          ;;
        *github.com/apple/*|git@github.com:apple/*)
          printf 'remote %s push URL for %s targets Apple; refusing: %s\n' "${remote_name}" "${repo}" "${push_url}" >&2
          exit 1
          ;;
      esac
    done < <(git -C "${path}" remote get-url --push --all "${remote_name}" 2>/dev/null || true)
  done < <(git -C "${path}" remote)

  if [[ "${repo}" == "container" || "${repo}" == "container-builder-shim" ]]; then
    if ! git -C "${path}" remote get-url --push origin 2>/dev/null | grep -qx 'no_push'; then
      printf '%s origin must keep push URL no_push\n' "${repo}" >&2
      exit 1
    fi
  fi
  if [[ "${repo}" == "containerization" ]] && git -C "${path}" remote get-url upstream >/dev/null 2>&1; then
    if ! git -C "${path}" remote get-url --push upstream 2>/dev/null | grep -qx 'no_push'; then
      printf 'containerization upstream must keep push URL no_push\n' >&2
      exit 1
    fi
  fi
}

# Fetch and align the local main branch.
prepare_repo_main() {
  local repo="$1" path remote
  path="$(repo_path "${repo}")"
  remote="$(push_remote "${repo}")"
  ensure_repo_exists "${repo}"
  ensure_clean "${repo}"
  ensure_push_boundary "${repo}"
  fetch_release_remote "${repo}"
  run git -C "${path}" switch main
  run git -C "${path}" pull --rebase --autostash "${remote}" main
  ensure_clean "${repo}"
}

# Prepare every stack participant in release order.
prepare_all_main() {
  local repo
  for repo in "${REPOS[@]}"; do
    prepare_repo_main "${repo}"
  done
}

# Read the compose plugin version from the Makefile.
current_compose_version() {
  sed -n 's/^COMPOSE_VERSION ?= //p' "$(repo_path "${COMPOSE_REPO}")/Makefile" | head -n 1
}

# Resolve an explicit or symbolic version relative to a semantic base version.
resolve_version_selector() {
  local selector="$1" base="$2" major minor patch plus_count
  if [[ ! "${base}" =~ ^[0-9]+[.][0-9]+[.][0-9]+$ ]]; then
    printf 'base version is not semantic: %s\n' "${base}" >&2
    exit 1
  fi

  if [[ "${selector}" =~ ^[0-9]+[.][0-9]+[.][0-9]+$ ]]; then
    printf '%s' "${selector}"
    return 0
  fi

  if [[ "${selector}" =~ ^[+-][+-][+-]$ ]]; then
    plus_count="${selector//[^+]}"
    if [[ "${#plus_count}" != "1" ]]; then
      printf 'increment selector must contain exactly one +: %s\n' "${selector}" >&2
      exit 2
    fi
    IFS=. read -r major minor patch <<<"${base}"
    case "${selector}" in
      +--)
        ((major += 1))
        minor=0
        patch=0
        ;;
      -+-)
        ((minor += 1))
        patch=0
        ;;
      --+)
        ((patch += 1))
        ;;
    esac
    printf '%s.%s.%s' "${major}" "${minor}" "${patch}"
    return 0
  fi

  printf 'invalid version selector: %s\n' "${selector}" >&2
  printf 'expected MAJOR.MINOR.PATCH, --+, -+-, or +--\n' >&2
  exit 2
}

# Resolve the release version from the latest semantic tag, not mutable files.
resolve_release_version() {
  local latest
  latest="$(latest_local_semver_tag "${COMPOSE_REPO}")"
  if [[ -z "${latest}" ]]; then
    latest="$(current_compose_version)"
  fi
  resolve_version_selector "$1" "${latest}"
}

ensure_release_version_is_valid() {
  local latest="$1" current="$2" version="$3"
  python3 - "$latest" "$current" "$version" <<'PY'
import sys

def parse(value):
    return tuple(int(part) for part in value.split("."))

latest, current, version = map(parse, sys.argv[1:])
if version <= latest:
    raise SystemExit(
        f"release version {sys.argv[3]} must be newer than latest release tag {sys.argv[1]}"
    )
if current > version:
    raise SystemExit(
        f"COMPOSE_VERSION {sys.argv[2]} is newer than requested release {sys.argv[3]}"
    )
PY
}

# Return the latest local semantic tag for a repo, if one exists.
latest_local_semver_tag() {
  local repo="$1"
  git -C "$(repo_path "${repo}")" tag --list '[0-9]*.[0-9]*.[0-9]*' \
    | python3 -c 'import re, sys
versions = [line.strip() for line in sys.stdin if re.fullmatch(r"[0-9]+[.][0-9]+[.][0-9]+", line.strip())]
versions.sort(key=lambda version: tuple(int(part) for part in version.split(".")))
print(versions[-1] if versions else "")
'
}

# Decide whether a repository changed since its latest local semver tag.
repo_changed_since_latest_tag() {
  local repo="$1" latest main_commit tag_commit path
  latest="$(latest_local_semver_tag "${repo}")"
  if [[ -z "${latest}" ]]; then
    return 0
  fi
  path="$(repo_path "${repo}")"
  main_commit="$(git -C "${path}" rev-parse main)"
  tag_commit="$(git -C "${path}" rev-list -n 1 "${latest}")"
  if [[ "${main_commit}" == "${tag_commit}" ]]; then
    return 1
  fi

  return 0
}

# Refuse to reuse a stable tag before any release-boundary mutation occurs.
ensure_new_stable_release() {
  local version="$1" path remote
  path="$(repo_path "${COMPOSE_REPO}")"
  remote="$(push_remote "${COMPOSE_REPO}")"

  if git -C "${path}" rev-parse -q --verify "refs/tags/${version}" >/dev/null; then
    printf 'stable tag already exists locally: %s\n' "${version}" >&2
    exit 1
  fi
  if git -C "${path}" ls-remote --exit-code --tags "${remote}" "refs/tags/${version}" >/dev/null 2>&1; then
    printf 'stable tag already exists remotely: %s\n' "${version}" >&2
    exit 1
  fi
}

# Return success when the semantic source tag already exists locally or remotely.
stable_tag_exists() {
  local version="$1" path remote
  path="$(repo_path "${COMPOSE_REPO}")"
  remote="$(push_remote "${COMPOSE_REPO}")"

  if git -C "${path}" rev-parse -q --verify "refs/tags/${version}" >/dev/null; then
    return 0
  fi
  git -C "${path}" ls-remote --exit-code --tags "${remote}" "refs/tags/${version}" >/dev/null 2>&1
}

# Reject a stale unpublished tag so a retry cannot replace a newer stable lane.
ensure_latest_stable_retry() {
  local version="$1" latest
  latest="$(latest_local_semver_tag "${COMPOSE_REPO}")"
  if [[ "${version}" != "${latest}" ]]; then
    printf 'stable tag %s is not the latest semantic source tag (%s)\n' \
      "${version}" "${latest:-missing}" >&2
    exit 1
  fi
}

# Refuse to retry a semantic tag once GitHub has made it a published release.
ensure_stable_release_is_unpublished() {
  local version="$1" output status
  if [[ "${EXECUTE}" != "1" ]]; then
    printf 'would verify that stable release %s is unpublished\n' "${version}"
    return 0
  fi

  need_command gh
  if output="$(github_cli release view "${version}" \
    --repo "$(github_repo "${COMPOSE_REPO}")" \
    --json id 2>&1)"; then
    printf 'stable release %s already exists and is immutable\n' "${version}" >&2
    exit 1
  else
    status="$?"
  fi

  if grep -Eqi 'release not found|HTTP 404' <<<"${output}"; then
    return 0
  fi

  printf 'could not determine whether stable release %s exists (gh exit %s):\n%s\n' \
    "${version}" "${status}" "${output}" >&2
  exit 1
}

# Require GitHub to recognise the signature on a newly-pushed stable tag. A
# local signature alone is not enough: it must be associated with the GitHub
# account that publishes this release.
verify_github_stable_tag_signature() {
  local version="$1" tag_object verification reason

  if [[ "${EXECUTE}" != "1" ]]; then
    printf 'would verify GitHub recognises the SSH signature for stable tag %s\n' "${version}"
    return 0
  fi

  need_command gh
  tag_object="$(
    gh api "repos/$(github_repo "${COMPOSE_REPO}")/git/ref/tags/${version}" \
      --jq '.object.sha'
  )"
  verification="$(
    gh api "repos/$(github_repo "${COMPOSE_REPO}")/git/tags/${tag_object}" \
      --jq '.verification.verified'
  )"
  reason="$(
    gh api "repos/$(github_repo "${COMPOSE_REPO}")/git/tags/${tag_object}" \
      --jq '.verification.reason'
  )"
  if [[ "${verification}" != "true" ]]; then
    printf 'GitHub did not verify stable tag %s (reason: %s)\n' \
      "${version}" "${reason:-missing}" >&2
    exit 1
  fi
}

# Create a new signed stable tag at the validated current container-compose
# main commit. Current-package tags are disposable release pointers; this is
# the permanent source identity that users and Homebrew trust.
tag_new_stable_version() {
  local version="$1" path remote
  path="$(repo_path "${COMPOSE_REPO}")"
  remote="$(push_remote "${COMPOSE_REPO}")"
  ensure_new_stable_release "${version}"
  run git -C "${path}" tag -s "${version}" main -m "$(github_repo "${COMPOSE_REPO}") ${version}"
  run git -C "${path}" push "${remote}" "refs/tags/${version}"
  verify_github_stable_tag_signature "${version}"
}

print_component_refs() {
  local repo path
  printf '\nComponent refs recorded by package metadata or companion release processes:\n'
  for repo in "${REPOS[@]}"; do
    path="$(repo_path "${repo}")"
    printf '  %-26s %s\n' "${repo}" "$(git -C "${path}" rev-parse main)"
  done
}

# Update one SwiftPM manifest to the current containerization stack revision.
update_containerization_package_pin() {
  local repo="$1" ref="$2" path
  path="$(repo_path "${repo}")"

  if [[ "${EXECUTE}" != "1" ]]; then
    printf 'would pin %s Package.swift containerization dependency to %s\n' "${repo}" "${ref}"
    return 0
  fi

  python3 - "${path}/Package.swift" "${ref}" <<'PY'
from pathlib import Path
import re
import sys

package = Path(sys.argv[1])
ref = sys.argv[2]
text = package.read_text(encoding="utf-8")
pattern = re.compile(
    r'(\.package\(\s*url:\s*"https://github.com/stephenlclarke/containerization\.git"\s*,\s*)'
    r'(?:branch|revision):\s*"[^"]*"'
    r"(\s*,?\s*\))",
    re.MULTILINE,
)
updated, count = pattern.subn(rf'\1revision: "{ref}"\2', text, count=1)
if count != 1:
    raise SystemExit(f"{package} is missing the stephenlclarke containerization dependency")
package.write_text(updated, encoding="utf-8")
PY
  run swift package --package-path "${path}" resolve
}

# Commit a SwiftPM containerization pin update when the manifest or lockfile changed.
commit_containerization_package_pin() {
  local repo="$1" ref="$2" path short_ref
  path="$(repo_path "${repo}")"
  short_ref="${ref:0:12}"

  if [[ "${EXECUTE}" != "1" ]]; then
    printf 'would commit %s containerization pin update if needed\n' "${repo}"
    return 0
  fi

  run git -C "${path}" add Package.swift Package.resolved
  if git -C "${path}" diff --cached --quiet -- Package.swift Package.resolved; then
    printf '%s containerization package pin already points at %s\n' "${repo}" "${ref}"
    return 0
  fi

  run git -C "${path}" commit \
    -m "chore(deps): pin containerization ${short_ref}" \
    -m "Release-Note: none"
}

# Keep the container and compose manifests aligned with the stack containerization checkout.
sync_containerization_package_pins() {
  local ref
  ref="$(git -C "$(repo_path "containerization")" rev-parse main)"
  print_header "sync exact containerization SwiftPM pins"
  update_containerization_package_pin "${CONTAINER_REPO}" "${ref}"
  commit_containerization_package_pin "${CONTAINER_REPO}" "${ref}"
  update_containerization_package_pin "${COMPOSE_REPO}" "${ref}"
  commit_containerization_package_pin "${COMPOSE_REPO}" "${ref}"
}

write_release_stack_manifest() {
  local path manifest builder_ref containerization_ref container_ref builder_image_metadata builder_image_repository builder_image_tag builder_image_digest
  path="$(repo_path "${COMPOSE_REPO}")"
  manifest="${path}/Tools/release/stack-refs.json"
  builder_ref="$(git -C "$(repo_path "container-builder-shim")" rev-parse main)"
  containerization_ref="$(git -C "$(repo_path "containerization")" rev-parse main)"
  container_ref="$(git -C "$(repo_path "container")" rev-parse main)"
  builder_image_metadata="$(container_builder_image_metadata)"
  builder_image_repository="$(printf '%s\n' "${builder_image_metadata}" | sed -n '1p')"
  builder_image_tag="$(printf '%s\n' "${builder_image_metadata}" | sed -n '2p')"
  builder_image_digest="$(printf '%s\n' "${builder_image_metadata}" | sed -n '3p')"

  if [[ "${EXECUTE}" != "1" ]]; then
    printf 'would update: %s\n' "${manifest}"
    printf '  container-builder-shim: %s\n' "${builder_ref}"
    printf '  builder image:          %s:%s@%s\n' "${builder_image_repository}" "${builder_image_tag}" "${builder_image_digest}"
    printf '  containerization:       %s\n' "${containerization_ref}"
    printf '  container:              %s\n' "${container_ref}"
    return 0
  fi

  python3 - "${manifest}" "${builder_ref}" "${builder_image_repository}" "${builder_image_tag}" "${builder_image_digest}" "${containerization_ref}" "${container_ref}" <<'PY'
from pathlib import Path
import json
import sys

manifest = Path(sys.argv[1])
manifest.parent.mkdir(parents=True, exist_ok=True)
data = {
    "schemaVersion": 1,
    "components": {
        "container-builder-shim": {
            "repository": "stephenlclarke/container-builder-shim",
            "ref": sys.argv[2],
            "image": {
                "repository": sys.argv[3],
                "tag": sys.argv[4],
                "digest": sys.argv[5],
            },
        },
        "containerization": {
            "repository": "stephenlclarke/containerization",
            "ref": sys.argv[6],
        },
        "container": {
            "repository": "stephenlclarke/container",
            "ref": sys.argv[7],
        },
    },
}
manifest.write_text(json.dumps(data, indent=2, sort_keys=True) + "\n", encoding="utf-8")
PY
}

remote_main_commit() {
  local repo="$1" path remote
  path="$(repo_path "${repo}")"
  remote="$(push_remote "${repo}")"
  git -C "${path}" ls-remote --heads "${remote}" refs/heads/main | awk '{print $1}'
}

compose_promotion_branch_name() {
  local purpose="$1" version="$2" path short_ref
  path="$(repo_path "${COMPOSE_REPO}")"
  short_ref="$(git -C "${path}" rev-parse --short=12 main)"
  printf 'release/%s-%s-%s\n' "${purpose}" "${version}" "${short_ref}"
}

compose_source_promotion_body() {
  local version="$1" path head
  path="$(repo_path "${COMPOSE_REPO}")"
  head="$(git -C "${path}" rev-parse main)"
  cat <<EOF
Promotes the container-compose source candidate for ${version}.

Validation:
- The hosted Stable Release Gate must pass before stable package publication.
- The promoted main tree must match this candidate before tagging.
- Apple upstream remotes remain read-only; only stephenlclarke-owned remotes are push targets.

Candidate:
- container-compose: ${head}
EOF
}

open_compose_promotion_pr() {
  local branch="$1" title="$2" body="$3" repo existing url
  repo="$(github_repo "${COMPOSE_REPO}")"
  existing="$(
    github_cli pr list \
      --repo "${repo}" \
      --head "${branch}" \
      --state open \
      --json number,url \
      --jq '.[0] | select(.number != null) | [.number, .url] | @tsv'
  )"

  if [[ -n "${existing}" ]]; then
    IFS=$'\t' read -r COMPOSE_PROMOTION_PR_NUMBER COMPOSE_PROMOTION_PR_URL <<<"${existing}"
    printf 'container-compose promotion PR already open: %s\n' "${COMPOSE_PROMOTION_PR_URL}"
    return 0
  fi

  url="$(
    github_cli pr create \
      --repo "${repo}" \
      --base main \
      --head "${branch}" \
      --title "${title}" \
      --body "${body}"
  )"
  COMPOSE_PROMOTION_PR_URL="${url}"
  COMPOSE_PROMOTION_PR_NUMBER="$(
    github_cli pr view "${url}" \
      --repo "${repo}" \
      --json number \
      --jq '.number'
  )"
  github_cli pr edit "${COMPOSE_PROMOTION_PR_NUMBER}" \
    --repo "${repo}" \
    --add-assignee "@me"
  printf 'container-compose promotion PR opened: %s\n' "${COMPOSE_PROMOTION_PR_URL}"
}

wait_for_compose_pr_checks() {
  local number="$1" repo deadline now status check_mode output
  local check_args=()
  repo="$(github_repo "${COMPOSE_REPO}")"
  deadline=$((SECONDS + PROMOTION_WAIT_SECONDS))
  check_mode="$(compose_pr_check_mode "${number}" "${repo}")"
  if [[ "${check_mode}" == "required" ]]; then
    check_args=(--required)
  else
    printf 'no required checks configured for container-compose PR #%s; waiting for all PR checks\n' "${number}"
  fi

  while true; do
    if output="$(github_cli pr checks "${number}" \
      --repo "${repo}" \
      "${check_args[@]}" 2>&1)"; then
      status=0
    else
      status="$?"
    fi
    case "${status}" in
      0)
        printf 'container-compose promotion PR checks passed: #%s\n' "${number}"
        return 0
        ;;
      8)
        ;;
      *)
        if grep -qi 'no checks reported' <<<"${output}"; then
          :
        else
          printf '%s\n' "${output}" >&2
          printf 'container-compose promotion PR checks failed: #%s\n' "${number}" >&2
          exit 1
        fi
        ;;
    esac

    now="${SECONDS}"
    if (( now >= deadline )); then
      printf 'timed out waiting for container-compose promotion PR checks: #%s\n' "${number}" >&2
      exit 1
    fi

    printf 'waiting for container-compose promotion PR checks #%s; next check in %ss\n' \
      "${number}" "${PROMOTION_POLL_SECONDS}"
    sleep "${PROMOTION_POLL_SECONDS}"
  done
}

compose_pr_check_mode() {
  local number="$1" repo="$2" output status
  if output="$(github_cli pr checks "${number}" \
    --repo "${repo}" \
    --required 2>&1)"; then
    printf 'required'
    return 0
  else
    status="$?"
  fi

  if [[ "${status}" == "8" ]]; then
    printf 'required'
    return 0
  fi
  if grep -Eqi 'no (required )?checks reported' <<<"${output}"; then
    printf 'all'
    return 0
  fi

  printf '%s\n' "${output}" >&2
  printf 'unable to inspect container-compose promotion PR checks: #%s\n' "${number}" >&2
  exit 1
}

# Wait for a promotion pull request to reach GitHub's merged state.
wait_for_compose_pr_merged() {
  local number="$1" repo deadline now details state merged_at url
  repo="$(github_repo "${COMPOSE_REPO}")"
  deadline=$((SECONDS + PROMOTION_WAIT_SECONDS))

  while true; do
    details="$(
      github_cli pr view "${number}" \
        --repo "${repo}" \
        --json state,mergedAt,url \
        --jq '[.state, (.mergedAt // ""), .url] | @tsv'
    )"
    IFS=$'\t' read -r state merged_at url <<<"${details}"

    if [[ -n "${merged_at}" ]]; then
      printf 'container-compose promotion PR merged: %s\n' "${url}"
      return 0
    fi
    if [[ "${state}" == "CLOSED" ]]; then
      printf 'container-compose promotion PR closed without merge: %s\n' "${url}" >&2
      exit 1
    fi

    now="${SECONDS}"
    if (( now >= deadline )); then
      printf 'timed out waiting for container-compose promotion PR merge: %s\n' "${url}" >&2
      exit 1
    fi

    printf 'waiting for container-compose promotion PR merge #%s; next check in %ss\n' \
      "${number}" "${PROMOTION_POLL_SECONDS}"
    sleep "${PROMOTION_POLL_SECONDS}"
  done
}

# Return success when GitHub already records the promotion pull request as merged.
compose_pr_is_merged() {
  local number="$1" repo merged_at
  repo="$(github_repo "${COMPOSE_REPO}")"
  if ! merged_at="$(
    github_cli pr view "${number}" \
      --repo "${repo}" \
      --json mergedAt \
      --jq '.mergedAt // ""'
  )"; then
    return 1
  fi
  [[ -n "${merged_at}" ]]
}

# Merge the validated promotion pull request or accept an equivalent external merge.
merge_compose_promotion_pr() {
  local number="$1" repo review_decision
  repo="$(github_repo "${COMPOSE_REPO}")"
  if compose_pr_is_merged "${number}"; then
    printf 'container-compose promotion PR already merged: #%s\n' "${number}"
    return 0
  fi

  if github_cli pr merge "${number}" \
    --repo "${repo}" \
    --merge \
    --delete-branch \
    --auto; then
    wait_for_compose_pr_merged "${number}"
    return 0
  fi

  printf 'auto-merge was not available for container-compose PR #%s; waiting for checks before merge\n' "${number}"
  if compose_pr_is_merged "${number}"; then
    printf 'container-compose promotion PR already merged: #%s\n' "${number}"
    return 0
  fi
  wait_for_compose_pr_checks "${number}"
  if github_cli pr merge "${number}" \
    --repo "${repo}" \
    --merge \
    --delete-branch; then
    wait_for_compose_pr_merged "${number}"
    return 0
  fi

  if compose_pr_is_merged "${number}"; then
    printf 'container-compose promotion PR already merged: #%s\n' "${number}"
    return 0
  fi

  review_decision="$(
    github_cli pr view "${number}" \
      --repo "${repo}" \
      --json reviewDecision \
      --jq '.reviewDecision // ""'
  )"
  if [[ "${COMPOSE_MAIN_MERGE_MODE}" == "checked-admin" && "${review_decision}" == "REVIEW_REQUIRED" ]]; then
    printf 'normal merge is blocked by the solo-maintainer review requirement; using checked admin merge after PR checks passed\n'
    run github_cli pr merge "${number}" \
      --repo "${repo}" \
      --merge \
      --delete-branch \
      --admin
    wait_for_compose_pr_merged "${number}"
    return 0
  fi

  printf 'container-compose promotion PR merge failed: #%s\n' "${number}" >&2
  printf 'review decision: %s\n' "${review_decision}" >&2
  printf 'set CONTAINER_STACK_RELEASE_COMPOSE_MAIN_MERGE_MODE=checked-admin only after confirming PR checks are sufficient for this release\n' >&2
  exit 1
}

# Align local main after GitHub has rewritten an identical candidate tree.
align_equivalent_compose_main() {
  local path="$1" remote="$2" remote_head="$3" candidate_tree="$4" aligned_head aligned_tree
  printf 'container-compose candidate tree is already promoted on %s/main with rewritten history; aligning local main before tagging\n' "${remote}"

  if [[ "${EXECUTE}" != "1" ]]; then
    printf 'would align local container-compose main with %s\n' "${remote_head}"
    return 0
  fi

  # The trees match exactly, so moving the local branch does not change files.
  run git -C "${path}" switch --detach "${remote_head}"
  run git -C "${path}" branch -f main "${remote_head}"
  run git -C "${path}" switch main

  aligned_head="$(git -C "${path}" rev-parse main)"
  aligned_tree="$(git -C "${path}" rev-parse 'main^{tree}')"
  if [[ "${aligned_head}" != "${remote_head}" || "${aligned_tree}" != "${candidate_tree}" ]]; then
    printf 'could not align local container-compose main with the already promoted candidate tree\n' >&2
    exit 1
  fi
}

# Synchronize local main after promotion while preserving the gated tree invariant.
synchronize_promoted_compose_main() {
  local path="$1" remote="$2" candidate_tree="$3" remote_head remote_tree local_head promoted_tree
  fetch_release_remote "${COMPOSE_REPO}"
  remote_head="$(remote_main_commit "${COMPOSE_REPO}")"
  if [[ -z "${remote_head}" ]]; then
    printf 'cannot resolve remote main for container-compose on %s\n' "${remote}" >&2
    exit 1
  fi

  remote_tree="$(git -C "${path}" rev-parse "${remote_head}^{tree}")"
  if [[ "${remote_tree}" != "${candidate_tree}" ]]; then
    printf 'promoted container-compose main tree differs from the locally gated candidate\n' >&2
    exit 1
  fi

  local_head="$(git -C "${path}" rev-parse main)"
  if [[ "${local_head}" != "${remote_head}" ]]; then
    if git -C "${path}" merge-base --is-ancestor "${local_head}" "${remote_head}"; then
      run git -C "${path}" pull --ff-only "${remote}" main
    else
      align_equivalent_compose_main "${path}" "${remote}" "${remote_head}" "${candidate_tree}"
    fi
  fi

  promoted_tree="$(git -C "${path}" rev-parse 'main^{tree}')"
  if [[ "${promoted_tree}" != "${candidate_tree}" ]]; then
    printf 'promoted container-compose main tree differs from the locally gated candidate\n' >&2
    exit 1
  fi
}

# Promote the gated Compose candidate through the configured main-branch policy.
promote_compose_main() {
  local version="$1" purpose="$2" title="$3" body="$4" path remote local_head remote_head branch candidate_tree remote_tree pushed_head
  path="$(repo_path "${COMPOSE_REPO}")"
  remote="$(push_remote "${COMPOSE_REPO}")"
  ensure_compose_promotion_mode
  fetch_release_remote "${COMPOSE_REPO}"
  local_head="$(git -C "${path}" rev-parse main)"
  candidate_tree="$(git -C "${path}" rev-parse 'main^{tree}')"
  remote_head="$(remote_main_commit "${COMPOSE_REPO}")"

  if [[ "${local_head}" == "${remote_head}" ]]; then
    printf 'container-compose main already promoted at %s\n' "${local_head}"
    return 0
  fi
  if [[ -z "${remote_head}" ]]; then
    printf 'cannot resolve remote main for container-compose on %s\n' "${remote}" >&2
    exit 1
  fi
  if [[ "${EXECUTE}" == "1" ]]; then
    remote_tree="$(git -C "${path}" rev-parse "${remote_head}^{tree}")"
    if [[ "${candidate_tree}" == "${remote_tree}" ]]; then
      align_equivalent_compose_main "${path}" "${remote}" "${remote_head}" "${candidate_tree}"
      return 0
    fi
  fi
  if ! git -C "${path}" merge-base --is-ancestor "${remote_head}" "${local_head}"; then
    printf 'container-compose main is not based on %s/main; pull and revalidate before release\n' "${remote}" >&2
    exit 1
  fi

  if [[ "${COMPOSE_MAIN_PROMOTION_MODE}" == "direct" ]]; then
    printf 'using emergency direct container-compose main promotion mode\n' >&2
    run git -C "${path}" push "${remote}" "refs/heads/main"
    return 0
  fi

  branch="$(compose_promotion_branch_name "${purpose}" "${version}")"
  if [[ "${EXECUTE}" != "1" ]]; then
    printf 'would push container-compose promotion branch %s at %s\n' "${branch}" "${local_head}"
    printf 'would open and merge a PR titled: %s\n' "${title}"
    printf 'would fast-forward local container-compose main after merge\n'
    return 0
  fi

  pushed_head="$(git -C "${path}" ls-remote --heads "${remote}" "refs/heads/${branch}" | awk '{print $1}')"
  if [[ -n "${pushed_head}" && "${pushed_head}" != "${local_head}" ]]; then
    printf 'promotion branch already exists with a different head: %s -> %s\n' "${branch}" "${pushed_head}" >&2
    exit 1
  fi
  if [[ -z "${pushed_head}" ]]; then
    run git -C "${path}" push "${remote}" "refs/heads/main:refs/heads/${branch}"
  else
    printf 'container-compose promotion branch already points at %s\n' "${local_head}"
  fi

  open_compose_promotion_pr "${branch}" "${title}" "${body}"
  merge_compose_promotion_pr "${COMPOSE_PROMOTION_PR_NUMBER}"
  synchronize_promoted_compose_main "${path}" "${remote}" "${candidate_tree}"
}

push_all_main() {
  local version="$1" repo path remote body
  print_header "promote stephenlclarke-owned source main branches"
  for repo in "${REPOS[@]}"; do
    path="$(repo_path "${repo}")"
    remote="$(push_remote "${repo}")"
    if [[ "${repo}" == "${COMPOSE_REPO}" ]]; then
      body="$(compose_source_promotion_body "${version}")"
      promote_compose_main \
        "${version}" \
        "source" \
        "chore(release): promote ${version} source" \
        "${body}"
    else
      run git -C "${path}" push "${remote}" "refs/heads/main"
    fi
  done
}

# Require an executable command when an executed workflow depends on it.
need_command() {
  local command_name="$1"
  if ! command -v "${command_name}" >/dev/null 2>&1; then
    printf 'required command not found: %s\n' "${command_name}" >&2
    exit 1
  fi
}

# Run GitHub CLI commands with the caller's authenticated credential. This
# supports the documented GITHUB_TOKEN path as well as gh's stored login.
github_cli() {
  gh "$@"
}

# Return the newest workflow_dispatch run id for the compose package workflow.
latest_compose_package_dispatch_run() {
  github_cli run list \
    --repo "$(github_repo "${COMPOSE_REPO}")" \
    --workflow "Prebuilt Binaries" \
    --event workflow_dispatch \
    --limit 1 \
    --json databaseId \
    --jq '.[0].databaseId // ""'
}

latest_stable_release_gate_dispatch_run() {
  github_cli run list \
    --repo "$(github_repo "${COMPOSE_REPO}")" \
    --workflow stable-release-gate.yml \
    --event workflow_dispatch \
    --limit 1 \
    --json databaseId \
    --jq '.[0].databaseId // ""'
}

# Wait for a GitHub Actions run to complete successfully.
wait_for_github_run_success() {
  local run_id="$1" label="$2" wait_seconds="${3:-${COMPOSE_PACKAGE_WAIT_SECONDS}}"
  local status conclusion url deadline now details
  deadline=$((SECONDS + wait_seconds))
  while true; do
    details="$(
      github_cli run view "${run_id}" \
        --repo "$(github_repo "${COMPOSE_REPO}")" \
        --json status,conclusion,url \
        --jq '[.status, (.conclusion // ""), .url] | @tsv'
    )"
    IFS=$'\t' read -r status conclusion url <<<"${details}"

    if [[ "${status}" == "completed" ]]; then
      if [[ "${conclusion}" == "success" ]]; then
        printf '%s passed: %s\n' "${label}" "${url}"
        return 0
      fi
      printf '%s ended with %s: %s\n' "${label}" "${conclusion}" "${url}" >&2
      exit 1
    fi

    now="${SECONDS}"
    if (( now >= deadline )); then
      printf 'timed out waiting for %s (%s): %s\n' "${label}" "${run_id}" "${url}" >&2
      exit 1
    fi

    printf 'waiting for %s %s (%s); next check in %ss\n' \
      "${label}" "${run_id}" "${status}" "${COMPOSE_PACKAGE_POLL_SECONDS}"
    sleep "${COMPOSE_PACKAGE_POLL_SECONDS}"
  done
}

# Verify the stable release assets and Homebrew formula agree.
verify_compose_stable_package() {
  local version="$1" repo asset expected_url tmp asset_names asset_sha checksum_sha formula_text formula_url formula_version formula_sha runtime_asset runtime_url runtime_asset_sha runtime_checksum_sha runtime_formula_text container_formula_url container_formula_sha
  repo="$(github_repo "${COMPOSE_REPO}")"
  asset="container-compose-plugin-release-arm64.tar.gz"
  expected_url="https://github.com/${repo}/releases/download/${version}/${asset}"
  print_header "verify container-compose ${version} package"

  if [[ "${EXECUTE}" != "1" ]]; then
    printf 'would verify GitHub release assets and stephenlclarke/tap/container-compose for %s\n' "${version}"
    return 0
  fi

  tmp="$(mktemp -d)"
  asset_names="$(
    github_cli release view "${version}" \
      --repo "${repo}" \
      --json assets \
      --jq '.assets[].name'
  )"
  if ! grep -Fxq "${asset}" <<<"${asset_names}"; then
    printf 'release %s is missing asset %s\n' "${version}" "${asset}" >&2
    exit 1
  fi
  if ! grep -Fxq "${asset}.sha256" <<<"${asset_names}"; then
    printf 'release %s is missing asset %s.sha256\n' "${version}" "${asset}" >&2
    exit 1
  fi

  runtime_asset="container-release-arm64.tar.gz"
  if ! grep -Fxq "${runtime_asset}" <<<"${asset_names}"; then
    printf 'release %s is missing asset %s\n' "${version}" "${runtime_asset}" >&2
    exit 1
  fi
  if ! grep -Fxq "${runtime_asset}.sha256" <<<"${asset_names}"; then
    printf 'release %s is missing asset %s.sha256\n' "${version}" "${runtime_asset}" >&2
    exit 1
  fi

  github_cli release download "${version}" \
    --repo "${repo}" \
    --pattern "${asset}" \
    --pattern "${asset}.sha256" \
    --pattern "${runtime_asset}" \
    --pattern "${runtime_asset}.sha256" \
    --dir "${tmp}"
  asset_sha="$(shasum -a 256 "${tmp}/${asset}" | awk '{print $1}')"
  checksum_sha="$(awk '{print $1}' "${tmp}/${asset}.sha256")"
  if [[ "${asset_sha}" != "${checksum_sha}" ]]; then
    printf 'release %s checksum mismatch: asset %s, checksum file %s\n' \
      "${version}" "${asset_sha}" "${checksum_sha}" >&2
    exit 1
  fi
  runtime_asset_sha="$(shasum -a 256 "${tmp}/${runtime_asset}" | awk '{print $1}')"
  runtime_checksum_sha="$(awk '{print $1}' "${tmp}/${runtime_asset}.sha256")"
  rm -rf "${tmp}"
  if [[ "${runtime_asset_sha}" != "${runtime_checksum_sha}" ]]; then
    printf 'release %s runtime checksum mismatch: asset %s, checksum file %s\n' \
      "${version}" "${runtime_asset_sha}" "${runtime_checksum_sha}" >&2
    exit 1
  fi

  formula_text="$(
    github_cli api \
      repos/stephenlclarke/homebrew-tap/contents/Formula/container-compose.rb \
      --jq '.content' | base64 --decode
  )"
  formula_url="$(sed -n 's/^  url "\(.*\)"/\1/p' <<<"${formula_text}" | head -n 1)"
  formula_version="$(sed -n 's/^  version "\(.*\)"/\1/p' <<<"${formula_text}" | head -n 1)"
  formula_sha="$(sed -n 's/^  sha256 "\(.*\)"/\1/p' <<<"${formula_text}" | head -n 1)"

  if [[ "${formula_url}" != "${expected_url}" ]]; then
    printf 'Homebrew formula URL mismatch: expected %s, got %s\n' "${expected_url}" "${formula_url}" >&2
    exit 1
  fi
  if [[ "${formula_version}" != "${version}" ]]; then
    printf 'Homebrew formula version mismatch: expected %s, got %s\n' "${version}" "${formula_version}" >&2
    exit 1
  fi
  if [[ "${formula_sha}" != "${asset_sha}" ]]; then
    printf 'Homebrew formula SHA mismatch: expected %s, got %s\n' "${asset_sha}" "${formula_sha}" >&2
    exit 1
  fi

  if ! grep -Fq 'depends_on "stephenlclarke/tap/container"' <<<"${formula_text}"; then
    printf 'stable compose formula does not depend on stephenlclarke/tap/container\n' >&2
    exit 1
  fi

  runtime_url="https://github.com/${repo}/releases/download/${version}/${runtime_asset}"
  runtime_formula_text="$(
    github_cli api \
      repos/stephenlclarke/homebrew-tap/contents/Formula/container.rb \
      --jq '.content' | base64 --decode
  )"
  container_formula_url="$(sed -n 's/^  url "\(.*\)"/\1/p' <<<"${runtime_formula_text}" | head -n 1)"
  container_formula_sha="$(sed -n 's/^  sha256 "\(.*\)"/\1/p' <<<"${runtime_formula_text}" | head -n 1)"
  if [[ "${container_formula_url}" != "${runtime_url}" ]]; then
    printf 'stable container formula URL mismatch: expected %s, got %s\n' \
      "${runtime_url}" "${container_formula_url}" >&2
    exit 1
  fi
  if [[ "${container_formula_sha}" != "${runtime_asset_sha}" ]]; then
    printf 'stable container formula SHA mismatch: expected %s, got %s\n' \
      "${runtime_asset_sha}" "${container_formula_sha}" >&2
    exit 1
  fi
  if ! grep -Fq 'opt/container-compose/libexec/container-plugins/compose' <<<"${runtime_formula_text}"; then
    printf 'stable container formula does not register the stable compose plugin\n' >&2
    exit 1
  fi

  printf 'stable stack %s package pair verified: %s + %s\n' "${version}" "${asset_sha}" "${runtime_asset_sha}"
}

# Dispatch and wait for the stable compose package workflow for a semantic tag.
dispatch_compose_stable_package() {
  local version="$1" previous_run run_id deadline now
  print_header "dispatch container-compose ${version} package"

  if [[ "${EXECUTE}" != "1" ]]; then
    printf 'would run: gh workflow run prebuilt-binaries.yml --repo %s --ref main -f ref=%s\n' \
      "$(github_repo "${COMPOSE_REPO}")" "${version}"
    printf 'would wait for the container-compose stable package workflow to publish assets and update Homebrew\n'
    return 0
  fi

  need_command gh
  previous_run="$(latest_compose_package_dispatch_run || true)"
  run github_cli workflow run prebuilt-binaries.yml \
    --repo "$(github_repo "${COMPOSE_REPO}")" \
    --ref main \
    -f "ref=${version}"

  deadline=$((SECONDS + COMPOSE_PACKAGE_WAIT_SECONDS))
  while true; do
    run_id="$(latest_compose_package_dispatch_run || true)"
    if [[ -n "${run_id}" && "${run_id}" != "${previous_run}" ]]; then
      printf 'container-compose package workflow started: %s\n' "${run_id}"
      wait_for_github_run_success "${run_id}" "container-compose stable package workflow"
      verify_compose_stable_package "${version}"
      return 0
    fi

    now="${SECONDS}"
    if (( now >= deadline )); then
      printf 'timed out waiting for container-compose package workflow dispatch for %s\n' "${version}" >&2
      exit 1
    fi

    printf 'waiting for container-compose package workflow dispatch for %s; next check in %ss\n' \
      "${version}" "${COMPOSE_PACKAGE_POLL_SECONDS}"
    sleep "${COMPOSE_PACKAGE_POLL_SECONDS}"
  done
}

dispatch_stable_release_gate() {
  local version="$1" previous_run run_id deadline now
  print_header "dispatch hosted stable release gate for ${version}"

  if [[ "${EXECUTE}" != "1" ]]; then
    printf 'would run: gh workflow run stable-release-gate.yml --repo %s --ref main -f ref=%s\n' \
      "$(github_repo "${COMPOSE_REPO}")" "${version}"
    printf 'would wait for the hosted gate to confirm green main CI, SonarQube, and full parity.\n'
    return 0
  fi

  need_command gh
  previous_run="$(latest_stable_release_gate_dispatch_run || true)"
  run github_cli workflow run stable-release-gate.yml \
    --repo "$(github_repo "${COMPOSE_REPO}")" \
    --ref main \
    -f "ref=${version}"

  deadline=$((SECONDS + STABLE_RELEASE_GATE_WAIT_SECONDS))
  while true; do
    run_id="$(latest_stable_release_gate_dispatch_run || true)"
    if [[ -n "${run_id}" && "${run_id}" != "${previous_run}" ]]; then
      printf 'stable release gate started: %s\n' "${run_id}"
      wait_for_github_run_success \
        "${run_id}" "hosted stable release gate" "${STABLE_RELEASE_GATE_WAIT_SECONDS}"
      return 0
    fi

    now="${SECONDS}"
    if (( now >= deadline )); then
      printf 'timed out waiting for stable release gate dispatch for %s\n' "${version}" >&2
      exit 1
    fi

    printf 'waiting for stable release gate dispatch for %s; next check in %ss\n' \
      "${version}" "${COMPOSE_PACKAGE_POLL_SECONDS}"
    sleep "${COMPOSE_PACKAGE_POLL_SECONDS}"
  done
}

# Publish the immutable assets and tap formulae for a signed stable source tag.
publish_stable_release() {
  local version="$1"
  dispatch_stable_release_gate "${version}"
  dispatch_compose_stable_package "${version}"
  print_component_refs
  cat <<EOF

Stable release point:
  version: ${version}
  label: latest
  release generation: container-compose stable package workflow dispatch
  tap update: stable container-compose formula published with the release package
EOF
}

# Tag a compose state as the stable/latest release point.
tag_stable_version() {
  local version="$1"
  print_header "tag container-compose main as ${version} latest"
  tag_new_stable_version "${version}"
  publish_stable_release "${version}"
}

# Resume an unreleased signed tag after a failed gate without mutating source identity.
resume_stable_release() {
  local version="$1"
  print_header "resume stable release ${version}"
  ensure_latest_stable_retry "${version}"
  ensure_stable_release_is_unpublished "${version}"
  verify_github_stable_tag_signature "${version}"
  publish_stable_release "${version}"
}

release_current_stack() {
  local latest current version path
  latest="$(latest_local_semver_tag "${COMPOSE_REPO}")"
  if [[ -z "${latest}" ]]; then
    latest="$(current_compose_version)"
  fi
  current="$(current_compose_version)"
  version="$(resolve_release_version "${VERSION_SELECTOR}")"
  if stable_tag_exists "${version}"; then
    printf 'resuming unpublished stable tag: %s\n' "${version}"
    resume_stable_release "${version}"
    return 0
  fi
  ensure_release_version_is_valid "${latest}" "${current}" "${version}"
  ensure_new_stable_release "${version}"
  path="$(repo_path "${COMPOSE_REPO}")"

  print_header "prepare stable release ${version}"
  printf 'latest semantic tag: %s\n' "${latest}"
  printf 'current COMPOSE_VERSION: %s\n' "${current}"
  printf 'release version: %s\n' "${version}"

  if [[ "${current}" != "${version}" ]]; then
    if [[ "${EXECUTE}" == "1" ]]; then
      bump_compose_version_files "${current}" "${version}"
    else
      printf 'would update: %s\n' "${path}/Makefile"
      printf 'would update: %s\n' "${path}/Sources/ComposePlugin/ComposePlugin.swift"
    fi
  else
    printf 'container-compose version files already declare %s\n' "${version}"
  fi
  sync_containerization_package_pins
  write_release_stack_manifest

  if [[ "${EXECUTE}" == "1" ]]; then
    git -C "${path}" add Makefile Sources/ComposePlugin/ComposePlugin.swift Tools/release/stack-refs.json
    if ! git -C "${path}" diff --cached --quiet -- Makefile Sources/ComposePlugin/ComposePlugin.swift Tools/release/stack-refs.json; then
      run git -C "${path}" commit -m "chore(release): prepare ${version}"
    else
      printf 'release prep files already match %s\n' "${version}"
    fi
  else
    run git -C "${path}" add Makefile Sources/ComposePlugin/ComposePlugin.swift Tools/release/stack-refs.json
    run git -C "${path}" commit -m "chore(release): prepare ${version}"
  fi

  ensure_clean "${COMPOSE_REPO}"
  run_local_release_gate
  push_all_main "${version}"
  tag_stable_version "${version}"
}

# Update compose version declarations and local smoke expectations.
bump_compose_version_files() {
  local current="$1" next="$2" path
  path="$(repo_path "${COMPOSE_REPO}")"
  python3 - "${path}" "${current}" "${next}" <<'PY'
from pathlib import Path
import re
import sys

root = Path(sys.argv[1])
current = sys.argv[2]
next_version = sys.argv[3]

makefile = root / "Makefile"
text = makefile.read_text(encoding="utf-8")
text = re.sub(r"^COMPOSE_VERSION \?= .+$", f"COMPOSE_VERSION ?= {next_version}", text, flags=re.MULTILINE)
text = text.replace(f'== "{current}"', f'== "{next_version}"')
text = text.replace(f'container-compose {current}', f'container-compose {next_version}')
text = text.replace(f'"version":"{current}"', f'"version":"{next_version}"')
makefile.write_text(text, encoding="utf-8")

source = root / "Sources" / "ComposePlugin" / "ComposePlugin.swift"
text = source.read_text(encoding="utf-8")
text = text.replace(f'var version: String = "{current}"', f'var version: String = "{next_version}"')
text = text.replace(f'version: "{current}"', f'version: "{next_version}"')
source.write_text(text, encoding="utf-8")
PY
}

# Print current stack release status.
plan() {
  local repo current latest next_patch next_minor next_major changed
  prepare_all_main
  current="$(current_compose_version)"
  latest="$(latest_local_semver_tag "${COMPOSE_REPO}")"
  if [[ -z "${latest}" ]]; then
    latest="${current}"
  fi
  next_patch="$(resolve_version_selector '--+' "${latest}")"
  next_minor="$(resolve_version_selector '-+-' "${latest}")"
  next_major="$(resolve_version_selector '+--' "${latest}")"

  print_header "simplified stack release plan"
  printf 'current COMPOSE_VERSION: %s\n' "${current}"
  printf 'latest semantic tag:     %s\n' "${latest}"
  printf 'next patch release:      %s\n' "${next_patch}"
  printf 'next minor release:      %s\n' "${next_minor}"
  printf 'next major release:      %s\n\n' "${next_major}"
  printf '%-26s %-40s %-18s\n' "component" "main-sha" "changed-since-tag"
  for repo in "${REPOS[@]}"; do
    changed="yes"
    if ! repo_changed_since_latest_tag "${repo}"; then
      changed="no"
    fi
    printf '%-26s %-40s %-18s\n' "${repo}" "$(git -C "$(repo_path "${repo}")" rev-parse main)" "${changed}"
  done

  cat <<'EOF'

Process:
  1. Keep main as the releasable integration branch.
  2. For a stable release, run release VERSION_SELECTOR after validation.
  3. The release mode resolves VERSION_SELECTOR from the latest semantic tag,
     bumps container-compose on main when needed, promotes stephenlclarke-owned
     source main branches, promotes container-compose through an automated PR by
     default, creates a new container-compose tag, dispatches the stable package
     workflow, and verifies the immutable release assets plus Homebrew tap update.
EOF
}

main() {
  parse_arguments "$@"
  case "${MODE}" in
    plan)
      plan
      ;;
    release)
      prepare_all_main
      release_current_stack
      ;;
  esac
}

if [[ "${CONTAINER_STACK_RELEASE_LIBRARY:-0}" != "1" ]]; then
  main "$@"
fi
