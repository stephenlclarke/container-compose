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

# Render a typed, live VHS session. A transient ttyd reset before the first
# command may be retried; all other recorder failures remain fail-closed.
set -euo pipefail

if [[ "$#" -ne 3 ]]; then
  printf 'usage: %s TAPE OUTPUT CONTAINER_BINARY\n' "$0" >&2
  exit 2
fi

tape="$1"
output="$2"
container_binary="$3"
vhs_bin="${VHS_BIN:-vhs}"
retry_count="${VHS_TRANSPORT_RETRIES:-3}"
log_directory="${RUNNER_TEMP:-$(dirname "${output}")}"

if ! [[ "${retry_count}" =~ ^[1-9][0-9]*$ ]]; then
  printf 'VHS_TRANSPORT_RETRIES must be a positive integer, got: %s\n' \
    "${retry_count}" >&2
  exit 2
fi

recorded=false
for attempt in $(seq 1 "${retry_count}"); do
  vhs_log="${log_directory}/container-compose-current-demo-vhs-${attempt}.log"
  rm -f "${output}" "${vhs_log}"
  if "${vhs_bin}" "${tape}" >"${vhs_log}" 2>&1; then
    cat "${vhs_log}"
    if test -s "${output}"; then
      recorded=true
      break
    fi
    printf 'VHS completed without producing %s\n' "${output}" >&2
    exit 1
  fi

  cat "${vhs_log}" >&2
  if ! grep -Fq 'could not open ttyd' "${vhs_log}"; then
    printf 'VHS failed after typing began; refusing to retry a live-demo failure\n' >&2
    exit 1
  fi
  if (( attempt == retry_count )); then
    printf 'VHS terminal transport did not recover after %s attempts\n' \
      "${retry_count}" >&2
    exit 1
  fi

  # A transport-only failure may leave an isolated service booted before the
  # browser connects. Return the next typed session to a clean runtime.
  "${container_binary}" system stop || true
  sleep "${attempt}"
done

if [[ "${recorded}" != "true" ]]; then
  printf 'VHS recording did not complete\n' >&2
  exit 1
fi
