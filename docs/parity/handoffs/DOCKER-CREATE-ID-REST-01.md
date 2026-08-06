<!-- markdownlint-disable MD013 -->

# DOCKER-CREATE-ID-REST-01 Handoff

## State

`Verified` as a narrow Docker CLI/public-socket certificate for canonical Docker
create identity and alias routing. It does not certify every Docker object
route, events, rename, migration, external-client, or release-performance
behavior.

## User-visible contract

The same unmodified Docker CLI receives a canonical immutable 64-character
lowercase-hex ID from `docker container create`, while the requested name
remains separately visible. The name, full ID, and unique 12-character prefix
all route to the same object for inspect, start, stop, delete, and logs. GELF
records and Docker logging plug-in configuration use the same canonical ID and
name rather than the native Container resource identity.

## Exact proof

The marker-protected Docker reference root
`/private/tmp/container-create-id-reference-v2.DRU21z` records Docker CLI
`29.7.1`, Engine `29.2.1`, API `1.53`, `alpine:3.20`, the exact fixture, and a
`0.700619291s` passing result. The marker-protected candidate root
`/private/tmp/container-create-id-candidate-v2.9lSjrX` contains
`FINGERPRINT-PREFLIGHT.json`, `ARCHIVE-VERIFICATION.json`, and
`FINGERPRINT-COMPLETE.json`; the source/dependency graph, signed archive,
binary hashes, guest/init images, public harness, wrapper, two candidate results,
and cleanup evidence all agree.

Focused source proof passes:

```sh
env CONTAINERIZATION_PACKAGE_PATH=/Users/sclarke/Documents/container/containerization-engine-sandbox \
  CONTAINERIZATION_REF=38d9c695 \
  CONTAINER_ENGINE_API_PACKAGE_PATH=/Users/sclarke/github/container-engine-api \
  swift test --filter 'ContainerLogsTests.dockerContainerIdentityUsesCanonicalIDAndNameAliases|AuthorityRemoteLogDriverPlaneTests.dockerLogInfoUsesCanonicalDockerIdentityWhenAvailable'
```

The candidate source behavior is preserved in signed Container commit
`9d2257a81176a895a31388124bd6a7b0b74d10e6`; the local Apple-shaped issue and
pull-request handoff pair is signed at `b580b2ee43540189e764db293c2a74a531123d26`.
Candidate runs passed in `1.591354583s` and `1.574481541s` (2.27x and 2.25x
Docker). The raw timings pass the fixture's 10x functional guard only; the
programme-wide comparable-or-better performance gap remains open.

## Correction retained as evidence

The original candidate at
`/private/tmp/container-create-id-candidate-v1.ga0khK` correctly returned and
routed the canonical ID but exposed GELF `_container_id` and `_container_name`
as native resource identity. The correction centralizes Docker logging identity
in `AuthorityRemoteLogDriverPlane.dockerLogInfo`, reused by both GELF and Docker
plug-in projection. The v2 source regression and two public candidates prove
the correction; the failed v1 root remains preserved for reproducibility.

## Remaining boundary

Every wider Docker lifecycle/object route, event and rename semantics,
external-client and provider matrices, Testcontainers/devcontainer adoption,
release publication, and the counterbalanced release-performance proof remain
queued. This contract explicitly does not convert the 2.27x/2.25x focused
timings into a comparable-or-better performance claim.

## Safe resumption

Keep both marker-protected roots, the signed Container implementation and
Apple-shaped handoff pair, this Compose ledger/handoff, and Slack START thread
`1785998717.472209`. Owned
[Container issue #74](https://github.com/stephenlclarke/container/issues/74)
has the exact evidence comment and is closed as completed after this Compose
checkpoint. Post the END reply in the retained START thread, and then select
one independent queued contract only after the silent Slack instruction poll.

<!-- markdownlint-enable MD013 -->
