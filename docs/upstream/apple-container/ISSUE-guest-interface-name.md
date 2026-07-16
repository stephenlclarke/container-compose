# Runtime API gap: request a guest interface name

## Summary

The runtime attachment configuration has no way to pass an optional stable
guest-interface name to the virtual-machine network primitive. This prevents
clients from selecting a predictable Linux interface name without coupling to
attachment order.

## Expected behavior

The Linux runtime attachment model should expose an optional guest-interface
name and pass it through each network strategy to the generic Containerization
interface model. Requests without a name must preserve existing behavior.

## Ownership

`apple/container` owns runtime attachment configuration and its typed API.
`apple/containerization` owns the guest-agent rename primitive. Higher layers
own Docker or Compose compatibility syntax.

## Upstream context

`apple/container#1283` is the closest open issue: it asks for choosing network
interfaces for multi-network containers. It does not define a guest-name API,
so this is complementary rather than a duplicate. Open PR #1882 concerns
vmnet routing and is unrelated.

## Validation expectations

- Attachment configuration remains backwards compatible when the field is
  absent.
- Both isolated and custom-network strategies pass the value to the interface
  model.
- Runtime configuration and public API tests cover the hand-off.
