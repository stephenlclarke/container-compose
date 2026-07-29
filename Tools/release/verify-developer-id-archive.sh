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

set -euo pipefail

if [[ "$#" -ne 1 ]]; then
    printf 'usage: %s ARCHIVE\n' "$(basename "$0")" >&2
    exit 2
fi

archive="$1"
codesign_command="${CODESIGN:-codesign}"
file_command="${FILE_COMMAND:-file}"

if [[ ! -f "${archive}" ]]; then
    printf 'signature verification archive does not exist: %s\n' "${archive}" >&2
    exit 1
fi

temporary_root="$(mktemp -d "${TMPDIR:-/tmp}/container-compose-signature.XXXXXX")"
cleanup() {
    rm -rf "${temporary_root}"
}
trap cleanup EXIT

python3 - "${archive}" "${temporary_root}" <<'PY'
import posixpath
import sys
import tarfile

archive_path, output_path = sys.argv[1:]
with tarfile.open(archive_path, "r:gz") as package:
    for member in package.getmembers():
        normalized_name = posixpath.normpath(member.name)
        if (
            member.name.startswith("/")
            or normalized_name == ".."
            or normalized_name.startswith("../")
        ):
            raise SystemExit(f"unsafe archive path: {member.name}")
        if not (
            member.isfile()
            or member.isdir()
            or member.issym()
            or member.islnk()
        ):
            raise SystemExit(f"unsupported archive entry: {member.name}")
        if member.issym() or member.islnk():
            link_base = (
                posixpath.dirname(normalized_name)
                if member.issym()
                else ""
            )
            normalized_link = posixpath.normpath(
                posixpath.join(link_base, member.linkname)
            )
            if (
                member.linkname.startswith("/")
                or normalized_link == ".."
                or normalized_link.startswith("../")
            ):
                raise SystemExit(
                    f"unsafe archive link: {member.name} -> {member.linkname}"
                )
    package.extractall(output_path)
PY

binary_count=0
expected_team_identifier=""
while IFS= read -r -d '' candidate; do
    description="$("${file_command}" -b "${candidate}")"
    if [[ "${description}" != Mach-O* ]]; then
        continue
    fi

    relative_path="${candidate#"${temporary_root}"/}"
    "${codesign_command}" --verify --strict --verbose=2 "${candidate}"
    signature="$("${codesign_command}" --display --verbose=4 "${candidate}" 2>&1)"

    if ! grep -Eq '^Authority=Developer ID Application: .+' <<<"${signature}"; then
        printf 'binary is not signed by a Developer ID Application identity: %s\n' \
            "${relative_path}" >&2
        exit 1
    fi
    if ! grep -Fxq 'Authority=Developer ID Certification Authority' <<<"${signature}"; then
        printf 'binary does not chain through the Developer ID certification authority: %s\n' \
            "${relative_path}" >&2
        exit 1
    fi
    if ! grep -Fxq 'Authority=Apple Root CA' <<<"${signature}"; then
        printf 'binary does not chain to the Apple Root CA: %s\n' \
            "${relative_path}" >&2
        exit 1
    fi
    if ! grep -Eq '^Timestamp=.+' <<<"${signature}"; then
        printf 'binary is missing a secure signing timestamp: %s\n' \
            "${relative_path}" >&2
        exit 1
    fi
    if ! grep -Eq '^flags=.*runtime' <<<"${signature}"; then
        printf 'binary is missing the hardened runtime signature flag: %s\n' \
            "${relative_path}" >&2
        exit 1
    fi

    team_identifier="$(
        sed -n 's/^TeamIdentifier=//p' <<<"${signature}" \
            | head -n 1
    )"
    if [[ ! "${team_identifier}" =~ ^[A-Z0-9]{10}$ ]]; then
        printf 'binary has an invalid Developer ID team identifier: %s\n' \
            "${relative_path}" >&2
        exit 1
    fi
    if [[ -z "${expected_team_identifier}" ]]; then
        expected_team_identifier="${team_identifier}"
    elif [[ "${team_identifier}" != "${expected_team_identifier}" ]]; then
        printf 'archive mixes Developer ID teams: %s uses %s, expected %s\n' \
            "${relative_path}" "${team_identifier}" \
            "${expected_team_identifier}" >&2
        exit 1
    fi

    printf 'Verified Developer ID signature: %s (team %s)\n' \
        "${relative_path}" "${team_identifier}"
    ((binary_count += 1))
done < <(find "${temporary_root}" -type f -print0)

if ((binary_count == 0)); then
    printf 'archive contains no Mach-O binaries: %s\n' "${archive}" >&2
    exit 1
fi

printf 'Verified %s Developer ID signed Mach-O binaries in %s\n' \
    "${binary_count}" "$(basename "${archive}")"
