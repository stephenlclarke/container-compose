# How To File Effective Bug Reports

This guide follows the issue-reporting pattern used by [`apple/container`](https://github.com/apple/container) and adapts it for `container-compose`. Complete, precise reports help maintainers tell the difference between a `container-compose` orchestration gap, a Compose normalization issue, and an [`apple/container`](https://github.com/apple/container) runtime primitive gap.

## Steps To Reproduce

Clear reproduction steps are the fastest path to a fix.

### What To Include

1. Starting state: mention whether this is a fresh install, an existing Compose project, a generated plugin archive, or a local SwiftPM checkout.
2. Exact Compose input: include the smallest `compose.yml` that still reproduces the issue, plus any override files, `.env` values, profiles, or relevant directory layout.
3. Exact commands: copy the full `container compose ...` command, including flags such as `--project-directory`, `--profile`, `--env-file`, `--dry-run`, or `--verbose`.
4. Reproducibility: say whether it happens every time, only after a previous `up`, only after rebuilding, or only with a specific image or runtime state.

### Example

```text
1. Create this compose.yml:

   services:
     api:
       image: alpine
       command: ["sh", "-c", "echo ready && sleep 30"]

2. Run: container compose --dry-run up api
3. Expected a deterministic container command for project "example".
4. Actual output omits the service label needed by later lifecycle commands.
```

## Problem Description

Describe both the current behavior and the behavior you expected.

### Current Behavior

Include details that make the failure observable:

- Exact error messages, not paraphrases.
- Exit codes or status output.
- Relevant `--dry-run` output.
- Differences between `container compose config` and Docker Compose v2, when the issue is normalization-related.
- Whether Docker Compose v2 handles the same file successfully.

### Expected Behavior

Explain what should happen instead:

- The Docker Compose v2 behavior you expected, with a link to upstream documentation when possible.
- The equivalent [`apple/container`](https://github.com/apple/container) primitive, if you know it.
- Whether you think the issue is a `container-compose` design gap, an [`apple/container`](https://github.com/apple/container) runtime gap, or not yet clear.

### Relevant Logs

Logs are most helpful when they are short and directly tied to the failing command. Remove credentials, registry tokens, private hostnames, private image names, and personal data before posting.

Useful command output can include:

```bash
container compose --verbose --dry-run up
container compose config
container compose logs --tail 100
container --debug <command>
```

## Environment Information

Include the versions and runtime details that affect the report.

### macOS Version

```bash
sw_vers
```

Example:

```text
ProductName:            macOS
ProductVersion:         26.0
BuildVersion:           25A354
```

### Xcode Version

```bash
xcodebuild -version
```

Example:

```text
Xcode 26.0
Build version 17A324
```

### apple/container Version

```bash
container --version
```

Example:

```text
container CLI version 0.1.0
```

### container-compose Version

```bash
container compose version
```

Example:

```text
container-compose 0.1.3
  source: stephenlclarke/container-compose
  lane: main
  branch: main
  commit: d34f29c4a6a3c3fa562fafa01cf06959cbb057f7
  build: release
  container: stephenlclarke/container@d13a7688e8c7bb5f96a545955011053587b3fbf5 (custom)
  containerization: stephenlclarke/containerization@cada6d31310761c7e7bf9be87a29fe4820ff628d (custom)
  compose-go: v2.12.1
```

### Plugin Installation Source

Mention how `container-compose` was installed:

- Release archive.
- Local `make install`.
- SwiftPM checkout.
- Manually copied plugin files.

## Compose Context

For Compose compatibility reports, include the smallest input that still demonstrates the issue.

Useful context can include:

- `compose.yml` and override files.
- `.env` files with secret values redacted.
- Profiles used with `--profile`.
- Build context shape, without private source code.
- Named volumes, networks, configs, and secrets used by the failing service.
- Whether the same project works with `docker compose`.

## Common Information Gaps

Before filing, check for the gaps that most often slow down triage:

- The report says "Compose does not work" but does not include a Compose file.
- The command output is summarized instead of copied exactly.
- The issue depends on a local image, private registry, or private path that maintainers cannot infer.
- The report does not say whether `container compose config` succeeds.
- The report does not say whether Docker Compose v2 behaves differently.
- The report includes secrets that should have been redacted.
