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

# Require the macOS container service namespace to remain absent before a
# release recording starts a newly unpacked runtime.
set -euo pipefail

launchctl_bin="${LAUNCHCTL_BIN:-launchctl}"
launchd_prefix="${CONTAINER_SYSTEM_LAUNCHD_PREFIX:-com.apple.container.}"
attempt_count="${CONTAINER_SYSTEM_STOP_WAIT_ATTEMPTS:-60}"
stable_count="${CONTAINER_SYSTEM_STOP_STABLE_OBSERVATIONS:-3}"
poll_interval="${CONTAINER_SYSTEM_STOP_POLL_INTERVAL_SECONDS:-1}"

if ! [[ "${attempt_count}" =~ ^[1-9][0-9]*$ ]]; then
  printf 'CONTAINER_SYSTEM_STOP_WAIT_ATTEMPTS must be a positive integer, got: %s\n' \
    "${attempt_count}" >&2
  exit 2
fi
if ! [[ "${stable_count}" =~ ^[1-9][0-9]*$ ]]; then
  printf 'CONTAINER_SYSTEM_STOP_STABLE_OBSERVATIONS must be a positive integer, got: %s\n' \
    "${stable_count}" >&2
  exit 2
fi
if (( stable_count > attempt_count )); then
  printf 'stable observations (%s) cannot exceed wait attempts (%s)\n' \
    "${stable_count}" "${attempt_count}" >&2
  exit 2
fi
if ! [[ "${poll_interval}" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
  printf 'CONTAINER_SYSTEM_STOP_POLL_INTERVAL_SECONDS must be non-negative, got: %s\n' \
    "${poll_interval}" >&2
  exit 2
fi

observed_stable=0
for attempt in $(seq 1 "${attempt_count}"); do
  if ! services="$("${launchctl_bin}" list)"; then
    printf 'failed to query launchd services with %s\n' "${launchctl_bin}" >&2
    exit 1
  fi

  if printf '%s\n' "${services}" | awk -v prefix="${launchd_prefix}" '
    NF >= 3 && index($3, prefix) == 1 {
      found = 1
    }
    END {
      exit(found ? 0 : 1)
    }
  '; then
    observed_stable=0
  else
    observed_stable=$((observed_stable + 1))
    if (( observed_stable >= stable_count )); then
      printf 'container launchd namespace remained stopped for %s observations\n' \
        "${stable_count}"
      exit 0
    fi
  fi

  if (( attempt < attempt_count )); then
    sleep "${poll_interval}"
  fi
done

printf 'container launchd namespace %s did not remain stopped after %s observations\n' \
  "${launchd_prefix}" "${attempt_count}" >&2
exit 1
