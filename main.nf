nextflow.enable.dsl = 2

include {
    RUN_REPOSITORY_STAGE as RUN_SOURCE_STAGE
} from './build-pipeline/modules/repository-stage'
include {
    RUN_REPOSITORY_STAGE as RUN_SWIFT_STAGE
} from './build-pipeline/modules/repository-stage'
include {
    RUN_REPOSITORY_STAGE as RUN_LIGHTWEIGHT_STAGE
} from './build-pipeline/modules/repository-stage'
include {
    RUN_REPOSITORY_STAGE as RUN_DOCUMENTATION_STAGE
} from './build-pipeline/modules/repository-stage'

params.pipelineProfile = 'repository'
params.pipelineAction = 'run'
params.stageSelector = ''
params.composeRepo = projectDir.toString()
params.composeRef = 'HEAD'
params.builderRepo = "${projectDir.parent}/container-builder-shim"
params.builderRef = 'HEAD'
params.containerizationRepo = "${projectDir.parent}/containerization"
params.containerizationRef = 'HEAD'
params.containerRepo = "${projectDir.parent}/container"
params.containerRef = 'HEAD'
params.engineApiRepo = "${projectDir.parent}/container-engine-api"
params.engineApiRef = 'HEAD'
params.devcontainerRepo = "${projectDir.parent}/devcontainer"
params.devcontainerRef = 'HEAD'
params.k8sRepo = "${projectDir.parent}/container-k8s"
params.k8sRef = 'HEAD'
params.homebrewRepo = "${projectDir.parent}/homebrew-tap"
params.homebrewRef = 'HEAD'
params.sourceTimeoutSeconds = 1800
params.functionalTimeoutSeconds = 7200
params.expectedNextflowVersion = '26.04.6'
params.expectedLauncherSha256 =
    '182a63c74074e2dc7956ffa3c8cd59de952ed2c44394e21faf5e1736b945444c'
params.launcherPath = "${projectDir}/.local/share/nextflow/26.04.6/nextflow"
params.deadlineRunner = "${projectDir}/Tools/ci/run-command-with-deadline.py"
params.stateRoot = "${projectDir}/.build/pipeline"
params.evidenceDir = "${params.stateRoot}/evidence/manual"
params.stateMarkerValue = 'container-compose recoverable pipeline v1'
params.executionPath = '/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin'
params.operatorHome = ''

def supportedProfiles() {
    ['focused', 'repository', 'stack', 'hosted-safe', 'release-hosted',
        'benchmark-reconstruction']
}

def encodeParameter(value) {
    value.toString().getBytes('UTF-8').encodeBase64().toString()
}

def persistSessionReceipt(evidenceDirectory, sessionIdentifier) {
    def directory = java.nio.file.Paths.get(evidenceDirectory.toString())
    if (!directory.isAbsolute() || !java.nio.file.Files.isDirectory(directory)) {
        error "The session evidence directory must be an existing absolute directory: ${directory}"
    }
    def temporary = directory.resolve('.session.uuid.tmp')
    java.nio.file.Files.writeString(
        temporary,
        "${sessionIdentifier}\n",
        java.nio.charset.StandardCharsets.UTF_8,
        java.nio.file.StandardOpenOption.CREATE,
        java.nio.file.StandardOpenOption.TRUNCATE_EXISTING,
    )
    java.nio.file.Files.move(
        temporary,
        directory.resolve('session.uuid'),
        java.nio.file.StandardCopyOption.ATOMIC_MOVE,
        java.nio.file.StandardCopyOption.REPLACE_EXISTING,
    )
}

def allRepositorySpecs() {
    [
        ['container-compose', params.composeRepo.toString(), params.composeRef.toString()],
        ['container-builder-shim', params.builderRepo.toString(), params.builderRef.toString()],
        ['containerization', params.containerizationRepo.toString(), params.containerizationRef.toString()],
        ['container', params.containerRepo.toString(), params.containerRef.toString()],
        ['container-engine-api', params.engineApiRepo.toString(), params.engineApiRef.toString()],
        ['devcontainer', params.devcontainerRepo.toString(), params.devcontainerRef.toString()],
        ['container-k8s', params.k8sRepo.toString(), params.k8sRef.toString()],
        ['homebrew-tap', params.homebrewRepo.toString(), params.homebrewRef.toString()],
    ]
}

def sourceStageSpecs() {
    [
        ['container-compose', 'compose-source', 'source', params.sourceTimeoutSeconds as Integer,
            'HAWKEYE_AUTO_INSTALL=0 make --no-print-directory PYTHON=python3 SWIFT=/usr/bin/swift GO=go MARKDOWNLINT=markdownlint HAWKEYE=hawkeye check',
            'make,apple-swift,go,gofmt,python3,ruby,markdownlint,hawkeye', '.', 'commit'],
        ['container-builder-shim', 'builder-source', 'source', params.sourceTimeoutSeconds as Integer,
            'mkdir -p .local/bin && ln -s "$(command -v hawkeye)" .local/bin/hawkeye && GOTOOLCHAIN=local make --no-print-directory GO=go GOLANGCI_LINT="$(command -v golangci-lint)" check-licenses vet lint',
            'make,go,golangci-lint,hawkeye', '.', 'commit,describe'],
        ['containerization', 'containerization-source', 'source', params.sourceTimeoutSeconds as Integer,
            'mkdir -p .local/bin && ln -s "$(command -v hawkeye)" .local/bin/hawkeye && HAWKEYE_AUTO_INSTALL=0 make --no-print-directory SWIFT=/usr/bin/swift check',
            'make,apple-swift,hawkeye', '.', 'commit'],
        ['container', 'container-source', 'source', params.sourceTimeoutSeconds as Integer,
            'mkdir -p .local/bin && ln -s "$(command -v hawkeye)" .local/bin/hawkeye && HAWKEYE_AUTO_INSTALL=0 make --no-print-directory PYTHON3=python3 check',
            'make,apple-swift,python3,hawkeye', '.', 'commit,describe'],
        ['container-engine-api', 'engine-api-source', 'source', params.sourceTimeoutSeconds as Integer,
            'python3 Tools/generate_route_ledger.py --check && python3 -m py_compile Tools/performance/*.py && python3 -B Tools/performance/check_engine_streaming_performance.py --self-test && /bin/bash -n Tools/ci/*.sh && swiftformat --lint Package.swift Sources Tests Tools/ContainerEngineStreamingPerformanceFixture && markdownlint README.md docs',
            'python3,swiftformat,markdownlint', '.', 'commit'],
        ['devcontainer', 'devcontainer-source', 'source', params.sourceTimeoutSeconds as Integer,
            'make --no-print-directory PYTHON=python3 MARKDOWNLINT=markdownlint SWIFTLINT=swiftlint SWIFTFORMAT=swiftformat ACTIONLINT=actionlint format-check lint parity-manifest',
            'make,python3,swiftformat,swiftlint,shellcheck,markdownlint,actionlint', '.', 'commit'],
        ['container-k8s', 'k8s-source', 'source', params.sourceTimeoutSeconds as Integer,
            'make --no-print-directory PYTHON=python3 MARKDOWNLINT=markdownlint check',
            'make,python3,markdownlint,ruby', '.', 'commit'],
        ['homebrew-tap', 'homebrew-source', 'source', params.sourceTimeoutSeconds as Integer,
            'ruby -c Formula/container-compose.rb', 'ruby', '.', 'commit'],
    ]
}

def functionalStageSpecs() {
    [
        ['container-compose', 'compose-swift-test', 'test', params.functionalTimeoutSeconds as Integer,
            'CONTAINER_COMPOSE_RUN_RUNTIME_TESTS=0 make --no-print-directory SWIFT=/usr/bin/swift PYTHON=python3 swift-test',
            'make,apple-swift,go,python3',
            'Package.swift Package.resolved Sources Tests Tools scripts Makefile config.toml docs/project/STATUS.md examples/logging/compose.yml',
            'none'],
        ['container-compose', 'compose-go-test', 'test', params.functionalTimeoutSeconds as Integer,
            'GOTOOLCHAIN=local GOPROXY=https://proxy.golang.org GOSUMDB=sum.golang.org make --no-print-directory GO=go go-test',
            'make,go', 'Tools/compose-normalizer Makefile', 'none'],
        ['container-compose', 'compose-cli-smoke', 'test', params.functionalTimeoutSeconds as Integer,
            'GOTOOLCHAIN=local GOPROXY=https://proxy.golang.org GOSUMDB=sum.golang.org make --no-print-directory SWIFT=/usr/bin/swift PYTHON=python3 GO=go build go-build cli-smoke-built',
            'make,apple-swift,go,python3,otool,codesign',
            'Package.swift Package.resolved Sources Tests Tools scripts Makefile config.toml docs/images/container-compose-icon-octopus.png',
            'none'],
        ['container-builder-shim', 'builder-test', 'test', params.functionalTimeoutSeconds as Integer,
            'GOTOOLCHAIN=local GIT_TAG="$PIPELINE_ORIGINAL_DESCRIBE" make --no-print-directory GO=go coverage',
            'make,go',
            'go.mod go.sum main.go main_test.go pkg vendor Makefile Protobuf.Makefile',
            'describe'],
        ['container-builder-shim', 'builder-build', 'build', params.functionalTimeoutSeconds as Integer,
            'GOTOOLCHAIN=local GIT_TAG="$PIPELINE_ORIGINAL_DESCRIBE" make --no-print-directory GO=go build',
            'make,go',
            'go.mod go.sum main.go pkg vendor Makefile Protobuf.Makefile',
            'describe'],
        ['containerization', 'containerization-test', 'test', params.functionalTimeoutSeconds as Integer,
            'CI=1 make --no-print-directory ROOT_DIR="$PWD" SWIFT=/usr/bin/swift test',
            'make,apple-swift',
            'Package.swift Package.resolved Sources Tests vminitd/Sources vminitd/Makefile Makefile Protobuf.Makefile .swift-version',
            'none'],
        ['containerization', 'containerization-build', 'build', params.functionalTimeoutSeconds as Integer,
            'CI=1 make --no-print-directory ROOT_DIR="$PWD" SWIFT=/usr/bin/swift containerization',
            'make,apple-swift,codesign',
            'Package.swift Package.resolved Sources Tests vminitd/Sources vminitd/Makefile Makefile Protobuf.Makefile .swift-version signing',
            'none'],
        ['container', 'container-build', 'build', params.functionalTimeoutSeconds as Integer,
            'CI=1 CONTAINER_SEMANTIC_HELPER_TOOLCHAIN_CACHE="$PIPELINE_INTERNAL_CACHE_ROOT/container-semantic-helper" make --no-print-directory ROOT_DIR="$PWD" PYTHON3=python3 GIT_COMMIT="$PIPELINE_ORIGINAL_COMMIT" RELEASE_VERSION="$PIPELINE_ORIGINAL_DESCRIBE" build',
            'make,apple-swift,codesign,python3',
            'Package.swift Package.resolved Sources Tests Tools scripts Makefile Protobuf.Makefile signing',
            'commit,describe'],
        ['container-engine-api', 'engine-api-build', 'build', params.functionalTimeoutSeconds as Integer,
            '/usr/bin/swift build --disable-automatic-resolution -Xswiftc -warnings-as-errors --build-tests && /usr/bin/swift build --disable-automatic-resolution -Xswiftc -warnings-as-errors --target ContainerEngineStreamingPerformanceFixture',
            'apple-swift',
            'Package.swift Package.resolved Sources Tests Tools/ContainerEngineStreamingPerformanceFixture',
            'none'],
        ['devcontainer', 'devcontainer-build', 'build', params.functionalTimeoutSeconds as Integer,
            'make --no-print-directory SWIFT=/usr/bin/swift build',
            'make,apple-swift',
            'Package.swift Package.resolved Sources Tests Plugins Tools/version-generator Makefile',
            'commit'],
        ['container-k8s', 'k8s-test', 'test', params.functionalTimeoutSeconds as Integer,
            '/usr/bin/swift test --disable-automatic-resolution',
            'apple-swift',
            'Package.swift Package.resolved Sources Tests Makefile APPLE_CONTAINER_REF',
            'none'],
        ['container-k8s', 'k8s-build-smoke', 'test', params.functionalTimeoutSeconds as Integer,
            '/usr/bin/swift build --disable-automatic-resolution --product k8s && make --no-print-directory cli-smoke-built',
            'make,apple-swift',
            'Package.swift Package.resolved Sources Tests Makefile APPLE_CONTAINER_REF',
            'none'],
    ]
}

