process RUN_REPOSITORY_STAGE {
    tag "${stageName}@${repositoryName}"
    label 'repository_stage'
    cache 'deep'
    errorStrategy 'terminate'
    maxRetries 0
    publishDir "${params.evidenceDir}/receipts", mode: 'copy', overwrite: true

    input:
    tuple val(stageName), val(repositoryName), val(failureClass),
        val(deadlineSeconds), val(stageCommandBase64), val(artifactPaths),
        val(sourcePaths), path(sourcePayload), path(sourceMetadata),
        path(stageTools), val(gateReady)
    path deadlineRunner
    val stateRootBase64
    val sessionIdentifier

    output:
    tuple val(repositoryName), val(stageName),
        path("${stageName}.receipt.tsv"), path("${stageName}.stdout.log"),
        path("${stageName}.stderr.log"),
        path("${stageName}.artifacts.tar"),
        path("${stageName}.artifacts.tsv"), emit: receipt

    shell:
    '''
    exec </dev/null
    if IFS= read -r unexpected_input; then
        printf 'pipeline stage inherited readable standard input: %s\n' \
            "$unexpected_input" >&2
        exit 90
    fi

    decode_parameter() {
        printf '%s' "$1" | /usr/bin/base64 -D
    }

    task_root="$PWD"
    stage_name="!{stageName}"
    repository_name="!{repositoryName}"
    failure_class="!{failureClass}"
    deadline_seconds="!{deadlineSeconds}"
    artifact_paths="!{artifactPaths}"
    source_paths="!{sourcePaths}"
    source_payload="$task_root/!{sourcePayload}"
    source_metadata="$task_root/!{sourceMetadata}"
    stage_tools="$task_root/!{stageTools}"
    staged_deadline_runner="$task_root/!{deadlineRunner}"
    state_root="$(decode_parameter '!{stateRootBase64}')"
    session_identifier="!{sessionIdentifier}"
    success_receipt="$task_root/!{stageName}.receipt.tsv"
    failure_receipt="$task_root/!{stageName}.failure.tsv"
    stdout_log="$task_root/!{stageName}.stdout.log"
    stderr_log="$task_root/!{stageName}.stderr.log"
    artifact_archive="$task_root/!{stageName}.artifacts.tar"
    artifact_manifest="$task_root/!{stageName}.artifacts.tsv"
    execution_root=
    stage_command=
    failure_session_root=
    semantic_cache_root=

    record_result_and_cleanup() {
        local stage_status="$1"
        local evidence_status=0
        set +e

        if [[ "$repository_name" == container ]] && [[ -n "$execution_root" ]] &&
            [[ -d "$execution_root/cache/container-semantic-helper" ]]; then
            for cached_archive in \
                "$execution_root/cache/container-semantic-helper"/*.tar.gz; do
                [[ -f "$cached_archive" ]] || continue
                if [[ -L "$cached_archive" ]]; then
                    evidence_status=74
                    continue
                fi
                archive_name="${cached_archive##*/}"
                archive_temporary="$(/usr/bin/mktemp \
                    "$semantic_cache_root/.${archive_name}.XXXXXX")" || {
                    evidence_status=$?
                    continue
                }
                /bin/cp "$cached_archive" "$archive_temporary" &&
                    /bin/mv "$archive_temporary" \
                        "$semantic_cache_root/$archive_name" ||
                    evidence_status=$?
            done
        fi

        if ((stage_status != 0)); then
            {
                printf 'schema\t1\n'
                printf 'stage\t%s\n' "$stage_name"
                printf 'repository\t%s\n' "$repository_name"
                printf 'classification\t%s\n' "$failure_class"
                printf 'exit\t%s\n' "$stage_status"
                printf 'workdir\t%s\n' "$task_root"
            } >"$failure_receipt"

            failure_staging="$failure_session_root/.${stage_name}.$$"
            failure_final="$failure_session_root/${stage_name}"
            if [[ -L "$failure_staging" ]] || [[ -e "$failure_staging" ]]; then
                evidence_status=74
            else
                /bin/mkdir "$failure_staging" || evidence_status=$?
            fi
            for evidence_file in "$failure_receipt" "$stdout_log" \
                "$stderr_log" "$stage_command" \
                "$task_root/.command.sh" "$task_root/.command.run"; do
                if [[ -f "$evidence_file" ]]; then
                    /bin/cp "$evidence_file" "$failure_staging/" ||
                        evidence_status=$?
                fi
            done
            if ((evidence_status == 0)); then
                if [[ -e "$failure_final" ]] || [[ -L "$failure_final" ]]; then
                    failure_final="${failure_final}.$$"
                fi
                if [[ -e "$failure_final" ]] || [[ -L "$failure_final" ]]; then
                    evidence_status=74
                else
                    /bin/mv "$failure_staging" "$failure_final" ||
                        evidence_status=$?
                fi
            fi
        fi

        if [[ -n "$execution_root" ]] &&
            [[ "$execution_root" == /private/tmp/container-compose-pipeline.* ]] &&
            [[ -f "$execution_root/.container-compose-execution-root" ]] &&
            [[ "$(<"$execution_root/.container-compose-execution-root")" == \
                'container-compose internal execution v1' ]]; then
            /usr/bin/find -P "$execution_root" -type d \
                -exec /bin/chmod u+w {} + || evidence_status=$?
            /bin/rm -rf -- "$execution_root" || evidence_status=$?
        fi
        if ((evidence_status != 0)); then
            printf 'failed to persist evidence or clean stage state: %s\n' \
                "$stage_name" >&2
            return 74
        fi
        return "$stage_status"
    }
    handle_exit() {
        local stage_status=$?
        local final_status
        trap - EXIT
        record_result_and_cleanup "$stage_status"
        final_status=$?
        exit "$final_status"
    }

    case "$repository_name" in
        container-compose|container-builder-shim|containerization|container|container-engine-api|devcontainer|container-k8s|homebrew-tap) ;;
        *) printf 'unsupported repository name: %s\n' "$repository_name" >&2; exit 2 ;;
    esac
    if ! [[ "$stage_name" =~ ^[a-z0-9][a-z0-9-]*$ ]] ||
        ! [[ "$failure_class" =~ ^(source|test|build)$ ]] ||
        ! [[ "$deadline_seconds" =~ ^[1-9][0-9]*$ ]] ||
        ! [[ "$artifact_paths" =~ ^(none|[A-Za-z0-9._/+ -]+)$ ]]; then
        printf 'invalid stage declaration: %s/%s/%s\n' \
            "$stage_name" "$failure_class" "$deadline_seconds" >&2
        exit 2
    fi
    test "!{gateReady}" = true
    test -s "$source_payload"
    test -s "$source_metadata"
    test -s "$stage_tools"
    test -x "$staged_deadline_runner"
    case "$state_root" in /*) ;; *) exit 2 ;; esac
    [[ "$session_identifier" =~ ^[[:xdigit:]]{8}-[[:xdigit:]]{4}-[[:xdigit:]]{4}-[[:xdigit:]]{4}-[[:xdigit:]]{12}$ ]]
    if [[ -L "$state_root" ]] || [[ ! -d "$state_root" ]]; then
        printf 'pipeline state root is indirect or invalid: %s\n' \
            "$state_root" >&2
        exit 2
    fi
    canonical_state="$(cd "$state_root" && pwd -P)"
    state_root="$canonical_state"
    state_marker="$state_root/.container-compose-pipeline-root"
    if [[ -L "$state_marker" ]] || [[ ! -f "$state_marker" ]] ||
        [[ "$(<"$state_marker")" != \
            'container-compose recoverable pipeline v1' ]]; then
        printf 'pipeline state marker is indirect or invalid: %s\n' \
            "$state_marker" >&2
        exit 2
    fi

    require_managed_directory() {
        local managed_name="$1"
        local managed_path="$state_root/$managed_name"
        local canonical_managed
        if [[ -L "$managed_path" ]] || [[ ! -d "$managed_path" ]]; then
            printf 'pipeline managed path is indirect or invalid: %s\n' \
                "$managed_path" >&2
            return 2
        fi
        canonical_managed="$(cd "$managed_path" && pwd -P)"
        if [[ "$canonical_managed" != "$state_root/$managed_name" ]]; then
            printf 'pipeline managed path escaped the marked root: %s\n' \
                "$canonical_managed" >&2
            return 2
        fi
    }
    require_managed_directory caches
    require_managed_directory failures

    failure_session_root="$state_root/failures/$session_identifier"
    if [[ -L "$failure_session_root" ]] ||
        [[ -e "$failure_session_root" && ! -d "$failure_session_root" ]]; then
        printf 'pipeline failure session path is indirect or invalid: %s\n' \
            "$failure_session_root" >&2
        exit 2
    fi
    /bin/mkdir -p "$failure_session_root"
    if [[ -L "$failure_session_root" ]] || [[ ! -d "$failure_session_root" ]] ||
        [[ "$(cd "$failure_session_root" && pwd -P)" != \
            "$state_root/failures/$session_identifier" ]]; then
        printf 'pipeline failure session path escaped its managed parent: %s\n' \
            "$failure_session_root" >&2
        exit 2
    fi

    if [[ "$repository_name" == container ]]; then
        semantic_cache_root="$state_root/caches/container-semantic-helper-downloads"
        if [[ -L "$semantic_cache_root" ]] ||
            [[ -e "$semantic_cache_root" && ! -d "$semantic_cache_root" ]]; then
            printf 'pipeline semantic-helper cache is indirect or invalid: %s\n' \
                "$semantic_cache_root" >&2
            exit 2
        fi
        if [[ ! -d "$semantic_cache_root" ]]; then
            /bin/mkdir "$semantic_cache_root"
        fi
        if [[ -L "$semantic_cache_root" ]] || [[ ! -d "$semantic_cache_root" ]] ||
            [[ "$(cd "$semantic_cache_root" && pwd -P)" != \
                "$state_root/caches/container-semantic-helper-downloads" ]]; then
            printf 'pipeline semantic-helper cache escaped its managed parent: %s\n' \
                "$semantic_cache_root" >&2
            exit 2
        fi
    fi
    trap handle_exit EXIT

    metadata_stage="$(/usr/bin/awk -F '\t' '$1 == "stage" { print $2 }' \
        "$source_metadata")"
    metadata_repository="$(/usr/bin/awk -F '\t' \
        '$1 == "repository" { print $2 }' "$source_metadata")"
    source_format="$(/usr/bin/awk -F '\t' '$1 == "format" { print $2 }' \
        "$source_metadata")"
    expected_payload_sha256="$(/usr/bin/awk -F '\t' \
        '$1 == "payload-sha256" { print $2 }' "$source_metadata")"
    expected_commit="$(/usr/bin/awk -F '\t' '$1 == "commit" { print $2 }' \
        "$source_metadata")"
    expected_branch="$(/usr/bin/awk -F '\t' '$1 == "branch" { print $2 }' \
        "$source_metadata")"
    expected_describe="$(/usr/bin/awk -F '\t' \
        '$1 == "describe" { print $2 }' "$source_metadata")"
    expected_origin_base64="$(/usr/bin/awk -F '\t' \
        '$1 == "origin-base64" { print $2 }' "$source_metadata")"
    expected_origin="$(decode_parameter "$expected_origin_base64")"
    actual_payload_sha256="$(/usr/bin/shasum -a 256 "$source_payload" | \
        /usr/bin/awk '{ print $1 }')"
    if [[ "$metadata_stage" != "$stage_name" ]] ||
        [[ "$metadata_repository" != "$repository_name" ]] ||
        ! [[ "$expected_payload_sha256" =~ ^[0-9a-f]{64}$ ]] ||
        [[ "$actual_payload_sha256" != "$expected_payload_sha256" ]] ||
        ! [[ "$source_format" =~ ^(git-bundle|git-tree-archive)$ ]]; then
        printf 'source payload metadata is invalid: %s\n' "$stage_name" >&2
        exit 2
    fi
    if [[ -n "$expected_commit" ]] &&
        ! [[ "$expected_commit" =~ ^[0-9a-f]{40}$ ]]; then
        printf 'declared source commit is invalid: %s\n' "$stage_name" >&2
        exit 2
    fi
    recorded_path="$(/usr/bin/awk -F '\t' '$1 == "path" { print $2 }' \
        "$stage_tools")"
    recorded_developer_directory="$(/usr/bin/awk -F '\t' \
        '$1 == "xcode-developer-dir" { print $2 }' "$stage_tools")"
    if [[ -z "$recorded_path" ]] || [[ "$recorded_path" == *$'\n'* ]] ||
        [[ "$recorded_path" == *$'\t'* ]]; then
        printf 'stage tool manifest has no valid PATH: %s\n' "$stage_name" >&2
        exit 2
    fi
    IFS=':' read -r -a path_components <<<"$recorded_path"
    for path_component in "${path_components[@]}"; do
        if [[ -z "$path_component" ]] || [[ "$path_component" != /* ]]; then
            printf 'stage tool PATH contains an empty or relative component: %s\n' \
                "$recorded_path" >&2
            exit 2
        fi
    done
    if [[ "$recorded_developer_directory" != /* ]] ||
        [[ ! -d "$recorded_developer_directory" ]]; then
        printf 'stage tool manifest has no valid Apple developer directory: %s\n' \
            "$stage_name" >&2
        exit 2
    fi
    if [[ -n "$expected_branch" ]] && [[ "$expected_branch" != HEAD ]]; then
        DEVELOPER_DIR="$recorded_developer_directory" \
            /usr/bin/git check-ref-format --branch "$expected_branch" >/dev/null
    fi

    verify_tool_closure() {
        while IFS=$'\t' read -r record_type field_one field_two field_three \
            field_four _remaining; do
            case "$record_type" in
                tool)
                tool_name="$field_one"
                tool_path="$field_two"
                expected_tool_sha256="$field_three"
                [[ "$tool_path" == /* ]] && [[ -x "$tool_path" ]] &&
                    [[ -f "$tool_path" ]] || exit 2
                actual_tool_sha256="$(/usr/bin/shasum -a 256 "$tool_path" | \
                    /usr/bin/awk '{ print $1 }')"
                [[ "$actual_tool_sha256" == "$expected_tool_sha256" ]] || {
                    printf 'stage tool changed after preflight: %s (%s)\n' \
                        "$tool_name" "$stage_name" >&2
                    exit 2
                }
                case "$tool_name" in
                    system-*) resolved_tool="$tool_path" ;;
                    apple-swift) resolved_tool=/usr/bin/swift ;;
                    codesign) resolved_tool=/usr/bin/codesign ;;
                    docc)
                        resolved_tool="$( \
                            DEVELOPER_DIR="$recorded_developer_directory" \
                            /usr/bin/xcrun --find docc)"
                        ;;
                    otool) resolved_tool=/usr/bin/otool ;;
                    *) resolved_tool="$(PATH="$recorded_path" command -v \
                        "$tool_name" 2>/dev/null || true)" ;;
                esac
                if [[ "$resolved_tool" != "$tool_path" ]]; then
                    printf 'stage tool resolution changed after preflight: %s\n' \
                        "$tool_name" >&2
                    exit 2
                fi
                    ;;
                interpreter)
                interpreter_owner="$field_one"
                interpreter_path="$field_three"
                expected_interpreter_sha256="$field_four"
                [[ "$interpreter_path" == /* ]] && [[ -x "$interpreter_path" ]] &&
                    [[ -f "$interpreter_path" ]] || exit 2
                actual_interpreter_sha256="$(/usr/bin/shasum -a 256 \
                    "$interpreter_path" | /usr/bin/awk '{ print $1 }')"
                [[ "$actual_interpreter_sha256" == \
                    "$expected_interpreter_sha256" ]] || {
                    printf 'script interpreter changed after preflight: %s (%s)\n' \
                        "$interpreter_owner" "$stage_name" >&2
                        exit 2
                }
                    ;;
                xcrun-tool)
                xcrun_name="$field_one"
                expected_resolved_path="$field_two"
                expected_resolved_sha256="$field_three"
                current_resolved_path="$( \
                    DEVELOPER_DIR="$recorded_developer_directory" \
                    /usr/bin/xcrun --find "$xcrun_name")"
                [[ "$current_resolved_path" == "$expected_resolved_path" ]] &&
                    [[ "$current_resolved_path" == /* ]] &&
                    [[ -x "$current_resolved_path" ]] &&
                    [[ -f "$current_resolved_path" ]] || {
                    printf 'xcrun tool resolution changed: %s (%s)\n' \
                        "$xcrun_name" "$stage_name" >&2
                    exit 2
                }
                current_resolved_sha256="$(/usr/bin/shasum -a 256 \
                    "$current_resolved_path" | /usr/bin/awk '{ print $1 }')"
                [[ "$current_resolved_sha256" == \
                    "$expected_resolved_sha256" ]] || {
                    printf 'xcrun tool changed after preflight: %s (%s)\n' \
                        "$xcrun_name" "$stage_name" >&2
                        exit 2
                }
                    ;;
                tool-tree)
                tree_owner="$field_one"
                tree_root="$field_two"
                expected_tree_sha256="$field_three"
                [[ "$tree_root" == /* ]] && [[ -d "$tree_root" ]] &&
                    [[ "$expected_tree_sha256" =~ ^[0-9a-f]{64}$ ]] || {
                    printf 'tool dependency tree identity is invalid: %s (%s)\n' \
                        "$tree_owner" "$stage_name" >&2
                    exit 2
                }
                current_tree_sha256="$( \
                    cd "$tree_root"
                    COPYFILE_DISABLE=1 /usr/bin/tar -cf - . | \
                        /usr/bin/shasum -a 256 | \
                        /usr/bin/awk '{ print $1 }'
                )"
                [[ "$current_tree_sha256" == "$expected_tree_sha256" ]] || {
                    printf 'tool dependency tree changed after preflight: %s (%s)\n' \
                        "$tree_owner" "$stage_name" >&2
                        exit 2
                }
                    ;;
                go-environment)
                go_environment_name="$field_one"
                expected_go_environment_value="$field_two"
                recorded_go_path="$(/usr/bin/awk -F '\t' \
                    '$1 == "tool" && $2 == "go" { print $3 }' \
                    "$stage_tools")"
                [[ "$go_environment_name" =~ ^(GOROOT|GOVERSION|GOHOSTOS|GOHOSTARCH|GOTOOLDIR)$ ]] &&
                    [[ "$recorded_go_path" == /* ]] &&
                    [[ -x "$recorded_go_path" ]] || {
                    printf 'Go environment manifest is invalid: %s (%s)\n' \
                        "$go_environment_name" "$stage_name" >&2
                    exit 2
                }
                /bin/mkdir -p "$task_root/go-environment-home"
                current_go_environment_value="$(/usr/bin/env -i \
                    PATH="$recorded_path" \
                    HOME="$task_root/go-environment-home" \
                    DEVELOPER_DIR="$recorded_developer_directory" \
                    GOTOOLCHAIN=local GOENV=off \
                    "$recorded_go_path" env "$go_environment_name")"
                [[ "$current_go_environment_value" == \
                    "$expected_go_environment_value" ]] || {
                    printf 'Go environment changed after preflight: %s (%s)\n' \
                        "$go_environment_name" "$stage_name" >&2
                    exit 2
                }
                    ;;
            esac
        done <"$stage_tools"

        current_developer_directory="$( \
            DEVELOPER_DIR="$recorded_developer_directory" \
            /usr/bin/xcode-select -p)"
        [[ "$current_developer_directory" == \
            "$recorded_developer_directory" ]] || {
            printf 'Apple developer directory changed after preflight: %s\n' \
                "$stage_name" >&2
            exit 2
        }
        recorded_sdk_path="$(/usr/bin/awk -F '\t' \
            '$1 == "xcode-sdk-path" { print $2 }' "$stage_tools")"
        if [[ -n "$recorded_sdk_path" ]]; then
            current_sdk_path="$(DEVELOPER_DIR="$recorded_developer_directory" \
                /usr/bin/xcrun --show-sdk-path)"
            current_sdk_version="$(DEVELOPER_DIR="$recorded_developer_directory" \
                /usr/bin/xcrun --show-sdk-version)"
            current_sdk_build_version="$(DEVELOPER_DIR="$recorded_developer_directory" \
                /usr/bin/xcrun --show-sdk-build-version)"
            DEVELOPER_DIR="$recorded_developer_directory" \
                /usr/bin/swift -print-target-info >current-swift-target-info.json
            current_swift_target_sha256="$(/usr/bin/shasum -a 256 \
                current-swift-target-info.json | /usr/bin/awk '{ print $1 }')"
            [[ "$current_sdk_path" == "$recorded_sdk_path" ]]
            [[ "$current_sdk_version" == "$(/usr/bin/awk -F '\t' \
                '$1 == "xcode-sdk-version" { print $2 }' "$stage_tools")" ]]
            [[ "$current_sdk_build_version" == "$(/usr/bin/awk -F '\t' \
                '$1 == "xcode-sdk-build-version" { print $2 }' "$stage_tools")" ]]
            [[ "$current_swift_target_sha256" == "$(/usr/bin/awk -F '\t' \
                '$1 == "swift-target-info-sha256" { print $2 }' "$stage_tools")" ]]
        fi
    }
    verify_tool_closure

    execution_root="$(/usr/bin/mktemp -d \
        "/private/tmp/container-compose-pipeline.${stage_name}.XXXXXX")"
    printf '%s\n' 'container-compose internal execution v1' \
        >"$execution_root/.container-compose-execution-root"
    /bin/mkdir -p "$execution_root/source" "$execution_root/home/.config" \
        "$execution_root/docker-config" "$execution_root/tmp" \
        "$execution_root/cache/container-semantic-helper" \
        "$execution_root/tool-bin"
    printf '{}\n' >"$execution_root/docker-config/config.json"
    /bin/cp "$source_payload" "$execution_root/source-input"
    /bin/cp "$staged_deadline_runner" "$execution_root/deadline-runner.py"
    /bin/chmod 0500 "$execution_root/deadline-runner.py"
    internal_payload="$execution_root/source-input"
    deadline_runner="$execution_root/deadline-runner.py"

    install_tool_link() {
        local link_name="$1"
        local link_target="$2"
        if ! [[ "$link_name" =~ ^[A-Za-z0-9._+-]+$ ]] ||
            [[ "$link_target" != /* ]] || [[ ! -x "$link_target" ]]; then
            printf 'invalid stage tool link: %s -> %s\n' \
                "$link_name" "$link_target" >&2
            exit 2
        fi
        link_path="$execution_root/tool-bin/$link_name"
        if [[ -L "$link_path" ]]; then
            [[ "$(/usr/bin/readlink "$link_path")" == "$link_target" ]] || {
                printf 'conflicting stage tool link: %s\n' "$link_name" >&2
                exit 2
            }
        elif [[ -e "$link_path" ]]; then
            printf 'stage tool link destination already exists: %s\n' \
                "$link_path" >&2
            exit 2
        else
            /bin/ln -s "$link_target" "$link_path"
        fi
    }
    while IFS=$'\t' read -r record_type field_one field_two field_three \
        field_four _remaining; do
        case "$record_type" in
            tool)
                case "$field_one" in
                    system-*) continue ;;
                    apple-swift) tool_alias=swift ;;
                    *) tool_alias="$field_one" ;;
                esac
                install_tool_link "$tool_alias" "$field_two"
                ;;
            interpreter)
                install_tool_link "$field_two" "$field_three"
                ;;
        esac
    done <"$stage_tools"
    stage_execution_path="$execution_root/tool-bin:/usr/bin:/bin:/usr/sbin:/sbin"

    if [[ "$repository_name" == container ]] &&
        [[ -d "$semantic_cache_root" ]]; then
        for cached_archive in \
            "$semantic_cache_root"/*.tar.gz; do
            [[ -f "$cached_archive" ]] || continue
            if [[ -L "$cached_archive" ]]; then
                printf 'pipeline semantic-helper cache entry is indirect: %s\n' \
                    "$cached_archive" >&2
                exit 2
            fi
            /bin/cp "$cached_archive" \
                "$execution_root/cache/container-semantic-helper/"
        done
    fi

    metadata_environment=(
        "PIPELINE_ORIGINAL_COMMIT=$expected_commit"
        "PIPELINE_ORIGINAL_DESCRIBE=$expected_describe"
        "PIPELINE_INTERNAL_CACHE_ROOT=$execution_root/cache"
    )
    if [[ -n "$expected_commit" ]]; then
        metadata_environment+=("GIT_COMMIT=$expected_commit")
    fi
    developer_environment=("DEVELOPER_DIR=$recorded_developer_directory")

    run_clean() {
        /usr/bin/env -i \
            PATH="$stage_execution_path" \
            HOME="$execution_root/home" \
            XDG_CONFIG_HOME="$execution_root/home/.config" \
            DOCKER_CONFIG="$execution_root/docker-config" \
            TMPDIR="$execution_root/tmp" \
            CI=1 \
            GOTOOLCHAIN=local \
            GOENV=off \
            GIT_TERMINAL_PROMPT=0 \
            GCM_INTERACTIVE=never \
            SSH_ASKPASS_REQUIRE=never \
            HOMEBREW_NO_AUTO_UPDATE=1 \
            GIT_CONFIG_NOSYSTEM=1 \
            GIT_CONFIG_GLOBAL=/dev/null \
            GIT_CONFIG_SYSTEM=/dev/null \
            GIT_AUTHOR_NAME=container-compose-pipeline \
            GIT_AUTHOR_EMAIL=pipeline.invalid \
            GIT_COMMITTER_NAME=container-compose-pipeline \
            GIT_COMMITTER_EMAIL=pipeline.invalid \
            GIT_AUTHOR_DATE=2000-01-01T00:00:00Z \
            GIT_COMMITTER_DATE=2000-01-01T00:00:00Z \
            LC_ALL=C LANG=C TERM=dumb TZ=UTC ZERO_AR_DATE=1 \
            "${developer_environment[@]}" \
            "${metadata_environment[@]}" \
            "$@"
    }

    if [[ "$source_format" == git-bundle ]]; then
        [[ -n "$expected_commit" ]] || exit 2
        run_clean /usr/bin/python3 "$deadline_runner" --seconds 300 -- \
            /usr/bin/git clone --quiet --no-checkout "$internal_payload" \
                "$execution_root/source"
        run_clean /usr/bin/python3 "$deadline_runner" --seconds 300 -- \
            /usr/bin/git -C "$execution_root/source" checkout --quiet \
                --detach "$expected_commit"
    else
        run_clean /usr/bin/python3 "$deadline_runner" --seconds 120 -- \
            /usr/bin/tar -xf "$internal_payload" -C "$execution_root/source"
        run_clean /usr/bin/git -C "$execution_root/source" init --quiet
        run_clean /usr/bin/git -C "$execution_root/source" \
            checkout --quiet -b pipeline-stage
        run_clean /usr/bin/git -C "$execution_root/source" add --force --all
        run_clean /usr/bin/git -C "$execution_root/source" \
            commit --quiet --no-gpg-sign -m 'deterministic stage source'
        if [[ -n "$expected_describe" ]]; then
            run_clean /usr/bin/git -C "$execution_root/source" \
                check-ref-format "refs/tags/$expected_describe"
            run_clean /usr/bin/git -C "$execution_root/source" \
                tag "$expected_describe"
        fi
    fi

    if [[ -n "$expected_commit" ]] && [[ "$source_format" == git-bundle ]]; then
        [[ "$(run_clean /usr/bin/git -C "$execution_root/source" rev-parse HEAD)" == \
            "$expected_commit" ]]
    fi
    if [[ -n "$expected_describe" ]]; then
        [[ "$(run_clean /usr/bin/git -C "$execution_root/source" \
            describe --tags --always)" == "$expected_describe" ]]
    fi
    [[ -z "$(run_clean /usr/bin/git -C "$execution_root/source" \
        status --porcelain=v1 --untracked-files=all)" ]]

    stage_command="$execution_root/stage-command.sh"
    {
        printf '%s\n' '#!/usr/bin/env bash' 'set -euo pipefail'
        decode_parameter '!{stageCommandBase64}'
        printf '\n'
    } >"$stage_command"
    /bin/chmod 0700 "$stage_command"

    set +e
    (
        cd "$execution_root/source"
        run_clean /usr/bin/python3 "$deadline_runner" \
            --seconds "$deadline_seconds" -- "$stage_command"
    ) >"$stdout_log" 2>"$stderr_log"
    stage_status=$?
    set -e
    /bin/cat "$stdout_log"
    /bin/cat "$stderr_log" >&2
    if ((stage_status != 0)); then
        exit "$stage_status"
    fi
    verify_tool_closure

    artifact_count=0
    artifact_arguments=()
    {
        printf 'schema\t1\n'
        printf 'stage\t%s\n' "$stage_name"
        printf 'repository\t%s\n' "$repository_name"
    } >"$artifact_manifest"
    if [[ "$artifact_paths" != none ]]; then
        read -r -a requested_artifacts <<<"$artifact_paths"
        for requested_artifact in "${requested_artifacts[@]}"; do
            if [[ "$requested_artifact" == /* ]] ||
                [[ "$requested_artifact" == -* ]] ||
                [[ "$requested_artifact" == '..' ]] ||
                [[ "$requested_artifact" == ../* ]] ||
                [[ "$requested_artifact" == */../* ]] ||
                [[ "$requested_artifact" == */.. ]]; then
                printf 'unsafe stage artifact path: %s\n' \
                    "$requested_artifact" >&2
                exit 2
            fi
            artifact_source="$execution_root/source/$requested_artifact"
            if [[ -L "$artifact_source" ]] || [[ ! -f "$artifact_source" ]]; then
                printf 'declared stage artifact is not a regular file: %s\n' \
                    "$requested_artifact" >&2
                exit 2
            fi
            artifact_sha256="$(/usr/bin/shasum -a 256 "$artifact_source" | \
                /usr/bin/awk '{ print $1 }')"
            artifact_size="$(/usr/bin/stat -f '%z' "$artifact_source")"
            printf 'artifact\t%s\t%s\t%s\n' "$requested_artifact" \
                "$artifact_sha256" "$artifact_size" >>"$artifact_manifest"
            artifact_arguments+=("$requested_artifact")
            ((artifact_count += 1))
        done
        (
            cd "$execution_root/source"
            COPYFILE_DISABLE=1 /usr/bin/tar -cf "$artifact_archive" \
                "${artifact_arguments[@]}"
        )
    else
        COPYFILE_DISABLE=1 /usr/bin/tar -cf "$artifact_archive" \
            --files-from /dev/null
    fi
    test -s "$artifact_archive"
    artifact_archive_sha256="$(/usr/bin/shasum -a 256 "$artifact_archive" | \
        /usr/bin/awk '{ print $1 }')"
    printf 'artifact-count\t%s\n' "$artifact_count" >>"$artifact_manifest"
    printf 'archive-sha256\t%s\n' "$artifact_archive_sha256" \
        >>"$artifact_manifest"

    command_sha256="$(/usr/bin/shasum -a 256 "$stage_command" | \
        /usr/bin/awk '{ print $1 }')"
    tools_sha256="$(/usr/bin/shasum -a 256 "$stage_tools" | \
        /usr/bin/awk '{ print $1 }')"
    source_metadata_sha256="$(/usr/bin/shasum -a 256 "$source_metadata" | \
        /usr/bin/awk '{ print $1 }')"
    stdout_sha256="$(/usr/bin/shasum -a 256 "$stdout_log" | \
        /usr/bin/awk '{ print $1 }')"
    stderr_sha256="$(/usr/bin/shasum -a 256 "$stderr_log" | \
        /usr/bin/awk '{ print $1 }')"
    artifact_manifest_sha256="$(/usr/bin/shasum -a 256 \
        "$artifact_manifest" | /usr/bin/awk '{ print $1 }')"
    {
        printf 'schema\t3\n'
        printf 'stage\t%s\n' "$stage_name"
        printf 'repository\t%s\n' "$repository_name"
        printf 'source-format\t%s\n' "$source_format"
        printf 'source-payload-sha256\t%s\n' "$actual_payload_sha256"
        printf 'source-metadata-sha256\t%s\n' "$source_metadata_sha256"
        printf 'classification\t%s\n' "$failure_class"
        printf 'deadline-seconds\t%s\n' "$deadline_seconds"
        printf 'command-sha256\t%s\n' "$command_sha256"
        printf 'stage-tools-sha256\t%s\n' "$tools_sha256"
        printf 'stdout-sha256\t%s\n' "$stdout_sha256"
        printf 'stderr-sha256\t%s\n' "$stderr_sha256"
        printf 'artifact-archive-sha256\t%s\n' \
            "$artifact_archive_sha256"
        printf 'artifact-manifest-sha256\t%s\n' \
            "$artifact_manifest_sha256"
        printf 'artifact-count\t%s\n' "$artifact_count"
        printf 'stdin-closed\ttrue\n'
        printf 'environment\tallowlisted\n'
        printf 'timezone\tUTC\n'
        printf 'execution-volume\tinternal\n'
        printf 'exit\t0\n'
    } >"$success_receipt"
    '''
}
