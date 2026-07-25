# Complete Docker structured output templates

## Problem

The Compose-owned row formatter supported Docker's documented formatting
functions, but its data model remained flat. `ps`, `stats`, and `volumes`
therefore rejected Go-template control actions, nested object paths, root and
variable references, and collection traversal before reading runtime state.
This left Docker Compose v2 formats such as label lookup, publisher ranges,
conditional output, and whitespace-trimmed blocks unavailable even though the
required runtime records were already present.

Output formatting is Compose presentation policy, not an Apple runtime
primitive. The fix must stay in `container-compose` and must not widen the
`apple/container` or `apple/containerization` forks.

## Acceptance Criteria

- Represent formatter input as recursive typed values rather than flattening
  nested objects and collections into strings.
- Support `if`, `else`, `else if`, `with`, `else with`, `range`, range
  variables, comments, pipelines, root paths, nested paths, and action
  whitespace trimming.
- Preserve deterministic object traversal and Docker-shaped display behavior.
- Support Docker/Go row helpers used by Compose output, including boolean
  helpers, `json`, string helpers, collection helpers, and portable `printf`
  verbs, width, and left alignment.
- Expose structured publisher, label, mount, network, and volume-label data to
  the commands that own it.
- Reject malformed templates, unknown root fields, invalid arity, invalid
  collection access, and unsupported formatting before runtime discovery or
  sampling.
- Cover the evaluator and all three command paths with unit tests.
- Commit a `compose.yaml` integration fixture and confirm its visible output
  against Docker Compose v2 and the matched Apple Current runtime.
- Keep the README, status matrix, critical review, and superseded handoff
  current.

## Implementation

Signed commit `d2a4a426792f08826e0e816c80e6775e177ab7cc`
(`feat(format): support structured output templates`) contains the complete
Compose-owned implementation, focused tests, committed integration fixture,
Docker Compose v2 oracle, and status updates.

Signed follow-up commit `af1e012fb4fad4162a1841bd9a13f80be68d9fb4`
(`fix(format): match Go template control semantics`) addresses every actionable
autobot finding with lazy boolean evaluation, Go-compatible comparison arity,
and whitespace-sensitive trim markers.

Signed follow-up commit `0fa6bafd119829df09da2b1555a5c463f1d41fc9`
(`fix(format): project runtime mount metadata`) aligns `.Mounts` and
`.LocalVolumes` with runtime-discovered named-volume and bind-mount records.

Signed follow-up commit `551710612d8ca9439029efb4596e7518c429f5e0`
(`fix(format): reject invalid scalar template operations`) makes invalid string
ranges, mixed-type comparisons, and scalar `len` calls fail exactly as the
Docker Compose v2 oracle does.

The remaining signed compatibility commits, through
`130ed4d91b2e3402e702d6d3ba3a265d92d8dd2b`
(`fix(format): preserve raw Go string helpers`), are enumerated in the paired
pull-request handoff. The final follow-ups prove root context across ordered
logical outcomes, handle empty-separator splitting as Go UTF-8 sequences,
truncate strings by UTF-8 bytes, reject negative truncation, and preserve
invalid partial UTF-8 through `split` and `join`. That handoff records the
complete code map, exact validation, coverage, Docker Compose dispositions for
every connector review, runtime revisions, and promotion evidence.

Signed follow-up commit `fce7edbadf8acfc4bf7b410d2f116d4e5f5ca0fa`
(`fix(format): preserve exact Go output semantics`) closes the delayed review:
`.Labels` participates in generic Go string helpers, root `index` access and
the unsupported `table` function fail before discovery, and direct, formatted,
table, `ps`, `stats`, and `volumes` output preserve partial UTF-8 as exact
bytes. The paired handoff records focused unit and command tests, Docker
Compose 5.3.1/Apple Current parity, increased coverage, and the passing
SonarQube pull-request quality gate.

Signed follow-up commit `4fbd1b26023c873cc006c69a8de42e6c10979d1d`
(`fix(format): preserve Go trim whitespace`) restricts trim-marker recognition
and adjacent trimming to Go's ASCII whitespace set. Literal non-breaking spaces
now survive both left and right markers, with focused unit coverage, committed
Docker Compose 5.3.1/Apple Current parity, and a clean SonarQube pull-request
quality gate.

Signed follow-up commit `3fe67c044ead24cca8e7c0ee2dd2afb125772a6c`
(`fix(format): preserve Go root and range semantics`) closes the next connector
review. Formatter roots retain Go struct semantics, so root `len` and `range`
fail before discovery, while positive integer ranges emit `0..<value`,
non-positive ranges are empty, one declaration is supported, and two
declarations are rejected. Focused evaluator and command-path tests, the
committed Docker Compose 5.3.1/Apple Current oracle, increased repository
coverage, and an exact-commit clean SonarQube pull-request quality gate protect
the behavior.

Signed follow-up commit `555dfb0ec739bb2a745d02af000d3b3ddf1f5344`
(`fix(format): restrict action whitespace to Go syntax`) addresses the remaining
thread from that connector review batch. Action trimming, token and control
separation, pipelines, and range declarations now accept only Go's ASCII space,
tab, carriage return, and newline syntax. Non-breaking spaces at action or
control boundaries fail before discovery, while quoted non-breaking spaces
remain valid data. Focused tests, the committed Docker Compose 5.3.1/Apple
Current oracle, increased coverage, and an exact-commit clean SonarQube quality
gate protect both sides of the behavior.

Signed follow-up commit `e63293cce41444f4e44e6aa6f2bf1ad8d099690b`
(`fix(format): reject possible root ranges`) closes the root-range connector
finding. Range preflight now rejects every expression that can return the root
formatter row, including `or` falling back from an empty publisher collection
to `$`. Focused evaluator and pre-discovery command tests, a committed one-off
Docker Compose 5.3.1/Apple Current live oracle, and an exact-commit clean
SonarQube quality gate protect the behavior.

Signed follow-up commit `65c03e127348fd3246d6f90f92428cb9583d2727`
(`fix(format): accept CRLF action whitespace`) closes a delayed connector
finding. Swift groups CRLF into one `Character`, so the Go whitespace predicate
now recognizes that combined grapheme as its two valid constituent action
whitespace runes. Focused field, control, and trim-marker coverage, the
committed Docker Compose 5.3.1/Apple Current live oracle, and an exact-commit
clean SonarQube quality gate protect the behavior.

## Compatibility

Existing literal, field-only, JSON, table, and function templates remain
supported. The implementation adds structured behavior without changing the
Apple runtime SPI or any fork. User-defined template functions are not part of
Docker CLI output-format behavior and remain outside this scope.