def releaseHostedSourceStageSpecs() {
    [
        ['container-builder-shim', 'builder-release-source', 'source',
            params.sourceTimeoutSeconds as Integer,
            'test -f Makefile && test -f go.sum',
            'make,go', '.', 'commit,describe'],
        ['containerization', 'containerization-release-source', 'source',
            params.sourceTimeoutSeconds as Integer,
            'test -f Makefile && test -f Package.resolved',
            'make,apple-swift', '.', 'commit'],
        ['container', 'container-release-source', 'source',
            params.sourceTimeoutSeconds as Integer,
            'test -f Makefile && test -f Package.resolved',
            'make,apple-swift', '.', 'commit,describe'],
        ['homebrew-tap', 'homebrew-release-source', 'source',
            params.sourceTimeoutSeconds as Integer,
            'test -f Formula/container-compose.rb',
            'ruby', '.', 'commit'],
    ]
}

def releaseHostedFunctionalStageSpecs() {
    [
        ['container-builder-shim', 'builder-release-validation', 'test',
            params.functionalTimeoutSeconds as Integer,
            'mkdir -p .local/bin && ln -s "$(command -v hawkeye)" .local/bin/hawkeye && GOTOOLCHAIN=local GIT_TAG="$PIPELINE_ORIGINAL_DESCRIBE" make --no-print-directory GO=go check-licenses vet lint coverage build',
            'make,go,hawkeye', '.', 'commit,describe'],
        ['containerization', 'containerization-release-validation', 'test',
            params.functionalTimeoutSeconds as Integer,
            'mkdir -p .local/bin && ln -s "$(command -v hawkeye)" .local/bin/hawkeye && CI=1 HAWKEYE_AUTO_INSTALL=0 make --no-print-directory ROOT_DIR="$PWD" SWIFT=/usr/bin/swift check containerization examples coverage',
            'make,apple-swift,hawkeye,codesign', '.', 'commit'],
        ['container', 'container-release-validation', 'test',
            params.functionalTimeoutSeconds as Integer,
            'mkdir -p .local/bin && ln -s "$(command -v hawkeye)" .local/bin/hawkeye && unset CONTAINER_APP_ROOT CONTAINER_SERVICE_NAMESPACE && export CI=1 HAWKEYE_AUTO_INSTALL=0 CONTAINER_SEMANTIC_HELPER_TOOLCHAIN_CACHE="$PIPELINE_INTERNAL_CACHE_ROOT/container-semantic-helper" && make --no-print-directory ROOT_DIR="$PWD" PYTHON3=python3 GIT_COMMIT="$PIPELINE_ORIGINAL_COMMIT" RELEASE_VERSION="$PIPELINE_ORIGINAL_DESCRIBE" check build dsym && HOME="$PIPELINE_OPERATOR_HOME" make --no-print-directory ROOT_DIR="$PWD" PYTHON3=python3 GIT_COMMIT="$PIPELINE_ORIGINAL_COMMIT" RELEASE_VERSION="$PIPELINE_ORIGINAL_DESCRIBE" coverage-unit',
            'make,apple-swift,python3,hawkeye,codesign', '.', 'commit,describe'],
        ['homebrew-tap', 'homebrew-release-validation', 'test',
            params.functionalTimeoutSeconds as Integer,
            'ruby -c Formula/container-compose.rb',
            'ruby', 'Formula/container-compose.rb', 'none'],
        ['containerization', 'containerization-release-documentation', 'build',
            params.functionalTimeoutSeconds as Integer,
            'CI=1 make --no-print-directory ROOT_DIR="$PWD" SWIFT=/usr/bin/swift docs',
            'make,apple-swift,docc', '.', 'commit'],
        ['container', 'container-release-documentation', 'build',
            params.functionalTimeoutSeconds as Integer,
            'CI=1 make --no-print-directory ROOT_DIR="$PWD" SWIFT=/usr/bin/swift docs',
            'make,apple-swift,docc', '.', 'commit,describe'],
    ]
}

def benchmarkReconstructionSourceStageSpecs() {
    [
        ['containerization', 'containerization-benchmark-source', 'source',
            params.sourceTimeoutSeconds as Integer,
            'test -f Makefile && test -f Package.resolved && test -f vminitd/Makefile',
            'make,apple-swift', '.', 'commit'],
    ]
}

def benchmarkReconstructionFunctionalStageSpecs() {
    [
        ['containerization', 'containerization-benchmark-cctl', 'build',
            params.functionalTimeoutSeconds as Integer,
            'CI=1 make --no-print-directory ROOT_DIR="$PWD" SWIFT=/usr/bin/swift BUILD_CONFIGURATION=release containerization',
            'make,apple-swift,codesign',
            'Package.swift Package.resolved Sources Tests vminitd/Sources vminitd/Makefile Makefile Protobuf.Makefile .swift-version signing',
            'commit'],
    ]
}

def stageArtifactPaths(stageName) {
    [
        'containerization-benchmark-cctl': 'bin/cctl',
    ].get(stageName.toString(), 'none')
}

def pipelineSelection() {
    def repositories = allRepositorySpecs()
    def sourceStages = params.pipelineProfile == 'release-hosted' ?
        releaseHostedSourceStageSpecs() :
        params.pipelineProfile == 'benchmark-reconstruction' ?
            benchmarkReconstructionSourceStageSpecs() : sourceStageSpecs()
    def functionalStages = params.pipelineProfile == 'release-hosted' ?
        releaseHostedFunctionalStageSpecs() :
        params.pipelineProfile == 'benchmark-reconstruction' ?
            benchmarkReconstructionFunctionalStageSpecs() : functionalStageSpecs()
    def profileRepositoryNames = params.pipelineProfile ==
        'benchmark-reconstruction' ? ['containerization'] :
        params.pipelineProfile in ['stack', 'hosted-safe', 'release-hosted'] ?
            repositories.collect { repository -> repository[0] } : ['container-compose']
    def selectedSources = sourceStages.findAll { stage ->
        profileRepositoryNames.contains(stage[0])
    }
    def selectedFunctionals = functionalStages.findAll { stage ->
        profileRepositoryNames.contains(stage[0])
    }

    if (params.pipelineProfile == 'focused' ||
        params.stageSelector.toString().trim()) {
        def requestedStages = params.stageSelector.toString().trim() ?
            params.stageSelector.toString().split(',')
                .collect { stageName -> stageName.trim() }
                .findAll { stageName -> stageName } :
            ['compose-source', 'compose-swift-test', 'compose-go-test',
                'compose-cli-smoke']
        def knownStages = (sourceStages + functionalStages).collect { stage -> stage[1] }
        def unknownStages = requestedStages.findAll { stageName ->
            !knownStages.contains(stageName)
        }
        if (unknownStages) {
            error "Unknown focused stage(s): ${unknownStages.join(', ')}"
        }
        selectedSources = sourceStages.findAll { stage -> requestedStages.contains(stage[1]) }
        selectedFunctionals = functionalStages.findAll { stage ->
            requestedStages.contains(stage[1])
        }
        def functionalRepositoryNames = selectedFunctionals
            .collect { stage -> stage[0] }
            .unique()
        selectedSources = sourceStages.findAll { stage ->
            requestedStages.contains(stage[1]) ||
                functionalRepositoryNames.contains(stage[0])
        }
    }

    def selectedRepositoryNames = (selectedSources + selectedFunctionals)
        .collect { stage -> stage[0] }
        .unique()
    def selectedRepositories = repositories.findAll { repository ->
        selectedRepositoryNames.contains(repository[0])
    }
    [
        repositories: selectedRepositories,
        sourceStages: selectedSources,
        functionalStages: selectedFunctionals,
    ]
}

def repositoryInputSpecs(selection) {
    def selectedStages = selection.sourceStages + selection.functionalStages
    selection.repositories.collect { repository ->
        def requirements = selectedStages
            .findAll { stage -> stage[0] == repository[0] }
            .collectMany { stage ->
                stage[7] == 'none' ? [] : stage[7].toString().split(',').toList()
            }
            .unique()
            .sort()
        [
            repository[0],
            encodeParameter(repository[1]),
            encodeParameter(repository[2]),
            requirements ? requirements.join(',') : 'none',
        ]
    }
}

def encodedStageInputSpecs(selection) {
    (selection.sourceStages + selection.functionalStages).collect { stage ->
        [
            stage[0], stage[1], stage[2], stage[3],
            encodeParameter(stage[4]),
            stage[5], stage[6], stage[7], stageArtifactPaths(stage[1]),
        ]
    }
}

def validateConfiguration(selection) {
    if (!supportedProfiles().contains(params.pipelineProfile.toString())) {
        error "Unsupported pipeline profile '${params.pipelineProfile}'. " +
            "Choose one of: ${supportedProfiles().join(', ')}"
    }
    if (nextflow.version.toString() != params.expectedNextflowVersion.toString()) {
        error "Nextflow ${params.expectedNextflowVersion} is required; " +
            "running ${nextflow.version}"
    }
    if (!selection.repositories) {
        error 'The selected profile contains no repository stages'
    }
    if (!['run', 'plan', 'preflight'].contains(params.pipelineAction.toString())) {
        error "Unsupported pipeline action '${params.pipelineAction}'. " +
            'Choose one of: run, plan, preflight'
    }
    if (params.pipelineProfile == 'release-hosted' &&
        params.pipelineAction == 'run') {
        def selectedFunctionalNames = selection.functionalStages.collect { stage ->
            stage[1]
        }
        def documentationSelected = selectedFunctionalNames.any { stageName ->
            stageName.endsWith('-release-documentation')
        }
        if (documentationSelected) {
            def requiredValidationNames = releaseHostedFunctionalStageSpecs()
                .collect { stage -> stage[1] }
                .findAll { stageName ->
                    !stageName.endsWith('-release-documentation')
                }
            def missingValidationNames = requiredValidationNames.findAll { stageName ->
                !selectedFunctionalNames.contains(stageName)
            }
            if (missingValidationNames) {
                error 'Release documentation requires every functional validation ' +
                    "stage; missing: ${missingValidationNames.join(', ')}"
            }
        }
    }
    if (!(params.expectedNextflowVersion.toString() ==~ /^[0-9]+[.][0-9]+[.][0-9]+$/)) {
        error 'The expected Nextflow version must be an exact semantic version'
    }
    if (!(params.expectedLauncherSha256.toString() ==~ /^[0-9a-f]{64}$/)) {
        error 'The expected Nextflow launcher digest must be a lowercase SHA-256 value'
    }
    if ((params.sourceTimeoutSeconds as Integer) < 1 ||
        (params.functionalTimeoutSeconds as Integer) < 1) {
        error 'Pipeline stage deadlines must be positive integers'
    }
    [params.stateRoot, params.evidenceDir, params.launcherPath, params.deadlineRunner]
        .each { configuredPath ->
            if (!configuredPath.toString().startsWith('/')) {
                error "Pipeline path must be absolute: ${configuredPath}"
            }
        }
    def pathComponents = params.executionPath.toString().split(':', -1)
    if (!pathComponents || pathComponents.any { component ->
        !component || !component.startsWith('/') || component.contains('\n') ||
            component.contains('\t')
    }) {
        error 'Every pipeline execution PATH component must be a non-empty absolute path without tabs or newlines'
    }
    selection.repositories.each { repository ->
        if (!repository[1].toString().startsWith('/') ||
            repository[1].toString().contains('\n') ||
            repository[1].toString().contains('\t')) {
            error "Repository path must be absolute: ${repository[1]}"
        }
        if (!(repository[2].toString() ==~ /^[A-Za-z0-9._\/@{}^~:+-]+$/)) {
            error "Unsafe repository reference: ${repository[2]}"
        }
    }
}

