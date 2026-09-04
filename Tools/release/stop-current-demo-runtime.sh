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

# Stop the marker-protected Current demo runtime. If the CLI cannot reach its
# API server, recover only the launch agent whose plist belongs to this exact
# demo root. A production or otherwise unrelated Container service remains a
# hard failure.
set -euo pipefail
# Teardown owns recovery once invoked. A workflow cancellation can deliver
# several signals while the bounded CLI stop is running; keep the helper alive
# long enough to execute its verified launchd fallback.
trap '' HUP INT QUIT TERM

if [[ "$#" -ne 2 ]]; then
  printf 'usage: %s DEMO_SESSION_ROOT CONTAINER_BINARY\n' "$0" >&2
  exit 2
fi

demo_session_root="${1%/}"
container_binary="$2"
marker="${demo_session_root}/.container-compose-current-demo-root"
marker_value=container-compose-current-demo-v1
demo_app_root="${demo_session_root}/app"
expected_container="${demo_session_root}/install/bin/container"
expected_plist="${demo_app_root}/apiserver/apiserver.plist"
service_label=com.apple.container.apiserver
user_domain="gui/$(id -u)"
launchctl_bin="${CONTAINER_DEMO_LAUNCHCTL:-/bin/launchctl}"
ps_bin="${CONTAINER_DEMO_PS:-/bin/ps}"
kill_bin="${CONTAINER_DEMO_KILL:-/bin/kill}"
deadline_runner="${CONTAINER_DEMO_DEADLINE_RUNNER:-$(
  dirname "${BASH_SOURCE[0]}"
)/../ci/run-command-with-deadline.py}"
stop_waiter="${CONTAINER_SYSTEM_STOP_WAITER:-$(
  dirname "${BASH_SOURCE[0]}"
)/wait-for-container-system-stop.sh}"
graceful_stop_seconds="${CONTAINER_DEMO_GRACEFUL_STOP_SECONDS:-3}"
skip_graceful_stop="${CONTAINER_DEMO_SKIP_GRACEFUL_STOP:-false}"

