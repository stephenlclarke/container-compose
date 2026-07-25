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
- Support `if`, `else`, `else if`, `with`, `range`, range variables, comments,
  pipelines, root paths, nested paths, and action whitespace trimming.
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

The paired pull-request handoff records the code map, exact validation, coverage,
runtime revisions, and promotion evidence.

## Compatibility

Existing literal, field-only, JSON, table, and function templates remain
supported. The implementation adds structured behavior without changing the
Apple runtime SPI or any fork. User-defined template functions are not part of
Docker CLI output-format behavior and remain outside this scope.
