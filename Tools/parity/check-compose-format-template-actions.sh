#!/usr/bin/env bash
#===----------------------------------------------------------------------===#
# Copyright (c) 2026 container-compose project authors.
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

#
# USAGE:
#   check-compose-format-template-actions.sh [options]
#
# OPTIONS:
#   --strict    Fail when Docker Compose V2 or container-compose is unavailable.
#   -h, --help  Show this help.
#
# ENVIRONMENT:
#   CONTAINER_COMPOSE  Path to the container-compose binary. Defaults to the
#                      local SwiftPM debug build at .build/debug/compose.
#   DOCKER_COMPOSE     Docker Compose command to compare with. Defaults to
#                      "docker compose" when available, otherwise docker-compose.
#
# This script keeps Docker Compose V2 and container-compose aligned for
# row-template functions, control actions, variables, whitespace trimming,
# label lookup, raw Go-string output, root-value validation, and structured
# publisher traversal across `ps`, `stats`, and `volumes`. It deliberately uses
# Compose-generated fields instead of image references because runtimes may
# canonicalize equivalent image names differently.

set -euo pipefail

readonly SELF_PATH="${BASH_SOURCE[0]:-$0}"
SCRIPT_NAME="$(basename "$SELF_PATH")"
readonly SCRIPT_NAME
REPO_ROOT="$(cd "$(dirname "$SELF_PATH")/../.." && pwd)"
readonly REPO_ROOT

STRICT=0
CONTAINER_COMPOSE="${CONTAINER_COMPOSE:-$REPO_ROOT/.build/debug/compose}"
DOCKER_COMPOSE_COMMAND=()
readonly FIXTURE_DIR="$REPO_ROOT/Tools/parity/fixtures/output-template"
DOCKER_PROJECT="cc-format-docker-$RANDOM"
CONTAINER_PROJECT="cc-format-container-$RANDOM"

# Writes a normal progress line.
info() {
    printf '%s\n' "$*"
}

# Writes a recoverable warning to stderr.
warning() {
    printf 'warning: %s\n' "$*" >&2
}

# Writes a failure message to stderr.
error() {
    printf 'error: %s\n' "$*" >&2
}

# Prints command usage from the header.
usage() {
    sed -n '/^# USAGE:/,/^# This script/ { /^# This script/d; s/^# //; s/^#//; p; }' "$SELF_PATH" \
        | sed "s/check-compose-format-template-actions.sh/$SCRIPT_NAME/"
}

# Parses script arguments.
parse_args() {
    while (($# > 0)); do
        case "$1" in
            --strict)
                STRICT=1
                shift
                ;;
            -h | --help)
                usage
                exit 0
                ;;
            *)
                error "unknown argument: $1"
                usage >&2
                return 2
                ;;
        esac
    done
}

# Skips a missing optional dependency unless strict mode requires it.
skip_or_fail() {
    local message="$1"

    if ((STRICT == 1)); then
        error "$message"
        return 1
    fi

    warning "$message; skipping Docker Compose format-template parity check"
    exit 0
}

# Chooses a usable Docker Compose V2 command.
detect_docker_compose() {
    if [[ -n "${DOCKER_COMPOSE:-}" ]]; then
        IFS=' ' read -r -a DOCKER_COMPOSE_COMMAND <<<"$DOCKER_COMPOSE"
    elif docker compose version >/dev/null 2>&1; then
        DOCKER_COMPOSE_COMMAND=(docker compose)
    elif command -v docker-compose >/dev/null 2>&1 && docker-compose version >/dev/null 2>&1; then
        DOCKER_COMPOSE_COMMAND=(docker-compose)
    else
        skip_or_fail 'Docker Compose V2 is not available'
    fi
}

# Verifies that both comparison commands can run.
check_tools() {
    if ! command -v docker >/dev/null 2>&1 || ! docker info >/dev/null 2>&1; then
        skip_or_fail 'Docker Engine is not available'
    fi
    if [[ ! -x "$CONTAINER_COMPOSE" ]]; then
        skip_or_fail "container-compose binary is not executable: $CONTAINER_COMPOSE"
    fi
}