if [[ -z "${demo_session_root}" || "${demo_session_root}" != /* ||
      "${demo_session_root}" == / || ! -d "${demo_session_root}" ||
      -L "${demo_session_root}" || ! -f "${marker}" || -L "${marker}" ||
      "$(cat "${marker}")" != "${marker_value}" ]]; then
  printf 'refusing unsafe Current demo root: %s\n' "${demo_session_root:-<unset>}" >&2
  exit 2
fi
read -r root_owner root_mode < <(
  python3 -c \
    'import os, stat, sys; value = os.lstat(sys.argv[1]); print(value.st_uid, oct(stat.S_IMODE(value.st_mode))[2:])' \
    "${demo_session_root}"
)
if [[ "${root_owner}" != "$(id -u)" || "${root_mode}" != 700 ]]; then
  printf 'Current demo root must be owned by this user with mode 700: %s\n' \
    "${demo_session_root}" >&2
  exit 2
fi
if [[ "${container_binary}" != "${expected_container}" ]]; then
  printf 'Current demo container binary is outside the protected root: %s\n' \
    "${container_binary}" >&2
  exit 2
fi
if [[ ! -x "${launchctl_bin}" || ! -x "${ps_bin}" ||
      ! -x "${kill_bin}" ]]; then
  printf 'Current demo cleanup tools are not executable: %s %s %s\n' \
    "${launchctl_bin}" "${ps_bin}" "${kill_bin}" >&2
  exit 2
fi
if ! [[ "${graceful_stop_seconds}" =~ ^[1-9][0-9]*$ ]]; then
  printf 'Current demo graceful-stop seconds must be a positive integer: %s\n' \
    "${graceful_stop_seconds}" >&2
  exit 2
fi
if [[ "${skip_graceful_stop}" != "true" &&
      "${skip_graceful_stop}" != "false" ]]; then
  printf 'CONTAINER_DEMO_SKIP_GRACEFUL_STOP must be true or false: %s\n' \
    "${skip_graceful_stop}" >&2
  exit 2
fi

service_state="$(mktemp "${TMPDIR:-/tmp}/container-compose-current-demo-service.XXXXXX")"
trap 'rm -f -- "${service_state}"' EXIT

demo_service_is_loaded() {
  if ! "${launchctl_bin}" print "${user_domain}/${service_label}" \
      >"${service_state}" 2>/dev/null; then
    return 1
  fi
  loaded_plist="$(awk '$1 == "path" && $2 == "=" { print $3; exit }' \
    "${service_state}")"
  if [[ "${loaded_plist}" != "${expected_plist}" ]]; then
    printf 'refusing to boot out unrelated Container launch agent at %s\n' \
      "${loaded_plist:-<unknown>}" >&2
    exit 2
  fi
}

# Boot out every remaining service only after proving that every matching
# launch agent belongs to this marker-protected demo root. Validation happens
# before mutation so an unrelated production service remains a hard failure.
bootout_demo_owned_services() {
  local label=""
  local loaded_plist=""
  local services=""
  local -a labels=()

  if ! services="$("${launchctl_bin}" list)"; then
    printf 'failed to list Container launch agents with %s\n' \
      "${launchctl_bin}" >&2
    return 1
  fi
  while read -r _ _ label; do
    if [[ "${label}" == com.apple.container.* ]]; then
      if ! [[ "${label}" =~ ^[A-Za-z0-9._-]+$ ]]; then
        printf 'refusing unsafe Current demo launch-agent label: %s\n' \
          "${label}" >&2
        return 2
      fi
      if ! "${launchctl_bin}" print "${user_domain}/${label}" \
          >"${service_state}" 2>/dev/null; then
        printf 'cannot inspect Current demo launch agent: %s\n' \
          "${label}" >&2
        return 2
      fi
      loaded_plist="$(awk '$1 == "path" && $2 == "=" { print $3; exit }' \
        "${service_state}")"
      case "${loaded_plist}" in
        "${demo_app_root}"/*)
          labels+=("${label}")
          ;;
        *)
          printf 'refusing to boot out unrelated Container launch agent at %s\n' \
            "${loaded_plist:-<unknown>}" >&2
          return 2
          ;;
      esac
    fi
  done <<<"${services}"

  for label in "${labels[@]}"; do
    # A parent service may have removed a child between the snapshot and this
    # loop. Revalidate every survivor immediately before mutation and accept a
    # service that is already absent.
    if ! "${launchctl_bin}" print "${user_domain}/${label}" \
        >"${service_state}" 2>/dev/null; then
      continue
    fi
    loaded_plist="$(awk '$1 == "path" && $2 == "=" { print $3; exit }' \
      "${service_state}")"
    case "${loaded_plist}" in
      "${demo_app_root}"/*)
        "${launchctl_bin}" bootout "${user_domain}/${label}"
        ;;
      *)
        printf 'refusing to boot out replaced Container launch agent at %s\n' \
          "${loaded_plist:-<unknown>}" >&2
        return 2
        ;;
    esac
  done
}

# The Compose engine is not launchd-managed. Recover it and any other
# demo-root executable with bounded TERM/KILL escalation after all verified
# demo launch agents have been booted out.
stop_demo_owned_processes() {
  local attempt=0
  local process_id=""
  local process_uid=""
  local executable=""
  local snapshot=""
  local -a process_ids=()

  if ! snapshot="$("${ps_bin}" -axo pid=,uid=,command=)"; then
    printf 'failed to inspect Current demo processes with %s\n' \
      "${ps_bin}" >&2
    return 1
  fi
  while read -r process_id process_uid executable _; do
    case "${executable}" in
      "${demo_session_root}"/*)
        if ! [[ "${process_id}" =~ ^[1-9][0-9]*$ ]] ||
           [[ "${process_uid}" != "$(id -u)" ]]; then
          printf 'refusing unsafe Current demo process: pid=%s uid=%s executable=%s\n' \
            "${process_id:-missing}" "${process_uid:-missing}" \
            "${executable:-missing}" >&2
          return 2
        fi
        process_ids+=("${process_id}")
        ;;
    esac
  done <<<"${snapshot}"

  if ((${#process_ids[@]} == 0)); then
    return 0
  fi
  "${kill_bin}" -TERM "${process_ids[@]}" 2>/dev/null || true
  for ((attempt = 1; attempt <= 10; attempt++)); do
    local -a remaining=()
    for process_id in "${process_ids[@]}"; do
      if "${kill_bin}" -0 "${process_id}" 2>/dev/null; then
        remaining+=("${process_id}")
      fi
    done
    process_ids=("${remaining[@]}")
    ((${#process_ids[@]} == 0)) && return 0
    sleep 0.1
  done
  "${kill_bin}" -KILL "${process_ids[@]}" 2>/dev/null || true
}

if demo_service_is_loaded; then
  if [[ "${skip_graceful_stop}" == "false" ]]; then
    if [[ ! -x "${container_binary}" ]]; then
      printf 'Current demo service is loaded but its CLI is unavailable: %s\n' \
        "${container_binary}" >&2
      exit 2
    fi
    CONTAINER_APP_ROOT="${demo_app_root}" \
      python3 "${deadline_runner}" --seconds "${graceful_stop_seconds}" \
        --grace-seconds 1 -- "${container_binary}" system stop || true
  fi
fi

bootout_demo_owned_services
stop_demo_owned_processes

LAUNCHCTL_BIN="${launchctl_bin}" bash "${stop_waiter}"
