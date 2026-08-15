#!/usr/bin/env python3
##===----------------------------------------------------------------------===##
## Copyright © 2026 container-compose project authors.
##
## Licensed under the Apache License, Version 2.0 (the "License");
## you may not use this file except in compliance with the License.
## You may obtain a copy of the License at
##
##   https://www.apache.org/licenses/LICENSE-2.0
##
## Unless required by applicable law or agreed to in writing, software
## distributed under the License is distributed on an "AS IS" BASIS,
## WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
## See the License for the specific language governing permissions and
## limitations under the License.
##===----------------------------------------------------------------------===##

from __future__ import annotations

import importlib.util
import json
import os
from pathlib import Path
import shlex
import subprocess
import sys
import tarfile
import tempfile
import unittest
from unittest import mock
import zipfile


MODULE_PATH = Path(__file__).with_name("codeql-local.py")
MAKE_ENTRY_PATH = Path(__file__).with_name("codeql-make.py")
PROCESS_ENTRY_PATH = Path(__file__).with_name("codeql-entry.sh")
SPEC = importlib.util.spec_from_file_location("codeql_local", MODULE_PATH)
assert SPEC is not None and SPEC.loader is not None
codeql = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = codeql
SPEC.loader.exec_module(codeql)
MAKE_SPEC = importlib.util.spec_from_file_location("codeql_make", MAKE_ENTRY_PATH)
assert MAKE_SPEC is not None and MAKE_SPEC.loader is not None
codeql_make = importlib.util.module_from_spec(MAKE_SPEC)
sys.modules[MAKE_SPEC.name] = codeql_make
MAKE_SPEC.loader.exec_module(codeql_make)


COMMIT = "a" * 40
OTHER_COMMIT = "b" * 40
TREE = "c" * 40
REPOSITORY = "example/container-compose"


def write_json(path: Path, payload: object) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")


def baseline_payload(allowed_results: list[dict[str, str]] | None = None) -> dict[str, object]:
    return {
        "schemaVersion": 1,
        "toolVersion": codeql.CODEQL_VERSION,
        "queryPack": f"{codeql.CODEQL_QUERY_PACK}@{codeql.CODEQL_QUERY_PACK_VERSION}",
        "category": codeql.CODEQL_CATEGORY,
        "allowedResults": allowed_results or [],
    }


def result_payload() -> dict[str, object]:
    return {
        "ruleId": "go/example",
        "message": {"text": "example result"},
        "locations": [
            {
                "physicalLocation": {
                    "artifactLocation": {"uri": "Tools/compose-normalizer/main.go"},
                    "region": {"startLine": 7},
                }
            }
        ],
        "partialFingerprints": {"primaryLocationLineHash": "fingerprint-1"},
    }


def sarif_payload(results: list[dict[str, object]] | None = None) -> dict[str, object]:
    return {
        "version": "2.1.0",
        "runs": [
            {
                "tool": {
                    "driver": {
                        "name": "CodeQL",
                        "semanticVersion": codeql.CODEQL_VERSION,
                        "rules": [{"id": "go/example"}],
                    }
                },
                "automationDetails": {"id": codeql.CODEQL_SARIF_AUTOMATION_ID},
                "results": results or [],
            }
        ],
    }


def create_retained_evidence(root: Path) -> tuple[Path, Path]:
    repository_root = root / "repository"
    artifact_root = repository_root / ".build" / "codeql"
    evidence = artifact_root / COMMIT
    config = repository_root / codeql.CODEQL_CONFIG
    baseline = repository_root / codeql.CODEQL_BASELINE
    sarif = evidence / codeql.SARIF_NAME
    config.parent.mkdir(parents=True, exist_ok=True)
    config.write_text("name: test\n", encoding="utf-8")
    write_json(baseline, baseline_payload())
    write_json(sarif, sarif_payload())
    make_path = Path("/trusted/bin/make")
    go_path = Path("/trusted/go1.26.3/bin/go")
    build_tools = {
        "make": {
            "path": str(make_path),
            "version": "GNU Make 4.4.1",
            "sha256": "d" * 64,
        },
        "go": {
            "path": str(go_path),
            "version": codeql.GO_TOOLCHAIN_VERSION,
            "versionOutput": "go version go1.26.3 linux/amd64",
            "sha256": "e" * 64,
            "archive": {
                "name": codeql.GO_TOOLCHAIN_PINS["darwin-arm64"].name,
                "platform": "darwin-arm64",
                "sha256": codeql.GO_TOOLCHAIN_PINS["darwin-arm64"].sha256,
                "url": codeql.GO_TOOLCHAIN_PINS["darwin-arm64"].url,
            },
        },
    }
    workflow_tools = {
        "git": {
            "path": "/usr/bin/git",
            "versionOutput": "git version 2.50.1",
            "sha256": "a" * 64,
        },
        "archiveExtractor": {
            "path": "/usr/bin/tar",
            "versionOutput": "bsdtar 3.5.3",
            "sha256": "b" * 64,
        },
        "downloader": {
            "path": "/usr/bin/curl",
            "versionOutput": "curl 8.7.1",
            "sha256": "c" * 64,
        },
    }
    manifest = {
        "schemaVersion": 1,
        "repository": REPOSITORY,
        "commit": COMMIT,
        "buildCommand": codeql.exact_build_command(make_path),
        "buildPath": codeql.exact_build_path(go_path),
        "buildTools": build_tools,
        "workflowTools": workflow_tools,
        "buildEnvironment": codeql.CODEQL_BUILD_ENVIRONMENT,
        "environmentPolicy": codeql.CODEQL_ENVIRONMENT_POLICY,
        "gitCommandConfig": codeql.CODEQL_GIT_COMMAND_CONFIG,
        "gitEnvironment": codeql.CODEQL_GIT_ENVIRONMENT,
        "goCachePolicy": codeql.CODEQL_GO_CACHE_POLICY,
        "temporaryRootPolicy": codeql.CODEQL_TEMPORARY_ROOT_POLICY,
        "temporaryRoot": str(codeql.TRUSTED_TEMPORARY_ROOT),
        "passThroughEnvironment": list(codeql.CODEQL_PASSTHROUGH_ENVIRONMENT),
        "sourceIsolation": codeql.CODEQL_SOURCE_ISOLATION,
        "sourceTree": TREE,
        "category": codeql.CODEQL_CATEGORY,
        "sarifAutomationId": codeql.CODEQL_SARIF_AUTOMATION_ID,
        "codeqlVersion": codeql.CODEQL_VERSION,
        "queryPack": f"{codeql.CODEQL_QUERY_PACK}@{codeql.CODEQL_QUERY_PACK_VERSION}",
        "querySuite": codeql.CODEQL_QUERY_SUITE,
        "platform": "osx64",
        "bundleSha256": codeql.BUNDLE_PINS["osx64"].sha256,
        "sarif": codeql.SARIF_NAME,
        "configSha256": codeql.sha256_file(config),
        "baselineSha256": codeql.sha256_file(baseline),
        "sarifSha256": codeql.sha256_file(sarif),
        "resultCount": 0,
        "ruleCount": 1,
    }
    write_json(evidence / codeql.MANIFEST_NAME, manifest)
    return repository_root, artifact_root


def authenticated_analysis(artifact_root: Path) -> object:
    evidence = artifact_root / COMMIT
    manifest = json.loads(
        (evidence / codeql.MANIFEST_NAME).read_text(encoding="utf-8")
    )
    return codeql.AuthenticatedAnalysis(
        path=evidence,
        commit=COMMIT,
        manifest_sha256=codeql.sha256_file(evidence / codeql.MANIFEST_NAME),
        sarif_sha256=manifest["sarifSha256"],
        result_count=manifest["resultCount"],
    )


