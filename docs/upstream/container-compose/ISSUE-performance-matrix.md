# Add reproducible same-host Compose performance-matrix evidence

## Compose surface

Docker Compose parity on macOS requires comparable or better performance, not only functional success. The existing bridge, service-discovery, links, and archive-copy checks record targeted timings, but they did not provide one representative 1/10/50-service median/P95 matrix.

## Docker Compose v2 behavior

Docker Compose can run identical warm-image projects repeatedly on one macOS host. A valid comparison must preserve the reference version, images, fixture state, runtime revisions, raw samples, and timeout outcomes so results are reproducible and do not silently treat incomplete work as performance.

## Previous container-compose behavior

The project goal named single-service and 10/50-service startup and teardown as representative workloads, but no executable local target generated median/P95 results with standard machine-readable evidence for those paths.

## Likely owner

container-compose performance-validation gap. No Apple runtime API or stack-pin change is needed to measure the existing detached lifecycle surface.

## Acceptance criteria

- [x] A local-only target compares Docker Compose and container-compose using identical warm `alpine:3.20` fixtures with 1, 10, and 50 independent services.
- [x] Every startup and teardown sample records a monotonic duration, lane, repetition, outcome, and command in TSV.
- [x] Each result records host, macOS, executable hashes, component revision, Docker engine, Docker Compose, and runtime versions.
- [x] JUnit and Markdown output report per-fixture median and P95 values.
- [x] Timeout, incomplete execution, and an order-of-magnitude median slowdown fail the executable regression guard.
- [ ] Attached/detached logs, `develop.watch` initial/incremental sync, and build-context transfer have equivalent matrix lanes.
- [ ] Measured candidate paths are comparable to or faster than Docker Compose outside the documented noise band.

## Known residual gaps

This adds evidence; it does not claim that the performance product goal is complete. The retained 10x failure policy is a hang/material-regression safeguard, not the project's comparable-or-better criterion. Runtime-owned logging-driver, volume-driver, device, and API-socket gaps remain separately tracked in `STATUS.md`.
