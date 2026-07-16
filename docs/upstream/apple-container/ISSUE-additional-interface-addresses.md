# Runtime API gap: request additional guest interface addresses

## Summary

Runtime attachment configuration cannot express supplementary IPv4 or IPv6
CIDRs for the guest interface. This blocks generic consumers that need explicit
secondary addresses after a network attachment has been allocated.

## Expected behavior

Attachment options should expose a typed list of additional CIDRs and pass it
through both isolated and custom-network strategies to Containerization.
Absent values must preserve existing configurations and runtime behavior.

## Ownership

`apple/container` owns the typed attachment configuration and strategy handoff.
`apple/containerization` owns guest address configuration. Higher layers own
their compatibility syntax and address masks.

## Upstream context

No matching open `apple/container` issue or pull request was found on
2026-07-16. `apple/container#1034` is related broader IPv6 work; its SLAAC and
router-advertisement scope is complementary to explicit supplemental CIDRs.

## Validation expectations

- Older serialized attachment data decodes with an empty list.
- Isolated and custom-network strategies forward the typed CIDRs unchanged.
- Runtime tests verify the Containerization interface receives the values.
