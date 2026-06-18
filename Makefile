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

SHELL := /bin/bash
.SHELLFLAGS := -euo pipefail -c
.DEFAULT_GOAL := all

SWIFT ?= swift
SWIFT_RESOLVED_FLAGS ?= --disable-automatic-resolution
GO ?= go
PYTHON ?= python3
MARKDOWNLINT ?= markdownlint
COVERAGE_MIN ?= 85
DIST_DIR ?= dist
PLUGIN_ARCHIVE ?= container-compose-plugin.tar.gz
SONAR_QUALITYGATE_WAIT ?= false
XCODE_SELECT_DEVELOPER_DIR ?= $(shell xcode-select -p 2>/dev/null || true)
SWIFT_RUNTIME_RESOURCE_PATH ?= $(shell $(SWIFT) -print-target-info 2>/dev/null | $(PYTHON) -c 'import json, sys; print(json.load(sys.stdin).get("paths", {}).get("runtimeResourcePath", ""))' 2>/dev/null || true)
SWIFT_TOOLCHAIN_USR_DIR := $(patsubst %/lib/swift,%,$(SWIFT_RUNTIME_RESOURCE_PATH))
SWIFT_XCODE_DEVELOPER_DIR := $(patsubst %/Toolchains/XcodeDefault.xctoolchain/usr/lib/swift,%,$(filter %/Toolchains/XcodeDefault.xctoolchain/usr/lib/swift,$(SWIFT_RUNTIME_RESOURCE_PATH)))
SWIFT_CLT_DEVELOPER_DIR := $(patsubst %/usr/lib/swift,%,$(filter-out %/Toolchains/XcodeDefault.xctoolchain/usr/lib/swift,$(filter %/usr/lib/swift,$(SWIFT_RUNTIME_RESOURCE_PATH))))
SWIFT_ACTIVE_DEVELOPER_DIR ?= $(firstword $(SWIFT_XCODE_DEVELOPER_DIR) $(SWIFT_CLT_DEVELOPER_DIR) $(XCODE_SELECT_DEVELOPER_DIR))
SWIFT_LLVM_COV ?= $(firstword $(wildcard $(SWIFT_TOOLCHAIN_USR_DIR)/bin/llvm-cov) $(shell xcrun --find llvm-cov 2>/dev/null || command -v llvm-cov 2>/dev/null || true))
SWIFT_TEST_FRAMEWORK_CANDIDATES := \
	$(SWIFT_ACTIVE_DEVELOPER_DIR)/Platforms/MacOSX.platform/Developer/Library/Frameworks \
	$(SWIFT_ACTIVE_DEVELOPER_DIR)/Library/Developer/Frameworks \
	$(XCODE_SELECT_DEVELOPER_DIR)/Platforms/MacOSX.platform/Developer/Library/Frameworks \
	$(XCODE_SELECT_DEVELOPER_DIR)/Library/Developer/Frameworks
SWIFT_TEST_RUNTIME_LIBRARY_CANDIDATES := \
	$(SWIFT_ACTIVE_DEVELOPER_DIR)/Platforms/MacOSX.platform/Developer/usr/lib \
	$(SWIFT_ACTIVE_DEVELOPER_DIR)/Library/Developer/usr/lib \
	$(XCODE_SELECT_DEVELOPER_DIR)/Platforms/MacOSX.platform/Developer/usr/lib \
	$(XCODE_SELECT_DEVELOPER_DIR)/Library/Developer/usr/lib
SWIFT_TEST_FRAMEWORK_SEARCH_PATH ?= $(firstword $(foreach path,$(SWIFT_TEST_FRAMEWORK_CANDIDATES),$(if $(wildcard $(path)/Testing.framework),$(path))))
SWIFT_TEST_RUNTIME_LIBRARY_PATH ?= $(firstword $(foreach path,$(SWIFT_TEST_RUNTIME_LIBRARY_CANDIDATES),$(if $(wildcard $(path)/lib_TestingInterop.dylib),$(path))))
SWIFT_TEST_RESULT_LOG ?= .build/swift-test.log
MARKDOWN_FILES := README.md BUILD.md COMPATIBILITY.md CONTRIBUTING.md DESIGN.md INSTALL.md

# Some local toolchains can build Swift Testing targets without adding the
# framework and interop library to SwiftPM's generated test runner. Derive
# those paths from the selected Swift executable so `SWIFT=... make swift-test`
# does not mix Xcode and Command Line Tools runtimes.
ifneq ($(strip $(SWIFT_TEST_FRAMEWORK_SEARCH_PATH)),)
SWIFT_TEST_FLAGS ?= -Xswiftc -F -Xswiftc '$(SWIFT_TEST_FRAMEWORK_SEARCH_PATH)' -Xlinker -rpath -Xlinker '$(SWIFT_TEST_FRAMEWORK_SEARCH_PATH)'
ifneq ($(strip $(SWIFT_TEST_RUNTIME_LIBRARY_PATH)),)
SWIFT_TEST_FLAGS += -Xlinker -rpath -Xlinker '$(SWIFT_TEST_RUNTIME_LIBRARY_PATH)'
endif
else
SWIFT_TEST_FLAGS ?=
endif

.PHONY: all workflow ci clean run build build-release test resolve swift-test swift-coverage go-test go-build cli-smoke coverage coverage-check sonar sonar-scan package coverage-tools-test lint format

all: workflow

workflow: ci package

ci: lint coverage-check go-build cli-smoke

resolve:
	$(SWIFT) package resolve

build:
	$(SWIFT) build $(SWIFT_RESOLVED_FLAGS) --product compose

build-release:
	$(SWIFT) build $(SWIFT_RESOLVED_FLAGS) -c release --product compose

run:
	$(SWIFT) run $(SWIFT_RESOLVED_FLAGS) compose version

test: swift-test go-test

swift-test:
	@mkdir -p .build
	@$(SWIFT) test $(SWIFT_RESOLVED_FLAGS) --enable-code-coverage $(SWIFT_TEST_FLAGS) 2>&1 | tee "$(SWIFT_TEST_RESULT_LOG)"
	@if ! grep -Eq 'Test run with [1-9][0-9]* tests .* passed|Executed [1-9][0-9]* tests' "$(SWIFT_TEST_RESULT_LOG)"; then \
		printf 'swift test completed without running tests; check the active toolchain Testing.framework and rpath settings.\n' >&2; \
		exit 1; \
	fi

