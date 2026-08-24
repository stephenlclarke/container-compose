# Issue 313: add a recoverable OSS Container-family build and test graph

## Problem description

The bespoke release checkpoint layer keyed unrelated repositories and stages
through one broad fingerprint. A change to one input invalidated unaffected
work, and retained recovery roots contained manually rewritten
`carried_forward` success records that were not independently validated.

A coding, build, or test failure must retain exact evidence and resume from the
last still-valid checkpoint after correction without repeating independent
successful work or accepting stale output.

## Resolution

The phase-one pipeline checksum-pins Nextflow OSS 26.04.6 and its Java runtime,
captures immutable Git-archive inputs per repository, and keys source, Swift,
Go, and CLI stages through their explicit source, dependency, tool, and
environment inputs. Existing Make targets remain stage adapters.

The wrapper establishes an allowlisted noninteractive environment, finite
process-group deadlines, symlink-safe durable state, and exact-session resume.
Every attempt retains task logs, history, trace, report, timeline, DAG, failure
records, and content-addressed evidence.

## Focused evidence

- Nineteen process-session and deadline regressions pass.
- Session `593d62e5-81d5-4e57-b88e-6930a0282c0d` passed the synthetic
  fail/correct/resume proof: both upstream tasks were cached and only the
  corrected downstream task completed again.
- The unchanged implementation tree previously completed immutable Compose
  source and Go stages without leaked Git-daemon descendants.
- Exact signed head `5fa6dd0c26e3a91430fdd37b23b592e99bd31fa5`
  completed the immutable Compose source and Go stages in session
  `pipeline_20260824T073438Z_58943`; both receipts report exit `0`.

## Scope

Phase one covers static, unit, and smoke-test orchestration. Live runtime,
signing, authenticated registry, TCC, package, and stable-release authority
remain on the existing release path until their explicit noninteractive stages
are implemented and proved.

Refs [#313](https://github.com/stephenlclarke/container-compose/issues/313).