process PREFLIGHT_HOST {
    tag "host:${pipelineProfile}"
    cache false
    errorStrategy 'terminate'
    publishDir "${params.evidenceDir}/preflight", mode: 'copy', overwrite: true

    input:
    val pipelineProfile
    val expectedVersionBase64
    val expectedLauncherSha256Base64
    val stateRootBase64
    val evidenceDirectoryBase64
    val expectedStateMarkerBase64
    val executionPathBase64
    val requiresOperatorKeychain
    val operatorHomeBase64
    path launcher
    path deadlineRunner

    output:
    path 'host-ready.tsv', emit: ready
    path 'host-tools.tsv', emit: tools

    shell:
    '''
    exec </dev/null
    if IFS= read -r unexpected_input; then
        printf 'host preflight inherited readable standard input: %s\n' \
            "$unexpected_input" >&2
        exit 90
    fi

    decode_parameter() {
        printf '%s' "$1" | /usr/bin/base64 -D
    }

    pipeline_profile="!{pipelineProfile}"
    expected_version="$(decode_parameter '!{expectedVersionBase64}')"
    expected_launcher_sha256="$(decode_parameter '!{expectedLauncherSha256Base64}')"
    state_root="$(decode_parameter '!{stateRootBase64}')"
    evidence_directory="$(decode_parameter '!{evidenceDirectoryBase64}')"
    expected_state_marker="$(decode_parameter '!{expectedStateMarkerBase64}')"
    execution_path="$(decode_parameter '!{executionPathBase64}')"
    requires_operator_keychain="!{requiresOperatorKeychain}"
    operator_home="$(decode_parameter '!{operatorHomeBase64}')"
    launcher="$PWD/!{launcher}"
    deadline_runner="$PWD/!{deadlineRunner}"
    export PATH="$execution_path"

    if ! [[ "$requires_operator_keychain" =~ ^(true|false)$ ]]; then
        printf 'operator Keychain requirement is invalid: %s\n' \
            "$requires_operator_keychain" >&2
        exit 2
    fi
    operator_login_keychain=
    if [[ "$requires_operator_keychain" == true ]]; then
        case "$operator_home" in
            /*) ;;
            *) printf 'operator home must be absolute: %s\n' "$operator_home" >&2; exit 2 ;;
        esac
        if [[ "$operator_home" == *$'\t'* ]] ||
            [[ "$operator_home" == *$'\n'* ]] || [[ -L "$operator_home" ]] ||
            [[ ! -d "$operator_home" ]]; then
            printf 'operator home is indirect or invalid: %s\n' "$operator_home" >&2
            exit 2
        fi
        canonical_operator_home="$(cd "$operator_home" && pwd -P)"
        if [[ "$canonical_operator_home" != "$operator_home" ]]; then
            printf 'operator home must be canonical: %s\n' "$operator_home" >&2
            exit 2
        fi
        operator_login_keychain="$operator_home/Library/Keychains/login.keychain-db"
        if [[ -L "$operator_login_keychain" ]] ||
            [[ ! -f "$operator_login_keychain" ]]; then
            printf 'operator login Keychain is indirect or missing: %s\n' \
                "$operator_login_keychain" >&2
            exit 2
        fi
        set +e
        /usr/bin/python3 "$deadline_runner" --seconds 5 -- \
            /usr/bin/security show-keychain-info "$operator_login_keychain" \
            >login-keychain-preflight.output 2>&1
        keychain_status="$?"
        set -e
        if [[ "$keychain_status" == 124 ]]; then
            printf 'operator login Keychain preflight exceeded its deadline\n' >&2
            exit 124
        fi
        if ((keychain_status != 0)); then
            printf 'operator login Keychain must be unlocked before release validation: %s\n' \
                "$operator_login_keychain" >&2
            exit 2
        fi
    else
        operator_home=
    fi

    developer_directory="${DEVELOPER_DIR:-}"
    if [[ -z "$developer_directory" ]]; then
        developer_directory="$(/usr/bin/xcode-select -p)"
    fi
    if [[ "$developer_directory" != /* ]] ||
        [[ -L "$developer_directory" ]] || [[ ! -d "$developer_directory" ]]; then
        printf 'active Apple developer directory is invalid: %s\n' \
            "$developer_directory" >&2
        exit 2
    fi
    developer_directory="$(cd "$developer_directory" && pwd -P)"
    export DEVELOPER_DIR="$developer_directory"

    case "$state_root" in
        /*) ;;
        *) printf 'pipeline state root must be absolute: %s\n' "$state_root" >&2; exit 2 ;;
    esac
    test "$state_root" != /
    test -d "$state_root"
    test -f "$state_root/.container-compose-pipeline-root"
    if [[ "$(<"$state_root/.container-compose-pipeline-root")" != \
        "$expected_state_marker" ]]; then
        printf 'pipeline state marker does not match: %s\n' "$state_root" >&2
        exit 2
    fi
    test -d "$evidence_directory"
    canonical_state="$(cd "$state_root" && pwd -P)"
    canonical_evidence="$(cd "$evidence_directory" && pwd -P)"
    case "$canonical_evidence/" in
        "$canonical_state"/*) ;;
        *)
            printf 'evidence directory must be inside the marked state root: %s\n' \
                "$canonical_evidence" >&2
            exit 2
            ;;
    esac

    launcher_sha256="$(/usr/bin/shasum -a 256 "$launcher" | \
        /usr/bin/awk '{ print $1 }')"
    if [[ "$launcher_sha256" != "$expected_launcher_sha256" ]]; then
        printf 'Nextflow launcher digest mismatch (expected %s, got %s)\n' \
            "$expected_launcher_sha256" "$launcher_sha256" >&2
        exit 2
    fi
    launcher_version="$(/usr/bin/python3 "$deadline_runner" --seconds 30 -- \
        "$launcher" -version 2>&1 | \
        /usr/bin/awk '/version [0-9]+[.][0-9]+[.][0-9]+/ { for (field = 1; field < NF; field += 1) if ($field == "version") { print $(field + 1); exit } }')"
    if [[ "$launcher_version" != "$expected_version" ]]; then
        printf 'Nextflow launcher version mismatch (expected %s, got %s)\n' \
            "$expected_version" "${launcher_version:-missing}" >&2
        exit 2
    fi

    : >host-tools.tsv
    printf 'schema\t1\n' >>host-tools.tsv
    printf 'profile\t%s\n' "$pipeline_profile" >>host-tools.tsv
    printf 'path\t%s\n' "$PATH" >>host-tools.tsv
    printf 'macos\t%s\n' "$(/usr/bin/sw_vers -productVersion)" >>host-tools.tsv
    printf 'kernel\t%s\n' "$(/usr/bin/uname -mrs)" >>host-tools.tsv
    printf 'nextflow-version\t%s\n' "$launcher_version" >>host-tools.tsv
    printf 'nextflow-sha256\t%s\n' "$launcher_sha256" >>host-tools.tsv
    tool_specs=(system-git:/usr/bin/git system-shasum:/usr/bin/shasum \
        system-bash:/bin/bash system-python:/usr/bin/python3 \
        system-xcode-select:/usr/bin/xcode-select system-xcrun:/usr/bin/xcrun)
    if [[ "$requires_operator_keychain" == true ]]; then
        tool_specs+=(system-security:/usr/bin/security)
    fi
    for tool_spec in "${tool_specs[@]}"; do
        tool_name="${tool_spec%%:*}"
        tool_selector="${tool_spec#*:}"
        if [[ "$tool_selector" == /* ]]; then
            tool_path="$tool_selector"
        else
            tool_path="$(command -v "$tool_selector" 2>/dev/null || true)"
        fi
        if [[ ! -x "$tool_path" ]]; then
            printf 'required unattended tool is missing: %s\n' "$tool_selector" >&2
            exit 2
        fi
        if [[ -f "$tool_path" ]]; then
            tool_sha256="$(/usr/bin/shasum -a 256 "$tool_path" | \
                /usr/bin/awk '{ print $1 }')"
        else
            tool_sha256=not-a-regular-file
        fi
        if [[ "$tool_name" == system-security ]]; then
            tool_version=binary-sha256-only
        else
            set +e
            /usr/bin/python3 "$deadline_runner" --seconds 30 -- \
                "$tool_path" --version >tool-version.output 2>&1
            probe_status="$?"
            set -e
            if [[ "$probe_status" == 124 ]]; then
                printf 'tool version probe exceeded its deadline: %s\n' \
                    "$tool_name" >&2
                exit 124
            fi
            tool_version="$(/usr/bin/head -n 1 tool-version.output)"
        fi
        tool_version="${tool_version//$'\t'/ }"
        printf 'tool\t%s\t%s\t%s\t%s\n' \
            "$tool_name" "$tool_path" "$tool_sha256" "$tool_version" \
            >>host-tools.tsv
    done

    : >host-ready.tsv.pending
    xcrun_shims=(git python3)
    if [[ "$pipeline_profile" == release-hosted ]]; then
        xcrun_shims+=(docc)
    fi
    for shim_name in "${xcrun_shims[@]}"; do
        resolved_tool="$(/usr/bin/python3 "$deadline_runner" --seconds 30 -- \
            /usr/bin/xcrun --find "$shim_name")"
        if [[ "$resolved_tool" != /* ]] || [[ ! -x "$resolved_tool" ]] ||
            [[ ! -f "$resolved_tool" ]]; then
            if [[ "$shim_name" == docc ]]; then
                printf 'stable release gate requires full Xcode with DocC: %s\n' \
                    "$developer_directory" >&2
            else
                printf 'xcrun resolved an invalid %s tool: %s\n' \
                    "$shim_name" "$resolved_tool" >&2
            fi
            exit 2
        fi
        resolved_sha256="$(/usr/bin/shasum -a 256 "$resolved_tool" | \
            /usr/bin/awk '{ print $1 }')"
        if [[ "$shim_name" == docc ]]; then
            resolved_version=binary-sha256-only
        else
            /usr/bin/python3 "$deadline_runner" --seconds 30 -- \
                "$resolved_tool" --version >resolved-tool-version.output 2>&1
            resolved_version="$(/usr/bin/head -n 1 resolved-tool-version.output)"
            resolved_version="${resolved_version//$'\t'/ }"
            [[ -n "$resolved_version" ]] || {
                printf 'resolved %s tool produced no version identity\n' \
                    "$shim_name" >&2
                exit 2
            }
        fi
        printf 'xcrun-tool\t%s\t%s\t%s\t%s\n' \
            "$shim_name" "$resolved_tool" "$resolved_sha256" \
            "$resolved_version" >>host-tools.tsv
        printf 'xcrun-%s-path\t%s\n' "$shim_name" "$resolved_tool" \
            >>host-ready.tsv.pending
        printf 'xcrun-%s-sha256\t%s\n' "$shim_name" "$resolved_sha256" \
            >>host-ready.tsv.pending
    done

    {
        printf 'schema\t1\n'
        printf 'profile\t%s\n' "$pipeline_profile"
        printf 'stdin-closed\ttrue\n'
        printf 'noninteractive\ttrue\n'
        printf 'state-root\t%s\n' "$canonical_state"
        printf 'evidence-directory\t%s\n' "$canonical_evidence"
        printf 'xcode-developer-dir\t%s\n' "$developer_directory"
        printf 'operator-home\t%s\n' "$operator_home"
        printf 'operator-login-keychain\t%s\n' "$operator_login_keychain"
        /bin/cat host-ready.tsv.pending
    } >host-ready.tsv
    /bin/rm host-ready.tsv.pending
    '''
}

