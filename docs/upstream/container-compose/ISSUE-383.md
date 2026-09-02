# Issue 383: remove 0.14 logging and single-service regressions

## Problem

The first exact published-artifact comparison of 0.14.0 with 0.13.0 recorded
five Docker-normalized median regressions: one-service startup, aggregate
one-service logging, filtered log reads, JSON compression writes, and local
rotation writes. Six logging stream fixtures also exposed stopped-runtime
cleanup failures, while every aggregate-50 repetition surfaced a VZ failure.

## Required work

- Recover interrupted prepared cleanup and preserve short-lived VM exits.
- Keep known-immediate starts off the speculative prewarm path.
- Retain stopped containers and their log histories after foreground Compose
  exit-control completes.
- Publish exact stable 0.13.1 and 0.14.1 maintenance artifacts.
- Compare 0.14.1 with 0.13.1 through the artifact-only benchmark workflow and
  retain raw evidence for every previously regressed case.
- Propagate any overlapping minimal fix and evidence to the stock-Apple
  optimization handoffs.

## Acceptance boundary

The issue remains open until the immutable patch releases exist, the
published-artifact comparison is complete, every previously regressed case is
reported, and applicable Apple-shaped handoffs carry the isolated evidence.
CodeQL and documentation publication are release gates rather than development
loop work.

