# Pull Request

## Type of Change

- [x] Bug fix
- [ ] New feature
- [ ] Breaking change
- [x] Documentation update

## Motivation and Context

`Flags.Process` already exposes `--ulimit <limit>` to every command that uses the shared process option group. `Parser.process(...)` maps those values for run/create, but the hand-built process configurations in `container exec` and `container machine run` did not carry them forward.

That made `--ulimit` an accepted but ignored option on those paths. The local fork now applies the same parser to every process-command surface that accepts the flag.

## Commit Tracking

- Container code commit: `c91dfa1a843d2dc28daa4537ae600c452899fddc` in `stephenlclarke/container` (`fix(process): honor ulimit process flags`).
- Validation cleanup commit: `350a63ea4daa7ed819a2c66a3b87124044a4370a` in `stephenlclarke/container` (`test(config): align builder image default expectation`).

## Implementation Details

- Factored `container exec` process configuration construction into a testable helper.
- Applied `Parser.rlimits(processFlags.ulimits)` to exec only when explicit ulimit flags are present, preserving inherited init-process rlimits for no-flag exec.
- Applied `Parser.rlimits(processFlags.ulimits)` in `container machine run` before process creation.
- Updated command reference documentation for the `exec` and `machine run` process option lists.
- Added focused command tests proving exec/machine-run command parsing carries ulimits into `ProcessConfiguration.rlimits`.
- Added release-mode non-CI CLI smokes for `container exec --ulimit nofile=1024:2048` and `container machine run --ulimit nofile=1024:2048`.

## Validation

Run from `/Users/sclarke/github/container`:

```sh
swift test --disable-automatic-resolution --filter 'ContainerExecCommandTests|MachineRunCommandTests|ParserTest.testUlimitParserSoftAndHard'
swift test --disable-automatic-resolution --filter 'ContainerExecCommandTests|MachineRunCommandTests|ConfigurationLoaderTests.defaultsWithNoFile'
swift format lint --strict --configuration .swift-format-nolint Sources/ContainerCommands/Container/ContainerExec.swift Sources/ContainerCommands/Machine/MachineRun.swift Tests/ContainerCommandsTests/ContainerExecCommandTests.swift Tests/ContainerCommandsTests/MachineRunCommandTests.swift Tests/ContainerPersistenceTests/ConfigurationLoaderTests.swift Tests/CLITests/Utilities/CLITest.swift Tests/CLITests/Subcommands/Containers/TestCLIExec.swift Tests/CLITests/Subcommands/Machine/TestCLIMachine.swift
swift build -c release --disable-automatic-resolution --product container
swift build --build-tests --disable-automatic-resolution
make coverage-unit
CLITEST_LOG_ROOT="$LOG_ROOT" CONTAINER_CLI_PATH="$PWD/.build/release/container" swift test -c release --disable-automatic-resolution --filter 'TestCLIExecCommand.testExecCommandUlimitNofile|TestCLIMachineRuntime.testRunCommandUlimitNofile'
git diff --check
```

Validation notes:

- Focused command tests passed.
- Touched-file Swift format lint passed.
- Release build passed.
- Release-mode live ulimit smokes passed: 2 tests in 2 suites.
- Unit coverage target passed: 831 tests, 42.05% line coverage, 45.23% function coverage.
- Full `make check` still reports unrelated pre-existing Swift format findings in files outside this slice.
- `markdownlint docs/command-reference.md` still reports broad pre-existing generated/manual command-reference style issues outside this slice.

## Compatibility Notes

Docker `container exec` does not expose `--ulimit`, while Docker `container run` does. This PR keeps the Apple CLI’s existing exposed option and makes it effective. It does not add any Compose-specific semantics to `apple/container`.

## Remaining Risks

- This does not introduce a way to clear inherited exec rlimits; no explicit ulimit flags preserve the previous base-process behavior.
- Per-process rlimit behavior still depends on the Linux runtime honoring `ProcessConfiguration.rlimits` for additional process creation.
