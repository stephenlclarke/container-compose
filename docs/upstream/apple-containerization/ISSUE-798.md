# SwiftPM Reports The CloudHypervisor README As An Unhandled File

## I Have Done The Following

- [x] Searched the existing `apple/containerization` issues and pull requests.
- [x] Reproduced the warning from current `apple/containerization` `main` at `2f947e76143c79e94fa5403ac74ff8d9bd9f0319`.

## Steps To Reproduce

1. Check out `apple/containerization` `main`.
2. Run `swift package describe`, `swift build`, or `swift test`.
3. Observe SwiftPM's unhandled-file warning for `Sources/CloudHypervisor/README.md`.

## Current Behavior

The `CloudHypervisor` target added by [apple/containerization#782](https://github.com/apple/containerization/pull/782) contains a Markdown file that is neither a Swift source, a declared resource, nor explicitly excluded. SwiftPM therefore warns that `Sources/CloudHypervisor/README.md` is unhandled whenever it evaluates or builds the package.

```text
warning: 'containerization': found 1 file(s) which are unhandled; explicitly declare them as resources or exclude from the target
    Sources/CloudHypervisor/README.md
```

## Expected Behavior

The README remains tracked as source documentation and the `CloudHypervisor` target explicitly excludes it from target inputs, so package evaluation and builds complete without an unhandled-file warning.

## Environment

- OS: macOS 26.5.1
- Xcode: 26.6 (17F113)
- Swift: Apple Swift 6.3.3

## Upstream Reference

- Follow-up to merged [apple/containerization#782](https://github.com/apple/containerization/pull/782), which added the `CloudHypervisor` target and its README.
- Submitted fix: [apple/containerization#798](https://github.com/apple/containerization/pull/798).

## Code Of Conduct

- [x] I agree to follow the project's Code of Conduct.
