# [Request]: Make parity programme progress exact-head verifiable

## Feature or enhancement request details

Initial Workflow Enabler 15 requires stable requirement/work-package identity
and one authoritative progress register before the broad parity waves begin.
The ten active design authorities currently use local numbers or prose headings,
and the completed workflow enablers are prose-only. Nothing fails when a number
is reused, a design row disappears, generated status drifts, a completed claim
does not point to an immutable accepted head, or dependent documentation was not
reviewed at that head. A pull request must not be able to call one of its own
commits accepted, and a cross-repository head must resolve in the named
repository rather than merely resemble a Git SHA.

Assign globally stable IDs to every Initial Workflow Enabler, coherent delivery
wave, residual closure wave, and focused-design implementation work package.
Store their state in one machine-readable register and generate the human reader
view from it. Verification must fail closed on missing, duplicate, or
unregistered design anchors; unsafe or stale evidence links; non-ancestor
accepted heads; evidence/document paths absent from the accepted Git tree;
un-actionable blocked rows; missing documentation dispositions; and a stale
generated projection.

A row implemented by the current commit cannot safely embed that commit's own
identity. Keep it `in progress` until the next reviewed checkpoint can point
back to the already-existing accepted merge. Do not introduce a floating
`HEAD`, self, latest, branch, or placeholder identity that would silently move.

## Compose compatibility impact

Workflow and documentation control only. This request changes no Compose model,
CLI behavior, runtime operation, stack pin, package payload, Docker oracle, or
performance threshold. Executable performance evidence is not applicable to
this slice.

## Acceptance criteria

- [x] All 15 workflow enablers have globally stable visible IDs and anchors.
- [x] Coherent Waves 0–9 (including 8b) and residual waves R0–R5 have stable IDs and anchors.
- [x] All 80 focused-design implementation work packages have stable IDs and anchors.
- [x] The checker independently pins the programme root and all 112 required IDs, so moving the baseline or removing an item from both its design and the register fails.
- [x] One JSON register partitions every ID into exactly one allowed state and generates one readable Markdown view.
- [x] Completed Enablers 3, 12, 13, and 14 name immutable accepted ancestor commits, evidence paths, repository heads, authorities, and same-head documentation reviews.
- [x] Every design declares an independently pinned dependent-documentation set; shrinking it fails, and a verified row without every review disposition and non-empty rationale fails.
- [x] Missing, duplicate, invisible, or unregistered anchors and omitted active design authorities fail.
- [x] Missing/non-ancestor accepted commits and evidence or documentation paths absent from the exact tree fail.
- [x] A verified head must be accepted through the trusted pre-change main/PR-base checkpoint; a commit introduced by the current pull request cannot verify itself or an earlier commit from the same pull request.
- [x] Every accepted/repository SHA names a commit object directly, and every matched repository head resolves to that real commit accepted by fetched `main` in an authenticated repository-specific checkout; annotated-tag IDs, missing, fabricated, unmerged, or misidentified repository objects fail.
- [x] Every design declares an independently pinned default repository-head set and any reviewed item overrides; verified evidence missing a required head or naming an undeclared repository fails.
- [x] Every authority uses a trusted, kind-specific GitHub resource in an affected repository; pull requests/comments and successful Actions runs must exist remotely and bind to the recorded accepted head, while commit deliveries bind to the authenticated repository object.
- [x] Hosted validation grants the read-only workflow token explicit Actions-read authority while retaining no write permission, so Actions evidence cannot fail because unspecified permissions default to none.
- [x] Full and documentation-only hosted validation provision full history for every repository the evidence contract accepts.
- [x] Exact-tree queries ignore local replacement refs and ambient Git configuration.
- [x] Blocked rows require an owner, concrete blocker, next action, and next review date.
- [x] Unsafe paths, duplicate JSON keys, non-finite numbers, malformed identifiers, unsupported schema fields/states, and non-verified evidence fail without crashing.
- [x] A stale generated view fails and reports the deterministic regeneration command.
- [x] Focused update/check Make targets exist and the check is part of ordinary `make check`.
- [x] Documentation-only CI checks out full history and runs the progress gate directly.
- [x] The development cycle documents exact state transitions and the non-self-referential verification rule.
- [x] PR #182 post-merge exact-main, Current-release, provenance, asset, and tap evidence is archived.
- [x] Deterministic unit tests cover valid evidence and every principal failure class, including synchronized scope deletion and malformed unhashable values.
- [ ] Exact final-head local gates, CodeQL, Sonar, hosted checks, and clean review are recorded in `PR-183.md`.

## Code of Conduct

- [x] I agree to follow this project's Code of Conduct.
- [x] I checked existing issue records before preparing this request.