process PREFLIGHT_REPOSITORY {
    tag "repository:${repositoryName}"
    cache false
    errorStrategy 'terminate'
    publishDir "${params.evidenceDir}/preflight", mode: 'copy', overwrite: true

    input:
    tuple val(repositoryName), val(sourceDirectoryBase64), val(sourceReferenceBase64),
        val(metadataRequirements), path(hostReady)
    path deadlineRunner

    output:
    tuple val(repositoryName), path("${repositoryName}.identity.tsv"),
        path("${repositoryName}.provenance.tsv"), emit: receipt

    shell:
    '''
    exec </dev/null
    decode_parameter() {
        printf '%s' "$1" | /usr/bin/base64 -D
    }

    repository_name="!{repositoryName}"
    source_directory="$(decode_parameter '!{sourceDirectoryBase64}')"
    source_reference="$(decode_parameter '!{sourceReferenceBase64}')"
    metadata_requirements="!{metadataRequirements}"
    deadline_runner="$PWD/!{deadlineRunner}"
    host_ready="$PWD/!{hostReady}"
    test -s "$host_ready"

    developer_directory="$(/usr/bin/awk -F '\t' \
        '$1 == "xcode-developer-dir" { print $2 }' "$host_ready")"
    xcrun_git_path="$(/usr/bin/awk -F '\t' \
        '$1 == "xcrun-git-path" { print $2 }' "$host_ready")"
    xcrun_git_sha256="$(/usr/bin/awk -F '\t' \
        '$1 == "xcrun-git-sha256" { print $2 }' "$host_ready")"
    xcrun_python_path="$(/usr/bin/awk -F '\t' \
        '$1 == "xcrun-python3-path" { print $2 }' "$host_ready")"
    xcrun_python_sha256="$(/usr/bin/awk -F '\t' \
        '$1 == "xcrun-python3-sha256" { print $2 }' "$host_ready")"
    if [[ "$developer_directory" != /* ]] ||
        [[ ! -d "$developer_directory" ]] ||
        [[ "$xcrun_git_path" != /* ]] || [[ ! -x "$xcrun_git_path" ]] ||
        [[ "$xcrun_python_path" != /* ]] || [[ ! -x "$xcrun_python_path" ]] ||
        ! [[ "$xcrun_git_sha256" =~ ^[0-9a-f]{64}$ ]] ||
        ! [[ "$xcrun_python_sha256" =~ ^[0-9a-f]{64}$ ]]; then
        printf 'host Apple toolchain identity is incomplete\n' >&2
        exit 2
    fi
    export DEVELOPER_DIR="$developer_directory"
    [[ "$(/usr/bin/xcrun --find git)" == "$xcrun_git_path" ]]
    [[ "$(/usr/bin/xcrun --find python3)" == "$xcrun_python_path" ]]
    [[ "$(/usr/bin/shasum -a 256 "$xcrun_git_path" | \
        /usr/bin/awk '{ print $1 }')" == "$xcrun_git_sha256" ]]
    [[ "$(/usr/bin/shasum -a 256 "$xcrun_python_path" | \
        /usr/bin/awk '{ print $1 }')" == "$xcrun_python_sha256" ]]

    case "$repository_name" in
        container-compose|container-builder-shim|containerization|container|container-engine-api|devcontainer|container-k8s|homebrew-tap) ;;
        *) printf 'unsupported repository name: %s\n' "$repository_name" >&2; exit 2 ;;
    esac
    case "$source_directory" in
        /*) ;;
        *) printf 'repository path must be absolute: %s\n' "$source_directory" >&2; exit 2 ;;
    esac
    if [[ "$source_directory" == *$'\t'* ]] ||
        [[ "$source_directory" == *$'\n'* ]]; then
        printf 'repository path contains a control character: %s\n' \
            "$repository_name" >&2
        exit 2
    fi
    if ! [[ "$source_reference" =~ ^[A-Za-z0-9._/@{}^~:+-]+$ ]]; then
        printf 'unsafe repository reference: %s\n' "$source_reference" >&2
        exit 2
    fi
    if ! [[ "$metadata_requirements" =~ ^(none|((branch|commit|describe|origin)(,(branch|commit|describe|origin))*))$ ]]; then
        printf 'unsafe repository metadata requirements: %s\n' \
            "$metadata_requirements" >&2
        exit 2
    fi
    test -d "$source_directory"
    test -e "$source_directory/.git"

    export GIT_TERMINAL_PROMPT=0
    export GCM_INTERACTIVE=never
    export SSH_ASKPASS_REQUIRE=never
    export GIT_CONFIG_NOSYSTEM=1
    export GIT_CONFIG_GLOBAL=/dev/null
    export GIT_CONFIG_SYSTEM=/dev/null

    canonical_source="$(cd "$source_directory" && pwd -P)"
    commit="$(/usr/bin/python3 "$deadline_runner" --seconds 120 -- \
        /usr/bin/git -C "$canonical_source" -c core.fsmonitor=false \
        rev-parse --verify "${source_reference}^{commit}")"
    tree="$(/usr/bin/python3 "$deadline_runner" --seconds 120 -- \
        /usr/bin/git -C "$canonical_source" -c core.fsmonitor=false \
        rev-parse --verify "${commit}^{tree}")"
    dirty="$(/usr/bin/python3 "$deadline_runner" --seconds 120 -- \
        /usr/bin/git -C "$canonical_source" \
        -c core.fsmonitor=false \
        -c core.hooksPath=/dev/null \
        status --porcelain=v1 --untracked-files=all)"
    if [[ -n "$dirty" ]]; then
        printf 'repository must be clean before immutable capture: %s\n%s\n' \
            "$canonical_source" "$dirty" >&2
        exit 2
    fi

    branch=
    describe=
    origin_url=
    tag_refs_sha256=
    case ",$metadata_requirements," in
        *,branch,*)
            symbolic_reference="$(/usr/bin/python3 "$deadline_runner" \
                --seconds 120 -- /usr/bin/git -C "$canonical_source" \
                -c core.fsmonitor=false rev-parse --symbolic-full-name \
                "$source_reference")"
            case "$symbolic_reference" in
                refs/heads/*) branch="${symbolic_reference#refs/heads/}" ;;
                *) branch=HEAD ;;
            esac
            if [[ "$branch" != HEAD ]]; then
                /usr/bin/python3 "$deadline_runner" --seconds 30 -- \
                    /usr/bin/git check-ref-format --branch "$branch" >/dev/null
            fi
            ;;
    esac
    case ",$metadata_requirements," in
        *,describe,*)
            describe="$(/usr/bin/python3 "$deadline_runner" --seconds 120 -- \
                /usr/bin/git -C "$canonical_source" -c core.fsmonitor=false \
                describe --tags --always "$commit")"
            tag_refs_sha256="$(/usr/bin/git -C "$canonical_source" \
                -c core.fsmonitor=false for-each-ref \
                --format='%(refname)%09%(objectname)' refs/tags | \
                /usr/bin/shasum -a 256 | /usr/bin/awk '{ print $1 }')"
            ;;
    esac
    case ",$metadata_requirements," in
        *,origin,*)
            if origin_url="$(/usr/bin/python3 "$deadline_runner" \
                --seconds 30 -- /usr/bin/git -C "$canonical_source" \
                -c core.fsmonitor=false remote get-url origin 2>/dev/null)"; then
                :
            else
                origin_url=
            fi
            ;;
    esac
    if [[ "$describe" == *$'\t'* ]] || [[ "$describe" == *$'\n'* ]] ||
        [[ "$origin_url" == *$'\t'* ]] || [[ "$origin_url" == *$'\n'* ]]; then
        printf 'repository Git metadata contains unsupported control characters: %s\n' \
            "$repository_name" >&2
        exit 2
    fi
    origin_base64="$(printf '%s' "$origin_url" | /usr/bin/base64 | /usr/bin/tr -d '\n')"

    {
        printf 'schema\t2\n'
        printf 'repository\t%s\n' "$repository_name"
        printf 'commit\t%s\n' "$commit"
        printf 'tree\t%s\n' "$tree"
        [[ -z "$branch" ]] || printf 'branch\t%s\n' "$branch"
        [[ -z "$describe" ]] || printf 'describe\t%s\n' "$describe"
        [[ -z "$tag_refs_sha256" ]] || \
            printf 'tag-refs-sha256\t%s\n' "$tag_refs_sha256"
        [[ -z "$origin_url" ]] || printf 'origin-base64\t%s\n' "$origin_base64"
        printf 'xcode-developer-dir\t%s\n' "$developer_directory"
        printf 'xcrun-git-path\t%s\n' "$xcrun_git_path"
        printf 'xcrun-git-sha256\t%s\n' "$xcrun_git_sha256"
        printf 'xcrun-python3-path\t%s\n' "$xcrun_python_path"
        printf 'xcrun-python3-sha256\t%s\n' "$xcrun_python_sha256"
        printf 'clean\ttrue\n'
    } >"${repository_name}.identity.tsv"
    {
        printf 'schema\t2\n'
        printf 'repository\t%s\n' "$repository_name"
        printf 'source\t%s\n' "$canonical_source"
        printf 'requested-reference\t%s\n' "$source_reference"
        printf 'commit\t%s\n' "$commit"
        printf 'tree\t%s\n' "$tree"
        [[ -z "$branch" ]] || printf 'branch\t%s\n' "$branch"
        [[ -z "$describe" ]] || printf 'describe\t%s\n' "$describe"
        [[ -z "$tag_refs_sha256" ]] || \
            printf 'tag-refs-sha256\t%s\n' "$tag_refs_sha256"
        [[ -z "$origin_url" ]] || printf 'origin-base64\t%s\n' "$origin_base64"
        printf 'xcode-developer-dir\t%s\n' "$developer_directory"
        printf 'xcrun-git-path\t%s\n' "$xcrun_git_path"
        printf 'xcrun-git-sha256\t%s\n' "$xcrun_git_sha256"
        printf 'xcrun-python3-path\t%s\n' "$xcrun_python_path"
        printf 'xcrun-python3-sha256\t%s\n' "$xcrun_python_sha256"
        printf 'clean\ttrue\n'
    } >"${repository_name}.provenance.tsv"
    '''
}

