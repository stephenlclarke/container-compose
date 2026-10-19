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

"""Carry Q's existing command lease through parity's detached CLI children."""

from contextlib import contextmanager
import fcntl
import os
import stat

COMMAND_LOCK_ENV = 'CONTAINER_QUALIFICATION_COMMAND_LOCK'


@contextmanager
def child_command_lease():
    path = os.environ.get(COMMAND_LOCK_ENV)
    if not path:
        yield ()
        return
    descriptor = os.open(path, os.O_RDWR | os.O_NOFOLLOW)
    try:
        information = os.fstat(descriptor)
        if (not stat.S_ISREG(information.st_mode) or information.st_uid != os.getuid()
                or information.st_nlink != 1 or information.st_mode & 0o022):
            raise RuntimeError('Qualification command lease is not a private single-owner file')
        fcntl.flock(descriptor, fcntl.LOCK_SH | fcntl.LOCK_NB)
        yield (descriptor,)
    finally:
        os.close(descriptor)