# Removes only the two isolated generated projects.
cleanup() {
    "${DOCKER_COMPOSE_COMMAND[@]}" --project-name "$DOCKER_PROJECT" -f "$FIXTURE_DIR/compose.yaml" \
        down --remove-orphans --volumes >/dev/null 2>&1 || true
    "$CONTAINER_COMPOSE" --project-name "$CONTAINER_PROJECT" -f "$FIXTURE_DIR/compose.yaml" \
        down --remove-orphans --volumes >/dev/null 2>&1 || true
}

# Compares one formatter result with its expected value.
assert_equal() {
    local actual="$1"
    local expected="$2"
    local label="$3"

    if [[ "$actual" != "$expected" ]]; then
        printf 'actual:   %q\nexpected: %q\n' "$actual" "$expected" >&2
        error "$label did not match Docker Compose V2"
        return 1
    fi
}

# Verifies that malformed Go-template execution fails instead of producing
# plausible but incompatible output.
assert_rejected() {
    local label="$1"
    shift

    if "$@" >/dev/null 2>&1; then
        error "$label unexpectedly succeeded"
        return 1
    fi
}

# Runs the shared ps template against one Compose implementation.
template_output() {
    local project="$1"
    shift
    "$@" --project-name "$project" -f "$FIXTURE_DIR/compose.yaml" ps \
        --format '{{upper .Service}}\t{{truncate .Name 6}}\t{{json .Name}}\t{{join (split .Name "-") "/"}}'
}