process CAPTURE_STAGE_SOURCE {
    tag "source:${stageName}@${repositoryName}"
    cache 'deep'
    errorStrategy 'terminate'

    input:
    tuple val(repositoryName), val(stageName), val(failureClass),
        val(deadlineSeconds), val(stageCommandBase64), val(requiredTools),
        val(sourcePaths), val(metadataRequirements), val(artifactPaths),
        path(repositoryIdentity), path(repositoryProvenance)
    path deadlineRunner

    output:
    tuple val(stageName), val(repositoryName), val(failureClass),
        val(deadlineSeconds), val(stageCommandBase64), val(artifactPaths),
        val(sourcePaths), path("${stageName}.payload.*"),
        path("${stageName}.source.tsv"), emit: prepared

    shell:
    '''
    exec </dev/null
    repository_name="!{repositoryName}"
    stage_name="!{stageName}"
    failure_class="!{failureClass}"
    source_paths="!{sourcePaths}"
    metadata_requirements="!{metadataRequirements}"
    repository_identity="$PWD/!{repositoryIdentity}"
    repository_provenance="$PWD/!{repositoryProvenance}"
    deadline_runner="$PWD/!{deadlineRunner}"

    if ! [[ "$stage_name" =~ ^[a-z0-9][a-z0-9-]*$ ]] ||
        ! [[ "$failure_class" =~ ^(source|test|build)$ ]] ||
        ! [[ "$metadata_requirements" =~ ^(none|((branch|commit|describe|origin)(,(branch|commit|describe|origin))*))$ ]]; then
        printf 'invalid source-capture declaration: %s/%s/%s\n' \
            "$stage_name" "$failure_class" "$metadata_requirements" >&2
        exit 2
    fi
    test -s "$repository_identity"
    test -s "$repository_provenance"
    test -x "$deadline_runner"

    identity_repository="$(/usr/bin/awk -F '\t' '$1 == "repository" { print $2 }' \
        "$repository_identity")"
    commit="$(/usr/bin/awk -F '\t' '$1 == "commit" { print $2 }' \
        "$repository_identity")"
    tree="$(/usr/bin/awk -F '\t' '$1 == "tree" { print $2 }' \
        "$repository_identity")"
    branch="$(/usr/bin/awk -F '\t' '$1 == "branch" { print $2 }' \
        "$repository_identity")"
    describe="$(/usr/bin/awk -F '\t' '$1 == "describe" { print $2 }' \
        "$repository_identity")"
    tag_refs_sha256="$(/usr/bin/awk -F '\t' \
        '$1 == "tag-refs-sha256" { print $2 }' "$repository_identity")"
    origin_base64="$(/usr/bin/awk -F '\t' '$1 == "origin-base64" { print $2 }' \
        "$repository_identity")"
    developer_directory="$(/usr/bin/awk -F '\t' \
        '$1 == "xcode-developer-dir" { print $2 }' "$repository_identity")"
    xcrun_git_path="$(/usr/bin/awk -F '\t' \
        '$1 == "xcrun-git-path" { print $2 }' "$repository_identity")"
    xcrun_git_sha256="$(/usr/bin/awk -F '\t' \
        '$1 == "xcrun-git-sha256" { print $2 }' "$repository_identity")"
    xcrun_python_path="$(/usr/bin/awk -F '\t' \
        '$1 == "xcrun-python3-path" { print $2 }' "$repository_identity")"
    xcrun_python_sha256="$(/usr/bin/awk -F '\t' \
        '$1 == "xcrun-python3-sha256" { print $2 }' "$repository_identity")"
    source_directory="$(/usr/bin/awk -F '\t' '$1 == "source" { print $2 }' \
        "$repository_provenance")"
    if [[ "$identity_repository" != "$repository_name" ]] ||
        ! [[ "$commit" =~ ^[0-9a-f]{40}$ ]] ||
        ! [[ "$tree" =~ ^[0-9a-f]{40}$ ]] ||
        [[ -z "$source_directory" ]] || [[ "$source_directory" != /* ]]; then
        printf 'repository identity is incomplete for %s\n' "$stage_name" >&2
        exit 2
    fi
    if [[ "$developer_directory" != /* ]] ||
        [[ ! -d "$developer_directory" ]] ||
        [[ "$xcrun_git_path" != /* ]] || [[ ! -x "$xcrun_git_path" ]] ||
        [[ "$xcrun_python_path" != /* ]] || [[ ! -x "$xcrun_python_path" ]] ||
        ! [[ "$xcrun_git_sha256" =~ ^[0-9a-f]{64}$ ]] ||
        ! [[ "$xcrun_python_sha256" =~ ^[0-9a-f]{64}$ ]]; then
        printf 'repository Apple toolchain identity is incomplete: %s\n' \
            "$stage_name" >&2
        exit 2
    fi
    export DEVELOPER_DIR="$developer_directory"
    [[ "$(/usr/bin/xcrun --find git)" == "$xcrun_git_path" ]]
    [[ "$(/usr/bin/xcrun --find python3)" == "$xcrun_python_path" ]]
    [[ "$(/usr/bin/shasum -a 256 "$xcrun_git_path" | \
        /usr/bin/awk '{ print $1 }')" == "$xcrun_git_sha256" ]]
    [[ "$(/usr/bin/shasum -a 256 "$xcrun_python_path" | \
        /usr/bin/awk '{ print $1 }')" == "$xcrun_python_sha256" ]]
    test -d "$source_directory"

    read -r -a requested_paths <<<"$source_paths"
    if ((${#requested_paths[@]} == 0)); then
        printf 'stage source declaration is empty: %s\n' "$stage_name" >&2
        exit 2
    fi
    for requested_path in "${requested_paths[@]}"; do
        if [[ "$requested_path" == /* ]] ||
            [[ "$requested_path" == '..' ]] ||
            [[ "$requested_path" == ../* ]] ||
            [[ "$requested_path" == */../* ]] ||
            [[ "$requested_path" == */.. ]]; then
            printf 'unsafe stage source path: %s\n' "$requested_path" >&2
            exit 2
        fi
    done

    export GIT_TERMINAL_PROMPT=0
    export GCM_INTERACTIVE=never
    export SSH_ASKPASS_REQUIRE=never
    export GIT_CONFIG_NOSYSTEM=1
    export GIT_CONFIG_GLOBAL=/dev/null
    export GIT_CONFIG_SYSTEM=/dev/null
    /usr/bin/python3 "$deadline_runner" --seconds 120 -- \
        /usr/bin/git -C "$source_directory" -c core.fsmonitor=false \
        cat-file -e "${tree}^{tree}"

    preserve_git_history=0
    if [[ "$failure_class" == source ]]; then
        preserve_git_history=1
    elif [[ "$source_paths" == . ]]; then
        case ",$metadata_requirements," in
            *,commit,*) preserve_git_history=1 ;;
        esac
    fi

    if ((preserve_git_history == 1)); then
        [[ "$source_paths" == . ]] || {
            printf 'Git-bundle stages require the complete repository: %s\n' \
                "$stage_name" >&2
            exit 2
        }
        case ",$metadata_requirements," in
            *,commit,*) ;;
            *)
                printf 'Git-bundle source stage must declare commit metadata: %s\n' \
                    "$stage_name" >&2
                exit 2
                ;;
        esac
        payload="$PWD/${stage_name}.payload.bundle"
        bundle_repository="$PWD/${stage_name}.bundle.git"
        /usr/bin/python3 "$deadline_runner" --seconds 300 -- \
            /usr/bin/git clone --quiet --bare --shared \
                "$source_directory" "$bundle_repository"
        /usr/bin/python3 "$deadline_runner" --seconds 120 -- \
            /usr/bin/git --git-dir "$bundle_repository" update-ref \
                refs/heads/pipeline-source "$commit"
        /usr/bin/python3 "$deadline_runner" --seconds 120 -- \
            /usr/bin/git --git-dir "$bundle_repository" symbolic-ref HEAD \
                refs/heads/pipeline-source
        bundle_references=(refs/heads/pipeline-source)
        case ",$metadata_requirements," in
            *,describe,*)
                [[ "$tag_refs_sha256" =~ ^[0-9a-f]{64}$ ]] || {
                    printf 'tag reference identity is missing: %s\n' \
                        "$stage_name" >&2
                    exit 2
                }
                captured_tag_refs_sha256="$( \
                    /usr/bin/git --git-dir "$bundle_repository" \
                        -c core.fsmonitor=false for-each-ref \
                        --format='%(refname)%09%(objectname)' refs/tags | \
                        /usr/bin/shasum -a 256 | \
                        /usr/bin/awk '{ print $1 }'
                )"
                if [[ "$captured_tag_refs_sha256" != "$tag_refs_sha256" ]]; then
                    printf 'repository tags changed during source capture: %s\n' \
                        "$stage_name" >&2
                    exit 2
                fi
                bundle_references+=(--tags)
                ;;
        esac
        /usr/bin/python3 "$deadline_runner" --seconds 300 -- \
            /usr/bin/git --git-dir "$bundle_repository" \
                -c pack.threads=1 -c pack.useBitmaps=false \
                bundle create "$payload" "${bundle_references[@]}"
        verifier_repository="$PWD/${stage_name}.verify.git"
        /usr/bin/python3 "$deadline_runner" --seconds 30 -- \
            /usr/bin/git init --quiet --bare "$verifier_repository"
        /usr/bin/python3 "$deadline_runner" --seconds 120 -- \
            /usr/bin/git --git-dir "$verifier_repository" \
                bundle verify "$payload" >/dev/null
        verification_checkout="$PWD/${stage_name}.verify.checkout"
        /usr/bin/python3 "$deadline_runner" --seconds 300 -- \
            /usr/bin/git clone --quiet --no-checkout "$payload" \
                "$verification_checkout"
        /usr/bin/python3 "$deadline_runner" --seconds 120 -- \
            /usr/bin/git -C "$verification_checkout" fsck --full --strict
        /usr/bin/python3 "$deadline_runner" --seconds 120 -- \
            /usr/bin/git -C "$verification_checkout" checkout --quiet \
                --detach "$commit"
        [[ "$(/usr/bin/git -C "$verification_checkout" rev-parse HEAD)" == \
            "$commit" ]]
        bundled_commit="$(/usr/bin/python3 "$deadline_runner" --seconds 120 -- \
            /usr/bin/git bundle list-heads "$payload" \
                refs/heads/pipeline-source | /usr/bin/awk '{ print $1 }')"
        [[ "$bundled_commit" == "$commit" ]]
        source_format=git-bundle
    else
        payload="$PWD/${stage_name}.payload.tar"
        /usr/bin/python3 "$deadline_runner" --seconds 300 -- \
            /usr/bin/git -C "$source_directory" -c core.fsmonitor=false \
            archive --format=tar --mtime=2000-01-01T00:00:00Z \
                --output="$payload" "$tree" -- "${requested_paths[@]}"
        /usr/bin/python3 "$deadline_runner" --seconds 120 -- \
            /usr/bin/tar -tf "$payload" >/dev/null
        source_format=git-tree-archive
    fi
    test -s "$payload"
    payload_sha256="$(/usr/bin/shasum -a 256 "$payload" | \
        /usr/bin/awk '{ print $1 }')"

    metadata="$PWD/${stage_name}.source.tsv"
    {
        printf 'schema\t1\n'
        printf 'stage\t%s\n' "$stage_name"
        printf 'repository\t%s\n' "$repository_name"
        printf 'format\t%s\n' "$source_format"
        printf 'source-paths\t%s\n' "$source_paths"
        printf 'payload-sha256\t%s\n' "$payload_sha256"
    } >"$metadata"
    if [[ "$metadata_requirements" != none ]]; then
        IFS=',' read -r -a requested_metadata <<<"$metadata_requirements"
        for metadata_name in "${requested_metadata[@]}"; do
            case "$metadata_name" in
                branch) printf 'branch\t%s\n' "$branch" >>"$metadata" ;;
                commit) printf 'commit\t%s\n' "$commit" >>"$metadata" ;;
                describe) printf 'describe\t%s\n' "$describe" >>"$metadata" ;;
                origin) printf 'origin-base64\t%s\n' "$origin_base64" >>"$metadata" ;;
            esac
        done
    fi
    '''
}

