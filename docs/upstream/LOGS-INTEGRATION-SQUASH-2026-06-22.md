# Logs Integration Squash Map

Snapshot date: 2026-06-22 17:30 BST.

`stephenlclarke/container:logs-integration-chris` was force-updated from the pre-squash tip `32d5f20ade09943efec241e44d96cf5581b607cf` to the squashed tip `85311e4a9ddfaa3aff6c4c3bc626491bdd7504a8`.

The pre-squash history is preserved at `stephenlclarke/container:backup/logs-integration-chris-pre-squash-20260622-171352`.

## Current Squashed Commits

| New commit | PR-sized slice | Pre-squash source |
| --- | --- | --- |
| `b598ead94376702c74a45e42a78aa1eed09530a4` | `feat(logs): add structured log retrieval stack` | `a18fee8^..2d2f9bc` |
| `8daea2c01196e74516a0de42e5ad365e70143688` | `feat(logs): add local policy and rotation replay` | `86a9bda^..43add25` |
| `a713ef8cdb729013c8ebf6d34612ef2665d82538` | `feat(api): expose container exit metadata` | `9b6f743` |
| `0854ad6260106def17891e1eb2bb1f7d092c66ce` | `feat(api): add container health checks` | `d995767^..a4fb99e` |
| `d25ffc097aba2df84190f76014a775463bf2a900` | `feat(runtime): add restart policies` | `fcbccbb^..7251c1` plus `32d5f20` |
| `03ef64c0b716a32ace47efaf3e77d45a1eb2b991` | `feat(api): expose image healthcheck metadata` | `831a013` |
| `0affac9b70da0d602d62f27286ebec044618174b` | `feat(network): add container identity primitives` | `bf1d6b4^..183ac5b` |
| `84e04c1f6ff897b6652499cf1f4bb287ce8f23fb` | `feat(runtime): add blkio runtime data` | `a41dd78^..cce5438` |
| `2cf92c3e0cdead7d057d48f060b22ebed38fe151` | `feat(runtime): add sysctl create flags` | `508e3a9` |
| `e06ef75c59f7aa9a5737dabedb0fd58593225d62` | `feat(runtime): add container pause controls` | `61a11f4` |
| `50b095fba5c975e4a77ece61a01b876a6f05ce57` | `feat(copy): add follow-link and archive modes` | `386622c^..f2a5c10` |
| `e6d5e7a3b9dda8fc42adff99b545a439c9738116` | `feat(runtime): expose container process identifiers` | `14a3067` |
| `23439264b2a11dfd7189b59af27a801acea8508b` | `feat(events): stream container lifecycle events` | `b71e4bb^..d0977b5` |
| `85311e4a9ddfaa3aff6c4c3bc626491bdd7504a8` | `docs(upstream): move handoff drafts to container-compose` | `214729a` |

## PR Construction Notes

- Use the new full commit IDs above when constructing future PR branches from `logs-integration-chris`.
- Existing handoff drafts that mention pre-squash commit IDs should be read together with this map until each draft is refreshed in place.
- The lower-runtime `stephenlclarke/containerization:integration/blkio-runtime` commits did not change in this squash; the branch still points at `aaa143b15f426912342cb4f29dc6a55065ba0651`.
- The `container-compose` `logs-integration` commits did not change in this squash; that branch is still nine commits ahead of `origin/logs-integration`.
