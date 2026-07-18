# Pull request: accept fractional CPU limits

## Commit tracking

- Constructible commit: `b2a44aa` (`feat(runtime): accept fractional CPU limits`)
- Required lower-runtime commit: `f7b45bf` in `apple/containerization`
- Separate Compose consumer: `aa1a5dab` (`feat(runtime): map stop defaults and CPU CFS resources`)

## Summary

Allow generic `--cpus 0.25` input, retain an integral sandbox-VM CPU count,
persist a CFS quota, and project it to the Linux guest. Integer behavior
remains the established 100 ms quota/period calculation.

## Apple-shaped boundary

The useful upstream surface is a generic fractional resource input plus an
optional CFS quota. No Compose types, Docker Compose file handling, or
Windows-specific resource controls are included.

## Code map and validation

The parser validates positive representable values; resource configuration
persists the quota; the runtime projects it to Containerization. Focused
parser/configuration tests, a guest `cpu.max == 25000 100000` integration
test, `make check`, and Container's 1,042-test coverage gate passed. The
downstream V2.5.3.1 config/local-dry-run parity fixture passed; Engine dry-run
was unavailable.

## Review checklist

- [ ] Replay `f7b45bf`, then `b2a44aa`.
- [ ] Verify integer and `0.25` CPU inputs produce expected guest quotas.
- [ ] Verify old configuration decodes with no explicit quota.

## Non-goals

Explicit CPU period/quota (separate slice), realtime CPU, cpuset, Windows,
and fractional VM vCPU allocation.
