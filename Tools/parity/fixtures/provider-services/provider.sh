#!/bin/sh
#===----------------------------------------------------------------------===#
# Copyright © 2026 container-compose project authors.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
# https://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#===----------------------------------------------------------------------===#

set -eu

if [ "${1:-}" != "compose" ]; then
    printf 'provider requires the compose protocol\n' >&2
    exit 2
fi

if [ "${2:-}" = "metadata" ]; then
    printf '%s\n' \
        '{"description":"provider parity fixture","up":{"parameters":[{"name":"name","required":true}]},"down":{"parameters":[{"name":"name","required":true}]},"stop":{"parameters":[]}}'
    exit 0
fi

if [ "${PROVIDER_PROJECT_TOKEN:-}" != "from-dotenv" ]; then
    printf '%s\n' \
        '{"type":"error","message":"normalized project environment was not propagated"}'
    exit 2
fi

case "${3:-}" in
    up)
        printf '%s\n' \
            '{"type":"info","message":"provider environment ready"}' \
            '{"type":"setenv","message":"URL=https://magic.cloud/secrets"}' \
            '{"type":"rawsetenv","message":"CLOUD_REGION=us-east-1"}'
        ;;
    down | stop)
        ;;
    *)
        printf '{"type":"error","message":"unsupported provider action: %s"}\n' "${3:-missing}"
        exit 2
        ;;
esac
