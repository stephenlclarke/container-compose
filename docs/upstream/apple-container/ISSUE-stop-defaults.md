# Compatibility gap: persisted container stop defaults

## Problem

The generic runtime had image-level stop signal behavior but no per-container
creation defaults. It also could not distinguish an omitted stop timeout from
the client-side five-second default. Compose therefore could not persist
`stop_signal` or `stop_grace_period` for reuse by direct and future lifecycle
operations.

## Required Apple primitive

Optional persisted signal/timeout values, optional stop-request overrides,
and a final runtime fallback only when neither source supplies a timeout.

## Intended review delta

`8650e5d` in `apple/container`; no Containerization dependency. The change is
generic configuration/lifecycle behavior and is macOS Linux-guest scoped.

## Non-goals

Windows behavior, Compose model types, and Docker lifecycle-event parity.