swift-coverage: swift-test
	@if [[ -z "$(SWIFT_LLVM_COV)" ]]; then \
		printf 'llvm-cov is required; install the active Swift toolchain or set SWIFT_LLVM_COV=/path/to/llvm-cov\n' >&2; \
		exit 1; \
	fi
	test_binary="$$(find .build -path '*.xctest/Contents/MacOS/*' -type f | head -n 1)"; \
	profile="$$(find .build -path '*/codecov/default.profdata' -type f | head -n 1)"; \
	"$(SWIFT_LLVM_COV)" export \
		-format=lcov \
		-instr-profile="$$profile" \
		"$$test_binary" \
		--sources Sources/ComposeCore \
		> coverage.lcov; \
	$(PYTHON) Tools/coverage/lcov-to-sonarqube-generic.py coverage.lcov coverage.xml

go-test:
	cd Tools/compose-normalizer && $(GO) test ./... -coverprofile=coverage.out -covermode=atomic

go-build:
	cd Tools/compose-normalizer && $(GO) build -o compose-normalizer .

cli-smoke: build
	.build/debug/compose --ansi never version >/dev/null
	.build/debug/compose version --dry-run >/dev/null
	version_short_output="$$(".build/debug/compose" version --short)"; \
	[[ "$$version_short_output" == "0.1.0" ]]; \
	version_json_output="$$(".build/debug/compose" version --format json)"; \
	[[ "$$version_json_output" == '{"version":"0.1.0"}' ]]; \
	version_short_format_output="$$(".build/debug/compose" version -f json)"; \
	[[ "$$version_short_format_output" == '{"version":"0.1.0"}' ]]; \
	version_compact_format_output="$$(".build/debug/compose" version -fjson)"; \
	[[ "$$version_compact_format_output" == '{"version":"0.1.0"}' ]]; \
	version_bad_format_output="$$(".build/debug/compose" version --format yaml 2>&1 || true)"; \
	[[ "$$version_bad_format_output" == *"unsupported compose feature: version --format 'yaml'; supported formats are pretty and json"* ]]; \
	stats_help_output="$$(".build/debug/compose" stats --help)"; \
	[[ "$$stats_help_output" == *"Optional service names."* ]]; \
	tmpdir="$$(mktemp -d)"; \
	trap 'rm -rf "$$tmpdir"' EXIT; \
	printf 'services:\n  api:\n    image: alpine\n    depends_on:\n      - db\n    ports:\n      - "8080:80"\n    mac_address: "02:42:ac:11:00:03"\n    volumes:\n      - /scratch\n      - cache:/cache\n    dns_opt:\n      - use-vc\n    networks:\n      default:\n        driver_opts:\n          com.docker.network.driver.mtu: "1450"\n  db:\n    image: alpine\n  job:\n    image: alpine\n    depends_on:\n      db:\n        condition: service_healthy\n        restart: true\n  shell:\n    image: alpine\n    tty: true\n    stdin_open: true\n  isolated:\n    image: alpine\n    network_mode: none\nnetworks:\n  default:\n    internal: true\n    ipam:\n      config:\n        - subnet: "10.77.0.0/24"\n        - subnet: "fd77::/64"\nvolumes:\n  cache:\n    driver: local\n    driver_opts:\n      journal: ordered\n      size: 64m\n' > "$$tmpdir/compose.yml"; \
	printf 'services:\n  api:\n    image: alpine\n    ports:\n      - "80"\n' > "$$tmpdir/dynamic-ports.yml"; \
	printf 'services:\n  api:\n    image: alpine\n    attach: false\n' > "$$tmpdir/attach-false.yml"; \
	printf 'services:\n  worker:\n    image: alpine\n' > "$$tmpdir/scale.yml"; \
	printf 'services:\n  api:\n    image: alpine\n    depends_on:\n      - db\n  db:\n    image: alpine\n' > "$$tmpdir/scale-deps.yml"; \
	printf 'services:\n  api:\n    image: alpine\n    ports:\n      - "8080-8081:80"\n' > "$$tmpdir/scale-ports.yml"; \
	printf 'services:\n  api:\n    image: alpine\n    pull_policy: daily\n' > "$$tmpdir/pull-window.yml"; \
	printf 'services:\n  api:\n    image: alpine\n    volumes:\n      - type: tmpfs\n        target: /scratch\n        tmpfs:\n          size: 64m\n          mode: 1777\n' > "$$tmpdir/tmpfs-options.yml"; \
	mkdir -p "$$tmpdir/api"; \
	printf 'FROM alpine:3.20\n' > "$$tmpdir/api/Dockerfile"; \
	printf 'secret\n' > "$$tmpdir/build-token.txt"; \
	printf 'services:\n  api:\n    image: example/api:build\n    build:\n      context: ./api\n      secrets:\n        - source: file_token\n        - source: env_token\n          target: npm_token\nsecrets:\n  file_token:\n    file: ./build-token.txt\n  env_token:\n    environment: NPM_TOKEN\n' > "$$tmpdir/build-secrets.yml"; \
	printf 'name: inline-build\nservices:\n  api:\n    image: example/api:inline\n    build:\n      context: ./api\n      dockerfile_inline: |\n        FROM alpine:3.20\n        RUN echo inline\n' > "$$tmpdir/build-inline.yml"; \
	printf 'services:\n  worker:\n    build:\n      context: ./api\n' > "$$tmpdir/build-only.yml"; \
	version_compact_global_output="$$(".build/debug/compose" -pcompact -f"$$tmpdir/compose.yml" version --short)"; \
	[[ "$$version_compact_global_output" == "0.1.0" ]]; \
	config_output="$$(".build/debug/compose" -f "$$tmpdir/compose.yml" config)"; \
	convert_output="$$(".build/debug/compose" -f "$$tmpdir/compose.yml" convert)"; \
	[[ "$$convert_output" == "$$config_output" ]]; \
	[[ "$$convert_output" == *'"name":"demo"'* ]]; \
	compact_global_output="$$(".build/debug/compose" --dry-run -pcompact -f"$$tmpdir/compose.yml" up api)"; \
	[[ "$$compact_global_output" == *"compact-db-1"* ]]; \
	[[ "$$compact_global_output" == *"compact-api-1"* ]]; \
	pull_options_output="$$(".build/debug/compose" --dry-run -f "$$tmpdir/compose.yml" pull --include-deps --ignore-pull-failures --policy missing -q api)"; \
	[[ "$$(printf '%s\n' "$$pull_options_output" | grep -c "container image inspect alpine")" == "2" ]]; \
	pull_window_output="$$(".build/debug/compose" --dry-run -f "$$tmpdir/pull-window.yml" up api)"; \
	[[ "$$pull_window_output" == *"container image inspect alpine"* ]]; \
	[[ "$$pull_window_output" == *"container image pull alpine"* ]]; \
	[[ "$$pull_window_output" == *"container run"* ]]; \
	tmpfs_options_output="$$(".build/debug/compose" --dry-run -f "$$tmpdir/tmpfs-options.yml" up api)"; \
	[[ "$$tmpfs_options_output" == *"--mount type=tmpfs,destination=/scratch,size=67108864,mode=1777"* ]]; \
	[[ "$$tmpfs_options_output" != *"--tmpfs /scratch"* ]]; \
	push_options_output="$$(".build/debug/compose" --dry-run -f "$$tmpdir/compose.yml" push --include-deps --ignore-push-failures -q api)"; \
	[[ "$$(printf '%s\n' "$$push_options_output" | grep -c "container image push alpine")" == "2" ]]; \
	run_output="$$(".build/debug/compose" --dry-run -f "$$tmpdir/compose.yml" run api echo hello)"; \
	[[ "$$run_output" == *"container run"* ]]; \
	[[ "$$run_output" == *"demo-db-1"* ]]; \
	[[ "$$run_output" == *" alpine echo hello"* ]]; \
	[[ "$$run_output" != *"--publish 8080:80"* ]]; \
	run_service_ports_output="$$(".build/debug/compose" --dry-run -f "$$tmpdir/compose.yml" run --service-ports api echo hello)"; \
	[[ "$$run_service_ports_output" == *"--publish 8080:80"* ]]; \
	run_dynamic_service_ports_output="$$(".build/debug/compose" --dry-run -f "$$tmpdir/dynamic-ports.yml" run --service-ports api echo hello 2>&1 || true)"; \
	[[ "$$run_dynamic_service_ports_output" == *"unsupported compose feature: service 'api' publishes target port 80/tcp dynamically; apple/container publish requires explicit host ports"* ]]; \
	run_publish_output="$$(".build/debug/compose" --dry-run -f "$$tmpdir/compose.yml" run -p 9090:90 api echo hello)"; \
	[[ "$$run_publish_output" == *"--publish 9090:90"* ]]; \
	[[ "$$run_publish_output" != *"--publish 8080:80"* ]]; \
	build_secret_output="$$(NPM_TOKEN=local-secret ".build/debug/compose" --dry-run -f "$$tmpdir/build-secrets.yml" build --pull --with-dependencies -q api)"; \
	[[ "$$build_secret_output" == *"--secret id=file_token,src=$$tmpdir/build-token.txt"* ]]; \
	[[ "$$build_secret_output" == *"--secret id=npm_token,env=NPM_TOKEN"* ]]; \
	[[ "$$build_secret_output" == *"--pull"* ]]; \
	[[ "$$build_secret_output" == *"--quiet"* ]]; \
	build_inline_output="$$(".build/debug/compose" --dry-run -f "$$tmpdir/build-inline.yml" build api)"; \
	[[ "$$build_inline_output" == *"container build"* ]]; \
	[[ "$$build_inline_output" == *"--tag example/api:inline"* ]]; \
	[[ "$$build_inline_output" == *"--file "*"container-compose-inline-build-api-"*"/Dockerfile"* ]]; \
	run_pull_output="$$(".build/debug/compose" --dry-run -f "$$tmpdir/compose.yml" run --pull missing api true)"; \
	[[ "$$run_pull_output" == *"container image inspect alpine"* ]]; \
	[[ "$$run_pull_output" == *"container image pull alpine"* ]]; \
	[[ "$$run_pull_output" == *" alpine true"* ]]; \
	run_named_output="$$(".build/debug/compose" --dry-run -f "$$tmpdir/compose.yml" run --name custom-api api echo hello)"; \
	[[ "$$run_named_output" == *"--name custom-api"* ]]; \
	[[ "$$run_named_output" == *" alpine echo hello"* ]]; \
	run_entrypoint_output="$$(".build/debug/compose" --dry-run -f "$$tmpdir/compose.yml" run --entrypoint "/bin/sh -c" api echo hello)"; \
	[[ "$$run_entrypoint_output" == *"--entrypoint '/bin/sh -c'"* ]]; \
	[[ "$$run_entrypoint_output" == *" alpine echo hello"* ]]; \
	run_workdir_output="$$(".build/debug/compose" --dry-run -f "$$tmpdir/compose.yml" run --workdir /workspace api pwd)"; \
	[[ "$$run_workdir_output" == *"--workdir /workspace"* ]]; \
	[[ "$$run_workdir_output" == *" alpine pwd"* ]]; \
	run_user_output="$$(".build/debug/compose" --dry-run -f "$$tmpdir/compose.yml" run -u 1000:1000 api id)"; \
	[[ "$$run_user_output" == *"--user 1000:1000"* ]]; \
	[[ "$$run_user_output" == *" alpine id"* ]]; \
	run_compact_user_output="$$(".build/debug/compose" --dry-run -f "$$tmpdir/compose.yml" run -u1000:1000 api id)"; \
	[[ "$$run_compact_user_output" == *"--user 1000:1000"* ]]; \
	[[ "$$run_compact_user_output" == *" alpine id"* ]]; \
	run_env_output="$$(".build/debug/compose" --dry-run -f "$$tmpdir/compose.yml" run -e LOG_LEVEL=debug --env-from-file .env.local api env)"; \
	[[ "$$run_env_output" == *"--env LOG_LEVEL=debug"* ]]; \
	[[ "$$run_env_output" == *"--env-file .env.local"* ]]; \
	[[ "$$run_env_output" == *" alpine env"* ]]; \
	run_compact_env_output="$$(".build/debug/compose" --dry-run -f "$$tmpdir/compose.yml" run -eLOG_LEVEL=trace api env)"; \
	[[ "$$run_compact_env_output" == *"--env LOG_LEVEL=trace"* ]]; \
	[[ "$$run_compact_env_output" == *" alpine env"* ]]; \
	run_label_output="$$(".build/debug/compose" --dry-run -f "$$tmpdir/compose.yml" run -l com.example.role=job api true)"; \
	[[ "$$run_label_output" == *"--label com.example.role=job"* ]]; \
	[[ "$$run_label_output" == *" alpine true"* ]]; \
	run_compact_label_output="$$(".build/debug/compose" --dry-run -f "$$tmpdir/compose.yml" run -lcom.example.compact=true api true)"; \
	[[ "$$run_compact_label_output" == *"--label com.example.compact=true"* ]]; \
	[[ "$$run_compact_label_output" == *" alpine true"* ]]; \
	run_volume_output="$$(".build/debug/compose" --dry-run -f "$$tmpdir/compose.yml" run -v /host:/container:ro api ls)"; \
	[[ "$$run_volume_output" == *"--volume /host:/container:ro"* ]]; \
	[[ "$$run_volume_output" == *" alpine ls"* ]]; \
	run_compact_volume_output="$$(".build/debug/compose" --dry-run -f "$$tmpdir/compose.yml" run -v/host:/container:ro api ls)"; \
	[[ "$$run_compact_volume_output" == *"--volume /host:/container:ro"* ]]; \
	[[ "$$run_compact_volume_output" == *" alpine ls"* ]]; \
	run_compact_workdir_output="$$(".build/debug/compose" --dry-run -f "$$tmpdir/compose.yml" run -w/workspace api pwd)"; \
	[[ "$$run_compact_workdir_output" == *"--workdir /workspace"* ]]; \
	[[ "$$run_compact_workdir_output" == *" alpine pwd"* ]]; \
	run_detached_output="$$(".build/debug/compose" --dry-run -f "$$tmpdir/compose.yml" run -d api sleep 60)"; \
	[[ "$$run_detached_output" == *"--detach"* ]]; \
	[[ "$$run_detached_output" == *" alpine sleep 60"* ]]; \
	run_tty_output="$$(".build/debug/compose" --dry-run -f "$$tmpdir/compose.yml" run shell sh)"; \
	[[ "$$run_tty_output" == *"--tty"* ]]; \
	[[ "$$run_tty_output" == *"--interactive"* ]]; \
	run_no_tty_output="$$(".build/debug/compose" --dry-run -f "$$tmpdir/compose.yml" run -T shell sh)"; \
	[[ "$$run_no_tty_output" != *"--tty"* ]]; \
	[[ "$$run_no_tty_output" == *"--interactive"* ]]; \
	run_deps_metadata_output="$$(".build/debug/compose" --dry-run -f "$$tmpdir/compose.yml" run job true 2>&1 || true)"; \
	[[ "$$run_deps_metadata_output" == *"unsupported compose feature: service 'job' depends on 'db' with condition 'service_healthy'"* ]]; \
	run_no_deps_output="$$(".build/debug/compose" --dry-run -f "$$tmpdir/compose.yml" run --no-deps job true)"; \
	[[ "$$run_no_deps_output" == *"container run"* ]]; \
	[[ "$$run_no_deps_output" == *" alpine true"* ]]; \
	run_no_network_output="$$(".build/debug/compose" --dry-run -f "$$tmpdir/compose.yml" run isolated true)"; \
	[[ "$$run_no_network_output" == *"--network none"* ]]; \
	[[ "$$run_no_network_output" == *" alpine true"* ]]; \
	up_output="$$(".build/debug/compose" --dry-run -f "$$tmpdir/compose.yml" up api)"; \
	[[ "$$up_output" == *"container network create --internal --subnet 10.77.0.0/24 --subnet-v6 fd77::/64"* ]]; \
	[[ "$$up_output" == *"container volume create --opt journal=ordered --opt size=64m"* ]]; \
	[[ "$$up_output" == *"container run"* ]]; \
	[[ "$$up_output" == *"demo-db-1"* ]]; \
	[[ "$$up_output" == *"--publish 8080:80"* ]]; \
	[[ "$$up_output" == *"--dns-option use-vc"* ]]; \
	[[ "$$up_output" == *"--network demo_default,mac=02:42:ac:11:00:03,mtu=1450"* ]]; \
	[[ "$$up_output" == *"--name demo-db-1 --detach"* ]]; \
	[[ "$$up_output" != *"--name demo-api-1 --detach"* ]]; \
	up_attach_false_output="$$(".build/debug/compose" --dry-run -f "$$tmpdir/attach-false.yml" up api)"; \
	[[ "$$up_attach_false_output" == *"--name demo-api-1 --detach"* ]]; \
	up_quiet_pull_output="$$(".build/debug/compose" --dry-run -f "$$tmpdir/compose.yml" up --pull always --quiet-pull api)"; \
	[[ "$$up_quiet_pull_output" == *"container image pull --progress none alpine"* ]]; \
	[[ "$$up_quiet_pull_output" == *"container run"* ]]; \
	up_always_recreate_deps_output="$$(".build/debug/compose" --dry-run -f "$$tmpdir/compose.yml" up --always-recreate-deps api)"; \
	[[ "$$up_always_recreate_deps_output" == *"container run"* ]]; \
	[[ "$$up_always_recreate_deps_output" == *"demo-db-1"* ]]; \
	[[ "$$up_always_recreate_deps_output" == *"demo-api-1"* ]]; \
	up_always_recreate_no_recreate_output="$$(".build/debug/compose" --dry-run -f "$$tmpdir/compose.yml" up --always-recreate-deps --no-recreate api 2>&1 || true)"; \
	[[ "$$up_always_recreate_no_recreate_output" == *"invalid compose project: --always-recreate-deps and --no-recreate are incompatible"* ]]; \
	up_timeout_output="$$(".build/debug/compose" --dry-run -f "$$tmpdir/compose.yml" up --timeout 12 api)"; \
	[[ "$$up_timeout_output" == *"container run"* ]]; \
	up_compact_timeout_output="$$(".build/debug/compose" --dry-run -f "$$tmpdir/compose.yml" up -t12 api)"; \
	[[ "$$up_compact_timeout_output" == *"container run"* ]]; \
	up_invalid_timeout_output="$$(".build/debug/compose" --dry-run -f "$$tmpdir/compose.yml" up --timeout=-1 api 2>&1 || true)"; \
	[[ "$$up_invalid_timeout_output" == *"invalid compose project: up --timeout must be between 0 and 2147483647 seconds"* ]]; \
	up_no_deps_output="$$(".build/debug/compose" --dry-run -f "$$tmpdir/compose.yml" up --no-deps api)"; \
	[[ "$$up_no_deps_output" == *"container run"* ]]; \
	[[ "$$up_no_deps_output" != *"demo-db-1"* ]]; \
	up_no_start_output="$$(".build/debug/compose" --dry-run -f "$$tmpdir/compose.yml" up --no-start api)"; \
	[[ "$$up_no_start_output" == *"container create"* ]]; \
	[[ "$$up_no_start_output" != *"container run"* ]]; \
	[[ "$$up_no_start_output" == *"demo-db-1"* ]]; \
	[[ "$$up_no_start_output" == *"demo-api-1"* ]]; \
	up_no_start_no_deps_output="$$(".build/debug/compose" --dry-run -f "$$tmpdir/compose.yml" up --no-start --no-deps api)"; \
	[[ "$$up_no_start_no_deps_output" == *"container create"* ]]; \
	[[ "$$up_no_start_no_deps_output" != *"container run"* ]]; \
	[[ "$$up_no_start_no_deps_output" != *"demo-db-1"* ]]; \
	up_no_build_output="$$(".build/debug/compose" --dry-run -f "$$tmpdir/build-only.yml" up --no-build worker)"; \
	[[ "$$up_no_build_output" == *"container run"* ]]; \
	[[ "$$up_no_build_output" != *"container build"* ]]; \
	[[ "$$up_no_build_output" == *"demo_worker:latest"* ]]; \
	up_quiet_build_output="$$(".build/debug/compose" --dry-run -f "$$tmpdir/build-only.yml" up --quiet-build worker)"; \
	[[ "$$up_quiet_build_output" == *"container build"* ]]; \
	[[ "$$up_quiet_build_output" == *"--quiet"* ]]; \
	[[ "$$up_quiet_build_output" == *"container run"* ]]; \
	up_build_no_build_output="$$(".build/debug/compose" --dry-run -f "$$tmpdir/build-only.yml" up --build --no-build worker 2>&1 || true)"; \
	[[ "$$up_build_no_build_output" == *"invalid compose project: --build and --no-build are incompatible"* ]]; \
	up_scale_output="$$(".build/debug/compose" --dry-run -f "$$tmpdir/scale.yml" up --scale worker=2 worker)"; \
	[[ "$$up_scale_output" == *"--name demo-worker-1"* ]]; \
	[[ "$$up_scale_output" == *"--name demo-worker-2 --detach"* ]]; \
	up_scale_ports_output="$$(".build/debug/compose" --dry-run -f "$$tmpdir/compose.yml" up --scale api=2 api 2>&1 || true)"; \
	[[ "$$up_scale_ports_output" == *"unsupported compose feature: service 'api' publishes '8080:80'; scaled published ports require at least 2 explicit host ports for 2 replicas"* ]]; \
	up_scale_port_range_output="$$(".build/debug/compose" --dry-run -f "$$tmpdir/scale-ports.yml" up --scale api=2 api)"; \
	[[ "$$up_scale_port_range_output" == *"--name demo-api-1"* ]]; \
	[[ "$$up_scale_port_range_output" == *"--publish 8080:80"* ]]; \
	[[ "$$up_scale_port_range_output" == *"--name demo-api-2 --detach"* ]]; \
	[[ "$$up_scale_port_range_output" == *"--publish 8081:80"* ]]; \
	create_scale_output="$$(".build/debug/compose" --dry-run -f "$$tmpdir/scale.yml" create --scale worker=2 worker)"; \
	[[ "$$create_scale_output" == *"--name demo-worker-1"* ]]; \
	[[ "$$create_scale_output" == *"--name demo-worker-2"* ]]; \
	scale_output="$$(".build/debug/compose" --dry-run -f "$$tmpdir/scale.yml" scale worker=2)"; \
	[[ "$$scale_output" == *"--name demo-worker-1 --detach"* ]]; \
	[[ "$$scale_output" == *"--name demo-worker-2 --detach"* ]]; \
	scale_deps_output="$$(".build/debug/compose" --dry-run -f "$$tmpdir/scale-deps.yml" scale api=2)"; \
	[[ "$$scale_deps_output" == *"--name demo-db-1 --detach"* ]]; \
	[[ "$$scale_deps_output" == *"--name demo-api-1 --detach"* ]]; \
	[[ "$$scale_deps_output" == *"--name demo-api-2 --detach"* ]]; \
	scale_no_deps_output="$$(".build/debug/compose" --dry-run -f "$$tmpdir/scale-deps.yml" scale --no-deps api=2)"; \
	[[ "$$scale_no_deps_output" != *"demo-db-1"* ]]; \
	[[ "$$scale_no_deps_output" == *"--name demo-api-1 --detach"* ]]; \
	[[ "$$scale_no_deps_output" == *"--name demo-api-2 --detach"* ]]; \
	scale_missing_output="$$(".build/debug/compose" --dry-run scale 2>&1 || true)"; \
	[[ "$$scale_missing_output" == *"invalid compose project: scale requires at least one SERVICE=REPLICAS argument"* ]]; \
	scale_ports_output="$$(".build/debug/compose" --dry-run -f "$$tmpdir/compose.yml" scale api=2 2>&1 || true)"; \
	[[ "$$scale_ports_output" == *"unsupported compose feature: service 'api' publishes '8080:80'; scaled published ports require at least 2 explicit host ports for 2 replicas"* ]]; \
	create_output="$$(".build/debug/compose" --dry-run -f "$$tmpdir/compose.yml" create --build api)"; \
	[[ "$$create_output" == *"container create"* ]]; \
	[[ "$$create_output" == *"--publish 8080:80"* ]]; \
	[[ "$$create_output" == *"--dns-option use-vc"* ]]; \
	[[ "$$create_output" == *"--network demo_default,mac=02:42:ac:11:00:03,mtu=1450"* ]]; \
	[[ "$$create_output" != *"--detach"* ]]; \
	create_quiet_pull_output="$$(".build/debug/compose" --dry-run -f "$$tmpdir/compose.yml" create --pull always --quiet-pull api)"; \
	[[ "$$create_quiet_pull_output" == *"container image pull --progress none alpine"* ]]; \
	[[ "$$create_quiet_pull_output" == *"container create"* ]]; \
	create_dynamic_ports_output="$$(".build/debug/compose" --dry-run -f "$$tmpdir/dynamic-ports.yml" create api 2>&1 || true)"; \
	[[ "$$create_dynamic_ports_output" == *"unsupported compose feature: service 'api' publishes target port 80/tcp dynamically; apple/container publish requires explicit host ports"* ]]; \
	detached_output="$$(".build/debug/compose" --dry-run -f "$$tmpdir/compose.yml" up --detach api)"; \
	[[ "$$detached_output" == *"container run"* ]]; \
	[[ "$$detached_output" == *"--detach"* ]]; \
	[[ "$$detached_output" == *"--name demo-api-1 --detach"* ]]; \
	logs_output="$$(".build/debug/compose" --dry-run -f "$$tmpdir/compose.yml" logs -f api)"; \
	[[ "$$logs_output" == *"container logs --follow"* ]]; \
	logs_tail_output="$$(".build/debug/compose" --dry-run -f "$$tmpdir/compose.yml" logs -n 5 api)"; \
	[[ "$$logs_tail_output" == *"container logs -n 5 demo-api-1"* ]]; \
	logs_compact_tail_output="$$(".build/debug/compose" --dry-run -f "$$tmpdir/compose.yml" logs -n5 api)"; \
	[[ "$$logs_compact_tail_output" == *"container logs -n 5 demo-api-1"* ]]; \
	logs_all_output="$$(".build/debug/compose" --dry-run -f "$$tmpdir/compose.yml" logs --tail all api)"; \
	[[ "$$logs_all_output" == *"container logs demo-api-1"* ]]; \
	[[ "$$logs_all_output" != *" -n "* ]]; \
	logs_index_output="$$(".build/debug/compose" --dry-run -f "$$tmpdir/compose.yml" logs --index 2 api)"; \
	[[ "$$logs_index_output" == *"container logs demo-api-2"* ]]; \
	logs_display_output="$$(".build/debug/compose" --dry-run -f "$$tmpdir/compose.yml" logs --no-color --no-log-prefix api)"; \
	[[ "$$logs_display_output" == *"container logs demo-api-1"* ]]; \
	attach_output="$$(".build/debug/compose" --dry-run -f "$$tmpdir/compose.yml" attach --no-stdin --sig-proxy=false api)"; \
	[[ "$$attach_output" == *"container logs --follow demo-api-1"* ]]; \
	attach_index_output="$$(".build/debug/compose" --dry-run -f "$$tmpdir/compose.yml" attach --no-stdin --sig-proxy=false --index 2 api)"; \
	[[ "$$attach_index_output" == *"container logs --follow demo-api-2"* ]]; \
	attach_default_output="$$(".build/debug/compose" --dry-run -f "$$tmpdir/compose.yml" attach api 2>&1 || true)"; \
	[[ "$$attach_default_output" == *"unsupported compose feature: attach: apple/container logs is output-only"* ]]; \
	exec_output="$$(".build/debug/compose" --dry-run -f "$$tmpdir/compose.yml" -p demo exec api echo ok)"; \
	[[ "$$exec_output" == *"container exec --interactive --tty demo-api-1 echo ok"* ]]; \
	exec_no_tty_output="$$(".build/debug/compose" --dry-run -f "$$tmpdir/compose.yml" -p demo exec -T api echo ok)"; \
	[[ "$$exec_no_tty_output" == *"container exec --interactive demo-api-1 echo ok"* ]]; \
	[[ "$$exec_no_tty_output" != *"--tty"* ]]; \
	exec_long_no_tty_output="$$(".build/debug/compose" --dry-run -f "$$tmpdir/compose.yml" -p demo exec --no-tty api echo ok)"; \
	[[ "$$exec_long_no_tty_output" == *"container exec --interactive demo-api-1 echo ok"* ]]; \
	[[ "$$exec_long_no_tty_output" != *"--tty"* ]]; \
	exec_non_interactive_output="$$(".build/debug/compose" --dry-run -f "$$tmpdir/compose.yml" -p demo exec --interactive=false -T api echo ok)"; \
	[[ "$$exec_non_interactive_output" == *"container exec demo-api-1 echo ok"* ]]; \
	[[ "$$exec_non_interactive_output" != *"--interactive"* ]]; \
	[[ "$$exec_non_interactive_output" != *"--tty"* ]]; \
	exec_options_output="$$(".build/debug/compose" --dry-run -f "$$tmpdir/compose.yml" -p demo exec -e FOO=bar -u 1000:1000 -w /app api env)"; \
	[[ "$$exec_options_output" == *"container exec --env FOO=bar --user 1000:1000 --workdir /app --interactive --tty demo-api-1 env"* ]]; \
	exec_compact_options_output="$$(".build/debug/compose" --dry-run -f "$$tmpdir/compose.yml" -p demo exec -eFOO=bar -u1000:1000 -w/app api env)"; \
	[[ "$$exec_compact_options_output" == *"container exec --env FOO=bar --user 1000:1000 --workdir /app --interactive --tty demo-api-1 env"* ]]; \
	exec_mixed_options_output="$$(".build/debug/compose" --dry-run -f "$$tmpdir/compose.yml" -p demo exec -e FOO=bar -u1000:1000 -w/app api env)"; \
	[[ "$$exec_mixed_options_output" == *"container exec --env FOO=bar --user 1000:1000 --workdir /app --interactive --tty demo-api-1 env"* ]]; \
	exec_detach_output="$$(".build/debug/compose" --dry-run -f "$$tmpdir/compose.yml" -p demo exec -d api sleep 60)"; \
	[[ "$$exec_detach_output" == *"container exec --detach demo-api-1 sleep 60"* ]]; \
	[[ "$$exec_detach_output" != *"--interactive"* ]]; \
	[[ "$$exec_detach_output" != *"--tty"* ]]; \
	exec_index_output="$$(".build/debug/compose" --dry-run -f "$$tmpdir/compose.yml" -p demo exec --index 2 api true)"; \
	[[ "$$exec_index_output" == *"container exec --interactive --tty demo-api-2 true"* ]]; \
	exec_privileged_output="$$(".build/debug/compose" --dry-run -f "$$tmpdir/compose.yml" -p demo exec --privileged api true 2>&1 || true)"; \
	[[ "$$exec_privileged_output" == *"unsupported compose feature: exec --privileged: apple/container exec does not expose privileged process execution"* ]]; \
	cp_output="$$(".build/debug/compose" --dry-run -f "$$tmpdir/compose.yml" -p demo cp api:/tmp/file .)"; \
	[[ "$$cp_output" == *"container cp demo-api-1:/tmp/file ."* ]]; \
	cp_index_one_output="$$(".build/debug/compose" --dry-run -f "$$tmpdir/compose.yml" -p demo cp --index 1 api:/tmp/file .)"; \
	[[ "$$cp_index_one_output" == *"container cp demo-api-1:/tmp/file ."* ]]; \
	cp_archive_output="$$(".build/debug/compose" --dry-run -f "$$tmpdir/compose.yml" -p demo cp -a api:/tmp/file . 2>&1 || true)"; \
	[[ "$$cp_archive_output" == *"unsupported compose feature: cp --archive: apple/container cp does not expose archive mode"* ]]; \
	cp_follow_link_output="$$(".build/debug/compose" --dry-run -f "$$tmpdir/compose.yml" -p demo cp -L api:/tmp/file . 2>&1 || true)"; \
	[[ "$$cp_follow_link_output" == *"unsupported compose feature: cp --follow-link: apple/container cp does not expose follow-link mode"* ]]; \
	cp_all_output="$$(".build/debug/compose" --dry-run -f "$$tmpdir/compose.yml" -p demo cp --all api:/tmp/file .)"; \
	[[ "$$cp_all_output" == *"container cp demo-api-1:/tmp/file ."* ]]; \
	cp_all_service_output="$$(".build/debug/compose" --dry-run -f "$$tmpdir/compose.yml" -p demo cp --all api:/tmp/file db:/tmp/file)"; \
	[[ "$$cp_all_service_output" == *"container cp demo-api-1:/tmp/file demo-db-1:/tmp/file"* ]]; \
	cp_index_output="$$(".build/debug/compose" --dry-run -f "$$tmpdir/compose.yml" -p demo cp --index 2 api:/tmp/file .)"; \
	[[ "$$cp_index_output" == *"container cp demo-api-2:/tmp/file ."* ]]; \
	export_output="$$(".build/debug/compose" --dry-run -f "$$tmpdir/compose.yml" -p demo export api)"; \
	[[ "$$export_output" == *"container export demo-api-1"* ]]; \
	export_file_output="$$(".build/debug/compose" --dry-run -f "$$tmpdir/compose.yml" -p demo export -o api.tar api)"; \
	[[ "$$export_file_output" == *"container export --output api.tar demo-api-1"* ]]; \
	export_index_output="$$(".build/debug/compose" --dry-run -f "$$tmpdir/compose.yml" -p demo export --index 2 api)"; \
	[[ "$$export_index_output" == *"container export demo-api-2"* ]]; \
	stop_timeout_output="$$(".build/debug/compose" --dry-run -f "$$tmpdir/compose.yml" -p demo stop --timeout 12 api)"; \
	[[ "$$stop_timeout_output" == *"container stop --time 12 demo-api-1"* ]]; \
	stop_compact_timeout_output="$$(".build/debug/compose" --dry-run -f "$$tmpdir/compose.yml" -p demo stop -t12 api)"; \
	[[ "$$stop_compact_timeout_output" == *"container stop --time 12 demo-api-1"* ]]; \
	restart_timeout_output="$$(".build/debug/compose" --dry-run -f "$$tmpdir/compose.yml" -p demo restart -t 13 api)"; \
	[[ "$$restart_timeout_output" == *"container stop --time 13 demo-api-1"* ]]; \
	restart_compact_timeout_output="$$(".build/debug/compose" --dry-run -f "$$tmpdir/compose.yml" -p demo restart -t13 api)"; \
	[[ "$$restart_compact_timeout_output" == *"container stop --time 13 demo-api-1"* ]]; \
	kill_compact_signal_output="$$(".build/debug/compose" --dry-run -f "$$tmpdir/compose.yml" -p demo kill -sSIGKILL api)"; \
	[[ "$$kill_compact_signal_output" == *"container kill --signal SIGKILL demo-api-1"* ]]; \
	rm_force_volumes_output="$$(".build/debug/compose" --dry-run -f "$$tmpdir/compose.yml" -p demo rm -fv api)"; \
	[[ "$$rm_force_volumes_output" == *"container delete --force demo-api-1"* ]]; \
	[[ "$$rm_force_volumes_output" == *"container volume delete demo_anon-"* ]]; \
	down_compact_timeout_output="$$(".build/debug/compose" --dry-run -f "$$tmpdir/compose.yml" -p demo down -t12)"; \
	[[ "$$down_compact_timeout_output" == *"container stop --time 12 demo-api-1"* ]]; \
	down_rmi_output="$$(".build/debug/compose" --dry-run -f "$$tmpdir/compose.yml" -p demo down --rmi all)"; \
	[[ "$$down_rmi_output" == *"container image delete --force alpine"* ]]; \
	ps_quiet_output="$$(".build/debug/compose" --dry-run -f "$$tmpdir/compose.yml" -p demo ps -q)"; \
	[[ "$$ps_quiet_output" == *"container list --format json"* ]]; \
	ps_services_output="$$(".build/debug/compose" --dry-run -f "$$tmpdir/compose.yml" -p demo ps --services)"; \
	[[ "$$ps_services_output" == *"container list --format json"* ]]; \
	ps_status_output="$$(".build/debug/compose" --dry-run -f "$$tmpdir/compose.yml" -p demo ps --status running)"; \
	[[ "$$ps_status_output" == *"container list --format json --all"* ]]; \
	ps_filter_output="$$(".build/debug/compose" --dry-run -f "$$tmpdir/compose.yml" -p demo ps --filter status=exited)"; \
	[[ "$$ps_filter_output" == *"container list --format json --all"* ]]; \
	images_json_output="$$(".build/debug/compose" --dry-run -f "$$tmpdir/compose.yml" -p demo images --format json api)"; \
	[[ "$$images_json_output" == *"container list --format json --all"* ]]; \
	images_quiet_output="$$(".build/debug/compose" --dry-run -f "$$tmpdir/compose.yml" -p demo images -q api)"; \
	[[ "$$images_quiet_output" == *"container list --format json --all"* ]]; \
	volumes_json_output="$$(".build/debug/compose" --dry-run -f "$$tmpdir/compose.yml" -p demo volumes --format json api)"; \
	[[ "$$volumes_json_output" == *"container volume list --format json"* ]]; \
	volumes_quiet_output="$$(".build/debug/compose" --dry-run -f "$$tmpdir/compose.yml" -p demo volumes -q api)"; \
	[[ "$$volumes_quiet_output" == *"container volume list --format json"* ]]; \
	volumes_bad_format_output="$$(".build/debug/compose" --dry-run -f "$$tmpdir/compose.yml" -p demo volumes --format yaml api 2>&1 || true)"; \
	[[ "$$volumes_bad_format_output" == *"unsupported compose feature: volumes --format 'yaml'; supported formats are table and json"* ]]; \
	stats_output="$$(".build/debug/compose" --dry-run -f "$$tmpdir/compose.yml" -p demo stats --no-stream --format json api db)"; \
	[[ "$$stats_output" == *"container stats --format json --no-stream demo-api-1 demo-db-1"* ]]; \
	ls_json_output="$$(".build/debug/compose" --dry-run ls --format json)"; \
	[[ "$$ls_json_output" == *"container list --format json"* ]]; \
	[[ "$$ls_json_output" != *"--all"* ]]; \
	ls_all_output="$$(".build/debug/compose" --dry-run ls --all --filter name=demo)"; \
	[[ "$$ls_all_output" == *"container list --format json --all"* ]]; \
	top_output="$$(".build/debug/compose" --dry-run -f "$$tmpdir/compose.yml" top api 2>&1 || true)"; \
	[[ "$$top_output" == *"unsupported compose feature: top:"* ]]; \
	[[ "$$top_output" == *"apple/container does not expose a process-list command yet"* ]]; \
	events_output="$$(".build/debug/compose" --dry-run -f "$$tmpdir/compose.yml" events --json 2>&1 || true)"; \
	[[ "$$events_output" == *"unsupported compose feature: events:"* ]]; \
	[[ "$$events_output" == *"apple/container does not expose an event stream yet"* ]]; \
	port_output="$$(".build/debug/compose" --dry-run -f "$$tmpdir/compose.yml" port api 80)"; \
	[[ "$$port_output" == *"0.0.0.0:8080"* ]]; \
	pause_output="$$(".build/debug/compose" --dry-run -f "$$tmpdir/compose.yml" pause api 2>&1 || true)"; \
	[[ "$$pause_output" == *"unsupported compose feature: pause:"* ]]; \
	[[ "$$pause_output" == *"apple/container does not expose pause yet"* ]]; \
	unpause_output="$$(".build/debug/compose" --dry-run -f "$$tmpdir/compose.yml" unpause api 2>&1 || true)"; \
	[[ "$$unpause_output" == *"unsupported compose feature: unpause:"* ]]; \
	[[ "$$unpause_output" == *"apple/container does not expose unpause yet"* ]]; \
	wait_output="$$(".build/debug/compose" --dry-run -f "$$tmpdir/compose.yml" wait api 2>&1 || true)"; \
	[[ "$$wait_output" == *"unsupported compose feature: wait:"* ]]; \
	for unsupported_command in watch commit publish; do \
		unsupported_output="$$(".build/debug/compose" --dry-run "$$unsupported_command" 2>&1 || true)"; \
		[[ "$$unsupported_output" == *"unsupported compose feature: $$unsupported_command:"* ]]; \
	done

