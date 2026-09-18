##===----------------------------------------------------------------------===##
## Copyright © 2026 container-compose project authors.
##
## Licensed under the Apache License, Version 2.0 (the "License");
## you may not use this file except in compliance with the License.
## You may obtain a copy of the License at
##
##   https://www.apache.org/licenses/LICENSE-2.0
##
## Unless required by applicable law or agreed to in writing, software
## distributed under the License is distributed on an "AS IS" BASIS,
## WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
## See the License for the specific language governing permissions and
## limitations under the License.
##===----------------------------------------------------------------------===##

"""Bound CLI fixtures whose captured helper changes process group, not session."""

import os
import signal
import subprocess
import time


def session_members(identifier: int) -> set[int]:
    result = subprocess.run(["/bin/ps", "-axo", "pid="], check=True, capture_output=True,
                            text=True, timeout=1, env={"PATH": "/usr/bin:/bin", "LC_ALL": "C"})
    members = set()
    for item in result.stdout.split():
        pid = int(item)
        try:
            if os.getsid(pid) == identifier:
                members.add(pid)
        except ProcessLookupError:
            # A process exiting between enumeration and inspection is absent.
            continue
    return members


def signal_owned(pid: int, identifier: int, value: int) -> None:
    try:
        if os.getsid(pid) == identifier:
            os.kill(pid, value)
    except ProcessLookupError:
        # Already-exited processes require no signal and are checked again.
        pass


def terminate_session(process: subprocess.Popen) -> None:
    identifier = process.pid
    if identifier == os.getsid(0):
        raise RuntimeError("Refusing to terminate the test runner session")
    # Keep the leader unreaped and prevent it launching more parser children.
    signal_owned(identifier, identifier, signal.SIGSTOP)
    try:
        for pid in session_members(identifier) - {identifier}:
            signal_owned(pid, identifier, signal.SIGKILL)
    finally:
        signal_owned(identifier, identifier, signal.SIGKILL)
        process.wait(timeout=5)
    end = time.monotonic() + 5
    while remaining := session_members(identifier):
        if time.monotonic() >= end:
            raise RuntimeError("CLI fixture session cleanup is unverified; preserve scratch")
        for pid in remaining:
            signal_owned(pid, identifier, signal.SIGKILL)
        time.sleep(0.01)


def run(command, *, cwd, env, stdout, stderr, timeout: float) -> int:
    process = subprocess.Popen(command, cwd=cwd, env=env, stdout=stdout, stderr=stderr, start_new_session=True)
    try:
        status = process.wait(timeout=timeout)
    except BaseException:
        terminate_session(process)
        raise
    if session_members(process.pid):
        terminate_session(process)
        raise RuntimeError("CLI exited while helper processes remained")
    return status