process PREFLIGHT_STAGE_TOOLS {
    tag "tools:${stageName}@${repositoryName}"
    cache false
    errorStrategy 'terminate'
    publishDir "${params.evidenceDir}/preflight", mode: 'copy', overwrite: true

    input:
    tuple val(repositoryName), val(stageName), val(failureClass),
        val(deadlineSeconds), val(stageCommandBase64), val(requiredTools),
        val(sourcePaths), val(metadataRequirements), val(artifactPaths),
        path(hostReady)
    val executionPathBase64
    path deadlineRunner

    output:
    tuple val(stageName), path("${stageName}.tools.tsv"), emit: manifest

    shell:
    '''
    exec </dev/null
    decode_parameter() {
        printf '%s' "$1" | /usr/bin/base64 -D
    }

    stage_name="!{stageName}"
    required_tools="!{requiredTools}"
    execution_path="$(decode_parameter '!{executionPathBase64}')"
    deadline_runner="$PWD/!{deadlineRunner}"
    host_ready="$PWD/!{hostReady}"
    test -s "$host_ready"
    developer_directory="$(/usr/bin/awk -F '\t' \
        '$1 == "xcode-developer-dir" { print $2 }' "$host_ready")"
    operator_home="$(/usr/bin/awk -F '\t' \
        '$1 == "operator-home" { print $2 }' "$host_ready")"
    operator_login_keychain="$(/usr/bin/awk -F '\t' \
        '$1 == "operator-login-keychain" { print $2 }' "$host_ready")"
    if [[ "$developer_directory" != /* ]] ||
        [[ ! -d "$developer_directory" ]]; then
        printf 'host Apple developer directory is invalid: %s\n' \
            "$developer_directory" >&2
        exit 2
    fi
    export DEVELOPER_DIR="$developer_directory"
    export PATH="$execution_path"

    IFS=':' read -r -a path_components <<<"$execution_path"
    for path_component in "${path_components[@]}"; do
        if [[ -z "$path_component" ]] || [[ "$path_component" != /* ]]; then
            printf 'stage PATH contains an empty or relative component: %s\n' \
                "$execution_path" >&2
            exit 2
        fi
    done

    if ! [[ "$stage_name" =~ ^[a-z0-9][a-z0-9-]*$ ]] ||
        ! [[ "$required_tools" =~ ^[a-zA-Z0-9,._+-]+$ ]]; then
        printf 'unsafe stage tool declaration: %s (%s)\n' \
            "$stage_name" "$required_tools" >&2
        exit 2
    fi

    manifest="$PWD/!{stageName}.tools.tsv"
    printf 'schema\t2\nstage\t%s\npath\t%s\nmacos\t%s\nkernel\t%s\n' \
        "$stage_name" "$execution_path" "$(/usr/bin/sw_vers -productVersion)" \
        "$(/usr/bin/uname -mrs)" >"$manifest"
    if [[ "$stage_name" == container-release-validation ]]; then
        if [[ "$operator_home" != /* ]] || [[ -L "$operator_home" ]] ||
            [[ ! -d "$operator_home" ]] ||
            [[ "$operator_login_keychain" != \
                "$operator_home/Library/Keychains/login.keychain-db" ]] ||
            [[ -L "$operator_login_keychain" ]] ||
            [[ ! -f "$operator_login_keychain" ]]; then
            printf 'operator Keychain authority is invalid: %s\n' "$stage_name" >&2
            exit 2
        fi
        printf 'operator-home\t%s\n' "$operator_home" >>"$manifest"
        printf 'operator-login-keychain\t%s\n' \
            "$operator_login_keychain" >>"$manifest"
    fi

    tool_specs=(system-bash:/bin/bash bash:bash system-python:/usr/bin/python3 \
        system-tar:/usr/bin/tar system-env:/usr/bin/env \
        system-git:/usr/bin/git system-shasum:/usr/bin/shasum \
        system-awk:/usr/bin/awk system-mktemp:/usr/bin/mktemp \
        system-mkdir:/bin/mkdir system-cp:/bin/cp system-mv:/bin/mv \
        system-rm:/bin/rm system-chmod:/bin/chmod system-cat:/bin/cat \
        system-ln:/bin/ln \
        system-base64:/usr/bin/base64 system-head:/usr/bin/head \
        system-file:/usr/bin/file system-tr:/usr/bin/tr \
        system-stat:/usr/bin/stat \
        system-ps:/bin/ps system-readlink:/usr/bin/readlink \
        system-xcode-select:/usr/bin/xcode-select system-xcrun:/usr/bin/xcrun)
    IFS=',' read -r -a requested_tools <<<"$required_tools"
    for tool_name in "${requested_tools[@]}"; do
        tool_specs+=("$tool_name:$tool_name")
    done
    seen=,
    for tool_spec in "${tool_specs[@]}"; do
        tool_name="${tool_spec%%:*}"
        tool_selector="${tool_spec#*:}"
        case "$seen" in
            *,"$tool_name",*) continue ;;
        esac
        seen="${seen}${tool_name},"
        case "$tool_selector" in
            apple-swift) tool_selector=/usr/bin/swift ;;
            codesign) tool_selector=/usr/bin/codesign ;;
            docc)
                tool_selector="$(/usr/bin/python3 "$deadline_runner" \
                    --seconds 30 -- /usr/bin/env \
                    DEVELOPER_DIR="$developer_directory" \
                    /usr/bin/xcrun --find docc)"
                ;;
            otool) tool_selector=/usr/bin/otool ;;
        esac
        if [[ "$tool_selector" == /* ]]; then
            tool_path="$tool_selector"
        else
            tool_path="$(command -v "$tool_selector" 2>/dev/null || true)"
        fi
        if [[ ! -x "$tool_path" ]] || [[ "$tool_path" != /* ]] ||
            [[ ! -f "$tool_path" ]]; then
            printf 'required stage tool is missing: %s (%s)\n' \
                "$tool_name" "$stage_name" >&2
            exit 2
        fi
        tool_sha256="$(/usr/bin/shasum -a 256 "$tool_path" | \
            /usr/bin/awk '{ print $1 }')"
        case "$tool_name" in
            system-*|otool|codesign|docc|gofmt)
                tool_version=binary-sha256-only
                ;;
            go)
                /usr/bin/python3 "$deadline_runner" --seconds 30 -- \
                    "$tool_path" version >tool-version.output 2>&1
                tool_version="$(/usr/bin/head -n 1 tool-version.output)"
                ;;
            *)
                /usr/bin/python3 "$deadline_runner" --seconds 30 -- \
                    "$tool_path" --version >tool-version.output 2>&1
                tool_version="$(/usr/bin/head -n 1 tool-version.output)"
                ;;
        esac
        if [[ -z "$tool_version" ]]; then
            printf 'tool version probe produced no identity: %s\n' \
                "$tool_name" >&2
            exit 2
        fi
        if [[ "$tool_name" == bash ]] && ! /usr/bin/python3 "$deadline_runner" \
            --seconds 30 -- "$tool_path" -c \
            '(( BASH_VERSINFO[0] >= 5 ))' >/dev/null 2>&1; then
            printf 'stable release gate requires Bash 5 or newer: %s\n' \
                "$tool_path" >&2
            exit 2
        fi
        tool_version="${tool_version//$'\t'/ }"
        printf 'tool\t%s\t%s\t%s\t%s\n' "$tool_name" "$tool_path" \
            "$tool_sha256" "$tool_version" >>"$manifest"

        file_description="$(/usr/bin/file -b "$tool_path")"
        case "$file_description" in
            *script*|*text*)
                first_line="$(/usr/bin/head -n 1 "$tool_path")"
                if [[ "$first_line" == '#!'* ]]; then
                    interpreter_spec="${first_line:2}"
                    read -r interpreter_selector interpreter_argument \
                        _ignored <<<"$interpreter_spec"
                    if [[ "$interpreter_selector" == /usr/bin/env ]]; then
                        [[ -n "$interpreter_argument" ]] || {
                            printf 'script interpreter is missing: %s\n' \
                                "$tool_path" >&2
                            exit 2
                        }
                        interpreter_path="$(command -v "$interpreter_argument" \
                            2>/dev/null || true)"
                        interpreter_name="$interpreter_argument"
                    else
                        interpreter_path="$interpreter_selector"
                        interpreter_name="${interpreter_selector##*/}"
                    fi
                    if [[ "$interpreter_path" != /* ]] ||
                        [[ ! -x "$interpreter_path" ]] ||
                        [[ ! -f "$interpreter_path" ]]; then
                        printf 'script interpreter is unavailable: %s (%s)\n' \
                            "$tool_path" "$interpreter_path" >&2
                        exit 2
                    fi
                    interpreter_sha256="$(/usr/bin/shasum -a 256 \
                        "$interpreter_path" | /usr/bin/awk '{ print $1 }')"
                    printf 'interpreter\t%s\t%s\t%s\t%s\n' \
                        "$tool_name" "$interpreter_name" "$interpreter_path" \
                        "$interpreter_sha256" >>"$manifest"
                fi
                ;;
        esac

        if [[ "$tool_name" == markdownlint ]]; then
            real_tool_path="$(/usr/bin/python3 -c \
                'import os, sys; print(os.path.realpath(sys.argv[1]))' \
                "$tool_path")"
            package_root="${real_tool_path%/*}"
            if [[ "$package_root" != /* ]] ||
                [[ ! -f "$package_root/package.json" ]] ||
                [[ ! -d "$package_root/node_modules" ]] ||
                [[ "$package_root" == *$'\t'* ]] ||
                [[ "$package_root" == *$'\n'* ]]; then
                printf 'markdownlint package closure is unavailable: %s\n' \
                    "$package_root" >&2
                exit 2
            fi
            package_tree_sha256="$( \
                cd "$package_root"
                COPYFILE_DISABLE=1 /usr/bin/tar -cf - . | \
                    /usr/bin/shasum -a 256 | \
                    /usr/bin/awk '{ print $1 }'
            )"
            printf 'tool-tree\t%s\t%s\t%s\n' "$tool_name" \
                "$package_root" "$package_tree_sha256" >>"$manifest"
        fi

        if [[ "$tool_name" == go ]]; then
            /bin/mkdir -p "$PWD/go-environment-home"
            go_environment=(/usr/bin/env -i \
                PATH="$execution_path" \
                HOME="$PWD/go-environment-home" \
                DEVELOPER_DIR="$developer_directory" \
                GOTOOLCHAIN=local GOENV=off \
                "$tool_path" env)
            for go_environment_name in GOROOT GOVERSION GOHOSTOS GOHOSTARCH \
                GOTOOLDIR; do
                go_environment_value="$(/usr/bin/python3 "$deadline_runner" \
                    --seconds 30 -- "${go_environment[@]}" \
                    "$go_environment_name")"
                if [[ -z "$go_environment_value" ]] ||
                    [[ "$go_environment_value" == *$'\t'* ]] ||
                    [[ "$go_environment_value" == *$'\n'* ]]; then
                    printf 'Go environment identity is invalid: %s\n' \
                        "$go_environment_name" >&2
                    exit 2
                fi
                printf 'go-environment\t%s\t%s\n' "$go_environment_name" \
                    "$go_environment_value" >>"$manifest"
                case "$go_environment_name" in
                    GOROOT) go_root="$go_environment_value" ;;
                    GOTOOLDIR) go_tool_directory="$go_environment_value" ;;
                esac
            done
            if [[ "$go_root" != /* ]] || [[ ! -d "$go_root" ]] ||
                [[ "$go_tool_directory" != "$go_root"/* ]] ||
                [[ ! -d "$go_tool_directory" ]]; then
                printf 'Go toolchain closure is invalid: %s\n' "$go_root" >&2
                exit 2
            fi
            go_tree_sha256="$( \
                cd "$go_root"
                COPYFILE_DISABLE=1 /usr/bin/tar -cf - . | \
                    /usr/bin/shasum -a 256 | \
                    /usr/bin/awk '{ print $1 }'
            )"
            printf 'tool-tree\tgo-toolchain\t%s\t%s\n' "$go_root" \
                "$go_tree_sha256" >>"$manifest"
        fi
    done

    xcrun_tools=(git python3)
    case ",$required_tools," in
        *,apple-swift,*)
            xcrun_tools+=(swift clang swift-frontend ld)
            ;;
    esac
    case ",$required_tools," in
        *,otool,*) xcrun_tools+=(otool) ;;
    esac
    case ",$required_tools," in
        *,docc,*) xcrun_tools+=(docc) ;;
    esac
    xcrun_seen=,
    for xcrun_name in "${xcrun_tools[@]}"; do
        case "$xcrun_seen" in
            *,"$xcrun_name",*) continue ;;
        esac
        xcrun_seen="${xcrun_seen}${xcrun_name},"
        resolved_tool="$(/usr/bin/python3 "$deadline_runner" --seconds 30 -- \
            /usr/bin/xcrun --find "$xcrun_name")"
        if [[ "$resolved_tool" != /* ]] || [[ ! -x "$resolved_tool" ]] ||
            [[ ! -f "$resolved_tool" ]]; then
            printf 'xcrun resolved an invalid %s tool: %s\n' \
                "$xcrun_name" "$resolved_tool" >&2
            exit 2
        fi
        resolved_sha256="$(/usr/bin/shasum -a 256 "$resolved_tool" | \
            /usr/bin/awk '{ print $1 }')"
        case "$xcrun_name" in
            docc|ld|otool)
                resolved_version=binary-sha256-only
                ;;
            *)
                /usr/bin/python3 "$deadline_runner" --seconds 30 -- \
                    "$resolved_tool" --version \
                    >resolved-tool-version.output 2>&1
                resolved_version="$(/usr/bin/head -n 1 \
                    resolved-tool-version.output)"
                ;;
        esac
        resolved_version="${resolved_version//$'\t'/ }"
        [[ -n "$resolved_version" ]] || {
            printf 'resolved %s tool produced no version identity\n' \
                "$xcrun_name" >&2
            exit 2
        }
        printf 'xcrun-tool\t%s\t%s\t%s\t%s\n' \
            "$xcrun_name" "$resolved_tool" "$resolved_sha256" \
            "$resolved_version" >>"$manifest"
    done

    printf 'xcode-developer-dir\t%s\n' "$developer_directory" >>"$manifest"

    case ",$required_tools," in
        *,apple-swift,*)
            sdk_path="$(/usr/bin/python3 "$deadline_runner" --seconds 30 -- \
                /usr/bin/env DEVELOPER_DIR="$developer_directory" \
                /usr/bin/xcrun --show-sdk-path)"
            sdk_version="$(/usr/bin/python3 "$deadline_runner" --seconds 30 -- \
                /usr/bin/env DEVELOPER_DIR="$developer_directory" \
                /usr/bin/xcrun --show-sdk-version)"
            sdk_build_version="$(/usr/bin/python3 "$deadline_runner" \
                --seconds 30 -- /usr/bin/env \
                DEVELOPER_DIR="$developer_directory" \
                /usr/bin/xcrun --show-sdk-build-version)"
            /usr/bin/python3 "$deadline_runner" --seconds 30 -- \
                /usr/bin/env DEVELOPER_DIR="$developer_directory" \
                /usr/bin/swift -print-target-info >swift-target-info.json
            swift_target_sha256="$(/usr/bin/shasum -a 256 \
                swift-target-info.json | /usr/bin/awk '{ print $1 }')"
            printf 'xcode-sdk-path\t%s\n' "$sdk_path" >>"$manifest"
            printf 'xcode-sdk-version\t%s\n' "$sdk_version" >>"$manifest"
            printf 'xcode-sdk-build-version\t%s\n' \
                "$sdk_build_version" >>"$manifest"
            printf 'swift-target-info-sha256\t%s\n' \
                "$swift_target_sha256" >>"$manifest"
            ;;
    esac
    '''
}

