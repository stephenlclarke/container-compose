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

SELF_PATH="${BASH_SOURCE[0]:-$0}"
readonly SELF_PATH
SCRIPT_NAME="$(basename "${SELF_PATH}")"
readonly SCRIPT_NAME
readonly SCRIPT_USAGE="scripts/${SCRIPT_NAME}"
readonly DEFAULT_REPOSITORY="stephenlclarke/container-compose"
readonly RUNNER_LABEL="container-compose-release"

REPOSITORY="${CONTAINER_COMPOSE_RELEASE_REPOSITORY:-${DEFAULT_REPOSITORY}}"
RUNNER_DIR="${CONTAINER_COMPOSE_RELEASE_RUNNER_DIR:-${HOME}/.local/share/container-compose-release-runner}"
RUNNER_NAME="${CONTAINER_COMPOSE_RELEASE_RUNNER_NAME:-}"
TEMPORARY_DIRECTORY=""

cleanup() {
  # Remove the verified runner archive after configuration or a failed install.
  if [[ -n "${TEMPORARY_DIRECTORY}" ]]; then
    rm -rf "${TEMPORARY_DIRECTORY}"
  fi
}

trap cleanup EXIT

usage() {
  cat <<USAGE
Usage:
  ${SCRIPT_USAGE} [--repository OWNER/REPOSITORY] [--runner-dir PATH] [--runner-name NAME]

Purpose:
  Register this Apple-silicon Mac as the dedicated local runner for the
  Scheduled Stable Release workflow, then install and start its launchd service.

The runner is restricted by the workflow to the main branch and the
${RUNNER_LABEL} label. It uses this user's existing GitHub CLI login and SSH
Git signing setup; this script never copies a GitHub token or private key into
the repository, Actions secrets, or the runner workspace.

Requirements:
  - macOS on Apple silicon with kern.hv_support=1
  - gh authenticated as the owner of the target repository
  - git configured with user.name, user.email, gpg.format=ssh, commit.gpgsign=true, and user.signingkey
  - swift, go, node, npm, python3, docker compose, jq, GNU tar, and shasum

Options:
  --repository OWNER/REPOSITORY  Target repository (default: ${DEFAULT_REPOSITORY})
  --runner-dir PATH              Runner installation directory
  --runner-name NAME             GitHub Actions runner name
USAGE
}

# Require one executable needed by the installer.
need_command() {
  local command_name="$1"
  if ! command -v "${command_name}" >/dev/null 2>&1; then
    printf 'required command not found: %s\n' "${command_name}" >&2
    exit 1
  fi
}

