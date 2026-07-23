# Publish relocatable release checksum sidecars

<!-- markdownlint-disable MD013 -->

## Problem

The `current` release publishes valid SHA-256 digests, but both sidecars record the release runner's absolute temporary path instead of the published asset basename:

```text
04468e0e4987f1758cebdbbcf6f4a6647bec924d12847c976c3d3c0f16d1283c  /Users/sclarke/.local/share/container-compose-release-runner/_work/_temp/container-compose-plugin-current-cf657aaf6d93-arm64.tar.gz
111766b38004b7e49cfb0a168e8de9d9c0fc1ae822a66990c6ce11c118314832  /Users/sclarke/.local/share/container-compose-release-runner/_work/_temp/container-current-cf657aaf6d93-arm64.tar.gz
```

A user who downloads an asset and its sidecar cannot run `shasum -a 256 -c <sidecar>` from the download directory because the recorded runner path does not exist. The records also disclose an irrelevant build-machine path.

## Reproducer

1. Download the two `.sha256` assets from [Current build `cf657aaf6d9341c7800e41670f112b2b62e86d62`](https://github.com/stephenlclarke/container-compose/releases/tag/current).
2. Inspect either record and observe `/Users/sclarke/.local/share/container-compose-release-runner/_work/_temp/`.
3. Download its matching archive into the same directory.
4. Run `shasum -a 256 -c <sidecar>`.
5. Verification fails because `shasum` follows the absolute runner path.

## Required behavior

- Publish the same SHA-256 digest followed by the published archive basename.
- Make every archive and sidecar pair independently verifiable from an arbitrary download directory.
- Apply the same rule to Compose and Container archives.
- Keep the repair in Compose release orchestration rather than changing either Apple fork.
- Preserve asset names, digest algorithms, release provenance, attestations, and Homebrew formula inputs.

## Acceptance criteria

- Focused tests prove the sidecar contains only the basename.
- A regression test relocates the archive and sidecar, then executes `shasum -a 256 -c` successfully.
- Release-policy tests require both runtime packaging paths and Compose packaging to use the shared writer.
- A real `make package` archive verifies after being written below an absolute temporary directory.
- `actionlint`, Markdown lint, `git diff --check`, and `make check` pass.
- Exact-main CI, SonarQube, CodeQL, Current packaging, attestations, Homebrew installation, and rendered VHS evidence pass.

## Implementation reference

Signed commit `f77d57fc54b0adf07766fdaa784f8b8bbaf37e33` (`fix(release): publish relocatable checksum sidecars`) contains the Compose-layer repair and regression coverage. The paired pull-request handoff records the complete code map and post-merge gates.
