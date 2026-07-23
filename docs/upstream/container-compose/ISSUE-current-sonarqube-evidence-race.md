# Retry Current publication while SonarQube job evidence converges

<!-- markdownlint-disable MD013 -->

## Context

GitHub emits a successful `workflow_run` event as soon as CI completes, but its
jobs API can briefly return stale step conclusions. The Current publisher used
that API to require an exact-main successful `SonarQube scan`. A stale response
was treated as permanently missing evidence, so the publisher completed
successfully while silently skipping the prerelease.

## Reproducer

1. Complete exact-main CI run
   [`29974362621`](https://github.com/stephenlclarke/container-compose/actions/runs/29974362621)
   with a successful `SonarQube scan` step.
2. Observe its automatic Prebuilt Binaries run
   [`29974857357`](https://github.com/stephenlclarke/container-compose/actions/runs/29974857357).
3. The resolve job reports that exact-main CI does not yet include a successful
   scan, sets `publish=false`, skips `Package`, and concludes successfully.
4. Immediately query the settled CI jobs API and SonarCloud. The scan is
   successful, analysis `ee1c2f60-9a6e-494a-a6b3-d7ba7924a2ce` is bound to
   `00f6cdca16733126d18046d545f9660ba4118352`, the quality gate is `OK`, and
   unresolved issues total zero.

## Required behavior

- Retry only absent exact-main SonarQube step evidence for a bounded interval
  when handling `workflow_run`.
- Publish as soon as the successful step conclusion becomes visible.
- Preserve the distinct fail-closed result for GitHub API read failures.
- Preserve manual-dispatch behavior, which runs after CI evidence has settled.
- Never publish a superseded main revision or a revision without a successful
  exact-main SonarQube scan.

## Acceptance criteria

- An executable unit harness proves missing evidence is retried and later
  accepted.
- The harness proves an authority-read failure is returned immediately as the
  existing distinct error.
- Release-policy, workflow lint, and repository checks pass.
- Exact-main CI, Quality, CodeQL, and Documentation workflows pass.
- Automatic Prebuilt Binaries runs `Package` instead of reporting a successful
  skip, and publishes Current for the exact main revision.

## Implementation reference

Signed commit `285a961a3fa37cb7b19325b1bf9fd4d29f087ada`
(`fix(release): wait for SonarQube job evidence`) contains the bounded retry and
regression coverage. The paired pull-request handoff records the code map and
publication gates.
