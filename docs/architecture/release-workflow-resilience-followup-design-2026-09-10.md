# Follow-up review and implementation design: recoverable Container-family builds

Date: 2026-09-10. Status: implemented on `release-workflow-resilience`; quiet-machine performance measurements remain deliberately deferred.

Reviewed checkout: `/Volumes/SSD/github/container-compose-release-0.14.3`, branch `release-workflow-resilience`, HEAD `acb46f59ac958136f4dae391e7fade5ff72129a7`. Review covers the changes in `8861c73b` and `acb46f59`, their callers, build/cleanup paths, release publication, DocC, checkpointing, and recovery inspection. Product version remains **0.14.3**.

## Decision

Do not yet treat the previous resilience implementation as fully recoverable, cleanup-safe, or sufficient to eliminate redundant work. The content-addressed store, atomic records, exact-byte checks, shared formula validator, and non-deleting Current finalization are useful foundations. Several guarantees, however, stop at a helper API rather than holding across the complete workflow.

This review identifies twelve findings: eight P1 correctness/recovery issues and four P2 recovery/efficiency issues. Eight isolated probe scenarios produced direct evidence; other findings are traced through callers and consumers. No native build, runtime/parity test, benchmark, production dispatch, release mutation, tap update, or Pages deployment was performed.

The previous document's implementation-status assertions about symlink-safe cleanup, complete checkout relocation, dispatch reconciliation, independent DocC retention, and universal storage separation were stronger than the implementation supported. This review supersedes those assertions, not the historical record of what was changed.

## Implementation record

The follow-up implementation closes R01–R12 through the shared storage
initializer, descriptor-relative cleanup, no-follow content acquisition,
repairable retained objects, source-independent product receipts, immutable
input indexes, output-manifest dependency identity, complete Compose package
materialization, output-aware validation checkpoints, atomic logical dispatch
claims and request-ID reconciliation, retained gate/package authority, resumable
exact-byte stable drafts, context-bound independently retained DocC sites, and
bounded typed release observation. Recovery inspection now proves the latest
stable formula bodies against the retained archive URLs and digests, and binds
the active Pages deployment to a successful exact-version Documentation run;
superseded versions are classified explicitly. Normal validation fingerprints
no longer execute Docker applications; Docker remains confined to explicit
oracle lanes.

The 0.15.0 integration extends the retained Compose product closure with both
Docker-free Linux volume-initializer executables. Their build outputs,
content-addressed objects, receipt members, checkpoint requirements,
materialization paths, executable modes, package verification, and archive
members are one contract. An interrupted SwiftPM editable session that cannot
be resolved during `unedit` is atomically quarantined beside its external build
workspace, preserving its evidence while restoring a clean canonical scratch
path and the original dependency lock.

For local/self-hosted work, build workspaces, compiler temporary directories,
downloads, and runner work are required to resolve beneath `/Volumes/SSD`.
Retained products, manifests, journals, locks, authority and publication inputs
are required to remain on the internal disk. GitHub-hosted workers are the
documented remote exception: their outputs do not become locally recoverable
authority until imported into the internal retained store.

The native stack's `container` receipt is validation evidence for the Container
CLI product, not a claim that one executable is the complete installed runtime.
The complete signed Container runtime archive and sidecar are retained by the
stable package closure; its helpers, resources, service images and manifests
remain governed by Container's own packaging manifest. Building those service
images is not added to the normal Compose stack path because it would invoke a
Docker application, contrary to this programme's boundary.

No elapsed-time speedup is claimed here. Deterministic work-count regressions
prove reuse without running a benchmark on a busy machine; the quiet-machine
protocol below remains the required follow-up before publishing timing results.

## Requirements and boundaries

- Keep disposable checkouts, worktrees, compiler scratch, temporary archives, downloads, runner work, and runtime fixtures on the external `/Volumes/SSD`.
- Keep everything required for recovery on the internal disk: complete usable products, signed distribution archives, source-recovery objects, immutable dependency locks, success/failure evidence, publication authority, manifests, journals, and deliberately retained acceleration caches.
- Workspace and branch cleanup must never select retained objects. Removing the SSD must not prevent local verification of already retained products.
- Do not rebuild or rerun tests merely to recover packaging, publication, a formula, or a documentation deployment when exact valid inputs and results exist.
- Keep existing OSS Docker Go libraries. Normal native/static/release-control paths must not invoke Docker applications. An explicitly selected parity/benchmark oracle is a separate lane.
- Performance comparisons require an agreed quiet-machine window. Work-count assertions can be tested now without timing a build.
- Production recovery drills remain separately authorized operations; this implementation used local fixtures only.

## Prioritized findings

P1 means fix before relying on the claimed recovery/cleanup guarantee. P2 means a remaining functional or efficiency gap to address in the same follow-up programme.

