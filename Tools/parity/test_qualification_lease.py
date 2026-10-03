#!/usr/bin/env python3
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

"""Prove an escaped parity child keeps recovery excluded after outer cancellation."""

import fcntl
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time
import unittest


ROOT = Path(__file__).resolve().parents[2]


class QualificationLeaseTests(unittest.TestCase):
    def test_detached_child_retains_shared_lease_after_outer_group_is_killed(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            lock = directory / 'commands.lock'
            lock.touch(mode=0o600)
            ready = directory / 'ready'
            script = '''
import os, pathlib, subprocess, sys, time
from Tools.parity.qualification_lease import child_command_lease
with child_command_lease() as descriptors:
    child = subprocess.Popen([sys.executable, '-c', 'import time; time.sleep(1.5)'],
                             start_new_session=True, pass_fds=descriptors)
pathlib.Path(sys.argv[1]).write_text(str(child.pid))
time.sleep(20)
'''
            environment = dict(os.environ, PYTHONPATH=str(ROOT),
                               CONTAINER_QUALIFICATION_COMMAND_LOCK=str(lock))
            outer = subprocess.Popen([sys.executable, '-c', script, str(ready)],
                                     env=environment, start_new_session=True)
            child_pid = None
            try:
                deadline = time.monotonic() + 5
                while not ready.exists() and time.monotonic() < deadline:
                    time.sleep(0.01)
                self.assertTrue(ready.exists(), 'outer controller never launched child')
                child_pid = int(ready.read_text())
                os.killpg(outer.pid, signal.SIGTERM)
                outer.wait(timeout=5)
                descriptor = os.open(lock, os.O_RDWR | os.O_NOFOLLOW)
                try:
                    with self.assertRaises(BlockingIOError):
                        fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
                    deadline = time.monotonic() + 5
                    while True:
                        try:
                            fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
                            break
                        except BlockingIOError:
                            if time.monotonic() >= deadline:
                                self.fail('detached child did not release lease after exit')
                            time.sleep(0.02)
                finally:
                    os.close(descriptor)
            finally:
                if outer.poll() is None:
                    os.killpg(outer.pid, signal.SIGKILL)
                    outer.wait(timeout=5)
                if child_pid is not None:
                    try:
                        os.kill(child_pid, signal.SIGKILL)
                    except ProcessLookupError:
                        pass


if __name__ == '__main__':
    unittest.main()
