#!/usr/bin/env bash
#===----------------------------------------------------------------------===#
# Copyright © 2026 container-compose project authors.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
# http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#===----------------------------------------------------------------------===#

# Quiesce and resume only the exact marker-protected Container candidate that
# owns the local release gate. Container's isolated integration suite may then
# use the host's virtualization resources without competing with the candidate
# shared sandbox or BuildKit VM.
set -euo pipefail

if (($# != 4)); then
  printf 'usage: %s {validate|quiesce|resume} CONTAINER_CLI APP_ROOT SERVICE_NAMESPACE\n' "$0" >&2
  exit 2
fi

action="$1"
container_cli="$2"
app_root="${3%/}"
service_namespace="$4"
script_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
compose_root="$(cd "${script_directory}/../.." && pwd -P)"
deadline_runner="${script_directory}/run-command-with-deadline.py"
runtime_wrapper="${compose_root}/scripts/run-with-container-runtime.sh"
launchctl_bin=/bin/launchctl
ps_bin=/bin/ps
sleep_bin=/bin/sleep
wait_attempts=100
wait_interval=0.1

if [[ "${CONTAINER_RELEASE_RUNTIME_TESTING:-0}" == 1 ]]; then
  launchctl_bin="${CONTAINER_RELEASE_RUNTIME_LAUNCHCTL:-${launchctl_bin}}"
  ps_bin="${CONTAINER_RELEASE_RUNTIME_PS:-${ps_bin}}"
  sleep_bin="${CONTAINER_RELEASE_RUNTIME_SLEEP:-${sleep_bin}}"
  deadline_runner="${CONTAINER_RELEASE_RUNTIME_DEADLINE_RUNNER:-${deadline_runner}}"
  runtime_wrapper="${CONTAINER_RELEASE_RUNTIME_WRAPPER:-${runtime_wrapper}}"
  wait_attempts="${CONTAINER_RELEASE_RUNTIME_WAIT_ATTEMPTS:-${wait_attempts}}"
  wait_interval="${CONTAINER_RELEASE_RUNTIME_WAIT_INTERVAL:-${wait_interval}}"
fi

case "${action}" in
  validate | quiesce | resume) ;;
  *)
    printf 'unknown release runtime action: %s\n' "${action}" >&2
    exit 2
    ;;
esac
if [[ ! "${app_root}" =~ ^(/private)?/tmp/c\.[^/]+/app$ ]] ||
  [[ -L "${app_root}" || ! -d "${app_root}" ]]; then
  printf 'release runtime application root is not the exact protected path: %s\n' \
    "${app_root:-unset}" >&2
  exit 2
fi
runtime_marker="${app_root}/.container-compose-runtime-root"
if [[ ! -f "${runtime_marker}" || -L "${runtime_marker}" ]] ||
  [[ "$(<"${runtime_marker}")" != 'container-compose isolated runtime state v1' ]]; then
  printf 'release runtime application root has no valid ownership marker: %s\n' \
    "${app_root}" >&2
  exit 2
fi
if [[ ! "${service_namespace}" =~ ^io\.github\.stephenlclarke\.container-compose\.runtime\.[A-Za-z0-9_-]+$ ]]; then
  printf 'release runtime namespace is invalid: %s\n' \
    "${service_namespace:-unset}" >&2
  exit 2
