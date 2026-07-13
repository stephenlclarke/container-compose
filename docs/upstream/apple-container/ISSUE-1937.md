# Directory Bind Mounts With Hardlinks Can Fail For Non-Root Guest Processes

## I Have Done The Following

- [x] I have searched the existing issues and pull requests.
- [x] I have exercised the reported path against the current `stephenlclarke`
  fork-backed stack.

## Steps To Reproduce

1. Create a host directory containing readable files and hard links to those
   files.
2. Run an Alpine container as a non-root UID with that directory mounted
   read-only through `--mount type=bind`.
3. Read every entry and archive the directory from inside the guest.
4. Repeat under normal runtime load until one of the guest reads returns
   `EACCES`.

The focused integration coverage uses 16 source files and 16 matching hard
links, runs as UID `1024`, reads every mounted file, and archives the mounted
directory. It preserves a live read-only bind mount rather than replacing it
with a copied snapshot.

## Problem Description

[apple/container#1937](https://github.com/apple/container/issues/1937) reports
intermittent `EACCES` failures while a non-root guest reads a directory bind
mount that contains host hard links. The current `stephenlclarke` source stack
passes the focused reproduction, but an intermittent pass does not establish
that the upstream runtime race is resolved.

[apple/containerization#665](https://github.com/apple/containerization/pull/665)
already addresses a related single-file mount case by sharing the parent
directory. Directory bind mounts remain a distinct behavior and must retain
their live mount semantics. A caller-side copy or snapshot workaround would
silently diverge from Docker bind-mount behavior.

## Environment

- OS: macOS 26 class host
- Image: `ghcr.io/linuxcontainers/alpine:3.20`
- Container: current `stephenlclarke/container` `main`
- Containerization: current `stephenlclarke/containerization` `main`

## Code Of Conduct

- [x] I agree to follow this project's Code of Conduct.
