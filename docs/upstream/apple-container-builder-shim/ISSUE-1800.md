# `.dockerignore` negation re-includes can stream orphan descendants

## Target

- Upstream issue: <https://github.com/apple/container/issues/1800>
- Upstream builder-shim PR: <https://github.com/apple/container-builder-shim/pull/87>
- Local fork implementation: `stephenlclarke/container-builder-shim`

## Problem

Build contexts whose `.dockerignore` excludes a directory's contents and then re-includes selected descendants can fail during BuildKit's `[internal] load build context` step with a `changes out of order` error. Rails-style ignore templates commonly contain this pattern:

```dockerignore
/foo/*
!/foo/.gitkeep
/foo/bar/*
!/foo/bar/.gitkeep
```

The failing path is not in Compose parsing. `container-compose` preserves the build inputs and delegates context transfer to the fork-backed `container` / `container-builder-shim` build backend. The compatibility gap is in the builder shim's file-sync stream: an excluded parent directory can be skipped while a re-included child is still emitted, so BuildKit receives the child before the required parent entry.

## Expected Behavior

BuildKit should see Docker-compatible `.dockerignore` behavior. When a negation re-includes a descendant below an excluded directory, the stream should include the necessary parent directory entries before the descendant so BuildKit's receiver validator accepts the change sequence.

## Local Resolution

The stephenlclarke fork moves exclude filtering from the raw host-tar walk into the `DiffCopy` path by wrapping the unpacked context cache with BuildKit's `fsutil.NewFilterFS`. That filter owns Docker-compatible include/exclude semantics and emits excluded ancestor directories before re-included descendants.

The fork keeps its staged Dockerfile exception by adding negation patterns for requested synthetic Dockerfile paths before constructing the `fsutil` filter.

## Validation

- `go test ./pkg/fssync`
- `go test ./...`
- `make build`
- `make vet`
- `make coverage`
- `make lint`
- `make fmt`
- `git diff --check`

## Apple Submission Notes

Do not push from this workspace to Apple remotes. The local fork implementation is aligned with the existing upstream PR shape in apple/container-builder-shim#87, with an additional staged-Dockerfile safeguard required by this fork's current build path.
