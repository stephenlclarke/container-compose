# Feature request: disable IPv6 on a vmnet network

## Summary

Generic clients can create vmnet networks with automatic IPv6 assignment, but cannot request an IPv4-only network. The public macOS vmnet configuration API exposes controls for NAT66 and router advertisements, yet the generic NetworkConfiguration model did not expose them.

## Expected behavior

NetworkConfiguration should expose a typed enableIPv6 Boolean that defaults to true for source and persisted-configuration compatibility. A false value should disable NAT66 and router advertisements before vmnet starts, and realized network status should omit the IPv6 prefix.

A configuration that disables IPv6 must not also contain an IPv6 subnet. That contradiction should fail before network creation.

## Ownership

apple/container owns the typed configuration, persistence, API service, helper startup, vmnet setup, status reporting, and generic CLI. Higher layers own their configuration syntax and any decision to retain an incompatible source-model field for inspection.

## Upstream context

[apple/container issue 282](https://github.com/apple/container/issues/282) is open and tracks broader user-controlled network addressing. [apple/container pull request 1174](https://github.com/apple/container/pull/1174) covers IPv6 gateway support and is complementary: it does not expose IPv6 disablement. This request is intentionally narrower and adds no Docker- or Compose-specific model.

## Scope

This is a macOS vmnet primitive. Windows functionality is out of scope. It does not add DNS, service discovery, custom network-driver support, or higher-level orchestration policy.

## Validation expectations

- Existing configuration payloads without the field decode as enabled.
- A disabled configuration round-trips through persisted configuration and API output.
- A disabled configuration with an IPv6 subnet fails before creation.
- The helper receives the setting and configures vmnet without NAT66 or router advertisements.
- Status has no IPv6 subnet and the generic CLI exposes the setting.
