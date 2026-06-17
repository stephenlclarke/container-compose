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
GO ?= go
PYTHON ?= python3
MARKDOWNLINT ?= markdownlint
COVERAGE_MIN ?= 85
DIST_DIR ?= dist
PLUGIN_ARCHIVE ?= container-compose-plugin.tar.gz
SONAR_QUALITYGATE_WAIT ?= false
SWIFT_TEST_FRAMEWORK_SEARCH_PATH ?= /Library/Developer/CommandLineTools/Library/Developer/Frameworks
SWIFT_TEST_RUNTIME_LIBRARY_PATH ?= /Library/Developer/CommandLineTools/Library/Developer/usr/lib
MARKDOWN_FILES := README.md BUILD.md COMPATIBILITY.md CONTRIBUTING.md DESIGN.md INSTALL.md

# Command Line Tools installs can place Swift Testing outside SwiftPM's default rpaths.
ifneq ($(wildcard $(SWIFT_TEST_FRAMEWORK_SEARCH_PATH)/Testing.framework),)
SWIFT_TEST_FLAGS ?= -Xswiftc -F -Xswiftc $(SWIFT_TEST_FRAMEWORK_SEARCH_PATH) -Xlinker -rpath -Xlinker $(SWIFT_TEST_FRAMEWORK_SEARCH_PATH)
ifneq ($(wildcard $(SWIFT_TEST_RUNTIME_LIBRARY_PATH)/lib_TestingInterop.dylib),)
SWIFT_TEST_FLAGS += -Xlinker -rpath -Xlinker $(SWIFT_TEST_RUNTIME_LIBRARY_PATH)
endif
else
SWIFT_TEST_FLAGS ?=
endif

.PHONY: all workflow ci clean run build build-release test resolve swift-test swift-coverage go-test go-build cli-smoke coverage coverage-check sonar sonar-scan package lint format

all: workflow

workflow: ci package

ci: resolve lint coverage-check go-build cli-smoke

resolve:
	$(SWIFT) package resolve

build:
	$(SWIFT) build --product compose

build-release:
	$(SWIFT) build -c release --product compose

run:
	$(SWIFT) run compose version

test: swift-test go-test

swift-test:
	$(SWIFT) test --enable-code-coverage $(SWIFT_TEST_FLAGS)