coverage: swift-coverage go-test

coverage-check: coverage
	$(PYTHON) Tools/coverage/check-coverage.py \
		--minimum "$(COVERAGE_MIN)" \
		--swift coverage.xml \
		--go Tools/compose-normalizer/coverage.out

sonar: coverage sonar-scan

sonar-scan:
	@test -f coverage.xml || { \
		printf 'coverage.xml is missing; run make coverage or make ci before make sonar-scan\n' >&2; \
		exit 2; \
	}
	@test -f Tools/compose-normalizer/coverage.out || { \
		printf 'Tools/compose-normalizer/coverage.out is missing; run make coverage or make ci before make sonar-scan\n' >&2; \
		exit 2; \
	}
	@sonar_token="$${SONAR_TOKEN:-$${SONAR_TOKEN_PERSONAL:-}}"; \
	if [[ -z "$$sonar_token" ]]; then \
		printf 'SONAR_TOKEN or SONAR_TOKEN_PERSONAL is required for make sonar\n' >&2; \
		exit 2; \
	fi
	sonar_token="$${SONAR_TOKEN:-$${SONAR_TOKEN_PERSONAL:-}}"; \
	branch="$${SONAR_BRANCH:-$$(git branch --show-current 2>/dev/null || true)}"; \
	if [[ -n "$$branch" && "$$branch" != "HEAD" ]]; then \
		SONAR_TOKEN="$$sonar_token" sonar-scanner -Dsonar.branch.name="$$branch" -Dsonar.qualitygate.wait="$(SONAR_QUALITYGATE_WAIT)"; \
	else \
		SONAR_TOKEN="$$sonar_token" sonar-scanner -Dsonar.qualitygate.wait="$(SONAR_QUALITYGATE_WAIT)"; \
	fi

