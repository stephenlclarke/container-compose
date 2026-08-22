# Pin native lifecycle identity inspection support

## Problem

Container Compose adopted atomic lifecycle discovery in [pull request 282](https://github.com/stephenlclarke/container-compose/pull/282), but its pinned Container revision could not inspect a native container by the immutable lifecycle ID returned from that discovery snapshot. Host-namespace lifecycle operations therefore discovered the correct container and then failed when the native `container inspect` command resolved only the legacy bundle-key namespace.

## Required behavior

The coordinated Compose stack must pin the merged Container correction from [Container pull request 135](https://github.com/stephenlclarke/container/pull/135). `Package.swift`, `Package.resolved`, the release stack manifest, and the reviewed fork classification must all name the same immutable Container revision. Native discovery must preserve the canonical Compose name and immutable ID, and native inspect/down must accept that discovered identity.

## Resolution

Container commit `b636d3f9d07de7ef3b4721de17eb47351c2544c1`, merged as `e76a28de2dcf2c3650871d8e5240d41d6a36cf12`, resolves inspect requests across the lifecycle ID, canonical name, and immutable bundle key. The focused live host-namespace certificate reached inspect and teardown successfully with that source commit. Compose pull request [304](https://github.com/stephenlclarke/container-compose/pull/304) moves every coordinated pin to the merged revision.

## Tracking

- Parent parity issue: [#274](https://github.com/stephenlclarke/container-compose/issues/274).
- Compose pull request: [#304](https://github.com/stephenlclarke/container-compose/pull/304).
- Container dependency: [stephenlclarke/container#135](https://github.com/stephenlclarke/container/pull/135).
