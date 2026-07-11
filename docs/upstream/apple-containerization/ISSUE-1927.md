# Copy-Out From A Missing Guest Path Can Hold The Container State Lock

## I Have Done The Following

- [x] Reviewed the existing report [apple/container#1927](https://github.com/apple/container/issues/1927) and its root-cause discussion.
- [x] Reproduced the lower-runtime failure path against current `apple/containerization` `main` at `2f947e76143c79e94fa5403ac74ff8d9bd9f0319`.

## Steps To Reproduce

1. Start a container with `container run`.
2. Copy an existing guest path to the host and observe that it succeeds.
3. Run `container cp CONTAINER:/does-not-exist DESTINATION`.
4. Attempt `container exec`, `container stop`, or another lifecycle operation against the same container.

## Current Behavior

`LinuxContainer.copyOut` holds the container state lock while a throwing task group coordinates the guest archive producer and host transfer consumer. When guest-side source validation fails before metadata or a vsock connection is emitted, the producer throws without finishing either asynchronous stream. The consumer waits indefinitely, the task group cannot unwind, and every later operation waits on the same state lock.

The root cause was independently identified in [apple/container#1927's discussion](https://github.com/apple/container/issues/1927#issuecomment-4925733977), and the reporter confirmed that the separate attached-exec work in `apple/container#1926` does not fix this copy path.

## Expected Behavior

- Copying a missing guest source returns an error promptly.
- The metadata stream and vsock listener terminate on every guest-side failure path.
- The task group unwinds and releases the container state lock.
- A later exec, stop, delete, or other lifecycle operation on the same container remains usable.

## Environment

- OS: macOS 26.5.1
- Xcode: 26.6 (17F113)
- Swift: Apple Swift 6.3.3
- Upstream report: macOS 26.5.2 on Apple M4 with Container CLI 1.1.0

## Relevant Log Output

Current upstream `main` emits no terminal error because the operation waits indefinitely. The focused regression supplies a five-second bound and verifies a successful follow-up exec on the same container.

## Ownership

`apple/containerization` owns stream termination and state-lock release. `apple/container` and `container-compose` should surface the resulting guest-path error without duplicating lower-runtime cleanup logic.

Current fix proposal: [apple/containerization#799](https://github.com/apple/containerization/pull/799).

## Code Of Conduct

- [x] I agree to follow the project's Code of Conduct.
