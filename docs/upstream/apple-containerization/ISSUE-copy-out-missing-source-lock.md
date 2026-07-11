# Copy-Out Failure Can Hold The Container State Lock

## Upstream Reference

- Existing report: [apple/container#1927](https://github.com/apple/container/issues/1927)
- Affected lower layer: `apple/containerization`

Do not open a duplicate `apple/container` issue. Use the existing report and
explain that the deadlock is in `LinuxContainer.copyOut`.

## Problem

`copyOut` holds the container state lock while a task group coordinates the
guest archive producer and host transfer consumer. When guest-side source
validation fails before metadata is emitted, the producer throws but does not
finish the metadata stream or vsock listener. The consumer waits indefinitely,
the task group cannot unwind, and later exec, stop, or delete operations wait
on the same state lock.

## Expected Behavior

- A missing guest source returns its error promptly.
- Both copy coordination streams finish on every producer exit path.
- The state lock is released before the call returns.
- A later exec or lifecycle operation on the same container succeeds.

## Ownership

`containerization` owns stream completion and lock release. `container` and
`container-compose` should only surface the lower-layer error.