| ID | Priority | Finding | Evidence |
| --- | --- | --- | --- |
| R01 | P1 | Cleanup can escape after a directory-to-symlink replacement | Deterministic fault injection |
| R02 | P1 | Storage policy is not enforced throughout the path and command tree | Promotion escape reproduced; root/environment callers traced |
| R03 | P1 | Dependent retained receipts still require old source locations | Relocation failure reproduced |
| R04 | P1 | Native retained pins are not complete runnable/packageable products | Build and package consumers traced |
| R05 | P1 | Production checkpoints can reuse success after products are deleted | Wrapper failure reproduced; production wiring traced |
| R06 | P1 | Dispatch journals do not prevent ambiguous duplicate requests | Two POSTs/two UUIDs reproduced with a fake remote |
| R07 | P1 | Publication recovery still has a retention/authority handoff gap | Workflow and controller paths traced |
| R08 | P1 | Exact retained-object repair fails; import can commit an inconsistent digest | Both failures reproduced |
| R09 | P2 | DocC recovery couples sites and lacks durable source-context binding | Retention, cache, manifest, and retry paths traced |
| R10 | P2 | Broad/repeated fingerprints invalidate unrelated work and probe Docker | Make and validation fingerprint paths traced |
| R11 | P2 | Single mutable pin slots and separate producer builds limit reuse | Receipt identity, pin paths, and build graph traced |
| R12 | P2 | Recovery plans omit important remote state and have unbounded reads | Incomplete/malformed remote fixtures plus code trace |

### R01: cleanup safety does not survive path replacement

Location: `Tools/build/stack-transient-clean.py:50`; wrapper lock at `Makefile:522`.

`remove_tree` checks a pathname with `lstat`, then scans the same pathname. Replacing that directory with a symlink between those operations makes the scan and child unlink operations follow the replacement. The probe deleted a sentinel outside the selected tree, then returned `NotADirectoryError`. Reporting failure after deletion is not containment.

The Make wrapper's cooperative lock helps only when every writer uses that exact lock. The cleanup CLI itself takes no lock, and the lock location changes with the transient root. Static symlink fixtures do not cover this race.

Required result: cleanup must remain contained under concurrent rename/replacement and must not depend solely on all other processes behaving correctly. An unexpected device, link, ownership change, or active lease must stop deletion before it reaches unrelated data.

### R02: separate default roots are not an enforced lifetime policy

Locations: `Makefile:419`, `Makefile:238`, `Tools/build/stack-artifact.py:87`, `Tools/build/stack-artifact.py:99`, `scripts/CONTAINER_STACK_RELEASE.sh:270`, `.github/workflows/docs.yml:218`.

The Make initializer checks that two roots have different device IDs, not that transient storage is on the approved SSD and retained storage is internal. It creates/marks roots before completing overlap/device checks. Managed children may resolve beneath either root instead of their assigned lifetime root. Direct-leaf symlink checks do not validate ancestors.

The promoter follows an existing `objects` directory symlink. The probe successfully returned an object path whose resolved location was outside its purported retained root. With both incoming and object directories redirected, the default separation is not a sufficient safeguard. The probe demonstrates path escape on one fixture filesystem, not a cross-volume crash test.

Native stack recipes set Swift scratch paths but do not centrally set `TMPDIR`/`GOTMPDIR`; therefore they cannot guarantee where subprocess temporaries land. The release transaction sets `TMPDIR` later, but that does not cover standalone native commands. DocC generation also still selects a hosted macOS runner; no technical exception to the local-MBP policy was established by this review.

Required result: validate the volume and the full managed path chain before writes; route every entry point through one storage/environment contract. An absent SSD must fail without creating a replacement `/Volumes/SSD` tree on the internal disk.

### R03: source-independent verification and recursive relocation are missing

Locations: `Tools/build/stack-pin.py:610`, `Tools/build/stack-pin.py:659`, `Tools/build/stack-pin.py:678`, `Tools/build/stack-pin.py:773`.

A caller can supply a replacement checkout for the top receipt. Recursive dependencies still use each receipt's recorded source path. Bundle creation and verification also call the source-dependent verifier without a repository-location map.

The probe moved a clean parent and dependency without changing their Git contents. Explicitly verifying the relocated leaf succeeded. Verifying the relocated parent failed because its dependency lookup used the removed location. Verifying retained bytes without a checkout also failed. This contradicts the intended cleanup and SSD-offline recovery contract.

Required result: separate artifact/receipt verification from verification of a newly supplied source checkout. Recursive dependencies must be resolved by immutable identity, not absolute historical paths.

### R04: the retained native stack is not a deployable closure

Locations: `Makefile:555` through `Makefile:726`, `Makefile:2377`, `Sources/ComposeCore/ComposeNormalizer.swift:235`.

Native stages promote individual executables, including only `compose` for Compose. The packaging target instead needs a specific layout containing the Go normalizer, configuration, icon, build metadata, and the Compose executable from `.build/<configuration>`. It does not consume the retained pin as a package input.

