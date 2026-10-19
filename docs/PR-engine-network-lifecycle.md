# PR: verify existing Engine networks before repeated lifecycle operations

## Motivation and implementation

The Engine adapter reuses a network after create conflict only when live inventory contains one exact-name resource with the requested labels and internal setting. Successful deletion retains its original path. Only after HTTP 404 does deletion query inventory and return on proven exact-name/ID absence. Ambiguous, malformed, foreign and unavailable responses remain failures.

## Validation

Mocked Unix server regressions cover repeated create, repeated delete, and negative identities. The original adapter failed the two positive regressions with three recorded issues in retained invocation `646a937c-2c2b-42d6-a88f-66ad6876a62a`. The final corrected adapter passed all 106 Engine tests across 16 suites in retained invocation `77a1d9d5-ad1a-4323-81df-0ea9f245b537`. Swift style and static lint also passed. Stock unit, coverage, and exact signed package gates follow at the committed checkpoint.

## Compatibility and remaining work

Successful operations keep their existing request paths. Error handling remains strict unless current inventory proves the requested repeated operation is safe. Dependency pins, published lower layers, package recipes, and native runtime behavior are unchanged. A freshly released signed gateway and the complete Devcontainer runtime qualification, including C04 and host restoration, remain required before release. Original failed campaign evidence remains unchanged.

## Linked issue

See [the reproduction and original failure](ISSUE-engine-network-lifecycle.md). No GitHub issue or PR number has been assigned.
