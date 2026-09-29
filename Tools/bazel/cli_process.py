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

from __future__ import annotations

import os
import signal
import subprocess
import sys
import time
from collections.abc import Callable


CASE_NONCE = "COMPOSE_FULL_SUITE_CASE_NONCE"
_GATED_EXEC = ("import os,sys; fd=int(sys.argv[1]); command=sys.argv[2:]; "
               "ready=os.read(fd,1); os.close(fd); "
               "sys.exit(125) if ready != b'1' else os.execvpe(command[0],command,os.environ)")


def session_members(identifier: int) -> set[int]:
    result = subprocess.run(["/bin/ps", "-axo", "pid=,state="], check=True, capture_output=True,
                            text=True, timeout=1, env={"PATH": "/usr/bin:/bin", "LC_ALL": "C"})
    members = set()
    for line in result.stdout.splitlines():
        fields = line.split()
        if len(fields) != 2 or not fields[0].isdigit() or fields[1].upper().startswith("Z"):
            continue
        pid = int(fields[0])
        try:
            if os.getsid(pid) == identifier:
                members.add(pid)
        except ProcessLookupError:
            # A process exiting between enumeration and inspection is absent.
            continue
    return members


def process_birth(pid: int) -> str:
    result = subprocess.run(["/bin/ps", "-o", "lstart=", "-p", str(pid)], check=True,
                            capture_output=True, text=True, timeout=1,
                            env={"PATH": "/usr/bin:/bin", "LC_ALL": "C"})
    birth = result.stdout.strip()
    if not birth:
        raise RuntimeError("Supervised process vanished before ownership was recorded")
    return birth


def has_case_nonce(pid: int, nonce: str) -> bool:
    # Inspect one same-user process locally; never retain or print its environment.
    result = subprocess.run(["/bin/ps", "eww", "-p", str(pid), "-o", "command="],
                            capture_output=True, text=True, timeout=1,
                            env={"PATH": "/usr/bin:/bin", "LC_ALL": "C"})
    if result.returncode not in (0, 1):
        raise RuntimeError("Cannot inspect supervised process ownership")
    return (CASE_NONCE + "=" + nonce) in result.stdout.split()


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


def recover_session(record: dict) -> None:
    """Drain one recorded case session, refusing reused or uncertain identities."""
    identifier = record['sid']
    if (type(identifier) is not int or identifier <= 1 or identifier != record['pid']
            or identifier == os.getsid(0) or not record.get('birth')
            or not record.get('nonce')):
        raise RuntimeError("Malformed full-suite session ownership")
    members = session_members(identifier)
    if not members:
        return
    if identifier in members and process_birth(identifier) != record['birth']:
        raise RuntimeError("Full-suite session leader birth changed; refusing cleanup")
    if not any(has_case_nonce(pid, record['nonce']) for pid in members):
        raise RuntimeError("Full-suite session ownership is unverified; refusing cleanup")
    deadline = time.monotonic() + 5
    while members:
        for pid in members:
            signal_owned(pid, identifier, signal.SIGKILL)
        if time.monotonic() >= deadline:
            raise RuntimeError("Full-suite session cleanup is unverified")
        time.sleep(0.01)
        members = session_members(identifier)


def run(command, *, cwd, env, stdout, stderr, timeout: float,
        on_start: Callable[[dict], None] | None = None,
        on_clear: Callable[[], None] | None = None,
        pass_fds: tuple[int, ...] = ()) -> int:
    if on_start is None:
        process = subprocess.Popen(command, cwd=cwd, env=env, stdout=stdout,
                                   stderr=stderr, start_new_session=True, pass_fds=pass_fds)
    else:
        read_fd, write_fd = os.pipe()
        try:
            process = subprocess.Popen([sys.executable, "-c", _GATED_EXEC, str(read_fd), *command],
                                       cwd=cwd, env=env, stdout=stdout, stderr=stderr,
                                       stdin=subprocess.DEVNULL, start_new_session=True,
                                       pass_fds=(*pass_fds, read_fd))
        except BaseException:
            os.close(read_fd)
            os.close(write_fd)
            raise
        os.close(read_fd)
        try:
            if os.getsid(process.pid) != process.pid:
                raise RuntimeError("Supervised child did not start a private session")
            on_start({'pid': process.pid, 'sid': process.pid,
                      'birth': process_birth(process.pid), 'nonce': env[CASE_NONCE]})
            os.write(write_fd, b"1")
        except BaseException:
            os.close(write_fd)
            terminate_session(process)
            raise
        os.close(write_fd)
    try:
        status = process.wait(timeout=timeout)
    except BaseException:
        terminate_session(process)
        if on_clear is not None:
            on_clear()
        raise
    if session_members(process.pid):
        terminate_session(process)
        if on_clear is not None:
            on_clear()
        raise RuntimeError("CLI exited while helper processes remained")
    if on_clear is not None:
        on_clear()
    return status