workflow PREFLIGHT_GRAPH {
    take:
    repositorySpecs
    launcher
    deadlineRunner
    requiresOperatorKeychain

    main:
    PREFLIGHT_HOST(
        channel.value(params.pipelineProfile.toString()),
        channel.value(encodeParameter(params.expectedNextflowVersion)),
        channel.value(encodeParameter(params.expectedLauncherSha256)),
        channel.value(encodeParameter(params.stateRoot)),
        channel.value(encodeParameter(params.evidenceDir)),
        channel.value(encodeParameter(params.stateMarkerValue)),
        channel.value(encodeParameter(params.executionPath)),
        requiresOperatorKeychain,
        channel.value(encodeParameter(params.operatorHome)),
        launcher,
        deadlineRunner,
    )
    repositoryInputs = repositorySpecs.combine(PREFLIGHT_HOST.out.ready)
    PREFLIGHT_REPOSITORY(repositoryInputs, deadlineRunner)

    emit:
    repositories = PREFLIGHT_REPOSITORY.out.receipt
    tools = PREFLIGHT_HOST.out.tools
    ready = PREFLIGHT_HOST.out.ready
}

workflow PREPARE_STAGE_GRAPH {
    take:
    stageSpecs
    repositoryReceipts
    hostReady
    deadlineRunner

    main:
    stageRepositoryInputs = stageSpecs.combine(repositoryReceipts, by: 0)
    CAPTURE_STAGE_SOURCE(stageRepositoryInputs, deadlineRunner)
    toolInputs = stageSpecs.combine(hostReady)
    PREFLIGHT_STAGE_TOOLS(
        toolInputs,
        channel.value(encodeParameter(params.executionPath)),
        deadlineRunner,
    )
    toolPreflightGate = PREFLIGHT_STAGE_TOOLS.out.manifest
        .collect()
        .map { true }
    preparedInputs = CAPTURE_STAGE_SOURCE.out.prepared
        .join(PREFLIGHT_STAGE_TOOLS.out.manifest)
        .combine(toolPreflightGate)
        .map { item -> item[0..-2] }

    emit:
    prepared = preparedInputs
}

process PIPELINE_SUMMARY {
    tag "summary:${pipelineProfile}"
    cache 'deep'
    errorStrategy 'terminate'
    publishDir "${params.evidenceDir}", mode: 'copy', overwrite: true

    input:
    val pipelineProfile
    val expectedStageNamesBase64
    val expectedRepositoryNamesBase64
    path stageEvidence
    path repositoryReceipts
    path hostTools

    output:
    path 'pipeline-summary.tsv', emit: summary

    shell:
    '''
    exec </dev/null
    decode_parameter() {
        printf '%s' "$1" | /usr/bin/base64 -D
    }
    pipeline_profile="!{pipelineProfile}"
    expected_stage_names="$(decode_parameter '!{expectedStageNamesBase64}')"
    expected_repository_names="$(decode_parameter '!{expectedRepositoryNamesBase64}')"
    : >pipeline-summary.tsv
    printf 'schema\t1\n' >>pipeline-summary.tsv
    printf 'profile\t%s\n' "$pipeline_profile" >>pipeline-summary.tsv
    printf 'host-tools-sha256\t%s\n' \
        "$(/usr/bin/shasum -a 256 "!{hostTools}" | /usr/bin/awk '{ print $1 }')" \
        >>pipeline-summary.tsv
    observed_stage_names=,
    observed_stage_count=0
    for evidence in !{stageEvidence}; do
        evidence_name="$(/usr/bin/basename "$evidence")"
        case "$evidence_name" in
            *.receipt.tsv) ;;
            *.stdout.log|*.stderr.log|*.artifacts.tar|*.artifacts.tsv)
                test -f "$evidence"
                ;;
            *) exit 2 ;;
        esac
    done
    for receipt in !{stageEvidence}; do
        [[ "$receipt" == *.receipt.tsv ]] || continue
        test -s "$receipt"
        receipt_stage="$(/usr/bin/awk -F '\t' '$1 == "stage" { print $2 }' \
            "$receipt")"
        [[ "$receipt_stage" =~ ^[a-z0-9][a-z0-9-]*$ ]]
        [[ "$(/usr/bin/basename "$receipt")" == \
            "${receipt_stage}.receipt.tsv" ]]
        case "$observed_stage_names" in
            *,"$receipt_stage",*) exit 2 ;;
        esac
        observed_stage_names="${observed_stage_names}${receipt_stage},"
        ((observed_stage_count += 1))
        stdout_log="${receipt_stage}.stdout.log"
        stderr_log="${receipt_stage}.stderr.log"
        artifact_archive="${receipt_stage}.artifacts.tar"
        artifact_manifest="${receipt_stage}.artifacts.tsv"
        test -f "$stdout_log"
        test -f "$stderr_log"
        test -s "$artifact_archive"
        test -s "$artifact_manifest"
        expected_stdout_sha256="$(/usr/bin/awk -F '\t' \
            '$1 == "stdout-sha256" { print $2 }' "$receipt")"
        expected_stderr_sha256="$(/usr/bin/awk -F '\t' \
            '$1 == "stderr-sha256" { print $2 }' "$receipt")"
        expected_artifact_archive_sha256="$(/usr/bin/awk -F '\t' \
            '$1 == "artifact-archive-sha256" { print $2 }' "$receipt")"
        expected_artifact_manifest_sha256="$(/usr/bin/awk -F '\t' \
            '$1 == "artifact-manifest-sha256" { print $2 }' "$receipt")"
        [[ "$expected_stdout_sha256" =~ ^[0-9a-f]{64}$ ]]
        [[ "$expected_stderr_sha256" =~ ^[0-9a-f]{64}$ ]]
        [[ "$expected_artifact_archive_sha256" =~ ^[0-9a-f]{64}$ ]]
        [[ "$expected_artifact_manifest_sha256" =~ ^[0-9a-f]{64}$ ]]
        [[ "$(/usr/bin/shasum -a 256 "$stdout_log" | \
            /usr/bin/awk '{ print $1 }')" == "$expected_stdout_sha256" ]]
        [[ "$(/usr/bin/shasum -a 256 "$stderr_log" | \
            /usr/bin/awk '{ print $1 }')" == "$expected_stderr_sha256" ]]
        [[ "$(/usr/bin/shasum -a 256 "$artifact_archive" | \
            /usr/bin/awk '{ print $1 }')" == \
            "$expected_artifact_archive_sha256" ]]
        [[ "$(/usr/bin/shasum -a 256 "$artifact_manifest" | \
            /usr/bin/awk '{ print $1 }')" == \
            "$expected_artifact_manifest_sha256" ]]
        [[ "$(/usr/bin/awk -F '\t' '$1 == "archive-sha256" { print $2 }' \
            "$artifact_manifest")" == "$expected_artifact_archive_sha256" ]]
        printf 'stage-receipt\t%s\t%s\n' "$(/usr/bin/basename "$receipt")" \
            "$(/usr/bin/shasum -a 256 "$receipt" | /usr/bin/awk '{ print $1 }')" \
            >>pipeline-summary.tsv
        printf 'stage-output\t%s\t%s\n' "$stdout_log" \
            "$expected_stdout_sha256" >>pipeline-summary.tsv
        printf 'stage-output\t%s\t%s\n' "$stderr_log" \
            "$expected_stderr_sha256" >>pipeline-summary.tsv
        printf 'stage-artifact\t%s\t%s\n' "$artifact_archive" \
            "$expected_artifact_archive_sha256" >>pipeline-summary.tsv
        printf 'stage-artifact\t%s\t%s\n' "$artifact_manifest" \
            "$expected_artifact_manifest_sha256" >>pipeline-summary.tsv
    done
    IFS=',' read -r -a expected_stages <<<"$expected_stage_names"
    [[ "$observed_stage_count" -eq "${#expected_stages[@]}" ]]
    for expected_stage in "${expected_stages[@]}"; do
        [[ -n "$expected_stage" ]]
        case "$observed_stage_names" in
            *,"$expected_stage",*) ;;
            *) exit 2 ;;
        esac
    done

    observed_repository_receipt_names=,
    observed_repository_receipt_count=0
    for receipt in !{repositoryReceipts}; do
        test -s "$receipt"
        receipt_name="$(/usr/bin/basename "$receipt")"
        receipt_repository="$(/usr/bin/awk -F '\t' \
            '$1 == "repository" { print $2 }' "$receipt")"
        case "$receipt_name" in
            "${receipt_repository}.identity.tsv"|"${receipt_repository}.provenance.tsv") ;;
            *) exit 2 ;;
        esac
        case "$observed_repository_receipt_names" in
            *,"$receipt_name",*) exit 2 ;;
        esac
        observed_repository_receipt_names="${observed_repository_receipt_names}${receipt_name},"
        ((observed_repository_receipt_count += 1))
        printf 'repository-receipt\t%s\t%s\n' "$(/usr/bin/basename "$receipt")" \
            "$(/usr/bin/shasum -a 256 "$receipt" | /usr/bin/awk '{ print $1 }')" \
            >>pipeline-summary.tsv
    done
    IFS=',' read -r -a expected_repositories <<<"$expected_repository_names"
    [[ "$observed_repository_receipt_count" -eq \
        "$((2 * ${#expected_repositories[@]}))" ]]
    for expected_repository in "${expected_repositories[@]}"; do
        [[ -n "$expected_repository" ]]
        case "$observed_repository_receipt_names" in
            *,"${expected_repository}.identity.tsv",*) ;;
            *) exit 2 ;;
        esac
        case "$observed_repository_receipt_names" in
            *,"${expected_repository}.provenance.tsv",*) ;;
            *) exit 2 ;;
        esac
    done
    printf 'complete\ttrue\n' >>pipeline-summary.tsv
    '''
}

