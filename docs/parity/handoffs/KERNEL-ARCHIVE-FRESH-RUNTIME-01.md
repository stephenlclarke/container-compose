# KERNEL-ARCHIVE-FRESH-RUNTIME-01

## Contract

| Field | Record |
| --- | --- |
| State | `Verified` — isolated runtime bootstrap prerequisite; it unblocks candidate Docker contracts but is not a logging-driver certificate. |
| Behaviour | A fresh, marker-protected Container runtime root downloads and installs the configured kernel, starts its namespace-derived Engine socket, answers an unmodified Docker CLI `docker version`, and stops its own services without a timeout or hang. |
| Explicit non-goals | GELF delivery, Docker Compose project behaviour, source-code performance optimisation, release performance, and the generic logging-driver matrix remain outside this prerequisite. |
| Docker oracle | Same-MBP Docker CLI `29.7.1` against Docker Engine `29.2.1` / API `1.53`. The candidate proof checks the same public Docker CLI command over the candidate's isolated socket; it is a liveness/bootstrap prerequisite rather than a differential logging oracle. |
| Exact inputs | Container `1f6b0057bdd1bfe0594c9b26391db388f54ff341`; Containerization `38d9c695e7a6915e5ce45d12c893dc323a661af7`; Engine API `afb8a8f68ed56829b669c95cbddb488a68dc9175`; package SHA-256 `2f806a9743da434ce41ac5a36564c3f48f3806252e33d801961e10dd853140ec`; CLI SHA-256 `9e8f9a509cc1eb6defdcbbd590d690ddc16eedcbba3c8f3ff19ccbca75e47c11`; guest init SHA-256 `5d4201135affb9bb0ce34ebcb184551689a214d3118b75564a8fa498667d77f6`; bootstrap SHA-256 `c714ab7421c71cebdfd0236c5a1af4b1e9af3da1855946cf3350a384491815f0`; wrapper SHA-256 `7a396d8626a0e37c1b7f71e732674baebd1b3752bedc3378a7e4510e3323987f`. |
| Focused proof | Two independent fresh roots, each with the exact input fingerprint retained before startup, installed `vmlinux-6.18.15-186`, returned `29.7.1\|homebrew-main-236-39f56bd8a193-231-g1f6b0057\|linux` from the isolated Docker socket, exited `0`, and stopped candidate services. |
| Completion criteria | Met: both fresh roots completed inside the bounded 180-second run; neither emitted the archive error or a timeout; the exact fingerprints and terminal records are retained; and this checkpoint leaves all edited repositories clean. |
| Blocker criteria | A fresh root reproduces `unable to open the archive, code -30` with sufficient local capacity, the socket smoke test times out/hangs, or the candidate affects the user-owned runtime. |
| Safe handoff | Preserve `/private/tmp/ctr-kernel-archive-evidence-01` and the two retained roots named below. Resume the previously handed-off GELF delayed-retry contract with two fresh full fixture candidates; do not count this prerequisite as GELF verification. |

## Root-cause evidence

The prior `v12` candidate failed while the APFS volume had only `117M` available. The failure appeared at `Installing kernel...` as `unable to open the archive, code -30`, before the GELF receiver or Docker fixture began. The failure was therefore neither a logging result nor a liveness timeout.

Only five identified, marker-protected, superseded SwiftPM/package-cache roots were removed: `ctr-gelf-vsock-build-01`, `ctr-gelf-vsock-build-02`, `container-gelf-tcp-retry-combined-01-swiftpm`, `container-gelf-tcp-retry-validate-01-swiftpm-noresolve`, and `ctr-gelf-vsock-package-bin-02`. That reclaimed 25 GB while retaining the current package extraction, source checkpoints, failure log, and every unmarked worktree. No Container source change was required or made.

## Fresh-root evidence

- `/private/tmp/ctr-kernel-archive-evidence-01/candidate-v13-preflight.txt` and `candidate-v13.terminal.log` bind the first fresh root `/private/tmp/ctr-kernel-v13`. Its terminal record shows kernel installation followed by the isolated socket version response and namespace-scoped stop.
- `/private/tmp/ctr-kernel-archive-evidence-01/candidate-v14-preflight.txt`, `candidate-v14.terminal.log`, and `candidate-v14.terminal.result.txt` bind the independent fresh root `/private/tmp/ctr-kernel-v14`. The result file records `exit_status=0`; the root retains the installed 16 MB `vmlinux-6.18.15-186` and default-kernel symlink.
- Both roots use `.container-compose-runtime-root`, while the shared evidence root uses `.container-parity-disposable`. No candidate process remained after either wrapper cleanup.

## Issue disposition

[Container issue #93](https://github.com/stephenlclarke/container/issues/93) was opened when the archive failure was still unexplained. This evidence shows it was a local-capacity incident, not a maintained-source defect. Close it with these exact records; reopen only if a fresh root reproduces the error with adequate space.