# Parse the supported installation options.
parse_arguments() {
  while (($#)); do
    case "$1" in
      --repository)
        if (($# < 2)); then
          printf '%s requires OWNER/REPOSITORY\n' "$1" >&2
          exit 2
        fi
        REPOSITORY="${2:-}"
        shift 2
        ;;
      --runner-dir)
        if (($# < 2)); then
          printf '%s requires PATH\n' "$1" >&2
          exit 2
        fi
        RUNNER_DIR="${2:-}"
        shift 2
        ;;
      --runner-name)
        if (($# < 2)); then
          printf '%s requires NAME\n' "$1" >&2
          exit 2
        fi
        RUNNER_NAME="${2:-}"
        shift 2
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        printf 'unknown option: %s\n' "$1" >&2
        usage >&2
        exit 2
        ;;
    esac
  done

  if [[ ! "${REPOSITORY}" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]]; then
    printf 'repository must be OWNER/REPOSITORY: %s\n' "${REPOSITORY}" >&2
    exit 2
  fi
  if [[ -z "${RUNNER_DIR}" || "${RUNNER_DIR}" != /* ]]; then
    printf 'runner directory must be an absolute path: %s\n' "${RUNNER_DIR}" >&2
    exit 2
  fi
}

# Reject machines that cannot run the full local stable-release gate.
ensure_release_host() {
  local signing_key signing_private_key support user_email user_name
  if [[ "$(uname -s)" != "Darwin" || "$(uname -m)" != "arm64" ]]; then
    printf 'scheduled stable releases require an Apple-silicon macOS host\n' >&2
    exit 1
  fi
  support="$(sysctl -n kern.hv_support 2>/dev/null || true)"
  if [[ "${support}" != "1" ]]; then
    printf 'scheduled stable releases require kern.hv_support=1\n' >&2
    exit 1
  fi
  if [[ "$(git config --global --get gpg.format || true)" != "ssh" ]]; then
    printf 'git gpg.format must be ssh for signed stable tags\n' >&2
    exit 1
  fi
  if [[ "$(git config --global --get commit.gpgsign || true)" != "true" ]]; then
    printf 'git commit.gpgsign must be true for source-promotion commits\n' >&2
    exit 1
  fi
  user_name="$(git config --global --get user.name || true)"
  user_email="$(git config --global --get user.email || true)"
  if [[ -z "${user_name}" || -z "${user_email}" ]]; then
    printf 'git user.name and user.email are required for source-promotion commits\n' >&2
    exit 1
  fi
  signing_key="$(git config --global --get user.signingkey || true)"
  if [[ -z "${signing_key}" || ! -r "${signing_key}" ]]; then
    printf 'git user.signingkey must name a readable SSH signing key\n' >&2
    exit 1
  fi
  signing_private_key="${signing_key%.pub}"
  if ! ssh-keygen -y -P '' -f "${signing_private_key}" >/dev/null 2>&1; then
    printf 'the stable-tag signing key must be usable without an interactive passphrase\n' >&2
    exit 1
  fi
}

# Verify the local toolchain and repository access before registering a runner.
ensure_tools() {
  local command_name
  for command_name in docker gh git go jq make node npm python3 shasum ssh-keygen swift tar; do
    need_command "${command_name}"
  done
  docker compose version >/dev/null
  gh api "repos/${REPOSITORY}" --jq '.full_name' >/dev/null
  if [[ "$(gh api user --jq '.login')" != "stephenlclarke" ]]; then
    printf 'the scheduled release runner must authenticate as stephenlclarke\n' >&2
    exit 1
  fi
}

# Derive a readable, repository-scoped runner name from the local host.
default_runner_name() {
  local hostname
  hostname="$(scutil --get LocalHostName 2>/dev/null || hostname -s)"
  hostname="$(tr -cs '[:alnum:]_.-' '-' <<<"${hostname}")"
  hostname="${hostname#-}"
  hostname="${hostname%-}"
  printf '%s-%s\n' "${RUNNER_LABEL}" "${hostname:-macos}"
}

# Return the latest macOS ARM64 runner asset name and its published SHA-256 digest.
release_asset() {
  local release_json asset
  release_json="$(gh api 'repos/actions/runner/releases/latest')"
  asset="$(jq -r '
    .assets[]
    | select(.name | test("^actions-runner-osx-arm64-[0-9]+[.][0-9]+[.][0-9]+[.]tar[.]gz$"))
    | [.name, .digest] | @tsv
  ' <<<"${release_json}")"
  if [[ -z "${asset}" || "${asset}" == $'\t'* ]]; then
    printf 'could not find a checksummed macOS ARM64 actions runner release\n' >&2
    exit 1
  fi
  printf '%s\n' "${asset}"
}

# Download, verify, register, and start the dedicated local runner.
install_runner() {
  local asset digest archive actual_digest registration_token release_tag
  if [[ -f "${RUNNER_DIR}/.runner" ]]; then
    printf 'scheduled release runner is already configured at %s\n' "${RUNNER_DIR}"
    "${RUNNER_DIR}/svc.sh" status
    return 0
  fi
  if [[ -e "${RUNNER_DIR}" && -n "$(find "${RUNNER_DIR}" -mindepth 1 -maxdepth 1 -print -quit)" ]]; then
    printf 'runner directory is not empty: %s\n' "${RUNNER_DIR}" >&2
    exit 1
  fi

  IFS=$'\t' read -r asset digest <<<"$(release_asset)"
  if [[ ! "${digest}" =~ ^sha256:[0-9a-f]{64}$ ]]; then
    printf 'runner release asset has no SHA-256 digest: %s\n' "${asset}" >&2
    exit 1
  fi
  release_tag="${asset#actions-runner-osx-arm64-}"
  release_tag="v${release_tag%.tar.gz}"
  TEMPORARY_DIRECTORY="$(mktemp -d)"
  gh release download "${release_tag}" --repo actions/runner --pattern "${asset}" --dir "${TEMPORARY_DIRECTORY}"
  archive="${TEMPORARY_DIRECTORY}/${asset}"
  actual_digest="sha256:$(shasum -a 256 "${archive}" | awk '{ print $1 }')"
  if [[ "${actual_digest}" != "${digest}" ]]; then
    printf 'actions runner digest mismatch for %s\n' "${asset}" >&2
    exit 1
  fi

  mkdir -p "${RUNNER_DIR}"
  chmod 700 "${RUNNER_DIR}"
  tar -xzf "${archive}" -C "${RUNNER_DIR}"
  registration_token="$(gh api --method POST "repos/${REPOSITORY}/actions/runners/registration-token" --jq '.token')"
  (
    cd "${RUNNER_DIR}"
    ./config.sh \
      --unattended \
      --url "https://github.com/${REPOSITORY}" \
      --token "${registration_token}" \
      --name "${RUNNER_NAME}" \
      --labels "${RUNNER_LABEL}" \
      --work "_work"
    ./svc.sh install
    ./svc.sh start
    ./svc.sh status
  )
  printf 'scheduled stable-release runner %s is online for %s\n' \
    "${RUNNER_NAME}" "${REPOSITORY}"
}

# Install the runner after validating its requested configuration.
main() {
  parse_arguments "$@"
  if [[ -z "${RUNNER_NAME}" ]]; then
    RUNNER_NAME="$(default_runner_name)"
  fi
  ensure_release_host
  ensure_tools
  install_runner
}

main "$@"
