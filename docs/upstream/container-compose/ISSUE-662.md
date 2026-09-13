# Issue 662: avoid the workflow-target release permission denial

Issue [#662](https://github.com/stephenlclarke/container-compose/issues/662)
tracks the final publication boundary exposed by the 0.15.1 recovery run.

## Failure

Package run
[34759904010](https://github.com/stephenlclarke/container-compose/actions/runs/34759904010)
successfully materialized the complete retained 0.15.1 asset set, rebuilt and
verified both signed archives, created their attestations, and then failed
closed while publishing the existing draft. GitHub returned `403 Resource not
accessible by integration` from the release-update endpoint. No release or
Homebrew mutation completed.

GitHub's current release API requires Workflows write permission when a
release update resolves to a commit whose `.github/workflows` tree differs
from the repository's default branch. The Actions `GITHUB_TOKEN` cannot be
granted that permission. The signed 0.15.1 tag predates the unattended-release
control changes now on `main`, so using its commit SHA as release metadata
triggered that boundary.

## Contract

- Continue authenticating the actual signed release tag as the exact immutable
  source commit.
- Use protected `main` as the release metadata `target_commitish`; GitHub uses
  that field only to create a missing tag, while the release tag already
  exists and remains independently verified.
- Accept either the legacy exact SHA or `main` while inspecting a pre-existing
  draft or immutable release, so interrupted earlier transactions remain
  recoverable.
- Create and publish every new draft with `main`, avoiding any personal-token
  or expanded workflow-permission dependency.
- Preserve exact tag checks before draft replacement and after publication.
- Cover draft creation, ambiguous retry, stable recovery, Current publication,
  invalid targets, and expected GitHub command lines.

## Expected recovery

The next retry reuses the retained byte-identical 0.15.1 set, migrates the
draft metadata target to `main`, publishes the already-existing signed tag,
and proceeds to the matched Homebrew formula transaction without requiring
interactive credentials.

GitHub documents this permission rule in its
[release update API](https://docs.github.com/en/rest/releases/releases#update-a-release).
