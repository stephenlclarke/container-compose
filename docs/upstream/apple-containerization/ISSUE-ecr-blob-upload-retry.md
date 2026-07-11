# Interrupted ECR Blob Uploads Reuse A Stale Session

## Upstream Reference

- Runtime issue: [apple/containerization#790](https://github.com/apple/containerization/issues/790)
- CLI report: [apple/container#1895](https://github.com/apple/container/issues/1895)
- Overlapping open pull request:
  [apple/containerization#792](https://github.com/apple/containerization/pull/792)

Do not open a competing issue or pull request. Use these notes to review or
improve the existing proposal.

## Problem

The generic request retry recreates a blob body stream at byte zero while
reusing the same registry upload URL. If ECR committed part of the first PUT,
it rejects the restarted body with HTTP 416 and `BLOB_UPLOAD_INVALID` because
the session expects the next byte offset.

The overlapping PR has the correct high-level idea but retries manifests and
non-retryable semantic failures, and it invents three retries for clients whose
retry policy is nil.

## Expected Behavior

- Every retried blob attempt starts with a new `POST /blobs/uploads/` session.
- The PUT itself never retries against the same upload UUID.
- Manifests retain the existing request behavior.
- Nil or zero retry policy performs no fresh-session retry.
- Only transport failures, server errors, and ECR's specific
  `416/BLOB_UPLOAD_INVALID` response restart the blob upload.
