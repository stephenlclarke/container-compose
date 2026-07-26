//===----------------------------------------------------------------------===//
// Copyright © 2026 container-compose project authors.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//   https://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
//===----------------------------------------------------------------------===//

import Foundation
#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#endif

/// Terminal handoff selected for a child process group.
struct ProcessForegroundConfiguration: Equatable, Sendable {
    let jobControlProcessGroup: pid_t?
    let makeChildForeground: Bool
}

/// Selects terminal foreground ownership without coupling tests to a real TTY.
func processForegroundConfiguration(
    inheritsStandardInput: Bool,
    standardInputIsTerminal: Bool,
    currentForegroundProcessGroup: pid_t,
    currentProcessGroup: pid_t,
) -> ProcessForegroundConfiguration {
    guard
        inheritsStandardInput,
        standardInputIsTerminal,
        currentForegroundProcessGroup > 0,
        currentProcessGroup > 0
    else {
        return ProcessForegroundConfiguration(
            jobControlProcessGroup: nil,
            makeChildForeground: false,
        )
    }
    guard currentForegroundProcessGroup == currentProcessGroup else {
        return ProcessForegroundConfiguration(
            jobControlProcessGroup: currentProcessGroup,
            makeChildForeground: false,
        )
    }
    return ProcessForegroundConfiguration(
        jobControlProcessGroup: currentProcessGroup,
        makeChildForeground: true,
    )
}

/// Performs terminal restoration while preserving the caller's signal mask.
func terminalForegroundRestorationErrorCode(
    processGroup: pid_t?,
    blockSignal: () -> Int32,
    setForegroundProcessGroup: (pid_t) -> Int32,
    restoreSignalMask: () -> Int32,
) -> Int32 {
    guard let processGroup else {
        return 0
    }
    let blockError = blockSignal()
    guard blockError == 0 else {
        return blockError
    }
    let foregroundError = setForegroundProcessGroup(processGroup)
    let restoreMaskError = restoreSignalMask()
    return foregroundError == 0 ? restoreMaskError : foregroundError
}

/// Restores terminal ownership without allowing `SIGTTOU` to stop Compose.
func restoreTerminalForegroundProcessGroup(
    _ processGroup: pid_t?,
    fileDescriptor: Int32,
) -> Error? {
    guard processGroup != nil else {
        return nil
    }

    var blockedSignals = sigset_t()
    if sigemptyset(&blockedSignals) != 0 || sigaddset(&blockedSignals, SIGTTOU) != 0 {
        return POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
    var originalSignalMask = sigset_t()
    let errorCode = terminalForegroundRestorationErrorCode(
        processGroup: processGroup,
        blockSignal: {
            pthread_sigmask(SIG_BLOCK, &blockedSignals, &originalSignalMask)
        },
        setForegroundProcessGroup: { processGroup in
            tcsetpgrp(fileDescriptor, processGroup) == 0 ? 0 : errno
        },
        restoreSignalMask: {
            pthread_sigmask(SIG_SETMASK, &originalSignalMask, nil)
        },
    )
    if errorCode != 0 {
        return POSIXError(POSIXErrorCode(rawValue: errorCode) ?? .EIO)
    }
    return nil
}

/// Selects terminal restoration only while the exiting child still owns it.
func terminalForegroundProcessGroupToRestore(
    childProcessGroup: pid_t?,
    parentProcessGroup: pid_t?,
    currentForegroundProcessGroup: pid_t,
) -> pid_t? {
    guard
        let childProcessGroup,
        let parentProcessGroup,
        currentForegroundProcessGroup == childProcessGroup
    else {
        return nil
    }
    return parentProcessGroup
}

/// System operations used while relaying one stopped child process group.
struct ProcessJobControlActions {
    let currentForegroundProcessGroup: () -> pid_t
    let setForegroundProcessGroup: (pid_t) -> Error?
    let signalProcessGroup: (pid_t, Int32) -> Int32
}

/// Provides the live terminal and process-group operations.
func liveProcessJobControlActions() -> ProcessJobControlActions {
    ProcessJobControlActions(
        currentForegroundProcessGroup: { tcgetpgrp(STDIN_FILENO) },
        setForegroundProcessGroup: {
            restoreTerminalForegroundProcessGroup($0, fileDescriptor: STDIN_FILENO)
        },
        signalProcessGroup: { kill(-$0, $1) == 0 ? 0 : errno },
    )
}

/// Relays foreground child suspension through Compose's shell job.
func relayStoppedProcessGroup(
    childProcessGroup: pid_t,
    parentProcessGroup: pid_t?,
    stopSignal: Int32,
    actions: ProcessJobControlActions,
) -> Error? {
    guard let parentProcessGroup else {
        return nil
    }

    if
        actions.currentForegroundProcessGroup() == childProcessGroup,
        let error = actions.setForegroundProcessGroup(parentProcessGroup)
    {
        return error
    }

    let stopError = actions.signalProcessGroup(parentProcessGroup, stopSignal)
    if stopError != 0 {
        return POSIXError(POSIXErrorCode(rawValue: stopError) ?? .EIO)
    }

    if
        actions.currentForegroundProcessGroup() == parentProcessGroup,
        let error = actions.setForegroundProcessGroup(childProcessGroup)
    {
        return error
    }

    let continueError = actions.signalProcessGroup(childProcessGroup, SIGCONT)
    if continueError != 0 {
        return POSIXError(POSIXErrorCode(rawValue: continueError) ?? .EIO)
    }
    return nil
}