# Runs the control/nested formatter surface against one implementation.
check_implementation() {
    local project="$1"
    shift
    local command=("$@")
    local actual combining expected name volume_name

    name="$project-api-1"
    volume_name="${project}_cache"
    combining=$'e\u0301'
    "${command[@]}" --project-name "$project" -f "$FIXTURE_DIR/compose.yaml" \
        up --detach --wait --wait-timeout 120 >/dev/null

    expected="API"$'\t'"cc-for"$'\t'"\"$name\""$'\t'"${name//-/\/}"
    actual="$(template_output "$project" "${command[@]}")"
    assert_equal "$actual" "$expected" "$project ps function template"

    actual="$(
        "${command[@]}" --project-name "$project" -f "$FIXTURE_DIR/compose.yaml" ps \
            --format '{{if .Name}}{{with index .Publishers 0}}{{.URL}}|{{.TargetPort}}|{{.PublishedPort}}|{{.Protocol}}{{end}}|{{.Label "oracle.example/key"}}{{else}}missing{{end}}'
    )"
    assert_equal "$actual" '127.0.0.1|8080|32768|tcp|value' "$project ps control template"

    actual="$(
        "${command[@]}" --project-name "$project" -f "$FIXTURE_DIR/compose.yaml" ps \
            --format '{{with ""}}missing{{else with .Service}}{{.}}{{end}}'
    )"
    assert_equal "$actual" 'api' "$project ps else-with template"

    actual="$(
        "${command[@]}" --project-name "$project" -f "$FIXTURE_DIR/compose.yaml" ps \
            --format '{{range .Publishers}}{{$.Label "oracle.example/key"}}{{end}}'
    )"
    assert_equal "$actual" 'value' "$project root label template"

    actual="$(
        "${command[@]}" --project-name "$project" -f "$FIXTURE_DIR/compose.yaml" ps \
            --format '{{"oracle.example/key" | .Label | upper}}|{{range .Publishers}}{{"oracle.example/key" | $.Label}}{{end}}'
    )"
    assert_equal "$actual" 'VALUE|value' "$project pipeline label template"

    actual="$(
        "${command[@]}" --project-name "$project" -f "$FIXTURE_DIR/compose.yaml" ps \
            --format '{{printf "%d" .ExitCode}}|{{eq .ExitCode 0}}'
    )"
    assert_equal "$actual" '0|true' "$project typed default exit-code template"

    actual="$(
        "${command[@]}" --project-name "$project" -f "$FIXTURE_DIR/compose.yaml" ps \
            --format 'missing={{.Label "oracle.example/missing"}}'
    )"
    assert_equal "$actual" 'missing=' "$project missing label template"

    actual="$(
        "${command[@]}" --project-name "$project" -f "$FIXTURE_DIR/compose.yaml" ps \
            --format '{{/* emitted as }} ( */}}{{.Name}}'
    )"
    assert_equal "$actual" "$name" "$project comment delimiter template"

    actual="$(
        "${command[@]}" --project-name "$project" -f "$FIXTURE_DIR/compose.yaml" ps \
            --format '{{if(.Name)}}{{with(index .Publishers 0)}}{{.TargetPort}}{{end}}|{{range(.Publishers)}}{{.PublishedPort}}{{end}}{{end}}'
    )"
    assert_equal "$actual" '8080|32768' "$project compact control template"

    # Go-template variables must reach Compose literally.
    # shellcheck disable=SC2016
    actual="$(
        "${command[@]}" --project-name "$project" -f "$FIXTURE_DIR/compose.yaml" ps \
            --format '{{range $publisher:=.Publishers}}{{$publisher.TargetPort}}{{end}}'
    )"
    assert_equal "$actual" '8080' "$project compact one-variable range template"

    # Go-template variables must reach Compose literally.
    # shellcheck disable=SC2016
    actual="$(
        "${command[@]}" --project-name "$project" -f "$FIXTURE_DIR/compose.yaml" ps \
            --format '{{range $index,$publisher:=.Publishers}}{{$index}}={{$publisher.TargetPort}}{{end}}'
    )"
    assert_equal "$actual" '0=8080' "$project compact two-variable range template"

    actual="$(
        "${command[@]}" --project-name "$project" -f "$FIXTURE_DIR/compose.yaml" ps \
            --format '{{(index .Publishers 0).TargetPort}}'
    )"
    assert_equal "$actual" '8080' "$project parenthesized selector template"

    actual="$(
        "${command[@]}" --project-name "$project" -f "$FIXTURE_DIR/compose.yaml" ps \
            --format '{{len "é"}}|{{index "é" 0}}|{{index "é" 1}}|{{printf "%q" (slice "é" 0 1)}}|{{printf "%q" (slice "é" 1 2)}}'
    )"
    assert_equal "$actual" '2|195|169|"\xc3"|"\xa9"' "$project UTF-8 byte helper template"

    actual="$(
        "${command[@]}" --project-name "$project" -f "$FIXTURE_DIR/compose.yaml" ps \
            --format '{{print 1 0}}|{{print true false}}|{{print 1 "x" 2}}|{{print "a" "b"}}|{{print "a" 1}}|{{print 1 "a"}}'
    )"
    assert_equal "$actual" '1 0|true false|1x2|ab|a1|1a' "$project print spacing template"

    actual="$(
        "${command[@]}" --project-name "$project" -f "$FIXTURE_DIR/compose.yaml" ps \
            --format '{{printf "%q" 7}}|{{printf "%q" true}}|{{printf "%q" "é"}}|{{printf "%q" 10}}'
    )"
    assert_equal "$actual" "'\\a'|%!q(bool=true)|\"é\"|'\\n'" "$project typed quote template"

    actual="$(
        "${command[@]}" --project-name "$project" -f "$FIXTURE_DIR/compose.yaml" ps \
            --format '{{printf "%q" .Publishers}}'
    )"
    assert_equal "$actual" \
        '[{"127.0.0.1" '\''ᾐ'\'' '\''耀'\'' "tcp"}]' \
        "$project structured quote template"

    actual="$(
        "${command[@]}" --project-name "$project" -f "$FIXTURE_DIR/compose.yaml" ps \
            --format '{{.Publishers}}|{{printf "%v" .Publishers}}'
    )"
    assert_equal "$actual" \
        '[{127.0.0.1 8080 32768 tcp}]|[{127.0.0.1 8080 32768 tcp}]' \
        "$project publisher struct display template"

    actual="$(
        "${command[@]}" --project-name "$project" -f "$FIXTURE_DIR/compose.yaml" ps \
            --format '{{join .Publishers ","}}'
    )"
    assert_equal "$actual" \
        '{127.0.0.1 8080 32768 tcp}' \
        "$project structured join template"

    actual="$(
        "${command[@]}" --project-name "$project" -f "$FIXTURE_DIR/compose.yaml" ps \
            --format '{{truncate (upper .Labels) 0}}|{{join (slice (split .Labels ",") 0 0) ""}}|{{truncate .Labels 0}}|{{eq (index .Labels 0) (index .Labels 0)}}|{{slice .Labels 0 0}}'
    )"
    assert_equal "$actual" '|||true|' "$project Labels Go-string helper template"

    actual="$(
        "${command[@]}" --project-name "$project" -f "$FIXTURE_DIR/compose.yaml" ps \
            --format '{{range .Publishers}}{{printf "%s|%d|%5s|%-5d" .TargetPort .Protocol .TargetPort .Protocol}}{{end}}'
    )"
    assert_equal "$actual" \
        '%!s(int=8080)|%!d(string=tcp)|%!s(int= 8080)|%!d(string=tcp  )' \
        "$project typed printf verb template"

    actual="$(
        "${command[@]}" --project-name "$project" -f "$FIXTURE_DIR/compose.yaml" ps \
            --format "{{printf \"[%2s]|[%3s]|[%-3s]\" \"$combining\" \"$combining\" \"$combining\"}}"
    )"
    assert_equal "$actual" \
        "[$combining]|[ $combining]|[$combining ]" \
        "$project printf rune width template"

    # Go-template variables must reach Compose literally.
    # shellcheck disable=SC2016
    actual="$(
        "${command[@]}" --project-name "$project" -f "$FIXTURE_DIR/compose.yaml" ps \
            --format '{{range $index, $publisher := .Publishers}}{{$index}}={{$publisher.TargetPort}}/{{$publisher.PublishedPort}}/{{end}}'
    )"
    assert_equal "$actual" '0=8080/32768/' "$project ps range template"

    actual="$(
        "${command[@]}" --project-name "$project" -f "$FIXTURE_DIR/compose.yaml" ps \
            --format 'table {{.Name}}\t{{.Name}}'
    )"
    assert_equal "$(printf '%s\n' "$actual" | sed -n '1p' | awk '{$1=$1; print}')" \
        'NAME NAME' "$project duplicate table headers"
    assert_equal "$(printf '%s\n' "$actual" | sed -n '2p' | awk '{$1=$1; print}')" \
        "$name $name" "$project duplicate table row"

    actual="$(
        "${command[@]}" --project-name "$project" -f "$FIXTURE_DIR/compose.yaml" ps \
            --format 'table {{if .Health}}{{.Health}}{{else}}{{.Status}}{{end}}'
    )"
    assert_equal "$(printf '%s\n' "$actual" | sed -n '1p' | awk '{$1=$1; print}')" \
        'STATUS' "$project conditional table header"

    local field_name
    for field_name in ExitCode Health LocalVolumes Mounts Names Networks Publishers; do
        actual="$(
            "${command[@]}" --project-name "$project" -f "$FIXTURE_DIR/compose.yaml" ps \
                --format "table {{.$field_name}}" \
                | sed -n '1p'
        )"
        assert_equal "$actual" '<no value>' "$project $field_name table header"
    done

    actual="$(
        "${command[@]}" --project-name "$project" -f "$FIXTURE_DIR/compose.yaml" ps \
            --format 'table {{.Label "oracle.example/key"}}'
    )"
    assert_equal "$actual" $'example/key\nvalue' "$project label table header"

    actual="$(
        "${command[@]}" --project-name "$project" -f "$FIXTURE_DIR/compose.yaml" ps \
            --format 'table {{"oracle.example/key" | print | printf "%s" | .Label}}'
    )"
    assert_equal "$actual" $'example/key\nvalue' "$project pipeline label table header"

    actual="$(
        "${command[@]}" --project-name "$project" -f "$FIXTURE_DIR/compose.yaml" ps \
            --format 'table {{"foo" | upper | .Label}}'
    )"
    assert_equal "$actual" $'foo\nupper' "$project upper label table header"

    actual="$(
        "${command[@]}" --project-name "$project" -f "$FIXTURE_DIR/compose.yaml" ps \
            --format 'table {{"FOO" | lower | .Label}}'
    )"
    assert_equal "$actual" $'FOO\nlower' "$project lower label table header"

    actual="$(
        "${command[@]}" --project-name "$project" -f "$FIXTURE_DIR/compose.yaml" ps \
            --format 'table {{"foo" | title | .Label}}'
    )"
    assert_equal "$actual" $'foo\ntitle' "$project title label table header"

    actual="$(
        "${command[@]}" --project-name "$project" -f "$FIXTURE_DIR/compose.yaml" ps \
            --format 'table {{pad "foo" 0 0 | .Label}}'
    )"
    assert_equal "$actual" $'foo\nlower' "$project pad label table header"

    actual="$(
        "${command[@]}" --project-name "$project" -f "$FIXTURE_DIR/compose.yaml" ps \
            --format 'table {{truncate "foo-extra" 3 | .Label}}'
    )"
    assert_equal "$actual" $'foo extra\nlower' "$project truncate label table header"

    actual="$(
        "${command[@]}" --project-name "$project" -f "$FIXTURE_DIR/compose.yaml" ps \
            --format '{{with . | or (index .Publishers 0)}}{{.TargetPort}}{{end}}'
    )"
    assert_equal "$actual" '8080' "$project logical publisher context"

    actual="$(
        "${command[@]}" --project-name "$project" -f "$FIXTURE_DIR/compose.yaml" ps \
            --format '{{join (split "abc" "") "-"}}'
    )"
    assert_equal "$actual" 'a-b-c' "$project empty separator split"

    actual="$(
        "${command[@]}" --project-name "$project" -f "$FIXTURE_DIR/compose.yaml" ps \
            --format '{{printf "%q" (split "" "")}}'
    )"
    assert_equal "$actual" '[]' "$project empty input split"

    actual="$(
        "${command[@]}" --project-name "$project" -f "$FIXTURE_DIR/compose.yaml" ps \
            --format '{{printf "%q" (truncate "é" 1)}}'
    )"
    assert_equal "$actual" '"\xc3"' "$project UTF-8 byte truncate"

    actual="$(
        "${command[@]}" --project-name "$project" -f "$FIXTURE_DIR/compose.yaml" ps \
            --format '{{printf "%q" (split (truncate "é" 1) "")}}'
    )"
    assert_equal "$actual" '["\xc3"]' "$project partial UTF-8 split"

    actual="$(
        "${command[@]}" --project-name "$project" -f "$FIXTURE_DIR/compose.yaml" ps \
            --format '{{truncate "é" 1}}' \
            | od -An -tx1 \
            | tr -d ' \n'
    )"
    assert_equal "$actual" 'c30a' "$project exact raw UTF-8 byte output"

    actual="$(
        "${command[@]}" --project-name "$project" -f "$FIXTURE_DIR/compose.yaml" ps \
            --format '{{printf "%s" (truncate "é" 1)}}' \
            | od -An -tx1 \
            | tr -d ' \n'
    )"
    assert_equal "$actual" 'c30a' "$project exact formatted UTF-8 byte output"

    assert_rejected "$project negative UTF-8 byte truncate" \
        "${command[@]}" --project-name "$project" -f "$FIXTURE_DIR/compose.yaml" ps \
        --format '{{truncate "abc" -1}}'
    # Root values are structs rather than maps in Docker's formatter context.
    # shellcheck disable=SC2016
    assert_rejected "$project root value index template" \
        "${command[@]}" --project-name "$project" -f "$FIXTURE_DIR/compose.yaml" ps \
        --format '{{index $ "Command"}}'
    # `table` is a --format prefix and is not registered as a Go template
    # function by Docker Compose.
    # shellcheck disable=SC2016
    assert_rejected "$project table function template" \
        "${command[@]}" --project-name "$project" -f "$FIXTURE_DIR/compose.yaml" ps \
        --format '{{with table $}}{{.Command}}{{end}}'

    actual="$(
        "${command[@]}" --project-name "$project" -f "$FIXTURE_DIR/compose.yaml" ps \
            --format 'A {{- if .Name -}} B {{- end -}} C'
    )"
    assert_equal "$actual" 'ABC' "$project ps whitespace template"

    actual="$(
        "${command[@]}" --project-name "$project" -f "$FIXTURE_DIR/compose.yaml" stats \
            --no-stream --no-trunc --format '{{if .Name}}{{.Name}}{{else}}missing{{end}}' api
    )"
    assert_equal "$actual" "$name" "$project stats control template"

    actual="$(
        "${command[@]}" --project-name "$project" -f "$FIXTURE_DIR/compose.yaml" stats \
            --no-stream --no-trunc --format '{{with ""}}missing{{else with .Name}}{{.}}{{end}}' api
    )"
    assert_equal "$actual" "$name" "$project stats else-with template"

    actual="$(
        "${command[@]}" --project-name "$project" -f "$FIXTURE_DIR/compose.yaml" stats \
            --no-stream --no-trunc --format 'table {{.Name}}\t{{.CPUPerc}}' api
    )"
    assert_equal "$(printf '%s\n' "$actual" | sed -n '1p' | awk '{$1=$1; print}')" \
        'NAME CPU %' "$project stats table headers"

    actual="$(
        "${command[@]}" --project-name "$project" -f "$FIXTURE_DIR/compose.yaml" volumes \
            --format '{{if .Name}}{{.Name}}={{.Label "oracle.example/key"}}{{else}}missing{{end}}'
    )"
    assert_equal "$actual" "$volume_name=value" "$project volumes control template"

    actual="$(
        "${command[@]}" --project-name "$project" -f "$FIXTURE_DIR/compose.yaml" volumes \
            --format '{{with ""}}missing{{else with .Name}}{{.}}{{end}}'
    )"
    assert_equal "$actual" "$volume_name" "$project volumes else-with template"

    actual="$(
        "${command[@]}" --project-name "$project" -f "$FIXTURE_DIR/compose.yaml" volumes \
            --format 'table {{.Name}}\t{{.Driver}}'
    )"
    assert_equal "$(printf '%s\n' "$actual" | sed -n '1p' | awk '{$1=$1; print}')" \
        'VOLUME NAME DRIVER' "$project volume table headers"

    assert_rejected "$project string range template" \
        "${command[@]}" --project-name "$project" -f "$FIXTURE_DIR/compose.yaml" ps \
        --format '{{range .Name}}{{.}}{{end}}'
    assert_rejected "$project mixed comparison template" \
        "${command[@]}" --project-name "$project" -f "$FIXTURE_DIR/compose.yaml" ps \
        --format '{{range .Publishers}}{{if eq .TargetPort "8080"}}invalid{{end}}{{end}}'
    assert_rejected "$project scalar length template" \
        "${command[@]}" --project-name "$project" -f "$FIXTURE_DIR/compose.yaml" ps \
        --format '{{range .Publishers}}{{len .TargetPort}}{{end}}'
    assert_rejected "$project non-string map key template" \
        "${command[@]}" --project-name "$project" -f "$FIXTURE_DIR/compose.yaml" ps \
        --format '{{index .Labels true}}'
    assert_rejected "$project string array index template" \
        "${command[@]}" --project-name "$project" -f "$FIXTURE_DIR/compose.yaml" ps \
        --format '{{index .Publishers "0"}}'
    assert_rejected "$project string byte index template" \
        "${command[@]}" --project-name "$project" -f "$FIXTURE_DIR/compose.yaml" ps \
        --format '{{index .Name "1"}}'
    assert_rejected "$project string slice bound template" \
        "${command[@]}" --project-name "$project" -f "$FIXTURE_DIR/compose.yaml" ps \
        --format '{{slice .Name "0" 1}}'
    assert_rejected "$project non-string printf format template" \
        "${command[@]}" --project-name "$project" -f "$FIXTURE_DIR/compose.yaml" ps \
        --format '{{range .Publishers}}{{printf .TargetPort}}{{end}}'
    assert_rejected "$project integer label key template" \
        "${command[@]}" --project-name "$project" -f "$FIXTURE_DIR/compose.yaml" ps \
        --format '{{.Label 1}}'
    assert_rejected "$project pipeline label arity template" \
        "${command[@]}" --project-name "$project" -f "$FIXTURE_DIR/compose.yaml" ps \
        --format '{{"oracle.example/key" | .Label "other"}}'
    assert_rejected "$project publisher label key template" \
        "${command[@]}" --project-name "$project" -f "$FIXTURE_DIR/compose.yaml" ps \
        --format '{{range .Publishers}}{{$.Label .TargetPort}}{{end}}'
    assert_rejected "$project nested scalar field template" \
        "${command[@]}" --project-name "$project" -f "$FIXTURE_DIR/compose.yaml" ps \
        --format '{{range .Publishers}}{{.TargetPort.Bad}}{{end}}'
    assert_rejected "$project missing publisher field template" \
        "${command[@]}" --project-name "$project" -f "$FIXTURE_DIR/compose.yaml" ps \
        --format '{{range .Publishers}}{{.Unknown}}{{end}}'
    # Go-template variables must reach Compose literally.
    # shellcheck disable=SC2016
    assert_rejected "$project undefined variable template" \
        "${command[@]}" --project-name "$project" -f "$FIXTURE_DIR/compose.yaml" ps \
        --format '{{range $index, $publisher := .Publishers}}{{$missing.TargetPort}}{{end}}'

    "${command[@]}" --project-name "$project" -f "$FIXTURE_DIR/compose.yaml" \
        down --remove-orphans --volumes >/dev/null

    "${command[@]}" --project-name "$project" -f "$FIXTURE_DIR/compose.yaml" \
        run --detach --no-deps api >/dev/null
    # Go-template variables must reach Compose literally.
    # shellcheck disable=SC2016
    actual="$(
        "${command[@]}" --project-name "$project" -f "$FIXTURE_DIR/compose.yaml" ps --all \
            --format '{{range $publisher := .Publishers}}{{else}}{{len $publisher}}{{end}}'
    )"
    assert_equal "$actual" '0' "$project empty range variable template"
    "${command[@]}" --project-name "$project" -f "$FIXTURE_DIR/compose.yaml" \
        down --remove-orphans --volumes >/dev/null
}