class CodeQLLocalTests(unittest.TestCase):
    def test_bundle_pins_are_exact_release_assets(self) -> None:
        self.assertEqual(codeql.CODEQL_VERSION, "2.26.2")
        self.assertEqual(codeql.CODEQL_QUERY_PACK_VERSION, "1.6.7")
        self.assertEqual(codeql.CODEQL_BUILD_ENVIRONMENT["CGO_ENABLED"], "0")
        self.assertEqual(codeql.CODEQL_BUILD_ENVIRONMENT["GOOS"], "linux")
        self.assertEqual(codeql.CODEQL_BUILD_ENVIRONMENT["GOARCH"], "amd64")
        self.assertEqual(codeql.CODEQL_BUILD_ENVIRONMENT["GOTOOLCHAIN"], "local")
        self.assertEqual(codeql.CODEQL_BUILD_ENVIRONMENT["GOFLAGS"], "-mod=readonly")
        self.assertEqual(
            codeql.CODEQL_BUILD_ENVIRONMENT["GOPROXY"],
            "https://proxy.golang.org",
        )
        self.assertEqual(codeql.CODEQL_BUILD_ENVIRONMENT["GOSUMDB"], "sum.golang.org")
        self.assertEqual(codeql.CODEQL_BUILD_ENVIRONMENT["GOVCS"], "*:off")
        self.assertEqual(codeql.CODEQL_GIT_ENVIRONMENT["GIT_CONFIG_GLOBAL"], "/dev/null")
        self.assertEqual(codeql.CODEQL_GIT_ENVIRONMENT["GIT_CONFIG_NOSYSTEM"], "1")
        self.assertEqual(codeql.CODEQL_GIT_ENVIRONMENT["GIT_NO_REPLACE_OBJECTS"], "1")
        self.assertEqual(codeql.CODEQL_GIT_COMMAND_CONFIG["core.fsmonitor"], "false")
        self.assertEqual(codeql.CODEQL_GIT_COMMAND_CONFIG["core.hooksPath"], "/dev/null")
        self.assertEqual(codeql.CODEQL_GIT_COMMAND_CONFIG["protocol.allow"], "never")
        self.assertEqual(codeql.CODEQL_GIT_COMMAND_CONFIG["protocol.ext.allow"], "never")
        self.assertEqual(codeql.GO_TOOLCHAIN_VERSION, "go1.26.3")
        self.assertEqual(codeql.GITHUB_CLI_VERSION, "2.96.0")
        self.assertEqual(
            codeql.BUNDLE_PINS["osx64"].sha256,
            "31641108d48133206e1ccd4bf047b21a0ce3347fdee66443cc3f7acf1b413126",
        )
        self.assertEqual(
            codeql.BUNDLE_PINS["linux64"].sha256,
            "cb361567fa1bdb9d322da4240f621b36f245e4d7bb97db3c3a2ad7f743c8e8e7",
        )
        self.assertEqual(
            codeql.GO_TOOLCHAIN_PINS["darwin-arm64"].sha256,
            "875cf54a15311eee2c99b9dd67c68c4a49351d489ab622bf2cfd28c8f2078d3c",
        )
        self.assertEqual(
            codeql.GO_TOOLCHAIN_PINS["darwin-amd64"].sha256,
            "278d580b32e299fe4a9c990fcf2d02acfe538c7e551a6ee18f9c7164573d2c63",
        )
        self.assertEqual(
            codeql.GO_TOOLCHAIN_PINS["linux-amd64"].sha256,
            "2b2cfc7148493da5e73981bffbf3353af381d5f93e789c82c79aff64962eb556",
        )
        self.assertEqual(
            codeql.GITHUB_CLI_PINS["macos-arm64"].sha256,
            "f23a0c37d963aacc3bed703ccbd59b41c5ca22101fab7f00eb2b7cad23aba463",
        )
        self.assertEqual(
            codeql.GITHUB_CLI_PINS["macos-amd64"].sha256,
            "4bd449df9ad639391bc62b8032546f0fe9edcd8526e06682a4f88abd8c5d163c",
        )
        self.assertEqual(
            codeql.GITHUB_CLI_PINS["linux-amd64"].sha256,
            "83d5c2ccad5498f58bf6368acb1ab32588cf43ab3a4b1c301bf36328b1c8bd60",
        )
        workflow = (MODULE_PATH.parents[2] / ".github/workflows/codeql.yml").read_text(
            encoding="utf-8"
        )
        self.assertIn(f"codeql-bundle-v{codeql.CODEQL_VERSION}", workflow)
        self.assertIn(codeql.BUNDLE_PINS["linux64"].url, workflow)
        self.assertIn("cache: false", workflow)
        self.assertIn('CGO_ENABLED: "0"', workflow)
        self.assertIn("GOARCH: amd64", workflow)
        self.assertIn("GOOS: linux", workflow)
        self.assertIn("GOTOOLCHAIN: local", workflow)
        self.assertIn("GOMODCACHE: ${{ runner.temp }}/codeql-go-module-cache", workflow)
        self.assertIn("GOCACHE: ${{ runner.temp }}/codeql-go-build-cache", workflow)
        go_module = (
            MODULE_PATH.parents[1] / "compose-normalizer/go.mod"
        ).read_text(encoding="utf-8")
        self.assertIn("\ngo 1.26.3\n", go_module)
        makefile = (MODULE_PATH.parents[2] / "Makefile").read_text(encoding="utf-8")
        self.assertNotIn("CODEQL_PATH", makefile)
        codeql_targets = makefile[
            makefile.index("codeql-local:") : makefile.index("cli-smoke:")
        ]
        self.assertEqual(
            codeql_targets.count("/usr/bin/python3 -I Tools/ci/codeql-local.py"),
            3,
        )
        self.assertEqual(codeql_targets.count("--make-environment"), 3)
        self.assertNotIn("$(PYTHON) Tools/ci/codeql-local.py", codeql_targets)
        self.assertNotIn("$(CODEQL_", codeql_targets)
        self.assertIn(
            "CODEQL_UPLOAD_REPOSITORY ?= stephenlclarke/container-compose",
            makefile,
        )
        self.assertIn(
            "MARKDOWN_FILES = $(shell /usr/bin/git ls-files '*.md')",
            makefile,
        )
        self.assertEqual(
            MODULE_PATH.read_text(encoding="utf-8").splitlines()[0],
            "#!/usr/bin/python3 -I",
        )
        self.assertEqual(
            MAKE_ENTRY_PATH.read_text(encoding="utf-8").splitlines()[0],
            "#!/usr/bin/python3 -I",
        )
        process_entry = PROCESS_ENTRY_PATH.read_text(encoding="utf-8")
        self.assertIn("container_compose_codeql() (", process_entry)
        self.assertIn("POSIXLY_CORRECT=1", process_entry)
        self.assertIn("\\trap - DEBUG RETURN ERR", process_entry)
        self.assertIn("\\set +x +T +E", process_entry)
        self.assertIn("\\unset -f builtin compgen printf read trap", process_entry)
        self.assertIn(
            "for codeql_name in $(\\builtin compgen -A function)",
            process_entry,
        )
        self.assertNotIn("< <(\\builtin compgen", process_entry)
        self.assertIn('dis_functions=("${(@kv)functions}")', process_entry)
        self.assertIn('functions[(I)TRAP*]', process_entry)
        self.assertIn("for codeql_name in $(\\builtin compgen -e)", process_entry)
        self.assertIn("parameters[(R)*export*]", process_entry)
        self.assertIn("\\builtin exec /usr/bin/python3", process_entry)
        self.assertIn("unsafe traced caller", process_entry)
        self.assertIn("unsafe trap-bearing caller", process_entry)
        self.assertIn("unsafe credential-bearing caller", process_entry)
        self.assertNotIn("\\builtin export GITHUB_TOKEN", process_entry)
        self.assertNotIn("\\builtin export GH_TOKEN", process_entry)
        self.assertNotIn("\\builtin export TMPDIR", process_entry)
        self.assertNotIn("\\builtin export TMP", process_entry)
        self.assertNotIn("\\builtin export TEMP", process_entry)
        self.assertNotIn("/usr/bin/env", process_entry)
        self.assertIn("/usr/bin/python3 -I Tools/ci/codeql-make.py", process_entry)
        local_workflow = MODULE_PATH.read_text(encoding="utf-8")
        self.assertIn('build_environment["GOCACHE"]', local_workflow)
        self.assertIn('build_environment["GOMODCACHE"]', local_workflow)
        self.assertIn("container-compose-codeql-go-cache-", local_workflow)

        repository_root = MODULE_PATH.parents[2]
        documentation_paths = (
            *repository_root.glob("*.md"),
            *(repository_root / "docs").rglob("*.md"),
            *(repository_root / ".github").rglob("*.md"),
        )
        for documentation in documentation_paths:
            text = documentation.read_text(encoding="utf-8")
            self.assertNotIn(
                "/usr/bin/python3 -I Tools/ci/codeql-make.py codeql-",
                text,
                str(documentation.relative_to(repository_root)),
            )
        build_documentation = (repository_root / "docs/guides/BUILD.md").read_text(
            encoding="utf-8"
        )
        contributing = (repository_root / "docs/CONTRIBUTING.md").read_text(
            encoding="utf-8"
        )
        for documentation in (build_documentation, contributing):
            self.assertIn("Tools/ci/codeql-entry.sh", documentation)
            self.assertIn("container_compose_codeql codeql-local", documentation)

    def test_controlled_environment_drops_inherited_build_overrides(self) -> None:
        inherited = {
            "HOME": "/safe/home",
            "PATH": "/safe/bin",
            "MAKEFILES": "/tmp/injected.mk",
            "MAKEFLAGS": "--eval=all:; false",
            "MFLAGS": "-e",
            "BASH_ENV": "/tmp/injected.sh",
            "GO": "/tmp/custom-go",
            "GO_RELEASE_ENV": "CGO_ENABLED=1",
            "GO_RELEASE_BUILD_FLAGS": "-tags=custom",
            "GO_RELEASE_LDFLAGS": "-X main.injected=true",
            "GOEXPERIMENT": "arenas",
            "GOCACHE": "/tmp/shared-go-build-cache",
            "GOMODCACHE": "/tmp/shared-go-module-cache",
            "GOROOT": "/tmp/custom-go-root",
        }
        with mock.patch.dict(codeql.os.environ, inherited, clear=True):
            environment = codeql.controlled_environment(
                codeql.CODEQL_BUILD_ENVIRONMENT
            )

        self.assertEqual(
            environment["HOME"],
            codeql.pwd.getpwuid(codeql.os.getuid()).pw_dir,
        )
        self.assertNotEqual(environment["HOME"], "/safe/home")
        self.assertEqual(environment["PATH"], codeql.CODEQL_FIXED_PATH)
        self.assertEqual(
            {key: environment[key] for key in codeql.CODEQL_BUILD_ENVIRONMENT},
            codeql.CODEQL_BUILD_ENVIRONMENT,
        )
        for rejected in (
            "MAKEFILES",
            "MAKEFLAGS",
            "MFLAGS",
            "BASH_ENV",
            "GO",
            "GO_RELEASE_ENV",
            "GO_RELEASE_BUILD_FLAGS",
            "GO_RELEASE_LDFLAGS",
            "GOEXPERIMENT",
            "GOCACHE",
            "GOMODCACHE",
            "GOROOT",
        ):
            self.assertNotIn(rejected, environment)

    def test_github_credential_environment_drops_proxy_tls_and_temp_controls(self) -> None:
        inherited = {
            "TMPDIR": "/tmp/attacker-parent",
            "TMP": "/tmp/attacker-parent",
            "TEMP": "/tmp/attacker-parent",
            "LANG": "en_GB.UTF-8",
            "SSL_CERT_FILE": "/tmp/attacker-ca.pem",
            "SSL_CERT_DIR": "/tmp/attacker-ca-directory",
            "HTTP_PROXY": "http://attacker.invalid:8080",
            "HTTPS_PROXY": "http://attacker.invalid:8080",
            "NO_PROXY": "api.github.com",
            "http_proxy": "http://attacker.invalid:8080",
            "https_proxy": "http://attacker.invalid:8080",
            "no_proxy": "api.github.com",
        }
        with mock.patch.dict(codeql.os.environ, inherited, clear=True):
            environment = codeql.github_cli_environment("selected-token")

        self.assertEqual(environment["GITHUB_TOKEN"], "selected-token")
        self.assertEqual(environment["TMPDIR"], str(codeql.TRUSTED_TEMPORARY_ROOT))
        self.assertNotIn("TMP", environment)
        self.assertNotIn("TEMP", environment)
        self.assertEqual(environment["LANG"], "en_GB.UTF-8")
        self.assertEqual(
            environment["HOME"],
            codeql.pwd.getpwuid(codeql.os.getuid()).pw_dir,
        )
        self.assertEqual(environment["PATH"], codeql.CODEQL_FIXED_PATH)
        for rejected in codeql.CODEQL_NETWORK_PASSTHROUGH_ENVIRONMENT:
            self.assertNotIn(rejected, environment)

    def test_trusted_temporary_root_rejects_replaceable_parent(self) -> None:
        original_tempdir = codeql.tempfile.tempdir
        try:
            with tempfile.TemporaryDirectory() as directory:
                replaceable = Path(directory) / "replaceable"
                replaceable.mkdir(mode=0o777)
                replaceable.chmod(0o777)
                with mock.patch.object(
                    codeql,
                    "TRUSTED_TEMPORARY_ROOT",
                    replaceable,
                ):
                    with self.assertRaisesRegex(
                        codeql.CodeQLError,
                        "trusted temporary root",
                    ):
                        codeql.trusted_temporary_root()
                with self.assertRaisesRegex(
                    codeql.CodeQLError,
                    "CodeQL artifact root ancestor is writable",
                ):
                    codeql.require_nonreplaceable_directory(
                        replaceable,
                        "CodeQL artifact root",
                    )

            with mock.patch.dict(
                codeql.os.environ,
                {
                    "TMPDIR": "/tmp/attacker-parent",
                    "TMP": "/tmp/attacker-parent",
                    "TEMP": "/tmp/attacker-parent",
                },
                clear=True,
            ):
                environment = codeql.controlled_environment(
                    {
                        "TMPDIR": "/tmp/attacker-override",
                        "TMP": "/tmp/attacker-override",
                        "TEMP": "/tmp/attacker-override",
                    }
                )
                with codeql.tempfile.TemporaryDirectory(
                    prefix="codeql-trusted-root-test-"
                ) as trusted_directory:
                    self.assertEqual(
                        Path(trusted_directory).parent,
                        codeql.TRUSTED_TEMPORARY_ROOT,
                    )
            self.assertEqual(
                environment["TMPDIR"],
                str(codeql.TRUSTED_TEMPORARY_ROOT),
            )
            self.assertNotIn("TMP", environment)
            self.assertNotIn("TEMP", environment)
        finally:
            codeql.tempfile.tempdir = original_tempdir

    def test_make_entry_requires_empty_process_boundary_and_allowlists_data(self) -> None:
        direct = subprocess.run(
            [
                "/usr/bin/python3",
                "-I",
                str(MAKE_ENTRY_PATH),
                "codeql-local",
            ],
            cwd=MODULE_PATH.parents[2],
            env={"PATH": "/usr/bin:/bin"},
            check=False,
            capture_output=True,
            text=True,
        )
        self.assertEqual(direct.returncode, 2)
        self.assertIn("unsafe direct invocation", direct.stderr)

        inherited = {
            codeql_make.PROCESS_ENTRY: "1",
            "CODEQL_CACHE_ROOT": "/reviewed/cache",
            "CODEQL_UPLOAD_REF": "refs/heads/reviewed",
            "GITHUB_TOKEN": "secret",
            "TMPDIR": "/tmp/attacker-parent",
            "TMP": "/tmp/attacker-parent",
            "TEMP": "/tmp/attacker-parent",
            "MAKEFILES": "/tmp/injected.mk",
            "PYTHONPATH": "/tmp/injected-python",
            "LD_PRELOAD": "",
            "DYLD_INSERT_LIBRARIES": "",
        }
        with mock.patch.dict(codeql_make.os.environ, inherited, clear=True):
            local_environment = codeql_make.clean_environment("codeql-local")
            upload_environment = codeql_make.clean_environment(
                "codeql-sarif-upload"
            )

        self.assertEqual(local_environment["CODEQL_CACHE_ROOT"], "/reviewed/cache")
        self.assertNotIn("CODEQL_UPLOAD_REF", local_environment)
        self.assertNotIn("GITHUB_TOKEN", local_environment)
        self.assertEqual(upload_environment["CODEQL_UPLOAD_REF"], "refs/heads/reviewed")
        self.assertNotIn("GITHUB_TOKEN", upload_environment)
        for rejected in (
            codeql_make.PROCESS_ENTRY,
            "MAKEFILES",
            "PYTHONPATH",
            "TMPDIR",
            "TMP",
            "TEMP",
            "LD_PRELOAD",
            "DYLD_INSERT_LIBRARIES",
        ):
            self.assertNotIn(rejected, local_environment)
            self.assertNotIn(rejected, upload_environment)

        with mock.patch.dict(
            codeql_make.os.environ,
            {
                "LD_AUDIT": "/tmp/audit.so",
                "DYLD_LIBRARY_PATH": "/tmp/libraries",
                "__XPC_DYLD_INSERT_LIBRARIES": "/tmp/xpc.dylib",
            },
            clear=True,
        ):
            self.assertEqual(
                codeql_make.native_loader_environment(),
                [
                    "DYLD_LIBRARY_PATH",
                    "LD_AUDIT",
                    "__XPC_DYLD_INSERT_LIBRARIES",
                ],
            )

    def test_shell_entry_blocks_native_loader_injection(self) -> None:
        if sys.platform not in {"darwin", "linux"}:
            self.skipTest("native-loader regression supports Darwin and Linux")
        compiler = Path("/usr/bin/cc")
        if not compiler.is_file():
            self.skipTest("/usr/bin/cc is unavailable")

        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            marker = root / "native-loader-ran"
            source = root / "injected.c"
            source.write_text(
                "#include <stdio.h>\n"
                "#include <stdlib.h>\n"
                "__attribute__((constructor)) static void injected(void) {\n"
                f"  FILE *output = fopen({json.dumps(str(marker))}, \"w\");\n"
                "  if (output == NULL) return;\n"
                "  const char *token = getenv(\"GITHUB_TOKEN\");\n"
                "  fputs(token == NULL ? \"<missing>\" : token, output);\n"
                "  fclose(output);\n"
                "}\n"
                "int main(void) { return 0; }\n",
                encoding="utf-8",
            )
            if sys.platform == "darwin":
                library = root / "injected.dylib"
                compile_arguments = [
                    str(compiler),
                    "-dynamiclib",
                    "-o",
                    str(library),
                    str(source),
                ]
                loader_name = "DYLD_INSERT_LIBRARIES"
                extra_assignment = "DYLD_FORCE_FLAT_NAMESPACE=1 "
            else:
                library = root / "injected.so"
                compile_arguments = [
                    str(compiler),
                    "-shared",
                    "-fPIC",
                    "-o",
                    str(library),
                    str(source),
                ]
                loader_name = "LD_PRELOAD"
                extra_assignment = ""
            subprocess.run(
                compile_arguments,
                check=True,
                capture_output=True,
                text=True,
            )
            probe = root / "native-loader-probe"
            subprocess.run(
                [str(compiler), "-o", str(probe), str(source)],
                check=True,
                capture_output=True,
                text=True,
            )

            clean_shell_environment = {
                "HOME": os.environ.get("HOME", "/tmp"),
                "PATH": "/usr/bin:/bin",
            }
            injected_environment = clean_shell_environment.copy()
            injected_environment.update(
                {
                    loader_name: str(library),
                    "GITHUB_TOKEN": "sentinel-token",
                }
            )
            if sys.platform == "darwin":
                injected_environment["DYLD_FORCE_FLAT_NAMESPACE"] = "1"
                direct_arguments = [str(probe)]
            else:
                direct_arguments = ["/usr/bin/python3", "-I", "-c", "pass"]
            direct = subprocess.run(
                direct_arguments,
                env=injected_environment,
                check=False,
                capture_output=True,
                text=True,
            )
            self.assertEqual(direct.returncode, 0, direct.stderr)
            self.assertEqual(marker.read_text(encoding="utf-8"), "sentinel-token")
            marker.unlink()

            shells = [Path("/bin/bash")]
            if Path("/bin/zsh").is_file():
                shells.append(Path("/bin/zsh"))
            for shell in shells:
                traced_command = (
                    '. "$1"\n'
                    "PS4='TRACE $(/usr/bin/printenv GITHUB_TOKEN 2>/dev/null || /usr/bin/printf \"<missing>\") '\n"
                    '[[ -z "${ZSH_VERSION-}" ]] || setopt PROMPT_SUBST\n'
                    "set -x\n"
                    "CODEQL_UPLOAD_REF=invalid "
                    f"CODEQL_UPLOAD_COMMIT={COMMIT} "
                    "container_compose_codeql codeql-sarif-upload"
                )
                shell_prefix = [str(shell)]
                if shell.name == "zsh":
                    shell_prefix.append("-f")
                traced = subprocess.run(
                    [
                        *shell_prefix,
                        "-c",
                        traced_command,
                        "codeql-entry-test",
                        str(PROCESS_ENTRY_PATH),
                        str(library),
                    ],
                    cwd=MODULE_PATH.parents[2],
                    env=clean_shell_environment,
                    check=False,
                    capture_output=True,
                    text=True,
                )
                self.assertEqual(traced.returncode, 2)
                self.assertIn("unsafe traced caller", traced.stderr)
                self.assertIn("TRACE <missing>", traced.stderr)
                self.assertNotIn("sentinel-token", traced.stdout)
                self.assertNotIn("sentinel-token", traced.stderr)
                self.assertFalse(
                    marker.exists(),
                    f"{shell} continued from a traced caller",
                )

                trap_assignments = f'export {loader_name}="$2"'
                if extra_assignment:
                    trap_assignments += f"; export {extra_assignment.strip()}"
                if shell.name == "bash":
                    trap_setup = (
                        f"trap '{trap_assignments}' DEBUG\n"
                        "set -ET\n"
                    )
                else:
                    trap_setup = f"TRAPDEBUG() {{ {trap_assignments}; }}\n"
                trapped_command = (
                    '. "$1"\n'
                    + trap_setup
                    + "CODEQL_UPLOAD_REF=invalid "
                    + f"CODEQL_UPLOAD_COMMIT={COMMIT} "
                    + "container_compose_codeql codeql-sarif-upload"
                )
                trapped = subprocess.run(
                    [
                        *shell_prefix,
                        "-c",
                        trapped_command,
                        "codeql-entry-test",
                        str(PROCESS_ENTRY_PATH),
                        str(library),
                    ],
                    cwd=MODULE_PATH.parents[2],
                    env=clean_shell_environment,
                    check=False,
                    capture_output=True,
                    text=True,
                )
                self.assertEqual(trapped.returncode, 2)
                self.assertIn("unsafe trap-bearing caller", trapped.stderr)
                self.assertFalse(
                    marker.exists(),
                    f"{shell} allowed an inherited trap across the boundary",
                )
                self.assertNotIn("sentinel-token", trapped.stdout)
                self.assertNotIn("sentinel-token", trapped.stderr)

                clean_command = (
                    '. "$1"\n'
                    f'{loader_name}="$2" {extra_assignment}'
                    "CODEQL_UPLOAD_REF=invalid "
                    f"CODEQL_UPLOAD_COMMIT={COMMIT} "
                    "container_compose_codeql codeql-sarif-upload"
                )
                protected = subprocess.run(
                    [
                        *shell_prefix,
                        "-c",
                        clean_command,
                        "codeql-entry-test",
                        str(PROCESS_ENTRY_PATH),
                        str(library),
                    ],
                    cwd=MODULE_PATH.parents[2],
                    env=clean_shell_environment,
                    check=False,
                    capture_output=True,
                    text=True,
                )
                self.assertNotEqual(protected.returncode, 0)
                self.assertIn(
                    "CodeQL upload ref must be a full heads, tags, or pull ref",
                    protected.stderr,
                )
                self.assertFalse(
                    marker.exists(),
                    f"{shell} loaded the injected library before the boundary",
                )
                self.assertNotIn("sentinel-token", protected.stdout)
                self.assertNotIn("sentinel-token", protected.stderr)
                self.assertNotIn("No such file or directory", protected.stderr)

    def test_shell_entry_rejects_a_credential_bearing_caller(self) -> None:
        for shell in (Path("/bin/bash"), Path("/bin/zsh")):
            if not shell.is_file():
                continue
            shell_arguments = [str(shell)]
            if shell.name == "zsh":
                shell_arguments.append("-f")
            shell_arguments.extend(
                [
                    "-c",
                    '. "$1"\ncontainer_compose_codeql codeql-sarif-upload',
                    "codeql-credential-entry-test",
                    str(PROCESS_ENTRY_PATH),
                ]
            )
            protected = subprocess.run(
                shell_arguments,
                cwd=MODULE_PATH.parents[2],
                env={
                    "HOME": os.environ.get("HOME", "/tmp"),
                    "PATH": "/usr/bin:/bin",
                    "GITHUB_TOKEN": "forbidden-entry-token",
                },
                check=False,
                capture_output=True,
                text=True,
            )
            self.assertEqual(protected.returncode, 2)
            self.assertIn("unsafe credential-bearing caller", protected.stderr)

    def test_shell_entry_disables_inherited_command_functions(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            marker = Path(directory) / "inherited-function-ran"
            replaceable = Path(directory) / "replaceable-temporary-root"
            replaceable.mkdir(mode=0o777)
            replaceable.chmod(0o777)
            shells = [Path("/bin/bash")]
            if Path("/bin/zsh").is_file():
                shells.append(Path("/bin/zsh"))

            for shell in shells:
                command = (
                    'set(){ > "$HOSTILE_FUNCTION_MARKER"; }\n'
                    'unset(){ > "$HOSTILE_FUNCTION_MARKER"; }\n'
                    'compgen(){ > "$HOSTILE_FUNCTION_MARKER"; }\n'
                    'read(){ > "$HOSTILE_FUNCTION_MARKER"; }\n'
                    'printf(){ > "$HOSTILE_FUNCTION_MARKER"; }\n'
                    'export(){ > "$HOSTILE_FUNCTION_MARKER"; }\n'
                    'typeset(){ > "$HOSTILE_FUNCTION_MARKER"; }\n'
                    'builtin(){ > "$HOSTILE_FUNCTION_MARKER"; }\n'
                    'trap(){ > "$HOSTILE_FUNCTION_MARKER"; }\n'
                    'exec(){ > "$HOSTILE_FUNCTION_MARKER"; }\n'
                    '. "$1"\n'
                    'container_compose_codeql codeql-sarif-upload\n'
                )
                environment = {
                    "HOME": os.environ.get("HOME", "/tmp"),
                    "PATH": "/usr/bin:/bin",
                    "HOSTILE_FUNCTION_MARKER": str(marker),
                    "TMPDIR": str(replaceable),
                    "TMP": str(replaceable),
                    "TEMP": str(replaceable),
                    "CODEQL_UPLOAD_REF": "invalid",
                    "CODEQL_UPLOAD_COMMIT": COMMIT,
                }
                shell_arguments = [str(shell)]
                if shell.name == "zsh":
                    shell_arguments.append("-f")
                shell_arguments.extend(
                    [
                        "-c",
                        command,
                        "codeql-function-entry-test",
                        str(PROCESS_ENTRY_PATH),
                    ]
                )
                protected = subprocess.run(
                    shell_arguments,
                    cwd=MODULE_PATH.parents[2],
                    env=environment,
                    check=False,
                    capture_output=True,
                    text=True,
                )
                self.assertNotEqual(protected.returncode, 0)
                self.assertIn(
                    "CodeQL upload ref must be a full heads, tags, or pull ref",
                    protected.stderr,
                )
                self.assertFalse(
                    marker.exists(),
                    f"{shell} resolved an inherited function before the scrub",
                )
                self.assertNotIn("sentinel-token", protected.stdout)
                self.assertNotIn("sentinel-token", protected.stderr)
                self.assertNotIn("No such file or directory", protected.stderr)

    def test_raw_worktree_check_ignores_executable_git_configuration(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            repository = root / "repository"
            fake_home = root / "home"
            fake_home.mkdir()
            global_marker = root / "global-monitor-ran"
            local_marker = root / "local-monitor-ran"
            filter_marker = root / "clean-filter-ran"

            def write_monitor(path: Path, marker: Path) -> None:
                path.write_text(
                    "#!/bin/sh\n"
                    f"printf '%s\\n' monitor >> {shlex.quote(str(marker))}\n"
                    "printf '\\n'\n",
                    encoding="utf-8",
                )
                path.chmod(0o755)

            global_monitor = root / "global-monitor"
            local_monitor = root / "local-monitor"
            clean_filter = root / "clean-filter"
            write_monitor(global_monitor, global_marker)
            write_monitor(local_monitor, local_marker)
            write_monitor(clean_filter, filter_marker)
            (fake_home / ".gitconfig").write_text(
                "[core]\n"
                f"\tfsmonitor = {global_monitor}\n",
                encoding="utf-8",
            )

            subprocess.run(
                ["/usr/bin/git", "init", "--initial-branch=main", str(repository)],
                check=True,
                capture_output=True,
                text=True,
            )
            (repository / "tracked.txt").write_text("tracked\n", encoding="utf-8")
            for arguments in (
                ("config", "user.name", "Test"),
                ("config", "user.email", "test@example.com"),
                ("config", "commit.gpgSign", "false"),
                ("add", "tracked.txt"),
                ("commit", "-m", "test: fixture"),
                ("config", "core.fsmonitor", str(local_monitor)),
                ("config", "filter.attack.clean", str(clean_filter)),
                ("config", "filter.attack.required", "true"),
            ):
                subprocess.run(
                    ["/usr/bin/git", "-C", str(repository), *arguments],
                    check=True,
                    capture_output=True,
                    text=True,
                )
            (repository / ".git/info/attributes").write_text(
                "tracked.txt filter=attack\n",
                encoding="utf-8",
            )
            original_commit = subprocess.run(
                ["/usr/bin/git", "-C", str(repository), "rev-parse", "HEAD"],
                check=True,
                capture_output=True,
                text=True,
            ).stdout.strip()
            (repository / "tracked.txt").write_text("replacement\n", encoding="utf-8")
            subprocess.run(
                ["/usr/bin/git", "-C", str(repository), "add", "tracked.txt"],
                check=True,
                capture_output=True,
                text=True,
            )
            replacement_tree = subprocess.run(
                ["/usr/bin/git", "-C", str(repository), "write-tree"],
                check=True,
                capture_output=True,
                text=True,
            ).stdout.strip()
            replacement_commit = subprocess.run(
                [
                    "/usr/bin/git",
                    "-C",
                    str(repository),
                    "commit-tree",
                    replacement_tree,
                    "-p",
                    original_commit,
                    "-m",
                    "test: replacement",
                ],
                check=True,
                capture_output=True,
                text=True,
            ).stdout.strip()
            subprocess.run(
                ["/usr/bin/git", "-C", str(repository), "read-tree", original_commit],
                check=True,
                capture_output=True,
                text=True,
            )
            (repository / "tracked.txt").write_text("tracked\n", encoding="utf-8")
            subprocess.run(
                [
                    "/usr/bin/git",
                    "-C",
                    str(repository),
                    "replace",
                    original_commit,
                    replacement_commit,
                ],
                check=True,
                capture_output=True,
                text=True,
            )
            filter_marker.unlink(missing_ok=True)
            local_marker.unlink(missing_ok=True)
            os.utime(repository / "tracked.txt", None)

            account = mock.Mock(pw_dir=str(fake_home))
            with mock.patch.object(codeql.pwd, "getpwuid", return_value=account):
                codeql.require_clean_worktree(repository)

            self.assertFalse(global_marker.exists())
            self.assertFalse(local_marker.exists())
            self.assertFalse(filter_marker.exists())

            (repository / "tracked.txt").write_text("changed\n", encoding="utf-8")
            with self.assertRaisesRegex(codeql.CodeQLError, "worktree differs"):
                codeql.require_clean_worktree(repository)
            self.assertFalse(filter_marker.exists())

    def test_make_targets_do_not_execute_or_reparse_caller_inputs(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            wrappers = Path(directory) / "wrappers"
            wrappers.mkdir()
            marker = Path(directory) / "caller-code-ran"
            for name in ("git", "python3", "swift"):
                wrapper = wrappers / name
                wrapper.write_text(
                    "#!/bin/sh\n"
                    f"printf '%s\\n' {shlex.quote(name)} >> "
                    f"{shlex.quote(str(marker))}\n"
                    "exit 99\n",
                    encoding="utf-8",
                )
                wrapper.chmod(0o755)
            bash_environment = Path(directory) / "bash-environment"
            bash_environment.write_text(
                f"printf '%s\\n' BASH_ENV >> {shlex.quote(str(marker))}\n",
                encoding="utf-8",
            )
            (wrappers / "sitecustomize.py").write_text(
                "from pathlib import Path\n"
                f"Path({str(marker)!r}).write_text('PYTHONPATH\\n', encoding='utf-8')\n",
                encoding="utf-8",
            )
            environment = os.environ.copy()
            environment["PATH"] = f"{wrappers}:{environment.get('PATH', '')}"
            environment["BASH_ENV"] = str(bash_environment)
            result = subprocess.run(
                [
                    "/usr/bin/make",
                    "--dry-run",
                    "codeql-local",
                    f"PYTHON={wrappers / 'python3'}",
                    f"SWIFT={wrappers / 'swift'}",
                ],
                cwd=MODULE_PATH.parents[2],
                env=environment,
                check=True,
                capture_output=True,
                text=True,
            )

            self.assertIn(
                "/usr/bin/python3 -I Tools/ci/codeql-local.py", result.stdout
            )
            self.assertIn("--make-environment", result.stdout)
            self.assertNotIn(str(wrappers), result.stdout)

            injection = f'hostile";>{marker};#'
            make_injection = f"$(shell /usr/bin/touch {marker})"
            upload_arguments = [
                f"CODEQL_CACHE_ROOT={make_injection}",
                f"CODEQL_ARTIFACT_ROOT={injection}",
                f"CODEQL_UPLOAD_REPOSITORY={injection}",
                f"CODEQL_UPLOAD_REF=refs/heads/{injection}",
                f"CODEQL_UPLOAD_COMMIT={COMMIT}",
            ]
            rendered_upload = subprocess.run(
                [
                    "/usr/bin/make",
                    "--dry-run",
                    "codeql-sarif-upload-dry-run",
                    *upload_arguments,
                ],
                cwd=MODULE_PATH.parents[2],
                env=environment,
                check=True,
                capture_output=True,
                text=True,
            )
            self.assertIn("--make-environment", rendered_upload.stdout)
            self.assertNotIn(injection, rendered_upload.stdout)
            self.assertNotIn(make_injection, rendered_upload.stdout)

            injected_makefile = Path(directory) / "injected.mk"
            injected_makefile.write_text(
                f"$(shell /usr/bin/touch {marker})\n",
                encoding="utf-8",
            )
            entry_environment = environment.copy()
            entry_environment.update(
                {
                    "MAKEFILES": str(injected_makefile),
                    "MAKEFLAGS": f"--eval=$(shell /usr/bin/touch {marker})",
                    "GNUMAKEFLAGS": f"--eval=$(shell /usr/bin/touch {marker})",
                    "PYTHONPATH": str(wrappers),
                    "CODEQL_CACHE_ROOT": make_injection,
                    "CODEQL_ARTIFACT_ROOT": injection,
                    "CODEQL_UPLOAD_REPOSITORY": injection,
                    "CODEQL_UPLOAD_REF": f"refs/heads/{injection}",
                    "CODEQL_UPLOAD_COMMIT": COMMIT,
                }
            )
            clean_shell_environment = {
                "HOME": environment.get("HOME", os.environ.get("HOME", "/tmp")),
                "PATH": "/usr/bin:/bin",
            }
            entry_command = "\n".join(
                [
                    f". {shlex.quote(str(PROCESS_ENTRY_PATH))}",
                    f"export PATH={shlex.quote(entry_environment['PATH'])}",
                    f"export BASH_ENV={shlex.quote(entry_environment['BASH_ENV'])}",
                    f"export MAKEFILES={shlex.quote(entry_environment['MAKEFILES'])}",
                    f"export MAKEFLAGS={shlex.quote(entry_environment['MAKEFLAGS'])}",
                    f"export GNUMAKEFLAGS={shlex.quote(entry_environment['GNUMAKEFLAGS'])}",
                    f"export PYTHONPATH={shlex.quote(entry_environment['PYTHONPATH'])}",
                    f"export CODEQL_CACHE_ROOT={shlex.quote(entry_environment['CODEQL_CACHE_ROOT'])}",
                    f"export CODEQL_ARTIFACT_ROOT={shlex.quote(entry_environment['CODEQL_ARTIFACT_ROOT'])}",
                    f"export CODEQL_UPLOAD_REPOSITORY={shlex.quote(entry_environment['CODEQL_UPLOAD_REPOSITORY'])}",
                    f"export CODEQL_UPLOAD_REF={shlex.quote(entry_environment['CODEQL_UPLOAD_REF'])}",
                    f"export CODEQL_UPLOAD_COMMIT={shlex.quote(entry_environment['CODEQL_UPLOAD_COMMIT'])}",
                    "container_compose_codeql codeql-sarif-upload-dry-run",
                ]
            )
            rejected_upload = subprocess.run(
                ["/bin/bash", "-c", entry_command],
                cwd=MODULE_PATH.parents[2],
                env=clean_shell_environment,
                check=False,
                capture_output=True,
                text=True,
            )
            self.assertNotEqual(rejected_upload.returncode, 0)
            self.assertIn(
                "CodeQL upload ref must be a full heads, tags, or pull ref",
                rejected_upload.stderr,
            )
            self.assertFalse(
                marker.exists(),
                marker.read_text(encoding="utf-8") if marker.exists() else "",
            )

    def test_normal_make_preserves_recursive_flags_and_custom_swift_flags(self) -> None:
        repository_root = MODULE_PATH.parents[2]
        with tempfile.TemporaryDirectory() as directory:
            marker = Path(directory) / "go-wrapper-ran"
            go_wrapper = Path(directory) / "go"
            go_wrapper.write_text(
                "#!/bin/sh\n"
                f"/usr/bin/touch {shlex.quote(str(marker))}\n"
                "exit 99\n",
                encoding="utf-8",
            )
            go_wrapper.chmod(0o755)
            environment = os.environ.copy()
            for name in (
                "BASH_ENV",
                "ENV",
                "GNUMAKEFLAGS",
                "MAKEFILES",
                "MAKEFLAGS",
                "MFLAGS",
            ):
                environment.pop(name, None)
            environment["GO"] = str(go_wrapper)

            recursive_dry_run = subprocess.run(
                ["/usr/bin/make", "--dry-run", "go-build"],
                cwd=repository_root,
                env=environment,
                check=False,
                capture_output=True,
                text=True,
            )

            self.assertEqual(
                recursive_dry_run.returncode,
                0,
                recursive_dry_run.stdout + recursive_dry_run.stderr,
            )
            self.assertIn(str(go_wrapper), recursive_dry_run.stdout)
            self.assertFalse(marker.exists(), "recursive dry-run executed the Go wrapper")

            environment.update(
                {
                    "SWIFT_TEST_FLAGS": "-Xswiftc CUSTOM",
                    "SWIFT_TEST_FRAMEWORK_SEARCH_PATH": "/reviewed/frameworks",
                    "SWIFT_TEST_RUNTIME_LIBRARY_PATH": "/reviewed/runtime",
                }
            )
            swift_dry_run = subprocess.run(
                ["/usr/bin/make", "--dry-run", "swift-test-build"],
                cwd=repository_root,
                env=environment,
                check=True,
                capture_output=True,
                text=True,
            )

            self.assertIn("-Xswiftc CUSTOM", swift_dry_run.stdout)
            self.assertIn(
                "-Xswiftc -F -Xswiftc '/reviewed/frameworks'",
                swift_dry_run.stdout,
            )
            self.assertIn(
                "-Xlinker -rpath -Xlinker '/reviewed/runtime'",
                swift_dry_run.stdout,
            )

    def test_build_tools_use_fixed_absolute_paths_and_exact_go(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            make_root = root / "trusted-make"
            goroot = root / "go1.26.3"
            make = make_root / "make"
            go = goroot / "bin" / "go"
            make.parent.mkdir(parents=True)
            go.parent.mkdir(parents=True)
            make.write_text(
                "#!/bin/sh\nprintf '%s\\n' 'GNU Make 4.4.1'\n",
                encoding="utf-8",
            )
            go.write_text(
                "#!/bin/sh\nprintf '%s\\n' 'go version go1.26.3 test/arch'\n",
                encoding="utf-8",
            )
            make.chmod(0o755)
            go.chmod(0o755)
            go_pin = codeql.GO_TOOLCHAIN_PINS["darwin-arm64"]

            with (
                mock.patch.object(codeql, "TRUSTED_MAKE_CANDIDATES", (make,)),
                mock.patch.object(codeql, "TRUSTED_MAKE_ROOTS", (make_root,)),
                mock.patch.object(
                    codeql,
                    "ensure_go_toolchain",
                    return_value=(go.resolve(), "darwin-arm64", go_pin),
                ),
                mock.patch.dict(
                    codeql.os.environ,
                    {"PATH": str(root / "caller-wrappers")},
                    clear=True,
                ),
            ):
                command, build_path, tools = codeql.resolve_build_tools(
                    "osx64", root / "cache", root / "private-tools"
                )

            self.assertEqual(
                command,
                codeql.exact_build_command(make.resolve()),
            )
            self.assertEqual(build_path, codeql.exact_build_path(go.resolve()))
            self.assertEqual(tools["make"]["path"], str(make.resolve()))
            self.assertEqual(tools["go"]["path"], str(go.resolve()))
            self.assertEqual(tools["go"]["version"], "go1.26.3")
            self.assertEqual(
                tools["go"]["archive"]["sha256"], go_pin.sha256
            )
            self.assertNotIn("caller-wrappers", command)
            self.assertNotIn("caller-wrappers", build_path)

    def test_source_and_bundle_tools_ignore_caller_path_wrappers(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            wrappers = root / "caller-wrappers"
            wrappers.mkdir()
            marker = root / "caller-wrapper-ran"
            for name in ("git", "tar", "curl"):
                wrapper = wrappers / name
                wrapper.write_text(
                    "#!/bin/sh\n"
                    f"printf '%s\\n' {shlex.quote(name)} >> {shlex.quote(str(marker))}\n"
                    "exit 99\n",
                    encoding="utf-8",
                )
                wrapper.chmod(0o755)

            bundle_source = root / "bundle-source" / "codeql"
            executable = bundle_source / "codeql"
            pack = (
                bundle_source
                / "qlpacks"
                / "codeql"
                / "go-queries"
                / codeql.CODEQL_QUERY_PACK_VERSION
                / "qlpack.yml"
            )
            executable.parent.mkdir(parents=True)
            pack.parent.mkdir(parents=True)
            executable.write_text(
                "#!/bin/sh\n"
                f"printf '%s\\n' '{{\"version\":\"{codeql.CODEQL_VERSION}\"}}'\n",
                encoding="utf-8",
            )
            executable.chmod(0o755)
            pack.write_text(
                "\n".join(
                    [
                        f"name: {codeql.CODEQL_QUERY_PACK}",
                        f"version: {codeql.CODEQL_QUERY_PACK_VERSION}",
                        "buildMetadata:",
                        f"  cliVersion: {codeql.CODEQL_VERSION}",
                        "",
                    ]
                ),
                encoding="utf-8",
            )
            cache_root = root / "cache"
            downloads = cache_root / "downloads"
            downloads.mkdir(parents=True)
            pin = codeql.BundlePin(
                name="test-bundle.tar.gz",
                sha256="",
                url="https://invalid.example/test-bundle.tar.gz",
            )
            archive = downloads / f"{codeql.CODEQL_VERSION}-{pin.name}"
            with tarfile.open(archive, "w:gz") as bundle:
                bundle.add(bundle_source, arcname="codeql")
            pin = codeql.BundlePin(
                name=pin.name,
                sha256=codeql.sha256_file(archive),
                url=pin.url,
            )
            go_source = root / "go-source" / "go"
            go_executable = go_source / "bin" / "go"
            go_executable.parent.mkdir(parents=True)
            go_executable.write_text(
                "#!/bin/sh\nprintf '%s\\n' 'go version go1.26.3 test/arch'\n",
                encoding="utf-8",
            )
            go_executable.chmod(0o755)
            go_pin = codeql.BundlePin(
                name="test-go.tar.gz",
                sha256="",
                url="https://invalid.example/test-go.tar.gz",
            )
            go_archive = downloads / f"{codeql.GO_TOOLCHAIN_VERSION}-{go_pin.name}"
            with tarfile.open(go_archive, "w:gz") as bundle:
                bundle.add(go_source, arcname="go")
            go_pin = codeql.BundlePin(
                name=go_pin.name,
                sha256=codeql.sha256_file(go_archive),
                url=go_pin.url,
            )
            repository_root = MODULE_PATH.parents[2]
            expected_head = subprocess.run(
                ["/usr/bin/git", "rev-parse", "HEAD"],
                cwd=repository_root,
                check=True,
                capture_output=True,
                text=True,
            ).stdout.strip()

            with (
                mock.patch.object(codeql, "selected_platform", return_value="osx64"),
                mock.patch.object(
                    codeql, "selected_go_platform", return_value="darwin-arm64"
                ),
                mock.patch.object(
                    codeql,
                    "TRUSTED_WORKFLOW_TOOL_CANDIDATES",
                    {
                        "osx64": {
                            "git": (Path("/usr/bin/git"),),
                            "archiveExtractor": (Path("/usr/bin/tar"),),
                            "downloader": (Path("/usr/bin/curl"),),
                        }
                    },
                ),
                mock.patch.object(
                    codeql,
                    "TRUSTED_WORKFLOW_TOOL_ROOTS",
                    {"osx64": (Path("/usr/bin"),)},
                ),
                mock.patch.object(codeql, "BUNDLE_PINS", {"osx64": pin}),
                mock.patch.object(
                    codeql, "GO_TOOLCHAIN_PINS", {"darwin-arm64": go_pin}
                ),
                mock.patch.dict(codeql.os.environ, {"PATH": str(wrappers)}, clear=True),
            ):
                paths, attestations = codeql.resolve_workflow_tools("osx64")
                actual_head = codeql.git_output(repository_root, "rev-parse", "HEAD")
                installed, host_platform, installed_pin = codeql.ensure_codeql(
                    cache_root,
                    root / "private-codeql",
                )
                go_installed, go_platform, installed_go_pin = (
                    codeql.ensure_go_toolchain(cache_root, root / "private-go")
                )
                codeql_digest = codeql.sha256_file(installed)
                go_digest = codeql.sha256_file(go_installed)
                archive.write_bytes(b"replaced cached CodeQL archive")
                go_archive.write_bytes(b"replaced cached Go archive")
                installed_version = codeql.command_output(
                    [str(installed), "version", "--format=json"],
                    env=codeql.controlled_environment(),
                )
                installed_go_version = codeql.command_output(
                    [str(go_installed), "version"],
                    env=codeql.controlled_environment(),
                )

            self.assertEqual(actual_head, expected_head)
            self.assertEqual(host_platform, "osx64")
            self.assertEqual(installed_pin, pin)
            self.assertTrue(installed.is_file())
            self.assertIn((root / "private-codeql").resolve(), installed.parents)
            self.assertEqual(codeql.sha256_file(installed), codeql_digest)
            self.assertEqual(
                json.loads(installed_version)["version"], codeql.CODEQL_VERSION
            )
            self.assertEqual(go_platform, "darwin-arm64")
            self.assertEqual(installed_go_pin, go_pin)
            self.assertTrue(go_installed.is_file())
            self.assertIn((root / "private-go").resolve(), go_installed.parents)
            self.assertEqual(codeql.sha256_file(go_installed), go_digest)
            self.assertEqual(
                installed_go_version,
                f"go version {codeql.GO_TOOLCHAIN_VERSION} test/arch",
            )
            self.assertEqual(paths["git"], Path("/usr/bin/git").resolve())
            self.assertEqual(
                paths["archiveExtractor"], Path("/usr/bin/tar").resolve()
            )
            self.assertEqual(attestations["git"]["path"], str(paths["git"]))
            self.assertFalse(marker.exists())

    def test_github_cli_ignores_caller_path_wrapper(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            wrappers = root / "caller-wrappers"
            wrappers.mkdir()
            wrapper = wrappers / "gh"
            marker = root / "caller-gh-ran"
            archive_name = f"gh_{codeql.GITHUB_CLI_VERSION}_macOS_arm64.zip"
            directory_name = archive_name.removesuffix(".zip")
            source = root / "source" / directory_name / "bin" / "gh"
            source.parent.mkdir(parents=True)
            source.write_text(
                "#!/bin/sh\nprintf '%s\\n' 'gh version 2.96.0 (test)'\n",
                encoding="utf-8",
            )
            wrapper.write_text(
                "#!/bin/sh\n"
                f"printf '%s\\n' wrapper > {shlex.quote(str(marker))}\n"
                "exit 99\n",
                encoding="utf-8",
            )
            source.chmod(0o755)
            wrapper.chmod(0o755)
            cache_root = root / "cache"
            downloads = cache_root / "downloads"
            downloads.mkdir(parents=True)
            archive = downloads / f"{codeql.GITHUB_CLI_VERSION}-{archive_name}"
            with zipfile.ZipFile(archive, "w", zipfile.ZIP_DEFLATED) as bundle:
                bundle.write(source, arcname=f"{directory_name}/bin/gh")
            pin = codeql.BundlePin(
                name=archive_name,
                sha256=codeql.sha256_file(archive),
                url="https://invalid.example/test-gh.zip",
            )

            with (
                mock.patch.object(
                    codeql,
                    "selected_github_cli_platform",
                    return_value="macos-arm64",
                ),
                mock.patch.object(
                    codeql, "GITHUB_CLI_PINS", {"macos-arm64": pin}
                ),
                mock.patch.dict(codeql.os.environ, {"PATH": str(wrappers)}, clear=True),
            ):
                executable, attestation = codeql.ensure_github_cli(
                    cache_root,
                    root / "private-gh",
                    "gh",
                )
                executable_digest = codeql.sha256_file(executable)
                archive.write_bytes(b"replaced cached GitHub CLI archive")
                version_output = codeql.command_output(
                    [str(executable), "--version"],
                    env=codeql.controlled_environment(),
                )
                with self.assertRaisesRegex(
                    codeql.CodeQLError,
                    "custom GitHub CLI executables are not supported",
                ):
                    codeql.ensure_github_cli(
                        cache_root,
                        root / "unsupported-gh",
                        str(wrapper),
                    )

            self.assertEqual(attestation["path"], str(executable))
            self.assertEqual(attestation["archive"]["sha256"], pin.sha256)
            self.assertIn((root / "private-gh").resolve(), executable.parents)
            self.assertEqual(codeql.sha256_file(executable), executable_digest)
            self.assertEqual(
                version_output,
                f"gh version {codeql.GITHUB_CLI_VERSION} (test)",
            )
            self.assertFalse(marker.exists())

    def test_checksum_verification_rejects_tampering(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "bundle"
            path.write_bytes(b"verified")
            codeql.verify_checksum(path, codeql.sha256_file(path))
            with self.assertRaisesRegex(codeql.CodeQLError, "checksum mismatch"):
                codeql.verify_checksum(path, "0" * 64)

    def test_receipt_bound_polling_cannot_select_a_concurrent_analysis(self) -> None:
        upload_id = "12345678-1234-1234-1234-123456789abc"
        upload_url = (
            "https://api.github.com/repos/example/container-compose/"
            f"code-scanning/sarifs/{upload_id}"
        )
        analyses_url = (
            "https://api.github.com/repos/example/container-compose/"
            f"code-scanning/analyses?sarif_id={upload_id}"
        )
        receipt = json.dumps({"id": upload_id, "url": upload_url})
        self.assertEqual(
            codeql.parse_sarif_upload_receipt(receipt, REPOSITORY),
            (upload_id, upload_url),
        )
        bound_analysis = {
            "id": 41,
            "commit_sha": COMMIT,
            "ref": "refs/heads/main",
            "category": codeql.CODEQL_CATEGORY,
            "error": "",
            "warning": "",
            "results_count": 0,
            "rules_count": 34,
            "tool": {"name": "CodeQL", "version": codeql.CODEQL_VERSION},
        }

        github_environment = codeql.github_cli_environment("selected-token")
        with mock.patch.object(
            codeql,
            "github_api_json",
            side_effect=[
                {"processing_status": "pending"},
                {
                    "processing_status": "complete",
                    "analyses_url": analyses_url,
                },
                [bound_analysis],
            ],
        ) as github_api:
            analysis = codeql.wait_for_uploaded_analysis(
                gh="/trusted/gh",
                repository=REPOSITORY,
                ref="refs/heads/main",
                commit=COMMIT,
                upload_id=upload_id,
                upload_url=upload_url,
                result_count=0,
                rule_count=34,
                poll_interval=0,
                poll_timeout=1,
                github_environment=github_environment,
            )

        self.assertEqual(analysis["id"], 41)
        self.assertEqual(
            [call.args[1] for call in github_api.call_args_list],
            [upload_url, upload_url, analyses_url],
        )
        for call in github_api.call_args_list:
            self.assertIs(call.kwargs["environment"], github_environment)

    def test_sarif_receipt_urls_cannot_redirect_github_credentials(self) -> None:
        upload_id = "12345678-1234-1234-1234-123456789abc"
        forged_receipt = json.dumps(
            {
                "id": upload_id,
                "url": f"https://attacker.invalid/sarifs/{upload_id}",
            }
        )
        with self.assertRaisesRegex(codeql.CodeQLError, "receipt URL mismatch"):
            codeql.parse_sarif_upload_receipt(forged_receipt, REPOSITORY)

        upload_url = (
            "https://api.github.com/repos/example/container-compose/"
            f"code-scanning/sarifs/{upload_id}"
        )
        with (
            mock.patch.object(
                codeql,
                "github_api_json",
                return_value={
                    "processing_status": "complete",
                    "analyses_url": (
                        "https://api.github.com/repos/example/container-compose/"
                        "code-scanning/analyses?sarif_id=unrelated-upload"
                    ),
                },
            ),
            self.assertRaisesRegex(codeql.CodeQLError, "not bound"),
        ):
            codeql.wait_for_uploaded_analysis(
                gh="/trusted/gh",
                repository=REPOSITORY,
                ref="refs/heads/main",
                commit=COMMIT,
                upload_id=upload_id,
                upload_url=upload_url,
                result_count=0,
                rule_count=34,
                poll_interval=0,
                poll_timeout=0,
                github_environment=codeql.github_cli_environment("selected-token"),
            )

    def test_upload_acquires_one_post_scrub_github_credential(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            repository_root, artifact_root = create_retained_evidence(Path(directory))
            authenticated = authenticated_analysis(artifact_root)
            upload_id = "12345678-1234-1234-1234-123456789abc"
            upload_url = (
                f"https://api.github.com/repos/{REPOSITORY}/"
                f"code-scanning/sarifs/{upload_id}"
            )
            upload_result = subprocess.CompletedProcess(
                args=[],
                returncode=0,
                stdout=json.dumps({"id": upload_id, "url": upload_url}).encode(),
                stderr=b"",
            )
            analysis = {
                "id": 41,
                "url": "https://api.github.com/analysis/41",
                "created_at": "2026-07-31T00:00:00Z",
                "results_count": 0,
                "rules_count": 1,
                "tool": {"version": codeql.CODEQL_VERSION},
            }
            with (
                mock.patch.dict(
                    codeql.os.environ,
                    {
                        "TMPDIR": "/tmp/attacker-parent",
                        "TMP": "/tmp/attacker-parent",
                        "TEMP": "/tmp/attacker-parent",
                        "SSL_CERT_FILE": "/tmp/attacker-ca.pem",
                        "SSL_CERT_DIR": "/tmp/attacker-ca-directory",
                        "HTTP_PROXY": "http://attacker.invalid:8080",
                        "HTTPS_PROXY": "http://attacker.invalid:8080",
                        "NO_PROXY": "api.github.com",
                        "http_proxy": "http://attacker.invalid:8080",
                        "https_proxy": "http://attacker.invalid:8080",
                        "no_proxy": "api.github.com",
                    },
                    clear=True,
                ),
                mock.patch.object(codeql, "verify_upload_identity"),
                mock.patch.object(codeql, "git_tree", return_value=TREE),
                mock.patch.object(
                    codeql, "command_output", return_value="selected-token"
                ) as token_command,
                mock.patch.object(
                    codeql, "run_command", return_value=upload_result
                ) as upload_command,
                mock.patch.object(
                    codeql, "wait_for_uploaded_analysis", return_value=analysis
                ) as confirmation,
            ):
                codeql.upload_with_private_tools(
                    repository_root=repository_root,
                    artifact_root=artifact_root,
                    repository=REPOSITORY,
                    ref="refs/heads/main",
                    commit=COMMIT,
                    codeql=Path("/verified/codeql"),
                    github_cli=Path("/verified/gh"),
                    github_cli_attestation={},
                    authenticated=authenticated,
                    poll_interval=0,
                    poll_timeout=1,
                )

            upload_environment = upload_command.call_args.kwargs["env"]
            self.assertEqual(
                token_command.call_args.args[0],
                ["/verified/gh", "auth", "token"],
            )
            token_environment = token_command.call_args.kwargs["env"]
            self.assertNotIn("GITHUB_TOKEN", token_environment)
            self.assertNotIn("GH_TOKEN", token_environment)
            for rejected in codeql.CODEQL_NETWORK_PASSTHROUGH_ENVIRONMENT:
                self.assertNotIn(rejected, token_environment)
            confirmation_environment = confirmation.call_args.kwargs[
                "github_environment"
            ]
            self.assertEqual(upload_environment["GITHUB_TOKEN"], "selected-token")
            self.assertEqual(
                upload_environment["TMPDIR"],
                str(codeql.TRUSTED_TEMPORARY_ROOT),
            )
            self.assertNotIn("TMP", upload_environment)
            self.assertNotIn("TEMP", upload_environment)
            self.assertNotIn("GH_TOKEN", upload_environment)
            for rejected in codeql.CODEQL_NETWORK_PASSTHROUGH_ENVIRONMENT:
                self.assertNotIn(rejected, upload_environment)
            self.assertIs(confirmation_environment, upload_environment)
            upload_receipt = json.loads(
                (artifact_root / COMMIT / codeql.UPLOAD_NAME).read_text(
                    encoding="utf-8"
                )
            )
            self.assertEqual(
                upload_receipt["credentialSource"],
                codeql.CODEQL_CREDENTIAL_SOURCE,
            )
            self.assertEqual(
                upload_receipt["credentialEnvironmentPolicy"],
                codeql.CODEQL_CREDENTIAL_ENVIRONMENT_POLICY,
            )
            self.assertEqual(
                upload_receipt["remoteIdentityEnvironmentPolicy"],
                codeql.CODEQL_REMOTE_IDENTITY_ENVIRONMENT_POLICY,
            )
            self.assertEqual(
                upload_receipt["remoteIdentityPassThroughEnvironment"],
                list(codeql.CODEQL_CREDENTIAL_PASSTHROUGH_ENVIRONMENT),
            )
            self.assertEqual(
                upload_receipt["temporaryRootPolicy"],
                codeql.CODEQL_TEMPORARY_ROOT_POLICY,
            )
            self.assertEqual(
                upload_receipt["temporaryRoot"],
                str(codeql.TRUSTED_TEMPORARY_ROOT),
            )
            self.assertEqual(
                upload_receipt["credentialPassThroughEnvironment"],
                list(codeql.CODEQL_CREDENTIAL_PASSTHROUGH_ENVIRONMENT),
            )

    def test_post_scrub_token_resolution_rejects_credential_environment(self) -> None:
        with mock.patch.dict(
            codeql.os.environ,
            {"GITHUB_TOKEN": "forbidden-entry-token"},
            clear=True,
        ):
            with self.assertRaisesRegex(
                codeql.CodeQLError,
                "credential environment reached the post-scrub uploader",
            ):
                codeql.resolve_github_token("/verified/gh")

    def test_missing_command_fails_without_a_traceback(self) -> None:
        with mock.patch.object(
            codeql.subprocess,
            "run",
            side_effect=FileNotFoundError("missing executable"),
        ):
            with self.assertRaisesRegex(
                codeql.CodeQLError,
                "could not run missing-tool: missing executable",
            ):
                codeql.run_command(["missing-tool"])

    def test_installed_query_pack_metadata_must_match_pins(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            executable = root / "codeql"
            executable.write_text("#!/bin/sh\n", encoding="utf-8")
            executable.chmod(0o755)
            pack = (
                root
                / "qlpacks"
                / "codeql"
                / "go-queries"
                / codeql.CODEQL_QUERY_PACK_VERSION
                / "qlpack.yml"
            )
            pack.parent.mkdir(parents=True)
            pack.write_text(
                "\n".join(
                    [
                        f"name: {codeql.CODEQL_QUERY_PACK}",
                        f"version: {codeql.CODEQL_QUERY_PACK_VERSION}",
                        "buildMetadata:",
                        f"  cliVersion: {codeql.CODEQL_VERSION}",
                        "",
                    ]
                ),
                encoding="utf-8",
            )
            with mock.patch.object(
                codeql,
                "command_output",
                return_value=json.dumps({"version": codeql.CODEQL_VERSION}),
            ):
                codeql.validate_installed_codeql(executable)
                pack.write_text(
                    pack.read_text(encoding="utf-8").replace(
                        f"version: {codeql.CODEQL_QUERY_PACK_VERSION}",
                        "version: 0.0.0",
                    ),
                    encoding="utf-8",
                )
                with self.assertRaisesRegex(codeql.CodeQLError, "version mismatch"):
                    codeql.validate_installed_codeql(executable)

    def test_empty_reviewed_baseline_accepts_empty_sarif(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            baseline = root / "baseline.json"
            sarif = root / "results.sarif"
            write_json(baseline, baseline_payload())
            write_json(sarif, sarif_payload())

            self.assertEqual(codeql.validate_sarif(sarif, baseline)[:2], (0, 1))

    def test_sarif_automation_id_requires_upload_category_delimiter(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            baseline = root / "baseline.json"
            sarif = root / "results.sarif"
            write_json(baseline, baseline_payload())
            payload = sarif_payload()
            payload["runs"][0]["automationDetails"]["id"] = codeql.CODEQL_CATEGORY
            write_json(sarif, payload)

            with self.assertRaisesRegex(codeql.CodeQLError, "automation ID mismatch"):
                codeql.validate_sarif(sarif, baseline)

    def test_unreviewed_result_fails_closed(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            baseline = root / "baseline.json"
            sarif = root / "results.sarif"
            write_json(baseline, baseline_payload())
            write_json(sarif, sarif_payload([result_payload()]))

            with self.assertRaisesRegex(
                codeql.CodeQLError, "without a reviewed baseline disposition"
            ):
                codeql.validate_sarif(sarif, baseline)

    def test_reviewed_result_requires_complete_current_disposition(self) -> None:
        disposition = {
            "ruleId": "go/example",
            "path": "Tools/compose-normalizer/main.go",
            "partialFingerprint": "fingerprint-1",
            "disposition": "accepted-risk",
            "rationale": "Reviewed test fixture.",
            "reviewedBy": "maintainer",
            "reviewedAt": "2026-07-31",
        }
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            baseline = root / "baseline.json"
            sarif = root / "results.sarif"
            write_json(baseline, baseline_payload([disposition]))
            write_json(sarif, sarif_payload([result_payload()]))
            self.assertEqual(codeql.validate_sarif(sarif, baseline)[:2], (1, 1))

            write_json(sarif, sarif_payload())
            with self.assertRaisesRegex(codeql.CodeQLError, "stale dispositions"):
                codeql.validate_sarif(sarif, baseline)

    def test_upload_identity_requires_exact_head_and_remote_ref(self) -> None:
        canonical_remote = f"https://github.com/{REPOSITORY}.git"
        remote_environments: list[dict[str, str]] = []
        responses = {
            ("rev-parse", "HEAD"): COMMIT,
            ("config", "--local", "--get", "remote.origin.url"): (
                "git@github.com:example/container-compose.git"
            ),
            ("ls-remote", "--exit-code", canonical_remote, "refs/heads/main"): (
                f"{COMMIT}\trefs/heads/main"
            ),
        }

        def fake_git(
            _root: Path,
            *arguments: str,
            environment: dict[str, str] | None = None,
        ) -> str:
            if arguments[0] == "ls-remote":
                self.assertIsNotNone(environment)
                remote_environments.append(environment or {})
            return responses[arguments]

        with (
            mock.patch.dict(
                codeql.os.environ,
                {
                    "SSL_CERT_FILE": "/tmp/attacker-ca.pem",
                    "SSL_CERT_DIR": "/tmp/attacker-ca-directory",
                    "HTTP_PROXY": "http://attacker.invalid:8080",
                    "HTTPS_PROXY": "http://attacker.invalid:8080",
                    "NO_PROXY": "github.com",
                    "http_proxy": "http://attacker.invalid:8080",
                    "https_proxy": "http://attacker.invalid:8080",
                    "no_proxy": "github.com",
                    "LANG": "en_GB.UTF-8",
                },
                clear=True,
            ),
            mock.patch.object(codeql, "require_clean_worktree"),
            mock.patch.object(codeql, "git_output", side_effect=fake_git),
        ):
            codeql.verify_upload_identity(
                Path("/unused"), REPOSITORY, "refs/heads/main", COMMIT
            )
            with self.assertRaisesRegex(codeql.CodeQLError, "head mismatch"):
                codeql.verify_upload_identity(
                    Path("/unused"), REPOSITORY, "refs/heads/main", OTHER_COMMIT
                )

        self.assertEqual(len(remote_environments), 1)
        remote_environment = remote_environments[0]
        for rejected in codeql.CODEQL_NETWORK_PASSTHROUGH_ENVIRONMENT:
            self.assertNotIn(rejected, remote_environment)
        self.assertEqual(
            set(remote_environment),
            set(codeql.CODEQL_GIT_ENVIRONMENT)
            | {"HOME", "LANG", "PATH", "TMPDIR"},
        )
        for name, value in codeql.CODEQL_GIT_ENVIRONMENT.items():
            self.assertEqual(remote_environment[name], value)
        self.assertEqual(remote_environment["LANG"], "en_GB.UTF-8")
        self.assertEqual(remote_environment["PATH"], codeql.CODEQL_FIXED_PATH)
        self.assertEqual(
            remote_environment["TMPDIR"],
            str(codeql.TRUSTED_TEMPORARY_ROOT),
        )

        responses[("rev-parse", "HEAD")] = COMMIT
        responses[("ls-remote", "--exit-code", canonical_remote, "refs/heads/main")] = (
            f"{OTHER_COMMIT}\trefs/heads/main"
        )
        with (
            mock.patch.object(codeql, "require_clean_worktree"),
            mock.patch.object(codeql, "git_output", side_effect=fake_git),
        ):
            with self.assertRaisesRegex(codeql.CodeQLError, "ref mismatch"):
                codeql.verify_upload_identity(
                    Path("/unused"), REPOSITORY, "refs/heads/main", COMMIT
                )

        tag_query = (
            "ls-remote",
            "--exit-code",
            canonical_remote,
            "refs/tags/v1",
            "refs/tags/v1^{}",
        )
        responses[tag_query] = (
            f"{OTHER_COMMIT}\trefs/tags/v1\n{COMMIT}\trefs/tags/v1^{{}}"
        )
        with (
            mock.patch.object(codeql, "require_clean_worktree"),
            mock.patch.object(codeql, "git_output", side_effect=fake_git),
        ):
            codeql.verify_upload_identity(
                Path("/unused"), REPOSITORY, "refs/tags/v1", COMMIT
            )

    def test_supported_go_scope_fails_when_tracked_source_expands(self) -> None:
        with mock.patch.object(codeql, "git_output") as git_output:
            git_output.side_effect = [
                "Tools/compose-normalizer/main.go\nOther/tool.go",
            ]
            with self.assertRaisesRegex(codeql.CodeQLError, "Other/tool.go"):
                codeql.require_supported_go_scope(Path("/unused"))

        with mock.patch.object(codeql, "git_output") as git_output:
            git_output.side_effect = [
                "Tools/compose-normalizer/main.go",
                "",
            ]
            codeql.require_supported_go_scope(Path("/unused"))

        with mock.patch.object(codeql, "git_output") as git_output:
            git_output.side_effect = [
                "Tools/compose-normalizer/main.go",
                "go.work",
            ]
            with self.assertRaisesRegex(codeql.CodeQLError, "go.work"):
                codeql.require_supported_go_scope(Path("/unused"))

    def test_exact_checkout_owns_objects_and_excludes_ignored_build_inputs(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            repository = root / "repository"
            source = repository / "Tools/compose-normalizer"
            source.mkdir(parents=True)
            (repository / ".gitignore").write_text(
                "Tools/compose-normalizer/compose-normalizer\n"
                "Tools/compose-normalizer/debug.go\n"
                "go.work\n",
                encoding="utf-8",
            )
            (repository / "Makefile").write_text("go-build:\n\t@true\n", encoding="utf-8")
            (source / "main.go").write_text("package main\n", encoding="utf-8")
            (source / "debug.go").write_text("package main\n", encoding="utf-8")
            (repository / "go.work").write_text("go 1.25\n", encoding="utf-8")
            codeql.run_command(["git", "init", "--quiet"], cwd=repository)
            codeql.run_command(["git", "add", "."], cwd=repository)
            codeql.run_command(
                [
                    "git",
                    "-c",
                    "commit.gpgsign=false",
                    "-c",
                    "user.name=CodeQL Test",
                    "-c",
                    "user.email=codeql-test@example.invalid",
                    "commit",
                    "--quiet",
                    "-m",
                    "test: exact source",
                ],
                cwd=repository,
            )
            commit = codeql.command_output(["git", "rev-parse", "HEAD"], cwd=repository)
            codeql.require_clean_worktree(repository)
            destination = root / "exact-source"
            codeql.create_exact_checkout(repository, commit, destination)

            self.assertTrue((destination / "Tools/compose-normalizer/main.go").is_file())
            self.assertFalse((destination / "Tools/compose-normalizer/debug.go").exists())
            self.assertFalse((destination / "go.work").exists())
            self.assertEqual(
                codeql.command_output(["git", "rev-parse", "HEAD"], cwd=destination),
                commit,
            )
            self.assertFalse(
                os.path.lexists(destination / ".git/objects/info/alternates")
            )

            tracked_path = "Tools/compose-normalizer/main.go"
            original_blob = codeql.command_output(
                ["git", "rev-parse", f"{commit}:{tracked_path}"],
                cwd=repository,
            )
            malicious_source = root / "malicious.go"
            malicious_source.write_text("package malicious\n", encoding="utf-8")
            malicious_blob = codeql.command_output(
                ["git", "hash-object", "-w", str(malicious_source)],
                cwd=repository,
            )

            def loose_object(object_id: str) -> Path:
                return repository / ".git/objects" / object_id[:2] / object_id[2:]

            original_object = loose_object(original_blob)
            malicious_object = loose_object(malicious_blob)
            self.assertTrue(original_object.is_file())
            self.assertTrue(malicious_object.is_file())
            original_object.chmod(0o644)
            original_object.write_bytes(malicious_object.read_bytes())
            (destination / tracked_path).write_text(
                "package malicious\n", encoding="utf-8"
            )
            with self.assertRaisesRegex(codeql.CodeQLError, "inputs changed"):
                codeql.verify_exact_checkout(destination, commit)

            (destination / tracked_path).write_text("package main\n", encoding="utf-8")
            codeql.verify_exact_checkout(destination, commit)

            destination_object = (
                destination / ".git/objects" / original_blob[:2] / original_blob[2:]
            )
            destination_object.parent.mkdir(parents=True, exist_ok=True)
            destination_object.write_bytes(malicious_object.read_bytes())
            (destination / tracked_path).write_text(
                "package malicious\n", encoding="utf-8"
            )
            with self.assertRaisesRegex(codeql.CodeQLError, "fsck"):
                codeql.verify_exact_checkout(destination, commit)

            destination_object.unlink()
            (destination / tracked_path).write_text("package main\n", encoding="utf-8")
            codeql.verify_exact_checkout(destination, commit)
            build_output = destination / "Tools/compose-normalizer/compose-normalizer"
            build_output.write_bytes(b"expected ignored build output")
            codeql.verify_exact_checkout(
                destination,
                commit,
                expected_untracked={codeql.CODEQL_BUILD_OUTPUT_PATH},
            )
            (destination / "Tools/compose-normalizer/main.go").write_text(
                "package changed\n",
                encoding="utf-8",
            )
            with self.assertRaisesRegex(codeql.CodeQLError, "inputs changed"):
                codeql.verify_exact_checkout(
                    destination,
                    commit,
                    expected_untracked={codeql.CODEQL_BUILD_OUTPUT_PATH},
                )

    def test_dry_run_reads_no_token_and_retains_sarif(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            repository_root, artifact_root = create_retained_evidence(Path(directory))
            sarif = artifact_root / COMMIT / codeql.SARIF_NAME
            with (
                mock.patch.object(codeql, "verify_upload_identity"),
                mock.patch.object(codeql, "git_tree", return_value=TREE),
                mock.patch.object(
                    codeql,
                    "resolve_github_token",
                    side_effect=AssertionError("dry run read a token"),
                ),
                mock.patch.object(
                    codeql,
                    "analyze",
                    side_effect=AssertionError("dry run regenerated analysis"),
                ),
            ):
                result = codeql.upload(
                    repository_root=repository_root,
                    cache_root=repository_root / ".local/share/codeql",
                    artifact_root=artifact_root,
                    repository=REPOSITORY,
                    ref="refs/heads/main",
                    commit=COMMIT,
                    dry_run=True,
                    gh="gh",
                    poll_interval=0,
                    poll_timeout=0,
                )
            self.assertIsNone(result)
            self.assertTrue(sarif.is_file())
            self.assertFalse((sarif.parent / codeql.UPLOAD_NAME).exists())

    def test_real_upload_revalidates_evidence_after_bundle_installation(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            repository_root, artifact_root = create_retained_evidence(Path(directory))
            sarif = artifact_root / COMMIT / codeql.SARIF_NAME
            authenticated = authenticated_analysis(artifact_root)

            def install_then_replace(
                _cache_root: Path, _installation: Path
            ) -> tuple[Path, str, object]:
                sarif.write_text("{}\n", encoding="utf-8")
                return (
                    Path("/verified/codeql"),
                    "osx64",
                    codeql.BUNDLE_PINS["osx64"],
                )

            with (
                mock.patch.object(codeql, "verify_upload_identity"),
                mock.patch.object(codeql, "git_tree", return_value=TREE),
                mock.patch.object(
                    codeql,
                    "analyze",
                    return_value=authenticated,
                ) as analyze,
                mock.patch.object(
                    codeql,
                    "ensure_codeql",
                    side_effect=install_then_replace,
                ),
                mock.patch.object(
                    codeql,
                    "ensure_github_cli",
                    return_value=(Path("/verified/gh"), {}),
                ),
                mock.patch.object(
                    codeql,
                    "resolve_github_token",
                    side_effect=AssertionError("invalid evidence reached token lookup"),
                ),
                self.assertRaises(codeql.CodeQLError),
            ):
                codeql.upload(
                    repository_root=repository_root,
                    cache_root=repository_root / ".local/share/codeql",
                    artifact_root=artifact_root,
                    repository=REPOSITORY,
                    ref="refs/heads/main",
                    commit=COMMIT,
                    dry_run=False,
                    gh="gh",
                    poll_interval=0,
                    poll_timeout=0,
                )
            analyze.assert_called_once()

    def test_upload_snapshot_rejects_bytes_changed_after_validation(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            repository_root, artifact_root = create_retained_evidence(Path(directory))
            evidence = artifact_root / COMMIT
            manifest = json.loads(
                (evidence / codeql.MANIFEST_NAME).read_text(encoding="utf-8")
            )
            snapshot = Path(directory) / "snapshot.sarif"
            codeql.snapshot_retained_sarif(
                evidence, manifest["sarifSha256"], snapshot
            )
            self.assertEqual(
                snapshot.read_bytes(),
                (evidence / codeql.SARIF_NAME).read_bytes(),
            )

            (evidence / codeql.SARIF_NAME).write_text("{}\n", encoding="utf-8")
            with self.assertRaisesRegex(codeql.CodeQLError, "changed"):
                codeql.snapshot_retained_sarif(
                    evidence,
                    manifest["sarifSha256"],
                    Path(directory) / "changed.sarif",
                )

    def test_regenerated_digests_reject_a_self_consistent_forged_pair(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            repository_root, artifact_root = create_retained_evidence(Path(directory))
            evidence = artifact_root / COMMIT
            authenticated = authenticated_analysis(artifact_root)
            sarif = evidence / codeql.SARIF_NAME
            forged_sarif = sarif_payload()
            forged_sarif["runs"][0]["invocations"] = [
                {"executionSuccessful": True}
            ]
            write_json(sarif, forged_sarif)
            manifest_path = evidence / codeql.MANIFEST_NAME
            forged_manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
            forged_manifest["sarifSha256"] = codeql.sha256_file(sarif)
            write_json(manifest_path, forged_manifest)

            with mock.patch.object(codeql, "git_tree", return_value=TREE):
                loaded_evidence, loaded_manifest = codeql.load_retained_evidence(
                    repository_root, artifact_root, REPOSITORY, COMMIT
                )
            with self.assertRaisesRegex(codeql.CodeQLError, "regenerated analysis"):
                codeql.authenticate_retained_evidence(
                    loaded_evidence,
                    loaded_manifest,
                    authenticated,
                )

    def test_retained_manifest_rejects_sarif_tampering(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            repository_root, artifact_root = create_retained_evidence(Path(directory))
            sarif = artifact_root / COMMIT / codeql.SARIF_NAME
            sarif.write_text("{}\n", encoding="utf-8")

            with (
                mock.patch.object(codeql, "git_tree", return_value=TREE),
                self.assertRaises(codeql.CodeQLError),
            ):
                codeql.load_retained_evidence(
                    repository_root, artifact_root, REPOSITORY, COMMIT
                )


if __name__ == "__main__":
    unittest.main()