The normalizer locator uses an explicit override, installed resources, or a source-checkout Go fallback. A retained standalone Compose executable cannot rely on that fallback after the checkout is removed. The existing stack graph does not build/retain the normalizer as part of this closure. Likewise, a single Container CLI is not by itself proof of a complete installed runtime; its distribution manifest must define the required helpers and resources.

Required result: retain a verified installation/package closure with logical member names and relative layout, not a collection of convenient executable probes. Packaging must consume that closure without rebuilding or depending on source-tree paths.

### R05: output-aware checkpoint support is unused by production callers

Locations: `Tools/ci/run-release-checkpoint.py:53`, `Tools/ci/run-release-checkpoint.py:397`, `Tools/ci/run-stack-release-validation.sh:548`, `Tools/ci/run-stack-release-validation.sh:590`.

The new `--required-output` option is used in its tests but not by production Make/workflow/controller callers. The sibling validator independently maintains input-only `.sha256` success stamps. It checkpoints producer targets such as build, docs, dSYM, and coverage as well as pure checks.

The probe ran a producer through the wrapper using the current output-free calling convention, deleted its product, then retried. The wrapper returned success and reported reuse while the product remained absent. This does not mean all check-only stamps are invalid; it means producer reuse lacks the postcondition it needs.

Required result: make output/evidence declarations mandatory for each producer stage and wire the same evaluator through the sibling validator. Logs cannot substitute for generated products or reusable test evidence.

### R06: a durable intent is not yet a reconciled operation

Locations: `scripts/CONTAINER_STACK_RELEASE.sh:6080`, `scripts/CONTAINER_STACK_RELEASE.sh:6125`, `Tools/release/release-dispatch-journal.py:63`, workflow `run-name` declarations at line 18.

Every dispatch call generates a new UUID and writes a new intent. No dispatch/resume path first searches the journal for an unresolved operation. Workflow run names omit the UUID; historical reuse searches only the latest 100 runs by title/control SHA. Journals also omit operation mode such as tap repair from their durable identity.

The fake remote accepted the first conceptual request but returned a timeout. A second invocation made another POST with a different UUID. The store then contained both `dispatch-unknown` and `dispatched` records. The inspector's warning is not enforced by the executor.

The API version/response field is not a finding: GitHub's 2026-03-10 dispatch contract documents a successful response with `workflow_run_id`. Keep that exact-run binding; add recovery when the response is lost. [GitHub workflow dispatch API](https://docs.github.com/en/rest/actions/workflows?apiVersion=2026-03-10#create-a-workflow-dispatch-event).

Required result: reconcile a stable logical operation before any new POST. Unknown does not mean failed or absent, and exhausting a run-list page is not proof that no run exists.

### R07: durable retention is not a prerequisite for publication

Locations: `.github/workflows/prebuilt-binaries.yml:1165`, `.github/workflows/prebuilt-binaries.yml:1713`, `scripts/CONTAINER_STACK_RELEASE.sh:6542`, `scripts/CONTAINER_STACK_RELEASE.sh:6932`, `Tools/release/publish-github-release.sh:137`, `Tools/release/publish-github-release.sh:199`.

The package workflow produces assets in runner temporary storage and publishes them without importing them into the internal retained store. The controller retains downloaded package assets later during verification. A manually dispatched workflow does not necessarily execute that controller step. Therefore the guarantee currently depends on an after-publication controller handoff.

The stable gate reuse path accepts a successful run without proving that its required output closure remains available. Fresh packaging requires a non-expired Actions artifact and downloads it. A successful old gate plus an expired authority artifact can thus be repeatedly selected while packaging remains unable to proceed. The published-authority fallback helps already published releases, not every pre-publication recovery state.