workflow PLAN {
    main:
    selection = pipelineSelection()
    validateConfiguration(selection)
    persistSessionReceipt(params.evidenceDir, workflow.sessionId)
    log.info """
    Container-family recoverable pipeline plan
      profile: ${params.pipelineProfile}
      state root: ${params.stateRoot}
      evidence: ${params.evidenceDir}
      repositories:
        ${selection.repositories.collect { repository -> "${repository[0]} ${repository[2]} @ ${repository[1]}" }.join('\n        ')}
      source stages:
        ${selection.sourceStages.collect { stage -> stage[1] }.join('\n        ')}
      functional stages:
        ${selection.functionalStages.collect { stage -> stage[1] }.join('\n        ')}
      runtime/parity/release mutation: disabled in this migration phase
    """.stripIndent()
}

workflow PREFLIGHT_ONLY {
    main:
    selection = pipelineSelection()
    validateConfiguration(selection)
    persistSessionReceipt(params.evidenceDir, workflow.sessionId)
    launcher = channel.value(file(params.launcherPath, checkIfExists: true))
    deadlineRunner = channel.value(file(params.deadlineRunner, checkIfExists: true))
    repositories = channel.fromList(repositoryInputSpecs(selection))
    stages = channel.fromList(encodedStageInputSpecs(selection))
    requiresOperatorKeychain = channel.value(selection.functionalStages.any { stage ->
        stage[1] == 'container-release-validation'
    })
    PREFLIGHT_GRAPH(
        repositories,
        launcher,
        deadlineRunner,
        requiresOperatorKeychain,
    )
    PREPARE_STAGE_GRAPH(
        stages,
        PREFLIGHT_GRAPH.out.repositories,
        PREFLIGHT_GRAPH.out.ready,
        deadlineRunner,
    )
    PREFLIGHT_GRAPH.out.repositories.view { item ->
        "repository preflight passed: ${item[0]} (${item[1]})"
    }
    PREPARE_STAGE_GRAPH.out.prepared.view { item ->
        "stage preflight passed: ${item[0]} (${item[9]})"
    }
}

workflow PIPELINE {
    selection = pipelineSelection()
    validateConfiguration(selection)
    persistSessionReceipt(params.evidenceDir, workflow.sessionId)
    launcher = channel.value(file(params.launcherPath, checkIfExists: true))
    deadlineRunner = channel.value(file(params.deadlineRunner, checkIfExists: true))
    repositories = channel.fromList(repositoryInputSpecs(selection))
    stages = channel.fromList(encodedStageInputSpecs(selection))
    requiresOperatorKeychain = channel.value(selection.functionalStages.any { stage ->
        stage[1] == 'container-release-validation'
    })
    PREFLIGHT_GRAPH(
        repositories,
        launcher,
        deadlineRunner,
        requiresOperatorKeychain,
    )
    PREPARE_STAGE_GRAPH(
        stages,
        PREFLIGHT_GRAPH.out.repositories,
        PREFLIGHT_GRAPH.out.ready,
        deadlineRunner,
    )

    repositoryReceipts = PREFLIGHT_GRAPH.out.repositories
    sourceStageNames = selection.sourceStages.collect { stage -> stage[1] }
    sourceInputs = PREPARE_STAGE_GRAPH.out.prepared
        .filter { item -> sourceStageNames.contains(item[0]) }
        .map { item -> item + [true] }
    stateRootBase64 = channel.value(encodeParameter(params.stateRoot))
    sessionIdentifier = channel.value(workflow.sessionId.toString())
    RUN_SOURCE_STAGE(
        sourceInputs,
        deadlineRunner,
        stateRootBase64,
        sessionIdentifier,
    )

    repositorySourceGates = RUN_SOURCE_STAGE.out.receipt.map { item ->
        tuple(item[0], true)
    }
    functionalStageNames = selection.functionalStages.collect { stage -> stage[1] }
    documentationStageNames = functionalStageNames.findAll { stageName ->
        stageName.endsWith('-release-documentation')
    }
    validationStageNames = functionalStageNames.findAll { stageName ->
        !documentationStageNames.contains(stageName)
    }
    functionalInputs = PREPARE_STAGE_GRAPH.out.prepared
        .filter { item -> functionalStageNames.contains(item[0]) }
        .map { item -> tuple(item[1], item[0], item[2], item[3], item[4],
            item[5], item[6], item[7], item[8], item[9]) }
        .combine(repositorySourceGates, by: 0)
        .map { item -> tuple(item[1], item[0], item[2], item[3], item[4],
            item[5], item[6], item[7], item[8], item[9], item[10]) }
    swiftRepositoryNames = [
        'container-compose', 'containerization', 'container',
        'container-engine-api', 'devcontainer', 'container-k8s',
    ]
    swiftFunctionalInputs = functionalInputs.filter { item ->
        validationStageNames.contains(item[0]) &&
            swiftRepositoryNames.contains(item[1])
    }
    lightweightFunctionalInputs = functionalInputs.filter { item ->
        validationStageNames.contains(item[0]) &&
            !swiftRepositoryNames.contains(item[1])
    }
    RUN_SWIFT_STAGE(
        swiftFunctionalInputs,
        deadlineRunner,
        stateRootBase64,
        sessionIdentifier,
    )
    RUN_LIGHTWEIGHT_STAGE(
        lightweightFunctionalInputs,
        deadlineRunner,
        stateRootBase64,
        sessionIdentifier,
    )
    validationCompletionGate = RUN_SWIFT_STAGE.out.receipt
        .concat(RUN_LIGHTWEIGHT_STAGE.out.receipt)
        .collect()
        .map { receipts ->
            if (receipts.size() != validationStageNames.size()) {
                error 'release validation did not produce every expected receipt'
            }
            true
        }
    documentationInputs = functionalInputs
        .filter { item -> documentationStageNames.contains(item[0]) }
        .combine(validationCompletionGate)
        .map { item -> tuple(item[0], item[1], item[2], item[3], item[4],
            item[5], item[6], item[7], item[8], item[9],
            item[10] && item[11]) }
    RUN_DOCUMENTATION_STAGE(
        documentationInputs,
        deadlineRunner,
        stateRootBase64,
        sessionIdentifier,
    )

    allStageEvidence = RUN_SOURCE_STAGE.out.receipt
        .flatMap { item -> [item[2], item[3], item[4], item[5], item[6]] }
        .concat(RUN_SWIFT_STAGE.out.receipt
            .flatMap { item -> [item[2], item[3], item[4], item[5], item[6]] })
        .concat(RUN_LIGHTWEIGHT_STAGE.out.receipt
            .flatMap { item -> [item[2], item[3], item[4], item[5], item[6]] })
        .concat(RUN_DOCUMENTATION_STAGE.out.receipt
            .flatMap { item -> [item[2], item[3], item[4], item[5], item[6]] })
        .collect()
    allRepositoryReceipts = repositoryReceipts
        .flatMap { item -> [item[1], item[2]] }
        .collect()
    PIPELINE_SUMMARY(
        channel.value(params.pipelineProfile.toString()),
        channel.value(encodeParameter(
            (selection.sourceStages + selection.functionalStages)
                .collect { stage -> stage[1] }
                .join(','),
        )),
        channel.value(encodeParameter(
            selection.repositories.collect { repository -> repository[0] }
                .join(','),
        )),
        allStageEvidence,
        allRepositoryReceipts,
        PREFLIGHT_GRAPH.out.tools,
    )
}

workflow {
    if (params.pipelineAction == 'plan') {
        PLAN()
    } else if (params.pipelineAction == 'preflight') {
        PREFLIGHT_ONLY()
    } else {
        PIPELINE()
    }
}
