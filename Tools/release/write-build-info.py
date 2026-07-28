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

"""Write container-compose package provenance metadata."""

from __future__ import annotations

import argparse
import json
from pathlib import Path


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", required=True)
    parser.add_argument("--version", required=True)
    parser.add_argument("--source", required=True)
    parser.add_argument("--branch", required=True)
    parser.add_argument("--lane", required=True)
    parser.add_argument("--commit", required=True)
    parser.add_argument("--build-type", required=True)
    parser.add_argument("--container-source", required=True)
    parser.add_argument("--container-ref", required=True)
    parser.add_argument("--containerization-source", required=True)
    parser.add_argument("--containerization-ref", required=True)
    parser.add_argument("--compose-go-version", required=True)
    parser.add_argument(
        "--runtime-capability-manifest",
        type=Path,
        default=Path(__file__).with_name("runtime-capabilities.json"),
    )
    return parser.parse_args()


def load_runtime_capability_manifest(path: Path) -> tuple[int, list[str]]:
    try:
        payload = json.loads(path.read_text(encoding="utf-8"))
    except FileNotFoundError as error:
        raise SystemExit(f"runtime capability manifest does not exist: {path}") from error
    except json.JSONDecodeError as error:
        raise SystemExit(f"invalid runtime capability manifest {path}: {error}") from error

    if not isinstance(payload, dict):
        raise SystemExit("runtime capability manifest must be a JSON object")
    schema_version = payload.get("schemaVersion")
    capabilities = payload.get("capabilities")
    if type(schema_version) is not int or schema_version < 1:
        raise SystemExit("runtime capability manifest schemaVersion must be a positive integer")
    if not isinstance(capabilities, list) or not capabilities:
        raise SystemExit("runtime capability manifest capabilities must be a non-empty list")
    if not all(
        isinstance(capability, str)
        and capability
        and capability == capability.strip()
        for capability in capabilities
    ):
        raise SystemExit("runtime capability manifest capability identifiers must be non-empty strings")
    if capabilities != sorted(capabilities):
        raise SystemExit("runtime capability manifest capabilities must be sorted")
    if len(capabilities) != len(set(capabilities)):
        raise SystemExit("runtime capability manifest capabilities must be unique")
    return schema_version, capabilities


def main() -> int:
    args = parse_args()
    runtime_capability_schema_version, runtime_capabilities = (
        load_runtime_capability_manifest(args.runtime_capability_manifest)
    )
    output = Path(args.output)
    output.parent.mkdir(parents=True, exist_ok=True)
    payload = {
        "version": args.version,
        "source": args.source,
        "branch": args.branch,
        "lane": args.lane,
        "commit": args.commit,
        "buildType": args.build_type,
        "containerSource": args.container_source,
        "containerRef": args.container_ref,
        "containerizationSource": args.containerization_source,
        "containerizationRef": args.containerization_ref,
        "composeGoVersion": args.compose_go_version,
        "runtimeCapabilitySchemaVersion": runtime_capability_schema_version,
        "runtimeCapabilities": runtime_capabilities,
    }
    output.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
