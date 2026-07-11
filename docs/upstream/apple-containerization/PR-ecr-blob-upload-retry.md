# Pull Request: Restart Interrupted Blob Uploads In Fresh Sessions

## Summary

- Incorporate the fresh-session design from
  [apple/containerization#792](https://github.com/apple/containerization/pull/792).
- Add an internal request policy that can truly disable generic retries.
- Apply the outer retry loop only to blobs.
- Retry only transport errors, 5xx responses, and ECR
  `416/BLOB_UPLOAD_INVALID` responses.
- Share the local HTTP stub between registry and Cloud Hypervisor tests.
- Prove that retry uses a second upload UUID and nil policy performs one POST
  and one PUT.

## Upstream Reference

- Fixes [apple/containerization#790](https://github.com/apple/containerization/issues/790).
- Resolves the lower-layer cause of
  [apple/container#1895](https://github.com/apple/container/issues/1895).
- Update the existing open
  [apple/containerization#792](https://github.com/apple/containerization/pull/792)
  rather than opening a competing pull request.

## Commit Tracking

- Shared test support: `d388a15` in `stephenlclarke/containerization`.
- Source fix and registry regressions: `c8043bb` in
  `stephenlclarke/containerization`.
- Keep the source fix as its own upstream-overlap commit.

## Validation

```sh
swift test --disable-automatic-resolution --filter blobPush
swift test --disable-automatic-resolution \
  --filter CloudHypervisorTests.ClientTests
make check
make test
```
