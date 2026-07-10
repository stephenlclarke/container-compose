#!/usr/bin/env bash
# USAGE: check-compose-bridge.sh [--strict]
#
# Compare Docker Compose and container-compose Bridge conversion and
# transformer-management behavior against Docker's maintained e2e fixture.

set -euo pipefail

readonly SELF_PATH="${BASH_SOURCE[0]:-$0}"
REPO_ROOT="$(cd "$(dirname "$SELF_PATH")/../.." && pwd)"
readonly REPO_ROOT
readonly CONTAINER_COMPOSE="${CONTAINER_COMPOSE:-$REPO_ROOT/.build/debug/compose}"
readonly FIXTURE_DIR="${DOCKER_COMPOSE_BRIDGE_FIXTURE:-$REPO_ROOT/.build/parity/docker-compose-e2e/pkg/e2e/fixtures/bridge}"
readonly KUBERNETES_TRANSFORMER="${BRIDGE_KUBERNETES_TRANSFORMER:-docker/compose-bridge-kubernetes@sha256:4ffd3f23f377b1fdd9d0195732980e7534a8975c8a210a12681dc803c002f761}"
readonly HELM_TRANSFORMER="${BRIDGE_HELM_TRANSFORMER:-docker/compose-bridge-helm@sha256:7aeee453c13045dcec87b92cb13973871ed8c72d5ca1e9365886487782ea2b09}"

STRICT=0
WORK_DIR=""
DOCKER_COMPOSE_COMMAND=()

# Print a fatal parity diagnostic.
error() {
    printf 'error: %s\n' "$*" >&2
}

# Print a non-fatal parity diagnostic.
warning() {
    printf 'warning: %s\n' "$*" >&2
}

# Print normal parity progress.
info() {
    printf '%s\n' "$*"
}

# Render command usage from the script header.
usage() {
    sed -n 's/^# \{0,1\}//p' "$SELF_PATH" | sed -n '/^USAGE:/,/^$/p'
}

# Parse strict-mode and help flags.
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

# Fail strict runs or skip optional local runs.
skip_or_fail() {
    local message="$1"

    if ((STRICT == 1)); then
        error "$message"
        return 1
    fi

    warning "$message; skipping Compose Bridge parity check"
    exit 0
}

# Select an available Docker Compose V2 command.
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

# Validate the binaries, fixture, and helper tools used by this check.
check_tools() {
    if [[ ! -x "$CONTAINER_COMPOSE" ]]; then
        skip_or_fail "container-compose binary is not executable: $CONTAINER_COMPOSE"
    fi
    if [[ ! -f "$FIXTURE_DIR/compose.yaml" ]]; then
        skip_or_fail "Docker Compose Bridge fixture is missing: $FIXTURE_DIR"
    fi
    if ! command -v diff >/dev/null 2>&1; then
        skip_or_fail 'diff is not available'
    fi
    if ! command -v python3 >/dev/null 2>&1; then
        skip_or_fail 'python3 is not available'
    fi
    if ! "${DOCKER_COMPOSE_COMMAND[@]}" version >/dev/null 2>&1; then
        skip_or_fail 'Docker Compose is not runnable'
    fi
    if ! "$CONTAINER_COMPOSE" version >/dev/null 2>&1; then
        skip_or_fail 'container-compose is not runnable'
    fi
}

# Compare two generated artifact trees recursively.
compare_tree() {
    local actual="$1"
    local expected="$2"
    local label="$3"

    if ! diff -ru "$expected" "$actual"; then
        error "$label differs from Docker Compose's expected Bridge output"
        return 1
    fi
}

# Validate Docker-shaped table, JSON, and quiet transformer output.
assert_transformer_list() {
    local command="$1"
    local table_output="$2"
    local json_output="$3"
    local quiet_output="$4"

    if [[ "$table_output" != *"IMAGE ID"* || "$table_output" != *"REPO"* || "$table_output" != *"TAGS"* || "$table_output" != *"SIZE"* ]]; then
        error "$command table output is missing Docker Compose transformer headers"
        return 1
    fi

    BRIDGE_LIST_JSON="$json_output" BRIDGE_LIST_QUIET="$quiet_output" BRIDGE_LIST_TABLE="$table_output" python3 - "$command" <<'PY'
import json
import os
import sys

label = sys.argv[1]
payload = json.loads(os.environ["BRIDGE_LIST_JSON"])
if not isinstance(payload, list) or len(payload) < 2:
    raise SystemExit(f"{label} JSON output did not contain both transformer summaries")
required = {"Containers", "Created", "Id", "Labels", "ParentId", "RepoDigests", "RepoTags", "SharedSize", "Size"}
ids = []
expected_quiet = []
for record in payload:
    missing = required.difference(record)
    if missing:
        raise SystemExit(f"{label} JSON summary is missing keys: {sorted(missing)}")
    ids.append(record["Id"])
    labels = record.get("Labels") or {}
    if labels.get("com.docker.compose.bridge") != "transformation":
        raise SystemExit(f"{label} JSON summary is missing the transformer label")
    repo_tags = record.get("RepoTags")
    if not isinstance(repo_tags, list) or not repo_tags:
        raise SystemExit(f"{label} JSON summary has no displayable transformer reference")
    reference = repo_tags[0]
    expected_quiet.append(reference)
    repository = reference.split("@", 1)[0]
    last_segment = repository.rsplit("/", 1)[-1]
    if "@" in reference:
        tag = "<none>"
    elif ":" in last_segment:
        repository, tag = repository.rsplit(":", 1)
    else:
        tag = "latest"
    table = os.environ["BRIDGE_LIST_TABLE"]
    if repository not in table or tag not in table:
        raise SystemExit(f"{label} table output is missing {repository}:{tag}")
if len(ids) != len(set(ids)):
    raise SystemExit(f"{label} JSON output contains duplicate image IDs")

quiet = [line for line in os.environ["BRIDGE_LIST_QUIET"].splitlines() if line]
if quiet != expected_quiet:
    raise SystemExit(f"{label} quiet output does not match JSON RepoTags")
PY
}