The stable publisher also rejects any existing release record without distinguishing a resumable matching draft from a published immutable release. GitHub CLI's documented asset-create sequence uses draft, upload, then publish; this review does not claim that `gh release create` necessarily exposes partial public assets. The gap is the repository's inability to reconcile a matching intermediate draft and the missing local durability barrier. [GitHub CLI release creation implementation](https://github.com/cli/cli/blob/trunk/pkg/cmd/release/create/create.go).

Required result: durably retain and authenticate gate authority and the complete package before publication. Make draft recovery explicit and exact-byte-only. Preserve stable immutability and the existing non-deleting Current behavior.

### R08: object acquisition needs repair and single-pass identity

Locations: `Tools/release/retain-local-release-assets.py:98`, `Tools/release/retain-local-release-assets.py:117`, `Tools/build/stack-artifact.py:127`.

When a manifest record exists with the right digest but its object is missing/corrupt, `retain` verifies the broken object and fails instead of restoring it from the exact candidate. The first probe removed only a fixture object and supplied its unchanged source bytes; repair failed.

The importer also hashes a candidate, then asks the promoter to independently read/hash it again, but records the first digest. The second probe changed the candidate between those reads. Retention returned success with a manifest that immediately failed verification. This is a deterministic race injection, not an assertion that a production candidate was observed changing.

Required result: record the identity of the bytes actually installed; distinguish an immutable logical asset identity from the repairable physical copy storing those bytes. A conflicting digest must still stop the operation.

### R09: DocC retains neither independent recovery progress nor source context

Locations: `scripts/CONTAINER_STACK_RELEASE.sh:6974`, `scripts/CONTAINER_STACK_RELEASE.sh:7025`, `.github/workflows/docs.yml:289`, `.github/workflows/docs.yml:396`, `Tools/ci/doc-site-manifest.py:90`.

The controller returns early only when all four local site archives exist, otherwise downloads all four and imports them together after workflow success. A successful site in an otherwise failed workflow is not independently retained by this path. A previously successful run with expired archives and missing local copies is selected again; recovery retries its unavailable download instead of planning only missing site generation.

The manifest proves file-list/content consistency but carries no repository, source SHA, site identity, hosting base path, toolchain, or generator contract. The hosted cache key supplies some context, but the retained archive verifier does not bind those semantics. Stable local names are only version plus site. A valid, self-consistent archive is not proof that it belongs to the requested site/source.

Required result: retain each successful site under an exact semantic context before assembling Pages. Rebuild only missing/invalid sites; retry deployment independently from generation.

### R10: stage keys are overbroad and fingerprint acquisition is repeated

Locations: `Makefile:238`, `Makefile:255`, `Tools/ci/run-stack-release-validation.sh:300`, `Tools/ci/run-stack-release-validation.sh:417`.

Swift and Go contracts hash broad shared Make sections. The recursive `$(shell ...)` variables are evaluated at multiple references. The sibling validator puts a shared environment/tool catalogue in every stage's fingerprint and rechecks broad identities at stage boundaries. Independent Make invocations also prevent a single Make traversal from sharing common prerequisites.

The shared catalogue explicitly executes `docker buildx version` and `docker compose version`, including when computing non-oracle validation fingerprints. Failures are tolerated, so this is not proof Docker is a required installed dependency; it is still an unnecessary Docker-application invocation in a normal path.

Required result: declare each stage's semantic input closure and relevant tools. Acquire an immutable observation once per run, then cheaply detect relevant mutation at boundaries. Do not weaken runtime/parity evidence merely to increase reuse.

### R11: retained lookup and build graph do not fully support cross-attempt reuse

Locations: `Makefile:227`, `Makefile:546`, `Tools/build/stack-pin.py:174`, `Tools/build/stack-pin.py:755`.

Pins use one mutable slot per repository/configuration. Building source A, then B, replaces the lookup for A even if A's object bytes remain retained. There is no input-key index to find the old receipt. Receipt hashes also include source location, completion time, and duration; dependencies key on those whole receipt hashes. Reissuing equivalent evidence can therefore invalidate consumers even when product semantics/bytes are unchanged.

The native stages use separate SwiftPM scratch roots. Downstream stages receive source package paths and receipt checks, not reusable binary library products. The graph orders and records builds, but must not be described as sharing compiled dependencies across those separate invocations. Actual compiler duplication was not measured.

Required result: separate semantic build identity, immutable output identity, and attempt evidence; retain multiple indexed results. Plan shared compatible build/test prerequisites once. Do not attempt unsafe cross-toolchain or arbitrary Swift module-cache sharing.

### R12: the inspector does not yet compute a complete recovery plan

Locations: `Tools/release/release-state.py:115`, `Tools/release/release-state.py:154`, `Tools/release/release-state.py:216`.

The next action is selected mainly from local missing assets and unresolved requests. It does not reconcile expected versus actual remote asset members/digests, does not verify formula/Pages state, and does not make failed acknowledged runs into explicit stage failure states. Both remote subprocess paths lack a timeout.

With all local assets present and a remote release reporting no assets, the probe recommended formula/Pages verification rather than restoring the missing remote members. A remote response with `assets: null` raised an uncaught `TypeError`. The tool also reloads the same local manifest for each member and deeply hashes payloads during ordinary status.

Required result: a bounded, typed observer must feed the same pure planner used by resume. Unknown/unavailable observations must remain distinct from absent, valid, and conflicting state.

## Target design

### A. One storage and lease contract

Extend the existing tools with a small shared Python storage module; do not create another independent cleanup/import framework. It should own path validation, root-role checks, object access, lock ordering, and atomic record replacement.

| Data class | Canonical location | Cleanup policy |
| --- | --- | --- |
| Active source/worktrees and build attempts | External SSD managed roots | Disposable only after source/evidence closure is retained |
| Compiler scratch, temporary files, downloads, test/runtime fixtures | External per-attempt directories | Lease-protected; recoverable quarantine before deletion |
| Complete product objects and signed package archives | Internal retained object store | Never included in transient cleanup |
| Source bundles/mirrors, locks, provenance, receipts, test logs, DocC sites | Internal retained namespaces | Explicit retention owner and reachability policy |
| Reusable compiler/module/download acceleration cache | Internal, explicitly retained and toolchain-keyed | Separate opt-in cache GC; never claimed as authoritative evidence |
| Writer leases, journals, release state, cleanup manifests | Internal retained control namespace | Survive SSD disappearance and process restart |

Configuration records approved retained volume identity, SSD volume identity, canonical roots, roles, and schema. Validate mounts using macOS mount/disk metadata and device identities; a different device ID alone is insufficient. Reject symlink/reparse-like ancestors, overlap, root aliases, wrong device, special files, and unmarked non-empty targets before creating children. Recheck at mutation boundaries. Existing marker text is supporting ownership evidence, not authorization to delete arbitrary paths.

Export scoped `TMPDIR`, `TMP`, `TEMP`, `GOTMPDIR`, Swift scratch, runtime roots, and runner working directories from one launcher. Do not repurpose `HOME` or `CODEX_HOME`. Distinguish retained acceleration caches from disposable compiler scratch. Scope enforcement to build/test/release processes; unrelated macOS application temporaries are not under this workflow's control.

Put locks under the retained control namespace, keyed by store/operation identity, not a configurable transient path. Fixed acquisition order: store mutation coordination, logical operation, then object/manifest lock. Use OS-held locks for live ownership and records with PID/start identity for diagnosis; do not treat a stale PID file as ownership. Independent objects/stages may proceed concurrently when their declared resources do not conflict.

Cleanup protocol:

1. Validate the mounted SSD, marker, target allowlist, active leases, and retained closure.
2. Write a retained plan with exact target identity, owner, reason, device/inode, and retention preconditions.
3. Acquire the shared cleanup/build lease and revalidate identities.
4. Rename each eligible disposable tree into a same-volume managed quarantine, retaining the rename result.
5. Delete using directory descriptors and no-follow relative operations, or a platform primitive whose symlink-attack resistance is checked at startup. A pathname `lstat` followed by pathname recursion is not sufficient.
6. Stop on mount/identity change; report partial completion precisely. Leave retained data untouched.

The deletion primitive itself must resist the R01 injected replacement even if a writer ignores the cooperative lease. Quarantine is recoverable until explicitly purged; distinguish disposal from irreversible purge in operator output.

### B. Identity model: inputs, outputs, evidence, locations

Keep these concepts separate:

- `input_key`: hash of schema, product/stage, source identities, dependency input/output contracts, configuration, architecture/SDK/toolchain, relevant environment, and the producing recipe contract.
- `output_manifest_digest`: hash of canonical logical members, file digests, size, executable mode, layout, and required package/signature metadata.
- `attempt_id`: unique execution record with start/end, duration, logs, exit state, host, and observed resource conditions.
- Source/build paths: optional diagnostic locators; never required to verify retained content.
- `authority`: independently verified provenance/approval binding. A self-hashed JSON file supplies integrity, not authenticity.

Store immutable receipts by identity and index `product/configuration/input_key` to valid output manifests. Keep optional `latest` pointers for convenience only. Preserve historical indexes until explicit reachability GC says they are unowned. A receipt repair or location change must not alter downstream semantic identity.

Provide separate operations:

- `verify-retained`: verify retained closure and provenance without a checkout or SSD.
- `match-source`: compare a supplied clean checkout to its expected source identity.
- `materialize`: produce a transient runnable/package layout from retained objects.
- `plan-build`: reuse an exact retained product or select missing producers.
- `verify-stack`: resolve dependency manifests recursively by digest with cycle, duplicate, and schema checks.

Record source bundle reachability before deleting a unique workspace or branch. Retaining a branch name is unnecessary if the exact source objects and metadata remain reachable; deleting the only reachable source representation is not authorized merely because binaries exist.

### C. Complete product closure and repairable acquisition

Define manifests from actual install/package consumers. Compose's minimum closure includes its executable, normalizer executable, `config.toml`, icon, and exact build metadata. Container and supporting products must enumerate required helpers, configuration, resources, guest/image references, and symbols if those are retained deliverables. Do not claim an arbitrary CLI subset is a full runtime.

Retain final signed distribution archives byte-for-byte. For an unpacked runnable product, preserve its required relative layout and validated metadata. Sign a derived staging copy, never mutate a shared immutable unsigned object. Cross-attempt signature/archive identity may differ even for equivalent source; once bound to a stable release, exact published bytes are the authority.

Acquisition protocol:

1. Lock the logical asset/manifest mutation and validate the expected digest/provenance, if one exists.
2. Open a regular source without following links; copy/hash one stream into an internal incoming object.
3. Record the digest, size, and normalized intended mode of the actual copied bytes. Reject a changing candidate when its before/after identity fails the import contract.
4. Compare against expected authority; install with no-clobber semantics and verify any concurrent winner.
5. Flush data and required directory/record updates before committing the manifest pointer.
6. If an existing logical member has matching identity but missing bytes, reinstall the exact object. If corrupt bytes occupy its immutable path, quarantine under an exclusive repair lock, install the expected bytes, verify, and record repair evidence.
7. A different digest for the same stable logical member is a conflict, never a clobber or implicit rebuild.

Successful import must imply that immediate verification succeeds. Disk full, permission failure, process death, or an unmounted source must leave either the old valid manifest or a recoverable pending import, never a success pointing at inconsistent bytes.

### D. Output-aware execution graph

Use a shared stage declaration consumed by Make, the checkpoint wrapper, and sibling validation. Extend existing orchestration incrementally; avoid a wholesale rewrite of the release controller.

Each stage declares ID, relevant inputs, dependencies, products/evidence, validator, side effects, resource class, and retry policy. Separate pure checks from producers and publication operations.

A stage is reusable only when input identity matches, its required output/evidence closure verifies, and its environment-sensitive policy permits reuse. Missing materialized scratch with valid retained output calls `materialize`, not `build`. Missing/corrupt evidence reruns only the stage whose proof is unavailable. A downstream consumer cannot manufacture success from a producer's surviving log.

Generate one build/test plan per coherent input snapshot. Merge identical prerequisites. Recheck relevant immutable heads/tool identities before a stage and before recording success; if another task changes a dependency, invalidate that dependent subgraph, not unrelated results.

Do not unconditionally memoize mutable observations across attempts. Cache immutable content by digest; use inexpensive metadata only to decide whether deeper identity validation is required. Full verification remains available before publication/cleanup. Restrict Docker fingerprints and invocations to explicit oracle stages.

### E. Dispatch and publication reconciliation

Logical operation identity is a hash of repository, workflow, workflow control SHA, candidate/release identity, full normalized inputs, and mode (package, tap repair, gate, docs, and so on). Reuse a retained operation record across controller restarts.

Dispatch states: `planned -> intent -> acknowledged -> observing -> verified`, with explicit `unknown`, `failed`, `cancelled`, and `conflict` branches. A new attempt is not automatically a new logical operation.

Before dispatch, lock and reconcile the operation. If acknowledged, inspect that exact run. If unknown, search paginated/time-bounded observations using the recorded request ID and validate repository, workflow, event, control SHA, and candidate. Put the request ID in the run name and an early machine-readable acknowledgement. Retain the remote run binding when it becomes known.

A bounded search that cannot prove acceptance or absence leaves the operation unknown and blocks another expensive dispatch. Do not promise exactly-once delivery from client journaling alone. Add an entry-point idempotency guard where duplicate deliveries could reach side effects. Genuine failure can create an explicit new attempt linked to the prior one; lost responses cannot.

GitHub concurrency controls schedule contention but are not the durable operation journal or business postcondition. Continue verifying actual candidate ownership and outputs. [GitHub concurrency documentation](https://docs.github.com/en/actions/how-tos/write-workflows/choose-when-workflows-run/control-workflow-concurrency).

Publication sequence:

1. Verify and retain gate authority, supporting logs, source identities, and guest/image closure as soon as the gate produces them.
2. Build/sign/package only missing product nodes; verify and retain the complete release manifest locally.
3. Record `retained-complete` before allowing remote publication, regardless of whether initiation was manual, scheduled, or controller-driven.
4. Create or reconcile a matching draft by exact tag/candidate/manifest identity. Upload only absent exact members; conflicting bytes stop.
5. Re-read the remote draft and required asset bindings; publish only when complete. A lost response triggers observation, not recreation.
6. Reconcile the formula pair and Pages separately with candidate-bound postconditions.
7. Retain final remote identities and evidence; then permit transient cleanup.

Already published stable assets remain immutable. If platform settings forbid adding a missing member, surface a precise blocker rather than weakening that policy. Do not delete/recreate Current; preserve the existing availability-safe behavior. A complete retained gate can be reused after hosted expiration only when its authenticated authority is sufficient under the release policy. Missing authority is not license to trust a local checksum or silently rebuild a different stable artifact.

### F. Independent DocC generation and deployment

Introduce a context-bearing site manifest with site, repository/source SHA, documentation dependency refs, toolchain/generator contract, hosting base path, complete member digests, and output-manifest digest. Verify expected context at every cache restore, local import, assembly, and deployment boundary.

Retain each site's successful archive immediately, independent of sibling outcome. Keep a source/toolchain input-key index and a release-to-site-manifest mapping. Preserve the exact first accepted archive; if regeneration is needed, normalize archive ordering/metadata where safe and distinguish semantic site identity from gzip byte identity.

Plan site generation, Pages assembly, and deployment as separate nodes. An expired hosted archive first falls back to internal retained bytes. If those bytes are genuinely missing and documentation regeneration is authorized, schedule only that site at its pinned source context. Do not repeatedly select the same expired run as an executable recovery plan.

Keep destination serialization and latest-stable ownership rechecks. An old release may retain its docs without being allowed to overwrite the current Pages destination. Run DocC generation on the local self-hosted Mac by default; keep only unavoidable GitHub Pages service operations hosted, with a documented exception for any required hosted compute.

### G. One bounded observer and pure recovery planner

Represent observations as typed states: absent, valid, incomplete, conflicting, unknown, unavailable, running, failed, and stale. Include evidence source, identity, verification depth, and observation time.

Read local manifests once per snapshot. Ordinary status may use previous integrity observations but must label their age/depth; `--verify` performs bounded deep checks. Never present cached integrity as fresh cryptographic verification.

Use bounded API calls and pagination; catch malformed top-level/member shapes. Permission/transport errors are not absence. Query candidate-bound remote asset inventory/digests, exact workflow runs, formula pair, and Pages deployment ownership where the requested plan requires them.

The pure planner takes observations and produces action records with prerequisites, reason, side effects, required authority, and invalidated descendants. The executor consumes this plan only under the normal execute boundary and revalidates before mutations. Inspection itself performs no build, dispatch, upload, cleanup, or large archive download.

## Implementation sequence

Keep one active vertical contract at a time. Each implementation commit should include its affected regression tests and concise operator documentation. Do not dispatch releases as an incidental validation step.

| Slice | End-to-end contract | Primary changes | Findings |
| --- | --- | --- | --- |
| 1 | Storage safety and exact object repair | Shared storage/lease utilities; promoter/importer; cleaner; Make entry points | R01, R02, R08 |
| 2 | Checkout-independent usable product recovery | Receipt schema/index; full product manifests; materialization; package consumers | R03, R04, R11 |
| 3 | Correct minimal stage reuse | Stage declarations; output-aware wrapper/sibling validator; scoped fingerprints | R05, R10 |
| 4 | Interruption-safe release transaction | Operation journal/reconciler; gate retention; package durability barrier; draft handling; observer/planner | R06, R07, R12 |
| 5 | Independent documentation recovery | Context manifest; per-site retention; local generation; assembly/deploy plan | R09 |
| 6 | Integrated migration and fault rehearsal | Import/report tooling; recovery fixture; coherent checkpoint validation | All |

Do not begin cross-stage performance tuning before storage and identity correctness are established. In Slice 2, preserve standalone developer targets while making their consumers use explicit retained products; avoid a flag day across all sibling repositories.

## Acceptance and fault-injection matrix

Tests must assert work counts and terminal state, not merely exit success or the presence of an error string.

| Scenario | Required outcome |
| --- | --- |
| SSD absent at command start | Build/cleanup fails before scratch creation; internal retained verification still works |
| Wrong-device or nested/ancestor-symlink root | No marker claiming, promotion, or deletion outside approved roots |
| Directory replaced during cleanup | Outside sentinel survives; operation stops or safely cleans only the opened target |
| Two workspaces share a retained store | No manifest lost update, pin overwrite race, or duplicate build for the same locked input |
| Source checkouts moved or removed | Retained dependency closure verifies; exact product materializes without historical paths |
| Compose source removed | Retained layout supports version/config smoke test without Go source fallback or Docker |
| Retained object missing/corrupt; exact copy available | Repair succeeds without build/sign/test; different bytes remain a conflict |
| Candidate changes during import | No success manifest contains a digest different from installed bytes |
| Kill/disk-full at each promotion/manifest boundary | Old valid state or explicit recoverable pending state; never false success |
| Producer scratch removed after checkpoint | Restore from retained product or rerun only missing producer; consumer sees valid output |
| Run A, B, then A again | Find A's valid indexed product; no unnecessary A rebuild |
| Response lost after accepted dispatch | Reconcile same operation/run; zero blind second POSTs |
| Controller dies after gate, signing, or upload | Resume from authenticated retained closure; zero repeated valid builds/tests/signing |
| Matching partial draft | Upload only missing exact members; published stable bytes never replaced |
| Hosted gate or site artifact expires | Use valid retained authority/site; otherwise explicit missing-node plan or authority blocker |
| One of four DocC sites fails | Retain three successes; retry only the failed site; deploy without regenerating valid sites |
| Self-consistent site from wrong source/base path | Reject despite valid file hashes |
| Remote unavailable/malformed/incomplete | Bounded typed observation and correct action/blocker, not false absence/completion |
| Unrelated tool/formatting change | Only stages whose declared inputs changed invalidate |
| Oracle disabled | Zero Docker application invocations, including version probes |

Use subprocess counters, deterministic filesystem hooks, and a stateful fake GitHub service for ordinary development. Add a non-production platform rehearsal only with authorization; local fakes do not prove GitHub queue timing, permissions, draft/immutability configuration, attestation availability, or Pages deployment behavior.

Aim for at least 90% focused line coverage of materially changed Python/controller boundaries, with meaningful branch/fault assertions and explicit exceptions. Do not manufacture coverage by testing only serialization or implementation strings.

## Performance design and quiet-machine protocol

No speedup or benchmark timing is claimed by this review. First enforce deterministic budgets:

- Warm unchanged resume: zero native builds, tests, signing operations, and new dispatches for already verified operations.
- Deleted materialization with retained closure: zero compilation; copy/verify only.
- Formula-only recovery: zero build/test/sign; at most one effective conflict-checked formula commit.
- One invalid site: one site generation, zero sibling generation.
- A single producer change: rebuild/retest only its justified transitive closure.
- Repeated status: one local manifest parse per snapshot; no implicit payload downloads.
- One run observation: avoid repeated full tool-catalog hashing for independent stages with the same immutable observation.

Then coordinate a quiet-machine window with the other task. Record exact source/toolchain/product identities, active runners/builds/VMs, host load/thermal context, cache state, and the agreed noise threshold. Acquire an exclusive performance lease; do not stop another task or user process without authorization. Recheck noise during samples and reject contaminated comparisons.

Compare cold, warm, one-component-change, failed-stage resume, source-relocation recovery, and docs-only retry using matched inputs. Report medians/spread and separate queue time, compilation, hashing, copying, signing, testing, and publication latency. Set numerical speedup targets only after a credible baseline; do not use the durations of these review probes as performance evidence.

## Migration, rollout, and rollback

1. Inventory current retained objects, old pin slots, release/source bundles, and SSD attempts without deletion. Record owner, identity, recovery role, and terminal condition.
2. Preserve old receipts read-only. Import verified objects into new manifests/indexes; do not infer missing output closure or authenticity from legacy success stamps.
3. Mark incomplete legacy products as diagnostic/partial, not runnable or publication-ready. Locate exact missing members from authenticated existing sources before considering a rebuild.
4. Run the new planner in read-only shadow mode, compare decisions against fixture expectations, and enable storage safety before enabling broader reuse.
5. Perform a relocation/disposal drill on dedicated fixtures. Any real cleanup requires verified internal retained closure and the normal explicit scope.
6. At the integrated immutable checkpoint, run affected focused suites, shell/YAML/Markdown/static checks, then one justified broad validation. Re-run broad gates only when evidence inputs change.
7. Keep rollback able to disable new reuse while preserving retained objects and stable immutability. Never roll back by deleting retained state or reinstating unsafe cleanup.
8. Correct the prior implementation-status claims and build/operator help when fixes actually meet the matrix.

The internal drive is the requested authoritative retained location, not a complete disaster-recovery strategy for internal-disk loss. A second authenticated replica is an optional operational decision; do not silently create new remote storage, upload artifacts, or delete the only internal copy.

## Coordination and integration inputs

The other task reported the following pending product work. These are coordination inputs, not claims that the PRs are merged or independently verified here:

- Compose PR 632, `fcccb9fd`: stock profile/lock, Engine Unix client, and CI lane.
- Engine API PR 41, `276a7cfd`.
- Container PR 257, `ccf99d73`.
- Devcontainer PR 75, `373f4ce`.

No product files or branches from that work were changed during this review. Before implementing product closure or stage identities, obtain the agreed immutable integration heads and include the selected stock/enhanced profile in the relevant contract. Do not reuse runtime evidence across different profiles merely because the Compose source version is 0.14.3.

## Evidence and review limitations

Retained local probe harness: `/Users/sclarke/Documents/ContainerFamily/designs/review-evidence/resilience-followup-probes-2026-09-10.py`.

Retained raw observations: `/Users/sclarke/Documents/ContainerFamily/designs/review-evidence/resilience-followup-probes-2026-09-10.json`.

The harness exercises real Python helpers and the real dispatch shell function, using temporary Git repositories and files under `/Volumes/SSD/cf/build/tmp`. Remote calls are replaced with a narrow fake. It records eight scenario groups covering recursive relocation, promotion escape, exact-object repair, changing-candidate import, cleanup replacement, missing-output checkpoint reuse, ambiguous dispatch retry, and incomplete/malformed release status. Fixture trees were removed by the harness; retained evidence remains internal.

During initial harness setup, the shell library's configured-root variable overrode the test's first environment choice, creating two fake dispatch journal records in the default retained store. No network call occurred. Those exact records were identified by UUID and moved, recoverably, to the review-evidence directory. The harness was corrected to use `CONTAINER_FAMILY_RETAINED_ROOT` and assert the resolved root before dispatching; subsequent probes were isolated.

These results are new fault evidence, not a rerun of the prior full test suite. No full Swift/Go product or API-compatibility audit was attempted; the scope is the build/release/recovery changes and their actual product consumers. Runtime correctness, benchmark speedups, cross-volume power-loss durability, live GitHub behavior, and pending product PR integration remain validation obligations for implementation, not verified outcomes of this design.
