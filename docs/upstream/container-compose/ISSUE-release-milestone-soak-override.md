# Add an auditable, milestone-only Current-soak override

## Problem

The stable-release helper correctly requires a seven-day Current-build soak for
ordinary milestone promotions. A maintainer may occasionally explicitly
authorize an earlier milestone promotion, as with the requested `0.7.0`
baseline. Before this change the only available bypass lanes were maintenance
or security, neither of which accurately describes an authorized non-security
milestone and both of which weaken release auditability.

## Acceptance criteria

- Keep the seven-day soak as the default for every milestone release and for
  scheduled stable promotion.
- Allow an exceptional milestone promotion only with a non-empty, documented
  override rationale.
- Reject that override for maintenance and security intents.
- Preserve Current tag/source identity, prerelease/package provenance, local
  and hosted release gates, signed-tag verification, immutable assets, and
  paired Homebrew verification.
- Cover the policy with release-helper regression tests and document the
  operator command.

## Scope

This is release-control policy only. It does not alter Compose behavior, the
Apple runtime forks, package contents, quality-snapshot metrics, or normal
weekly stable-release scheduling.
