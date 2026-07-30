# Correct service-platform metadata in `compose commit`

## Compose surface

`container compose commit` inherited OCI image configuration for a service
with an explicit `platform`.

Tracking issue:
[`#172`](https://github.com/stephenlclarke/container-compose/issues/172).
Implementation pull request:
[`#173`](https://github.com/stephenlclarke/container-compose/pull/173).

## Docker Compose v2 behavior

Docker Compose commits the selected service container. Its resulting image
inherits the configuration of the image variant used by that service,
including user, environment, process defaults, working directory, labels,
ports, stop signal, healthcheck, and declared volumes.

## Previous container-compose behavior

PR 173 initially loaded complete metadata for the host-default image variant,
then performed separate requested-platform lookups for only healthcheck and
declared-volume fields. A service targeting another available platform could
therefore commit a hybrid config: host-default process and identity fields
combined with requested-platform healthcheck and volume fields.

That path also converted the same local image to an `ImageResource` up to three
times for one commit.

## Likely owner

container-compose design gap. The live Apple adapter already exposes every
required field on one selected `ImageResource.Variant`; no Apple runtime or
stack-pin change is required.

## Minimal example

```yaml
services:
  api:
    image: example/multi-platform:latest
    platform: linux/amd64
```

If the host-default and `linux/amd64` variants have different OCI configs, the
committed image must inherit the complete `linux/amd64` config.

## Acceptance criteria

- [x] A requested, available service platform supplies the complete inherited
  OCI config.
- [x] A successful requested-platform lookup converts the image to an
  `ImageResource` once, rather than three times.
- [x] An unavailable or failed platform lookup falls back to the existing
  default-variant metadata policy.
- [x] An available variant with empty fields clears host-default healthcheck
  and volume declarations instead of restoring them.
- [x] Focused tests distinguish every inherited field between host-default and
  selected variants and assert the exact request sequence.
- [x] Local CI, quality, accepted SonarQube analysis, and post-change Docker
  Compose v5.3.1 parity are green.
- [x] Hosted CI, Quality, Documentation, and SonarQube validation are green on
  the merged revision.
- [ ] CodeQL evidence is intentionally outstanding while the workflow is
  manually disabled at the owner's request; the required context remains
  configured and no absent run is counted as green.

## Final disposition

Pull request 173 merged on 30 July 2026 with head `aa273273536bfab5cc4d0d2a576ec8961aa69070` and merge commit `31b83499abec6fe090a44dfe24527f0d220fd0b9`; issue 172 closed with the merge.

Exact-merge [CI run 30546490764](https://github.com/stephenlclarke/container-compose/actions/runs/30546490764), [Documentation run 30546492821](https://github.com/stephenlclarke/container-compose/actions/runs/30546492821), and [Quality run 30546494706](https://github.com/stephenlclarke/container-compose/actions/runs/30546494706) all passed. The CI runtime-validation job included a successful SonarQube scan. CodeQL did not run because GitHub reports the workflow as `disabled_manually`; this is documented as missing evidence, not a pass.

## Known residual gaps

The maintained runtime gap register remains authoritative. Container-facing
DNS, direct tar-stream metadata fidelity, richer security/GPU behavior,
custom network and volume drivers, Docker API socket support, and distinct
logging-driver semantics require generic runtime primitives before their
Compose adapters can be completed. PR 173 does not emulate those missing
runtime capabilities in the Compose layer.

## Code of Conduct and documentation

- [x] I agree to follow this project's Code of Conduct.
- [x] I checked `STATUS.md`, the current critical review, and the relevant
  command help.