package: build-release
	cd Tools/compose-normalizer && $(GO) build -o compose-normalizer .
	rm -rf "$(DIST_DIR)"
	mkdir -p "$(DIST_DIR)/compose/bin" "$(DIST_DIR)/compose/resources"
	cp .build/release/compose "$(DIST_DIR)/compose/bin/compose"
	cp config.toml "$(DIST_DIR)/compose/config.toml"
	cp Tools/compose-normalizer/compose-normalizer "$(DIST_DIR)/compose/resources/compose-normalizer"
	tar -czf "$(PLUGIN_ARCHIVE)" -C "$(DIST_DIR)" compose

coverage-tools-test:
	$(PYTHON) -m py_compile Tools/coverage/*.py
	$(PYTHON) -m unittest discover Tools/coverage

lint: coverage-tools-test
	@if command -v "$(MARKDOWNLINT)" >/dev/null 2>&1; then \
		"$(MARKDOWNLINT)" $(MARKDOWN_FILES); \
	elif command -v markdownlint-cli2 >/dev/null 2>&1; then \
		markdownlint-cli2 $(MARKDOWN_FILES); \
	else \
		printf 'markdownlint is required; install markdownlint-cli or set MARKDOWNLINT=/path/to/markdownlint\n' >&2; \
		exit 1; \
	fi
	@unformatted="$$(find Tools/compose-normalizer -name '*.go' -type f -print0 | xargs -0 gofmt -l)"; \
	if [[ -n "$$unformatted" ]]; then \
		printf 'Go files need formatting:\n%s\n' "$$unformatted" >&2; \
		exit 1; \
	fi

format:
	cd Tools/compose-normalizer && $(GO) fmt ./...

clean:
	$(SWIFT) package clean
	rm -rf "$(DIST_DIR)" "$(PLUGIN_ARCHIVE)" .scannerwork coverage.lcov coverage.out coverage.report coverage.xml
	rm -f *.profraw Tools/compose-normalizer/coverage.out Tools/compose-normalizer/compose-normalizer
	find Tools -type d -name __pycache__ -prune -exec rm -rf {} +