# Confirms that selectors appended to a parenthesized root cannot bypass the
# supported-field gate. Docker Compose accepts Command, while container-compose
# deliberately rejects that unavailable field before asking the Apple runtime
# to discover containers.
check_container_field_validation() {
    "${DOCKER_COMPOSE_COMMAND[@]}" --project-name "$DOCKER_PROJECT" -f "$FIXTURE_DIR/compose.yaml" \
        ps --format '{{($).Command}}' >/dev/null
    assert_rejected "$CONTAINER_PROJECT parenthesized unsupported ps field" \
        "$CONTAINER_COMPOSE" --project-name "$CONTAINER_PROJECT" -f "$FIXTURE_DIR/compose.yaml" ps \
        --format '{{($).Command}}'
    "${DOCKER_COMPOSE_COMMAND[@]}" --project-name "$DOCKER_PROJECT" -f "$FIXTURE_DIR/compose.yaml" \
        ps --format '{{with or $ .Name}}{{.Command}}{{end}}' >/dev/null
    assert_rejected "$CONTAINER_PROJECT logical root unsupported ps field" \
        "$CONTAINER_COMPOSE" --project-name "$CONTAINER_PROJECT" -f "$FIXTURE_DIR/compose.yaml" ps \
        --format '{{with or $ .Name}}{{.Command}}{{end}}'
}

# Runs Docker first so both implementations can use the same fixed host port.
run_checks() {
    check_implementation "$DOCKER_PROJECT" "${DOCKER_COMPOSE_COMMAND[@]}"
    check_implementation "$CONTAINER_PROJECT" "$CONTAINER_COMPOSE"
    check_container_field_validation
}

# Runs the parity check.
main() {
    parse_args "$@"
    detect_docker_compose
    check_tools
    trap cleanup EXIT
    run_checks
    info 'Docker Compose structured format-template parity passed.'
}

main "$@"
