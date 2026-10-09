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

"""Check that SwiftPM's local overrides leave every remote pin authenticated."""

import argparse
import json
import os
from pathlib import Path


OVERRIDES = {
    "container": "CONTAINER_PACKAGE_PATH",
    "containerization": "CONTAINERIZATION_PACKAGE_PATH",
    "zstd": "ZSTD_PACKAGE_PATH",
}


def pins(path):
    value = json.loads(path.read_text())
    entries = value["pins"]
    result = {}
    for entry in entries:
        identity = entry["identity"]
        if identity in result:
            raise ValueError("Duplicate SwiftPM pin identity: " + identity)
        result[identity] = entry
    return result


def graph_overrides(graph, expected):
    found = {name: 0 for name in expected}

    def visit(node):
        if isinstance(node, list):
            for child in node:
                visit(child)
        elif isinstance(node, dict):
            name = node.get("name")
            identity = node.get("identity")
            if name in expected or identity in expected:
                selected_name = name if name in expected else identity
                selected = expected[selected_name]
                if (identity, name, node.get("url"), node.get("path"),
                        node.get("version")) != (selected_name, selected_name, selected,
                                                  selected, "unspecified"):
                    raise ValueError("SwiftPM did not select the reviewed local " + selected_name)
                found[selected_name] += 1
            for child in node.values():
                visit(child)

    visit(graph)
    if any(count == 0 for count in found.values()):
        raise ValueError("SwiftPM omitted a reviewed local package")
    return found


def verify(before, after, profile, graph=None, environment=None):
    old = pins(before)
    new = pins(after)
    allowed = set(OVERRIDES) if profile == "enhanced" else set()
    if profile not in ("stock", "enhanced"):
        raise ValueError("Unsupported SwiftPM profile")
    if not allowed.issubset(old):
        raise ValueError("Reviewed local override pin missing from original lock")
    if set(new) - set(old) or set(old) - set(new) - allowed:
        raise ValueError("SwiftPM changed the remote pin inventory")
    if any(new[name] != old[name] for name in new):
        raise ValueError("SwiftPM changed a remote pin")
    if allowed:
        if graph is None:
            raise ValueError("Missing resolved SwiftPM graph")
        env = os.environ if environment is None else environment
        expected = {}
        for name, variable in OVERRIDES.items():
            raw = env.get(variable, "")
            path = Path(raw)
            if not raw or not path.is_absolute() or not path.is_dir():
                raise ValueError("Missing reviewed local package path: " + name)
            expected[name] = str(path.resolve(strict=True))
        found = graph_overrides(json.loads(graph.read_text()), expected)
    else:
        found = {}
    return {"profile": profile, "retainedOverridePins": sorted(allowed & set(new)),
            "removedOverridePins": sorted(allowed - set(new)),
            "localGraphOccurrences": found}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--before", type=Path, required=True)
    parser.add_argument("--after", type=Path, required=True)
    parser.add_argument("--profile", choices=("stock", "enhanced"), required=True)
    parser.add_argument("--graph", type=Path)
    args = parser.parse_args()
    result = verify(args.before, args.after, args.profile, args.graph)
    print(json.dumps(result, sort_keys=True))


if __name__ == "__main__":
    main()
