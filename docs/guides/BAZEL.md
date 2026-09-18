# Native Bazel migration

Status: opt-in implementation, not a release or replacement for the existing required gates.

The native graph compiles ComposeRuntimeSPI, ComposeCore, the selected stock/enhanced provider and ComposePlugin directly with Bazel. The CLI and CLI tests share one compiled entry-point module. The Go normalizer and Linux ARM64/AMD64 volume initializers are also native Bazel products. Builds do not invoke `swift build`, `go build`, or recursively run the existing Makefile. The selected `Package.stock.resolved` or `Package.resolved` supplies immutable Swift revisions; Go dependencies and the downloaded Go 1.26.3 SDK come from the existing `go.mod`/`go.sum`. Swift package access uses the shared `container_compose` identity.

## Shared workflow

The family launcher is reused from the reviewed devcontainer workflow rather than duplicated. For this development checkpoint, use `Tools/bazel/run.sh` from devcontainer commit `0a20370` (PR [83](https://github.com/stephenlclarke/devcontainer/pull/83)). `Tools/bazel/workflow-tooling.json` binds every shared executable helper's bytes and permissions; a different helper set fails before the build. Keep that checkout on internal storage. This explicit source-tooling dependency is not a runtime dependency on devcontainer and is not a stable clean-machine bootstrap claim.

```sh
export FAMILY_BAZEL_LAUNCHER=/absolute/path/to/reviewed-devcontainer/Tools/bazel/run.sh
make -f Tools/bazel/Makefile build BAZEL_PROFILE=stock
make -f Tools/bazel/Makefile test-spi BAZEL_PROFILE=stock
make -f Tools/bazel/Makefile test-cli BAZEL_PROFILE=stock
make -f Tools/bazel/Makefile test-unit BAZEL_PROFILE=stock
make -f Tools/bazel/Makefile test-unit BAZEL_PROFILE=enhanced
make -f Tools/bazel/Makefile test-go
make -f Tools/bazel/Makefile coverage BAZEL_PROFILE=enhanced
make -f Tools/bazel/Makefile coverage-report INVOCATION=RETAINED-ID
make -f Tools/bazel/Makefile coverage-check BAZEL_PROFILE=enhanced INVOCATION=RETAINED-ID
make -f Tools/bazel/Makefile package BAZEL_PROFILE=enhanced
make -f Tools/bazel/Makefile test-package BAZEL_PROFILE=enhanced
make -f Tools/bazel/Makefile restore-package INVOCATION=RETAINED-PACKAGE-ID
```

Use `BAZEL_PROFILE=enhanced` for the pinned enhanced provider. The shared launcher's legacy internal `DEVCONTAINER_RUNTIME_PROFILE` variable selects the dependency graph together with the Bazel `runtime_profile` setting; callers select only the named profile. Repository/dependency overrides remain refused.

The same enrolled-SSD checks, source/helper identity checks, output lease, native action cache, build durations, cache metrics and retained evidence apply to both products. Temporary work remains on `/Volumes/SSD/cf/bazel`; accepted archives and evidence remain under the internal ContainerFamily retained store. Existing release/signing entry points and operator runtimes are not changed or invoked.

The small duplicated Starlark profile adapter, Bazel configuration, test wrapper and rules_swift patch originate from the Apache-2.0 devcontainer checkpoint above; copyright notices are retained. These are project graph configuration, not a second coordinator. The substantial acquisition, storage, timing, evidence and execution implementation remains shared.

## Qualification and remaining work

The first native runtime-SPI test invocation passed (`a86eea6f-5fa1-4f36-b766-c170920e066c`), reusing 32 disk-cache actions. The first full stock build exposed the missing Swift package-access name; that failed invocation (`1fafecab-0456-4783-8eb6-8de612dd1ead`) remains retained. The corrected stock CLI build passed (`d3e6a329-1279-4f88-9679-6d9fd09ace39`, 55.697 seconds Bazel elapsed time). These are development-worktree observations, not quiet benchmarks, release-build timings or complete unit-suite qualification.

The enhanced CLI graph also builds (`a66291f4-6596-4ab3-ae61-067a837c5e13`, 56.765 seconds Bazel elapsed, 28 disk-cache actions and 1,144 action-cache hits). The `test-cli` target executes only the native help surface, without services, Go assets or registry access. It does not establish packaging or command behavior.

Native help smoke checks pass in enhanced (`5d52852c-ee61-4bc1-a83f-23c4abf4e31a`) and stock (`cbe4c5e4-0ef3-47f1-8cc7-ccad1a46b8a6`) profiles. The initial smoke fixture expected Swift Argument Parser's generic headings instead of this project's custom Docker-shaped help; that test-only mismatch is retained at `268946a3-8bda-4830-987e-cb85f37b3b93`. The assertion now checks the actual declared root usage and up/down command descriptions and retains help output before asserting. Runtime-SPI discovery reports 20 actual Swift Testing cases; the enhanced repeat (`1f1f9fc5-f5eb-4369-9abf-febcfdce2c41`) reuses the unchanged test result. No container services are started by these checks.

## Unit and filesystem migration

`test-unit` selects the explicit `unit_stock` or `unit_enhanced` suite, matching the package's provider-conditional test modules. Both include all six Go test targets, focused private-storage regressions and runtime-neutral Core tests. Stock now runs 1,057 Core cases without importing either concrete provider; enhanced runs 1,247 Core cases and provider fixtures, including the new process-diagnostics check. The explicit five-file provider-coupled inventory is identical in Bazel and Package.swift, so new neutral suites run in both profiles by default. Concrete lifecycle/event/discovery/archive assertions in mixed suites use the explicit enhanced-profile flag, never `canImport` (cached modules can remain discoverable across a profile switch). The remaining 190 enhanced Core cases still require provider separation or equivalent stock-provider proof. The opt-in live `ComposeRuntimeTests` suite is not silently counted as a unit pass; its runtime-lease adapter remains unfinished.

### Cancellation diagnostic evidence

The retained stock GitHub failure at `ac6ef809` (`35299032455`, job `105458020296`) took 2.543 seconds against the existing strict two-second cancellation bound. Its cause remains unresolved. Passing subsequent runs do not supersede that failure or qualify it as fixed.

An internal, optional per-run observer now records scheduling, SIGTERM, escalation, leader reaping, pipe drainage and continuation completion. Production callers leave it unset; no queue, signal, grace period, process ownership or completion condition changes. The four existing cancellation tests retain their error type, two-second limit and parent/descendant PID-absence checks. Their retained test output includes JSON phase offsets in monotonic nanoseconds and the caller's `awaitReturned` duration. Negative offsets mean the phase preceded cancellation. Diagnostics are rendered after the measured operation; they contain no command, environment, process output or PID payloads.

The final source passes all 1,057 stock Core tests in 38 suites (`2762b313-1df7-46e0-8311-e3c2b80ceaea`, 39.277 seconds build/test) and all 1,247 enhanced Core tests in 40 suites (`471cfacf-96c2-4a54-a41d-73233c41d4dc`, 70.349 seconds build/test). Strict touched-file Swift formatting/lint and independent final source review pass. Both invocations retain raw phase JSON in the `ComposeCoreTests` test log. The measured cancellation totals were:

| I/O mode | Stock milliseconds | Enhanced milliseconds |
| --- | ---: | ---: |
| Captured, no input | 294.025 | 346.170 |
| Captured, input | 353.041 | 287.422 |
| Captured stdout, inherited stdin/stderr | 312.141 | 350.627 |
| Inherited | 311.904 | 330.492 |

These are instrumented diagnostic observations, not quiet paired benchmarks, performance comparisons or a fix for the historical timeout. The intended next evidence is a failing phase trace: delay before escalation implicates scheduling; delay after reaping can be separated into stream drainage, process-group waiting and caller resumption. No timing waiver or retry-to-green policy was introduced. Public CLI behavior, README installation commands and DocC usage remain unchanged.

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

## Validated coverage evidence

`Tools/bazel/evidence-policy.json` declares the stock/enhanced test inventories, minimum discovered cases, mandatory executed production files and Swift/Go source roots. The shared family validator checks both `test-unit` and `coverage`; missing/skipped cases, wrong target sets, missing production probes and inconsistent LCOV line counts fail. Only the test-only `ComposeTestStorage` fixture utility is excluded from instrumentation; no product source is excluded.

`coverage-report` reconstructs LCOV, Sonar XML and a source/profile/digest receipt from internally retained bytes without a build or rerun. Export requires a clean recorded source identity, not merely a successful dirty development test. `coverage-check` additionally requires a clean current checkout and evidence for the same source SHA, selected profile and consumer policy, then enforces 90% using unrounded line counts. Another profile or repository's passing report cannot satisfy it. A below-target result leaves the diagnostic report available and fails the gate.

The first policy-validated development runs measured 28,380/32,443 enhanced lines (`e9fc2e16-3217-4ad7-918b-243da128b0a4`) and 8,020/29,967 stock lines (`4b89f05c-89ea-4f68-b51a-14880adf14b3`). Neither reached 90%. That stock graph omitted the entire Core suite; this omission is now partially corrected, not waived. These dated diagnostic observations are not current-head Sonar results or release acceptance.

After separating neutral fixtures, stock Core passes all 284 cases at `67a505d8-1e99-4a1a-b28b-9c9f814821f7`. Stock instrumented aggregate `3528175e-6dfd-4ac5-9c06-4f7d1fb5e6ba` passes all eleven targets and reports 13,134/29,971 lines (43.8224%), up from 26.76%. Enhanced Core still passes all 1,246 cases at `cd552bc4-05dd-457f-b62d-2f63ab39336e`. The consumer policy requires the stock Core inventory and executed normalizer/process production files. No production source exclusion or test-assertion weakening was used. These are development results (26.046, 13.819 and 68.845 seconds respectively), not quiet benchmarks or a passing 90% gate.

The subsequent orchestration-fixture separation expands stock Core to 1,056 cases: `3b4bc918-7943-453c-8a46-ef3c885b8b95` validates all eleven instrumented targets and 25,780/29,971 lines (86.0165%). Its 0.370-second Bazel duration reuses all eleven passing results; the preceding execution took 44.344 seconds but its evidence policy incorrectly expected 1,120 cases and therefore failed validation. That failed invocation remains retained, not relabelled as a pass. The corrected inventory is the actual non-skipped XML count. Shared helpers retain their assertions; concrete provider models/clients move into two enhanced-only support files. No production sources are excluded. The 90% gate, live runtime qualification and quiet paired performance evidence remain open.

At clean commit `3f765e3e39d3cf7683bab554a552a312a9f1f3ee`, invocation `c4fbd357-2818-4bcf-808a-b7e504943e27` reused all eleven enhanced test results in 0.487 seconds and validated 28,388/32,451 production lines (87.4796%). Authenticated export succeeds; the 90% gate correctly fails, and requesting the stock gate against this enhanced evidence also fails. These are development observations, not quiet benchmarks.

Enhanced aggregate `c785d07c-bc8c-45c2-8666-6bf52e9c9ea1` confirms all 1,246 Core cases remain passing after the final separation. All eleven instrumented targets pass, with 28,374/32,451 lines (87.4364%) and 65.498 seconds Bazel elapsed. This is development validation, not a quiet benchmark or a passing 90% gate.

### Native sanitizer lanes

`make -f Tools/bazel/Makefile test-asan BAZEL_PROFILE=enhanced` and `test-tsan` select the existing native address/thread sanitizer configurations. Either also accepts `BAZEL_PROFILE=stock`. They run the complete selected-profile unit inventory through the same SSD launcher and retained evidence path, with one attempt and no blanket suppression or silent fallback to ordinary tests. Swift and C dependencies use the pinned rules_swift/toolchain sanitizer features. Included Go tests still run but are not sanitizer-instrumented; `test-go-race` selects rules_go's own race mode for all six Go targets. Live runtime leak detection remains a separate qualification requirement. Unit sanitizer success is not VM/runtime parity or macOS `leaks` evidence.

The enhanced address-sanitizer aggregate passes all eleven targets at `45a1052a-7e6b-4f8e-b271-009930f7fb2e` (197.024 seconds initial instrumented build/test; not a quiet benchmark). The initial thread-sanitizer aggregate fails at `b08f099d-e6c7-4c29-bd3b-f62876974400`: globally forwarding Clang TSan into CGo links an incompatible runtime and crashes Go startup. The narrow rules_go context patch disables only those Clang address/thread features at the CGo boundary; it leaves Swift/C instrumentation and Go's dedicated race mode intact. After that correction, all six ordinary Go targets and the instrumented 1,246-case Core target pass at `00313bb9-122f-485c-b37b-476cccc0c99c` (8.199 seconds, six cached targets). The failed aggregate remains retained; no tests were removed.

The separate Go race aggregate executes and passes all six targets at `2101ab46-46f5-4722-814a-cd6cd2b8af33` (72.162 seconds initial race build/test). This is Go race-detector evidence, not ordinary cached Go results or a quiet benchmark.

The remaining original TSan failure was a real Containerization EXT4 aligned-load crash, not a sanitizer false positive. The ordinary alignment regression reproduces it at `421c2b24-261b-4133-b2a6-5d4f87b5bc2e`. [Containerization PR 103](https://github.com/stephenlclarke/containerization/pull/103) supplies the generic unaligned-load fix. The enhanced candidate pins its exact source commit `ea5ff3b97bd1a12c4054f262ce9fbb7207e6f443`; stock Apple pins remain unchanged. With this fix, all 32 affected runtime-unit cases pass under TSan at `7040f032-1f97-4660-8ec0-237c8e701dd8` (13.274 seconds), and the full enhanced eleven-target TSan aggregate passes at `87d7bbd6-8aa2-4c20-8920-9aeb5230965b` (9.826 seconds; two executed, nine cached). The failed original evidence and private crash diagnostics remain retained. This source candidate does not replace any installed runtime, downloaded oracle or published guest image; coordinated lower-PR merge and matched-stack release admission remain required. Stock sanitizer and live leak qualification remain open.

## Native unsigned candidates

The EXT4 fix also requires the coordinated [Container dependency PR 286](https://github.com/stephenlclarke/container/pull/286). Its exact source commit `1b68690e99e86c8dc4425ff7fe4dd8270308a068` aligns Container's own manifest/lock with Compose's selected Containerization revision. Legacy CI correctly rejected the preceding mixed graph; its failures remain retained. Native Bazel success alone is not SwiftPM constraint-resolution proof. The existing stack-consistency check now passes against that exact Container worktree, and the matched enhanced TSan aggregate passes all eleven targets at `b0d45ce7-10a2-416b-bd95-b87de5657115` (18.885 seconds; three executed, eight cached). Required remote checks and lower-PR admission remain open.

`package` builds the four optimized products once and uses pinned `rules_pkg` to assemble the existing `compose/` plugin layout. `bin/compose`, `resources/compose-normalizer` and both `resources/volume-initializer/` executables retain executable permissions; configuration, icon, licence and JSON metadata are read-only package data. Archive ownership and timestamps are normalized. No SwiftPM/Go build subprocess, keychain access, signing, installation or publication occurs.

`resources/build-info.json` preserves the existing version command contract using the declared Makefile version, selected immutable Swift dependency pins, compose-go version and validated enhanced capability inventory (empty in stock). `resources/candidate.json` records all four binary hashes, dependency-lock hashes and the bundled third-party notice hash/counts. The adjacent archive receipt additionally binds the exact compressed archive bytes. Both explicitly say `distributionReady: false` and `licenseClosureComplete: false`: text collection does not establish complete vendored-source/legal closure or signing, and this archive is not a release.

`test-package` checks malformed/wrong-architecture inputs and the real archive inventory, normalized modes, hashes and metadata consistency. It also extracts into isolated SSD scratch, runs the packaged version command and renders a local Compose fixture with the bundled parser. It starts no containers and downloads no images. This proves package assembly and local CLI/parser integration, not runtime parity or Developer ID trust. Debug candidate assembly is refused.

The launcher retains successful `//:candidate_archive` bytes in the internal evidence store. `restore-package` authenticates and restores those bytes to the managed SSD without invoking Bazel or compilers; a repeated restore reuses the identical files. Restore is artifact recovery, not clean-source release admission. A dirty development candidate remains ineligible for release.

Release-note Git fixtures also have a native target, `//Tools/bazel:release_notes_tests`. Their disposable repositories disable automatic Git maintenance before the first commit, preventing detached maintenance from racing cleanup (the CI failure was `Directory not empty: '.git'`). This does not change the user's global Git configuration.

Development package evidence:

| Invocation | Observation |
| --- | --- |
| `c77e2ad9-459a-45d6-a23f-e09da1b49710` | First optimized enhanced archive: 113.993 seconds; retained archive restores repeatedly with SHA-256 `281578c6c3933a2f6425a5aee63f9337e2d08e7172e6078c546a8d69203d675f`. |
| `dbddbd92-5e1c-42fc-a052-35268afb5b5b` | Stock: seven metadata/input cases and both real archive/CLI/parser cases pass; 1.847 seconds. |
| `18aea4b3-0dbe-474a-b534-03cc997da6b9` | Enhanced: the same seven metadata and two archive cases pass; 6.609 seconds, with metadata results cached. |
| `ffd87e8b-cedf-4295-b513-89acedfcf9de` | All 28 release-note cases pass, including fixture-local maintenance configuration; 4.988 seconds. |
| `e88475f7-6666-46d0-8922-7cf07c474e8e` | Negative check: debug candidate assembly is rejected during analysis. |

Earlier smoke invocations `853ffef6-27ea-4189-af4c-e2392c08173c` and `5b3dc751-b74c-48d2-a8fa-538e14c0bb6d` built packages but reran only metadata cases because the wrapper omitted the archive argument. They are not archive-smoke proof. The wrapper now forwards every argument, and a required mode/arity check prevents silent fallback. All listed timings are development observations, not quiet-machine benchmarks or stable-release qualification.

### Dependency notices

`THIRD-PARTY-NOTICES.txt` is collected from the actual four-product dependency graph using `rules_license`, not a second package download or build. Metadata-only Go overlays preserve Gazelle's package identities, versions and PURLs while attaching the upstream root licence/notice texts. The inventory must match every existing `go.mod` module/version and exact reviewed text names; missing, empty, conflicting, unknown or version-mismatched Go notice inputs fail assembly. The same downloaded Go SDK supplies its LICENSE/PATENTS texts.

A small pinned `rules_swift_package_manager` metadata patch retains every root LICENSE/NOTICE/COPYING/PATENTS/COPYRIGHT file instead of just the shortest LICENSE filename. This includes Swift Crypto and NIO SSL's separate NOTICE files. No product source or product dependency version is changed by these overlays. Notice headings are deterministic and omit local machine paths; the final text hash is embedded in candidate identity and checked by the real archive test. Go transitive repositories need no extra direct imports: their texts reach the archive through the real executable graph.

After adding notices, enhanced packaging/smoke checks pass at `8a42abf0-c68f-4c78-b5f5-b26380826551` with 127 texts, 57 Go modules and 35 Swift packages. Stock passes at `5941b7c1-8f9b-4f89-ba75-b26e41fb89fd`; the simplified direct-graph repeat `c0536054-1ea6-4b8f-9b2b-b4dcac8e1eed` reuses both passing tests and packages 125 texts from 57 Go modules and 33 Swift packages. Ten focused metadata/notice cases cover inventory drift, empty/missing texts, version mismatches and deterministic duplication; two archive cases check the real bundle. These are development results, not release approval. The initial omission of Bazel's protobuf notice provenance is retained as a failed assembly and now handled explicitly.

When upgrading Go dependencies, update `licenses/inventory.json` and the corresponding metadata patch/module binding together after inspecting the new source notices. The validator refuses stale versions or missing texts. Complete Swift/vendor inventory review remains open: current validation requires the selected Container/Containerization texts, but does not claim that every nested third-party component's legal obligations have been audited. Do not change `licenseClosureComplete` merely because text collection passes.

#### Embedded BoringSSL texts

Swift Crypto and Swift NIO SSL embed different BoringSSL revisions whose root licences are not retained in their Swift source distributions. The package vendoring metadata identifies those revisions; Swift NIO SSL also references BoringSSL in its NOTICE, whereas Swift Crypto's NOTICE lists other dependencies. Those files do not supply both complete BoringSSL texts. `Tools/bazel/licenses/vendored.json` now binds the checked-in upstream texts and SHA-256 digests to reviewed immutable containing-package revisions. Assembly declares these files as Bazel inputs and makes no extra network request. Missing/duplicate package pins, changed package revisions, malformed revision inventories, missing/duplicate files, changed bytes or inconsistent provenance fail before archive creation. A dependency upgrade requires inspecting the new package's `Sources/CCryptoBoringSSL/hash.txt` or `Sources/CNIOBoringSSL/hash.txt` and reviewing the corresponding upstream licence; do not merely append the new package revision.

| Containing package | Admitted package revisions | Embedded BoringSSL licence |
| --- | --- | --- |
| Swift Crypto, both profiles | `da9d28d69ebe3894b18376c8f2395c2f37b8448f` | [0226f304 licence](https://github.com/google/boringssl/blob/0226f30467f540a3f62ef48d453f93927da199b6/LICENSE) |
| Swift NIO SSL, enhanced / stock | `322f3c2a4a21df31c84ca416bf65ee5e9059e440` / `03827c1a9fdb2b6b00a4e93ede8861520263af8c` | [817ab07e licence](https://github.com/google/boringssl/blob/817ab07ebb53da35afea409ab9328f578492832d/LICENSE) |

The two upstream texts differ and are intentionally not collapsed into one. Candidate metadata records each containing-package revision, embedded revision, source URL and text digest; the archive includes both under distinct deterministic headings. Thirteen package-unit cases pass at `509134b0-62b7-4c5d-9e85-1cd5cd903fb4`. The actual optimized archive and packaged CLI/parser smoke pass two cases per profile: enhanced `cc09dcef-c7d1-4cd5-bd79-e01361a4110e` (5.419 seconds, 129 texts) and stock `79e8758e-6234-4b29-95df-25acdf5721b2` (8.636 seconds, 127 texts). Go module and Swift root-package counts remain unchanged. These are development/cache-reuse observations, not quiet benchmarks. This closes the identified missing BoringSSL root-text issue only; `licenseClosureComplete` and `distributionReady` remain false pending the complete audit and distribution gates.

Remaining cutover gates include closing coverage gaps and sanitizers/leaks, complete dependency licence closure, signed candidate admission/reuse, downloaded-release integration/parity, fault recovery, CI authority and stable publication. Existing workflows remain available until the complete replacement is qualified.

### OpenTelemetry diagnostic redaction

The candidate updates the normalizer's OpenTelemetry `otel`, `metric`, `sdk` and `trace` modules from 1.44.0 to 1.45.0 and aligns the required `go-logr/logr` module at 1.4.4. [GHSA-8wmf-6v46-5gfg](https://github.com/advisories/GHSA-8wmf-6v46-5gfg) describes conditional exposure of exporter endpoint configuration through verbose internal diagnostic logging; the default logger does not emit those messages. This is dependency hardening, not evidence that this project disclosed user credentials. [Upstream 1.45.0](https://github.com/open-telemetry/opentelemetry-go/releases/tag/v1.45.0) supplies the fix. The Go toolchain stays at 1.26.3.

The regression uses a fictional exported endpoint field and checks both batch and simple span processors: marshalled diagnostics must omit configuration while retaining exporter type identity. It opens no network connection and changes no global logger. The SDK is a direct test dependency; production imports are unchanged. Module sums were checked through the official Go checksum database, and licence inventory/overlays move with their module versions. Generated package notices contain the updated module identities. Nested-vendor licence closure and distribution readiness remain false.

| Retained invocation | Evidence |
| --- | --- |
| `48b18657-06c4-49e6-9078-47c5b54aad2f` | Expected red: the regression fails for both processors against the old matched dependency pins; 4.097 seconds. |
| `b6b6c2c9-8756-4580-ada6-739850317df1` | Patched pins: six Go race targets pass, 308 XML cases including subtests; seven package-unit cases also pass. 6.351 seconds, with unchanged targets reused. |
| `eaf39c95-b6d7-4c1d-8c55-54340c404180` | Enhanced optimized archive: both actual archive/CLI/bundled-parser smoke cases pass; 65.401 seconds build/test. |
| `20822660-93a9-4a3f-86fc-248e6626ff46` | Stock optimized archive: both smoke cases pass; 16.565 seconds build/test. |

The initial invocation `79a6cc7d-5dd5-475c-bd23-714de26a3cbc` supplied the nonexistent `go-race` configuration and was rejected before tests. Its incomplete event stream cannot be sealed as normal evidence; raw diagnostics are retained internally as `diagnostics/run.eCW5kw`. The supported native flag is `--@rules_go//go/config:race=true`, already used by `make -f Tools/bazel/Makefile test-go-race`. The preliminary patched run `ecde17e6-f864-446a-af4e-df10a6f20f19` predates the new regression and is not its proof.

All timings above are development observations, not quiet paired benchmarks. No installed runtime or service changed. Dependabot alert 28 is not closed by this draft branch; default-branch promotion and a qualified stable release remain required. README installation, CLI help, compatibility tables, examples, DocC and stable status remain unchanged because this checkpoint alters no public interface or released capability.

### Native CLI/parser contracts

`make -f Tools/bazel/Makefile test-cli BAZEL_PROFILE=stock` (or `enhanced`) now runs both help smoke and `//Tools/bazel:cli_contracts`. The latter consumes the declared CLI and Go normalizer products directly, so compilation finishes before any command's 30-second deadline begins. No `go run`, SwiftPM build, package installation, image pull or runtime service is used. Each case has an isolated SSD home/working directory, a clean environment without a Go toolchain on PATH, and a configured container-command trap that fails if invoked.

The six cases retain every assertion from the existing foreground dry-run attachment contract, verify config interpolation/dependency data and required-variable errors, reject a missing declared parser, prove timeout cleanup across the parser's separate process group, and preserve nonzero exit status. The config assertion checks the implementation's current internal JSON model (`dependsOn`); it is not Docker Compose schema or live parity qualification. Each case retains its own monotonic JUnit duration. These are development timings, not quiet paired benchmarks.

Timeout cleanup is explicitly scoped to the declared CLI/parser's isolated process session, including separate process groups. It rechecks session membership before signals and verifies session absence; it does not claim to contain arbitrary descendants that create new sessions. Unverified cleanup preserves private scratch. Numbered stdout/stderr files survive exceptional returns for diagnosis. The timeout regression creates a distinct-group child and checks it is gone while an unrelated session remains untouched. This does not establish crash recovery for live container services.

Final-source six-case validation passes stock at `e8c6c430-4945-4b63-9ab5-3570611f39f2` (3.837 seconds build/test) and enhanced at `fe5e5009-d1da-40eb-b192-0ce13f519106` (9.947 seconds including profile analysis/cache changes). Independent final review is clean; shell syntax, ShellCheck and help checks pass. The initial development run `13596831-b28c-4119-b27f-3057fc3315ce` retains two incorrect new-test assumptions: the current config output uses `dependsOn`, and a missing executable reports errno without its path. The original foreground assertions already passed in that run; neither their 30-second bound nor their expected attachment behavior was relaxed.

The legacy hosted stock job `105492819266` in run `35310984659` remains a recorded failure: its foreground dry-run command timed out after 30 seconds while loading the Compose model. Other parser tests took about 93 seconds, and the source-checkout fallback can invoke Go compilation inside the command deadline. This motivates separating build and execution; it is not a conclusive diagnosis of that hosted delay. The native gate is not yet the authoritative CI replacement, so its passes do not relabel the old job or complete the overall migration.
