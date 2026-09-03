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
deadline_runner="${CONTAINER_DEMO_DEADLINE_RUNNER:-$(
  dirname "${BASH_SOURCE[0]}"
)/../ci/run-command-with-deadline.py}"
stop_waiter="${CONTAINER_SYSTEM_STOP_WAITER:-$(
  dirname "${BASH_SOURCE[0]}"
)/wait-for-container-system-stop.sh}"

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
if [[ ! -x "${launchctl_bin}" ]]; then
  printf 'Current demo launch-agent inspector is not executable: %s\n' \
    "${launchctl_bin}" >&2
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

if demo_service_is_loaded; then
  if [[ ! -x "${container_binary}" ]]; then
    printf 'Current demo service is loaded but its CLI is unavailable: %s\n' \
      "${container_binary}" >&2
    exit 2
  fi
  CONTAINER_APP_ROOT="${demo_app_root}" \
    python3 "${deadline_runner}" --seconds 30 --grace-seconds 5 -- \
      "${container_binary}" system stop || true
fi

if demo_service_is_loaded; then
  "${launchctl_bin}" bootout "${user_domain}/${service_label}"
fi

LAUNCHCTL_BIN="${launchctl_bin}" bash "${stop_waiter}"