swift-coverage: swift-test
	test_binary="$$(find .build -path '*.xctest/Contents/MacOS/*' -type f | head -n 1)"; \
	profile="$$(find .build -path '*/codecov/default.profdata' -type f | head -n 1)"; \
	xcrun llvm-cov export \
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
	tmpdir="$$(mktemp -d)"; \
	trap 'rm -rf "$$tmpdir"' EXIT; \
	printf 'services:\n  api:\n    image: alpine\n    ports:\n      - "8080:80"\n' > "$$tmpdir/compose.yml"; \
	run_output="$$(".build/debug/compose" --dry-run -f "$$tmpdir/compose.yml" run api echo hello)"; \
	[[ "$$run_output" == *"container run"* ]]; \
	[[ "$$run_output" == *" alpine echo hello"* ]]; \
	[[ "$$run_output" != *"--publish 8080:80"* ]]; \
	run_service_ports_output="$$(".build/debug/compose" --dry-run -f "$$tmpdir/compose.yml" run --service-ports api echo hello)"; \
	[[ "$$run_service_ports_output" == *"--publish 8080:80"* ]]; \
	run_publish_output="$$(".build/debug/compose" --dry-run -f "$$tmpdir/compose.yml" run -p 9090:90 api echo hello)"; \
	[[ "$$run_publish_output" == *"--publish 9090:90"* ]]; \
	[[ "$$run_publish_output" != *"--publish 8080:80"* ]]; \
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
	run_env_output="$$(".build/debug/compose" --dry-run -f "$$tmpdir/compose.yml" run -e LOG_LEVEL=debug --env-from-file .env.local api env)"; \
	[[ "$$run_env_output" == *"--env LOG_LEVEL=debug"* ]]; \
	[[ "$$run_env_output" == *"--env-file .env.local"* ]]; \
	[[ "$$run_env_output" == *" alpine env"* ]]; \
	run_label_output="$$(".build/debug/compose" --dry-run -f "$$tmpdir/compose.yml" run -l com.example.role=job api true)"; \
	[[ "$$run_label_output" == *"--label com.example.role=job"* ]]; \
	[[ "$$run_label_output" == *" alpine true"* ]]; \
	run_volume_output="$$(".build/debug/compose" --dry-run -f "$$tmpdir/compose.yml" run -v /host:/container:ro api ls)"; \
	[[ "$$run_volume_output" == *"--volume /host:/container:ro"* ]]; \
	[[ "$$run_volume_output" == *" alpine ls"* ]]; \
	run_detached_output="$$(".build/debug/compose" --dry-run -f "$$tmpdir/compose.yml" run -d api sleep 60)"; \
	[[ "$$run_detached_output" == *"--detach"* ]]; \
	[[ "$$run_detached_output" == *" alpine sleep 60"* ]]; \
	up_output="$$(".build/debug/compose" --dry-run -f "$$tmpdir/compose.yml" up api)"; \
	[[ "$$up_output" == *"container run"* ]]; \
	[[ "$$up_output" == *"--publish 8080:80"* ]]; \
	[[ "$$up_output" != *"--detach"* ]]; \
	detached_output="$$(".build/debug/compose" --dry-run -f "$$tmpdir/compose.yml" up --detach api)"; \
	[[ "$$detached_output" == *"container run"* ]]; \
	[[ "$$detached_output" == *"--detach"* ]]; \
	logs_output="$$(".build/debug/compose" --dry-run -f "$$tmpdir/compose.yml" logs -f api)"; \
	[[ "$$logs_output" == *"container logs --follow"* ]]; \
	logs_tail_output="$$(".build/debug/compose" --dry-run -f "$$tmpdir/compose.yml" logs -n 5 api)"; \
	[[ "$$logs_tail_output" == *"container logs -n 5 demo-api-1"* ]]; \
	logs_all_output="$$(".build/debug/compose" --dry-run -f "$$tmpdir/compose.yml" logs --tail all api)"; \
	[[ "$$logs_all_output" == *"container logs demo-api-1"* ]]; \
	[[ "$$logs_all_output" != *" -n "* ]]; \
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
	cp_output="$$(".build/debug/compose" --dry-run -f "$$tmpdir/compose.yml" -p demo cp api:/tmp/file .)"; \
	[[ "$$cp_output" == *"container cp demo-api-1:/tmp/file ."* ]]; \
	top_output="$$(".build/debug/compose" --dry-run -f "$$tmpdir/compose.yml" top api 2>&1 || true)"; \
	[[ "$$top_output" == *"unsupported compose feature: top:"* ]]; \
	[[ "$$top_output" == *"apple/container does not expose a process-list command yet"* ]]; \
	events_output="$$(".build/debug/compose" --dry-run -f "$$tmpdir/compose.yml" events --json 2>&1 || true)"; \
	[[ "$$events_output" == *"unsupported compose feature: events:"* ]]; \
	[[ "$$events_output" == *"apple/container does not expose an event stream yet"* ]]; \
	pause_output="$$(".build/debug/compose" --dry-run -f "$$tmpdir/compose.yml" pause api 2>&1 || true)"; \
	[[ "$$pause_output" == *"unsupported compose feature: pause:"* ]]; \
	[[ "$$pause_output" == *"apple/container does not expose pause yet"* ]]; \
	unpause_output="$$(".build/debug/compose" --dry-run -f "$$tmpdir/compose.yml" unpause api 2>&1 || true)"; \
	[[ "$$unpause_output" == *"unsupported compose feature: unpause:"* ]]; \
	[[ "$$unpause_output" == *"apple/container does not expose unpause yet"* ]]; \
	wait_output="$$(".build/debug/compose" --dry-run -f "$$tmpdir/compose.yml" wait api 2>&1 || true)"; \
	[[ "$$wait_output" == *"unsupported compose feature: wait:"* ]]

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

lint:
	$(PYTHON) -m py_compile Tools/coverage/*.py
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
