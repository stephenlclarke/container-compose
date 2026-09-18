# Native Bazel migration

Status: opt-in implementation, not a release or replacement for the existing required gates.

The native graph compiles ComposeRuntimeSPI, ComposeCore, the selected stock/enhanced provider and ComposePlugin directly with Bazel. The CLI and CLI tests share one compiled entry-point module. The Go normalizer and Linux ARM64/AMD64 volume initializers are also native Bazel products. Builds do not invoke `swift build`, `go build`, or recursively run the existing Makefile. The selected `Package.stock.resolved` or `Package.resolved` supplies immutable Swift revisions; Go dependencies and the downloaded Go 1.26.3 SDK come from the existing `go.mod`/`go.sum`. Swift package access uses the shared `container_compose` identity.

## Shared workflow

The family launcher is reused from the reviewed devcontainer workflow rather than duplicated. For this development checkpoint, use `Tools/bazel/run.sh` from devcontainer commit `49d254f` (PR [83](https://github.com/stephenlclarke/devcontainer/pull/83)). `Tools/bazel/workflow-tooling.json` binds every shared executable helper's bytes and permissions; a different helper set fails before the build. Keep that checkout on internal storage. This explicit source-tooling dependency is not a runtime dependency on devcontainer and is not a stable clean-machine bootstrap claim.

```sh
export FAMILY_BAZEL_LAUNCHER=/absolute/path/to/reviewed-devcontainer/Tools/bazel/run.sh
make -f Tools/bazel/Makefile build BAZEL_PROFILE=stock
make -f Tools/bazel/Makefile test-spi BAZEL_PROFILE=stock
make -f Tools/bazel/Makefile test-cli BAZEL_PROFILE=stock
make -f Tools/bazel/Makefile test-unit BAZEL_PROFILE=stock
make -f Tools/bazel/Makefile test-unit BAZEL_PROFILE=enhanced
make -f Tools/bazel/Makefile test-go
```

Use `BAZEL_PROFILE=enhanced` for the pinned enhanced provider. The shared launcher's legacy internal `DEVCONTAINER_RUNTIME_PROFILE` variable selects the dependency graph together with the Bazel `runtime_profile` setting; callers select only the named profile. Repository/dependency overrides remain refused.

The same enrolled-SSD checks, source/helper identity checks, output lease, native action cache, build durations, cache metrics and retained evidence apply to both products. Temporary work remains on `/Volumes/SSD/cf/bazel`; accepted archives and evidence remain under the internal ContainerFamily retained store. Existing release/signing entry points and operator runtimes are not changed or invoked.

The small duplicated Starlark profile adapter, Bazel configuration, test wrapper and rules_swift patch originate from the Apache-2.0 devcontainer checkpoint above; copyright notices are retained. These are project graph configuration, not a second coordinator. The substantial acquisition, storage, timing, evidence and execution implementation remains shared.

## Qualification and remaining work

The first native runtime-SPI test invocation passed (`a86eea6f-5fa1-4f36-b766-c170920e066c`), reusing 32 disk-cache actions. The first full stock build exposed the missing Swift package-access name; that failed invocation (`1fafecab-0456-4783-8eb6-8de612dd1ead`) remains retained. The corrected stock CLI build passed (`d3e6a329-1279-4f88-9679-6d9fd09ace39`, 55.697 seconds Bazel elapsed time). These are development-worktree observations, not quiet benchmarks, release-build timings or complete unit-suite qualification.

The enhanced CLI graph also builds (`a66291f4-6596-4ab3-ae61-067a837c5e13`, 56.765 seconds Bazel elapsed, 28 disk-cache actions and 1,144 action-cache hits). The `test-cli` target executes only the native help surface, without services, Go assets or registry access. It does not establish packaging or command behavior.

Native help smoke checks pass in enhanced (`5d52852c-ee61-4bc1-a83f-23c4abf4e31a`) and stock (`cbe4c5e4-0ef3-47f1-8cc7-ccad1a46b8a6`) profiles. The initial smoke fixture expected Swift Argument Parser's generic headings instead of this project's custom Docker-shaped help; that test-only mismatch is retained at `268946a3-8bda-4830-987e-cb85f37b3b93`. The assertion now checks the actual declared root usage and up/down command descriptions and retains help output before asserting. Runtime-SPI discovery reports 20 actual Swift Testing cases; the enhanced repeat (`1f1f9fc5-f5eb-4369-9abf-febcfdce2c41`) reuses the unchanged test result. No container services are started by these checks.

## Unit and filesystem migration

`test-unit` selects the explicit `unit_stock` or `unit_enhanced` suite, matching the package's provider-conditional test modules. Both include all six Go test targets and focused private-storage regressions. The enhanced suite includes the complete ComposeCore tests and provider fixtures. The opt-in live `ComposeRuntimeTests` suite is not silently counted as a unit pass; its runtime-lease adapter remains unfinished.

Swift test fixtures explicitly use the runner's canonical SSD directory; undeclared Bazel scratch fails closed. The processed resource bundle preserves SwiftPM's flattened fixture names. CLI tests declare their real executable, and parser tests declare the native Go executable instead of rebuilding it using `go run`. Fallback-launcher tests inject their selection environment without changing concurrent tests' process environment. Go test targets enable verbose events so their retained XML contains actual passing cases, not an empty success report.

Compose temporary files now honor an absolute `TMPDIR` (invalid or absent values retain the Foundation default). Fresh private files are exclusively created in the requested directory. Config/secret, pull-metadata and generated Dockerfile publication uses a same-directory atomic rename with permissions applied before publication, avoiding Foundation's out-of-sandbox volume replacement area. Persistent per-user state locations are unchanged. Watcher fixtures retain atomic replacement semantics rather than weakening their writes for the sandbox.

The single `permission_bits_test` target is local-only and runs without the Darwin sandbox: the sandbox strips set-ID bits from its input fixture before the initializer runs. Invocation `b30969f2-8113-4eec-9b37-dac3e2df44e4` records that source-capability failure. The isolated target retains every source and destination assertion, creates only disposable SSD fixtures and does not execute the permission-marked file or start a VM. The remaining Go tests and all Swift tests retain sandboxing. Both initializer targets pass at `93509c0b-6174-4143-af49-5c1ceac22aee`; this exception does not constitute Linux runtime validation.

Latest development evidence (not quiet or release qualification):

| Invocation | Observation |
| --- | --- |
| `b77a5b4c-99e8-4f6b-b0ba-8527132509d3` | Initial stock migration: 24 SPI, 25 Engine runtime and 92 CLI tests passed. |
| `af6f8eb3-9780-46f5-8381-a4346928879d` | Native Go helper builds passed; first build took 84.337 seconds including tool/dependency compilation. |
| `b46dc5c0-66c5-4cc6-86fe-4977b102a311` | Enhanced Swift suites passed: 1,246 Core, 31 provider, 91 CLI, 25 SPI/storage and eight temporary-file cases in retained XML. |
| `09fbdfa5-0231-4c81-bb6b-9f8196261f03` | All six Go targets passed with 305 retained XML cases, including subtests; 1.624 seconds Bazel elapsed. |
| `180a2464-4721-4f59-ace7-4d6c3ff368d1` | Product graph built Compose, normalizer and both Linux initializers; 10.609 seconds, reusing 2,469 action-cache entries. |
| `bc40aa15-8df6-4a96-84d8-9666bedd54be` | Complete stock unit aggregate: all ten targets pass; eight reuse cached results. |
| `3b3d3252-3ddd-4de3-b82f-d2aced9f1622` | Complete enhanced unit aggregate: all eleven targets reuse passing results; 5.016 seconds Bazel elapsed. |
| `c43d7fac-4949-4b67-9808-525fe08146cf` | All eleven enhanced targets pass instrumented; combined LCOV retained. Consumer-specific report validation/export remains to be wired; this is not a coverage quality-gate pass. |

The preceding suite-configuration, missing-input and filesystem failures remain retained. These records describe development observations; exact-head checkpoint runs and a reuse check must accompany promotion. A cached result is valid only for the same declared action inputs.

Remaining cutover gates include aggregate coverage and sanitizers/leaks, versioned packaging, signed retained candidate reuse, downloaded-release integration/parity, fault recovery, CI authority and stable publication. Do not package these binaries as a complete Compose distribution before version metadata, resources and distribution gates are wired. Existing workflows remain available until the complete replacement is qualified.
