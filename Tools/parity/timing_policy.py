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

"""Shared timing policy for Docker Compose parity checks."""

from __future__ import annotations

import math


def slowdown_ratio(reference_seconds: float, candidate_seconds: float) -> float:
    """Return the candidate/reference duration ratio."""
    if not math.isfinite(reference_seconds) or not math.isfinite(candidate_seconds):
        raise ValueError("timing durations must be finite")
    if reference_seconds < 0 or candidate_seconds < 0:
        raise ValueError("timing durations must be non-negative")
    if reference_seconds == 0:
        return math.inf
    return candidate_seconds / reference_seconds


def exceeds_slowdown_boundary(
    reference_seconds: float,
    candidate_seconds: float,
    max_ratio: float,
) -> bool:
    """Return whether the candidate reaches the inclusive slowdown boundary."""
    if not math.isfinite(max_ratio) or max_ratio <= 0:
        raise ValueError("maximum slowdown ratio must be finite and positive")
    return slowdown_ratio(reference_seconds, candidate_seconds) >= max_ratio