# Compare transformer identities and references while allowing runtime-specific size accounting.
compare_transformer_lists() {
    local docker_json="$1"
    local container_json="$2"

    DOCKER_BRIDGE_LIST_JSON="$docker_json" CONTAINER_BRIDGE_LIST_JSON="$container_json" python3 - <<'PY'
import json
import os

def identities(name):
    payload = json.loads(os.environ[name])
    return sorted(
        (record["Id"], tuple(sorted(record["RepoTags"])), tuple(sorted(record["RepoDigests"])))
        for record in payload
    )

docker = identities("DOCKER_BRIDGE_LIST_JSON")
container = identities("CONTAINER_BRIDGE_LIST_JSON")
if container != docker:
    raise SystemExit(
        "container-compose transformer identities differ from Docker Compose\n"
        f"Docker: {docker!r}\ncontainer-compose: {container!r}"
    )
PY
}

# Compare Kubernetes and Helm conversions with Docker's maintained fixtures.
check_conversions() {
    local compose_file="$FIXTURE_DIR/compose.yaml"
    local docker_kubernetes="$WORK_DIR/docker-kubernetes"
    local container_kubernetes="$WORK_DIR/container-kubernetes"
    local docker_helm="$WORK_DIR/docker-helm"
    local container_helm="$WORK_DIR/container-helm"
    local kubernetes_image="$KUBERNETES_TRANSFORMER"
    local helm_image="$HELM_TRANSFORMER"

    local docker_kubernetes_ready=0
    local docker_helm_ready=0

    if "${DOCKER_COMPOSE_COMMAND[@]}" -f "$compose_file" -p bridge bridge convert \
        --output "$docker_kubernetes" --transformation "$kubernetes_image"; then
        docker_kubernetes_ready=1
        compare_tree "$docker_kubernetes" "$FIXTURE_DIR/expected-kubernetes" 'Docker Compose Kubernetes conversion'
    else
        warning 'Docker Compose Kubernetes conversion is unavailable; using its maintained expected fixture as the strict oracle'
    fi
    "$CONTAINER_COMPOSE" -f "$compose_file" -p bridge bridge convert \
        --output "$container_kubernetes" --transformation "$kubernetes_image"
    compare_tree "$container_kubernetes" "$FIXTURE_DIR/expected-kubernetes" 'container-compose Kubernetes conversion'
    if ((docker_kubernetes_ready == 1)); then
        compare_tree "$container_kubernetes" "$docker_kubernetes" 'container-compose Kubernetes conversion'
    fi

    if "${DOCKER_COMPOSE_COMMAND[@]}" -f "$compose_file" -p bridge bridge convert \
        --output "$docker_helm" --transformation "$helm_image"; then
        docker_helm_ready=1
        compare_tree "$docker_helm" "$FIXTURE_DIR/expected-helm" 'Docker Compose Helm conversion'
    else
        warning 'Docker Compose Helm conversion is unavailable; using its maintained expected fixture as the strict oracle'
    fi
    "$CONTAINER_COMPOSE" -f "$compose_file" -p bridge bridge convert \
        --output "$container_helm" --transformation "$helm_image"
    compare_tree "$container_helm" "$FIXTURE_DIR/expected-helm" 'container-compose Helm conversion'
    if ((docker_helm_ready == 1)); then
        compare_tree "$container_helm" "$docker_helm" 'container-compose Helm conversion'
    fi
}

# Check list and ls output against Docker Compose.
check_transformer_lists() {
    local docker_table docker_json docker_quiet
    local container_table container_json container_quiet

    docker_table="$("${DOCKER_COMPOSE_COMMAND[@]}" bridge transformations list)"
    docker_json="$("${DOCKER_COMPOSE_COMMAND[@]}" bridge transformations list --format json)"
    docker_quiet="$("${DOCKER_COMPOSE_COMMAND[@]}" bridge transformations list --quiet)"
    container_table="$("$CONTAINER_COMPOSE" bridge transformations ls)"
    container_json="$("$CONTAINER_COMPOSE" bridge transformations list --format json)"
    container_quiet="$("$CONTAINER_COMPOSE" bridge transformations list --quiet)"

    assert_transformer_list 'Docker Compose' "$docker_table" "$docker_json" "$docker_quiet"
    assert_transformer_list 'container-compose' "$container_table" "$container_json" "$container_quiet"
    compare_transformer_lists "$docker_json" "$container_json"
}

# Compare transformer source extraction byte for byte.
check_transformer_create() {
    local image="$KUBERNETES_TRANSFORMER"
    local docker_output="$WORK_DIR/docker-transformer"
    local container_output="$WORK_DIR/container-transformer"

    "${DOCKER_COMPOSE_COMMAND[@]}" bridge transformations create --from "$image" "$docker_output"
    "$CONTAINER_COMPOSE" bridge transformations create --from "$image" "$container_output"
    compare_tree "$container_output" "$docker_output" 'container-compose transformer creation'
}

# Remove the private parity workspace.
cleanup() {
    if [[ -n "$WORK_DIR" ]]; then
        rm -rf "$WORK_DIR"
    fi
}

# Run all Bridge parity checks.
main() {
    parse_args "$@"
    detect_docker_compose
    check_tools
    WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/compose-bridge-parity.XXXXXX")"
    trap cleanup EXIT
    check_conversions
    check_transformer_lists
    check_transformer_create
    info 'Docker Compose Bridge parity passed.'
}

main "$@"
