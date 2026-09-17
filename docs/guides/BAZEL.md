# Native Bazel migration

Status: opt-in implementation, not a release or replacement for the existing required gates.

The native graph compiles ComposeRuntimeSPI, ComposeCore, the selected stock/enhanced provider and ComposePlugin directly with Bazel. It does not invoke `swift build` or recursively run the existing Makefile. The CLI and eventual CLI tests share one compiled entry-point module. The selected `Package.stock.resolved` or `Package.resolved` supplies immutable dependency revisions; the package manifest remains the product/dependency contract. Swift package access uses the shared `container_compose` identity without widening API visibility.

## Shared workflow

The family launcher is reused from the reviewed devcontainer workflow rather than duplicated. For this development checkpoint, use `Tools/bazel/run.sh` from devcontainer commit `49d254f` (PR [83](https://github.com/stephenlclarke/devcontainer/pull/83)). `Tools/bazel/workflow-tooling.json` binds every shared executable helper's bytes and permissions; a different helper set fails before the build. Keep that checkout on internal storage. This explicit source-tooling dependency is not a runtime dependency on devcontainer and is not a stable clean-machine bootstrap claim.

```sh
export FAMILY_BAZEL_LAUNCHER=/absolute/path/to/reviewed-devcontainer/Tools/bazel/run.sh
make -f Tools/bazel/Makefile build BAZEL_PROFILE=stock
make -f Tools/bazel/Makefile test-spi BAZEL_PROFILE=stock
make -f Tools/bazel/Makefile test-cli BAZEL_PROFILE=stock
```

Use `BAZEL_PROFILE=enhanced` for the pinned enhanced provider. The shared launcher's legacy internal `DEVCONTAINER_RUNTIME_PROFILE` variable selects the dependency graph together with the Bazel `runtime_profile` setting; callers select only the named profile. Repository/dependency overrides remain refused.

The same enrolled-SSD checks, source/helper identity checks, output lease, native action cache, build durations, cache metrics and retained evidence apply to both products. Temporary work remains on `/Volumes/SSD/cf/bazel`; accepted archives and evidence remain under the internal ContainerFamily retained store. Existing release/signing entry points and operator runtimes are not changed or invoked.

The small duplicated Starlark profile adapter, Bazel configuration, test wrapper and rules_swift patch originate from the Apache-2.0 devcontainer checkpoint above; copyright notices are retained. These are project graph configuration, not a second coordinator. The substantial acquisition, storage, timing, evidence and execution implementation remains shared.

## Qualification and remaining work

The first native runtime-SPI test invocation passed (`a86eea6f-5fa1-4f36-b766-c170920e066c`), reusing 32 disk-cache actions. The first full stock build exposed the missing Swift package-access name; that failed invocation (`1fafecab-0456-4783-8eb6-8de612dd1ead`) remains retained. The corrected stock CLI build passed (`d3e6a329-1279-4f88-9679-6d9fd09ace39`, 55.697 seconds Bazel elapsed time). These are development-worktree observations, not quiet benchmarks, release-build timings or complete unit-suite qualification.

The enhanced CLI graph also builds (`a66291f4-6596-4ab3-ae61-067a837c5e13`, 56.765 seconds Bazel elapsed, 28 disk-cache actions and 1,144 action-cache hits). The `test-cli` target executes only the native help surface, without services, Go assets or registry access. It does not establish packaging or command behavior.

Native help smoke checks pass in enhanced (`5d52852c-ee61-4bc1-a83f-23c4abf4e31a`) and stock (`cbe4c5e4-0ef3-47f1-8cc7-ccad1a46b8a6`) profiles. The initial smoke fixture expected Swift Argument Parser's generic headings instead of this project's custom Docker-shaped help; that test-only mismatch is retained at `268946a3-8bda-4830-987e-cb85f37b3b93`. The assertion now checks the actual declared root usage and up/down command descriptions and retains help output before asserting. Runtime-SPI discovery reports 20 actual Swift Testing cases; the enhanced repeat (`1f1f9fc5-f5eb-4369-9abf-febcfdce2c41`) reuses the unchanged test result. No container services are started by these checks.

Remaining cutover gates include every existing unit suite and fixture resource, explicit SSD test scratch, native Go normalizer/volume initializer targets, aggregate coverage and sanitizers/leaks, versioned packaging, signed retained candidate reuse, downloaded-release parity, fault recovery, CI authority and stable publication. Do not label the runtime-SPI subset as the full unit suite or package the bare CLI as a complete Compose distribution. Existing workflows remain available until the complete replacement is qualified.
