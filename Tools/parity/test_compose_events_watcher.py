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

"""Focused tests for bounded Compose events watcher shutdown."""

from __future__ import annotations

import subprocess
import tempfile
import time
import unittest
from pathlib import Path


REPOSITORY = Path(__file__).parents[2]
HARNESS = REPOSITORY / "Tools" / "parity" / "check-compose-events.sh"


class EventsWatcherShutdownTests(unittest.TestCase):
    def test_term_resistant_process_tree_is_killed_within_deadline(self) -> None:
        with tempfile.TemporaryDirectory(prefix="compose-events-watcher-") as directory:
            root = Path(directory)
            resistant = root / "term-resistant.sh"
            resistant.write_text(
                "#!/usr/bin/env bash\n"
                "trap '' TERM\n"
                "bash -c 'trap \"\" TERM; while true; do sleep 1; done' &\n"
                "wait\n",
                encoding="utf-8",
            )
            resistant.chmod(0o755)
            events = root / "events.jsonl"

            started = time.monotonic()
            result = subprocess.run(
                [
                    "bash",
                    "-c",
                    (
                        'EVENTS_STOP_TIMEOUT_SECONDS=1; source "$1"; '
                        'EVENTS_FILE="$2"; DOCKER_COMPOSE_COMMAND=("$3"); '
                        "start_events_watcher; watcher_pid=$EVENTS_PID; "
                        "stop_events_watcher; "
                        'if kill -0 -- "-$watcher_pid" 2>/dev/null; then exit 91; fi'
                    ),
                    "_",
                    HARNESS,
                    events,
                    resistant,
                ],
                cwd=REPOSITORY,
                capture_output=True,
                check=False,
                text=True,
                timeout=8,
            )
            elapsed = time.monotonic() - started

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertLess(elapsed, 5, f"watcher shutdown took {elapsed:.2f}s")


if __name__ == "__main__":
    unittest.main()