fi
if [[ "${container_cli}" != /* || ! -f "${container_cli}" ||
  -L "${container_cli}" || ! -x "${container_cli}" ]]; then
  printf 'release runtime CLI is not an exact executable file: %s\n' \
    "${container_cli:-unset}" >&2
  exit 2
fi
candidate_root="$(cd "$(dirname "${container_cli}")/.." && pwd -P)"
runtime_user_id="$(id -u)"
candidate_marker_valid=false
candidate_marker_value=""
if [[ "${candidate_root}" =~ ^(/private)?/tmp/container-compose-runtime-${runtime_user_id}/candidate-[0-9a-f]{16}$ ]]; then
  candidate_marker="${candidate_root}/.container-compose-runtime-candidate-staging"
  if [[ -f "${candidate_marker}" && ! -L "${candidate_marker}" ]]; then
    IFS= read -r candidate_marker_value <"${candidate_marker}" || true
    if [[ "${candidate_marker_value}" =~ ^container-compose\ runtime\ candidate\ staging\ v1\ [0-9a-f]{64}$ ]]; then
      candidate_marker_valid=true
    fi
  fi
elif [[ "${candidate_root}" =~ ^(/private)?/tmp/container-compose-runtime-candidate\.([0-9a-f]{40})\.[A-Za-z0-9]{6}$ ]]; then
  candidate_head="${BASH_REMATCH[2]}"
  candidate_marker="${candidate_root}/.container-compose-runtime-candidate-run"
  if [[ -f "${candidate_marker}" && ! -L "${candidate_marker}" ]]; then
    IFS= read -r candidate_marker_value <"${candidate_marker}" || true
    if [[ "${candidate_marker_value}" =~ ^container-compose\ runtime\ candidate\ run\ v1\ ${candidate_head}\ [0-9a-f]{64}$ ]]; then
      candidate_marker_valid=true
    fi
  fi
else
  printf 'release runtime CLI is outside protected candidate storage: %s\n' \
    "${container_cli}" >&2
  exit 2
fi
if [[ "${candidate_marker_valid}" != true ]]; then
  printf 'release runtime CLI has no valid candidate marker: %s\n' \
    "${candidate_root}" >&2
  exit 2
fi
for tool in "${deadline_runner}" "${launchctl_bin}" "${ps_bin}" "${sleep_bin}"; do
  if [[ ! -x "${tool}" ]]; then
    printf 'release runtime lifecycle tool is not executable: %s\n' "${tool}" >&2
    exit 2
  fi
done
if ! [[ "${wait_attempts}" =~ ^[1-9][0-9]*$ ]] ||
  ! [[ "${wait_interval}" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
  printf 'release runtime lifecycle wait policy is invalid\n' >&2
  exit 2
fi

if [[ "${action}" == validate ]]; then
  printf 'validated exact release runtime namespace: %s\n' "${service_namespace}"
  exit 0
fi

runtime_services() {
  "${launchctl_bin}" list | /usr/bin/awk -v prefix="${service_namespace}." \
    'index($3, prefix) == 1 { print $3 }'
}

runtime_processes() {
  local process_id process_uid executable process_snapshot
  if ! process_snapshot="$("${ps_bin}" -axo pid=,uid=,command=)"; then
    printf 'failed to inspect release runtime processes\n' >&2
    return 1
  fi
  while read -r process_id process_uid executable _; do
    case "${executable}" in
      "${candidate_root}"/*)
        if [[ "${process_uid}" == "$(id -u)" ]]; then
          printf '%s\n' "${process_id}"
        fi
        ;;
    esac
  done <<<"${process_snapshot}"
}

if [[ "${action}" == quiesce ]]; then
  env CONTAINER_APP_ROOT="${app_root}" \
    CONTAINER_SERVICE_NAMESPACE="${service_namespace}" \
    "${deadline_runner}" --seconds 60 --grace-seconds 0 -- \
      "${container_cli}" system stop

  remaining_services=""
  remaining_processes=""
  for ((attempt = 1; attempt <= wait_attempts; attempt++)); do
    remaining_services="$(runtime_services)"
    remaining_processes="$(runtime_processes)"
    if [[ -z "${remaining_services}" && -z "${remaining_processes}" ]]; then
      printf 'quiesced exact release runtime namespace: %s\n' \
        "${service_namespace}"
      exit 0
    fi
    if ((attempt < wait_attempts)); then
      "${sleep_bin}" "${wait_interval}"
    fi
  done
  if [[ -n "${remaining_services}" ]]; then
    printf 'release runtime services survived quiescence: %s\n' \
      "$(tr '\n' ' ' <<<"${remaining_services}" | sed 's/[[:space:]]*$//')" >&2
  fi
  if [[ -n "${remaining_processes}" ]]; then
    printf 'release runtime processes survived quiescence: %s\n' \
      "$(tr '\n' ' ' <<<"${remaining_processes}" | sed 's/[[:space:]]*$//')" >&2
  fi
  exit 1
fi

if [[ ! -x "${runtime_wrapper}" ]]; then
  printf 'release runtime wrapper is not executable: %s\n' \
    "${runtime_wrapper}" >&2
  exit 2
fi
env CONTAINER_RUNTIME_MANAGED=1 \
  CONTAINER_RUNTIME_APP_ROOT="${app_root}" \
  CONTAINER_RUNTIME_SERVICE_NAMESPACE="${service_namespace}" \
  CONTAINER_APP_ROOT="${app_root}" \
  CONTAINER_SERVICE_NAMESPACE="${service_namespace}" \
  "${deadline_runner}" --seconds 120 --grace-seconds 0 -- \
    "${runtime_wrapper}" "${container_cli}" /usr/bin/true
env CONTAINER_APP_ROOT="${app_root}" \
  CONTAINER_SERVICE_NAMESPACE="${service_namespace}" \
  "${deadline_runner}" --seconds 30 --grace-seconds 0 -- \
    "${container_cli}" list --all --format json >/dev/null
printf 'resumed exact release runtime namespace: %s\n' "${service_namespace}"
