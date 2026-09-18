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

"""Compile declared native symbol graphs into an offline, source-pinned DocC site."""

import json
from pathlib import Path
import re
import shutil
import subprocess
import sys


def compile_site(spec):
    """No downloads, package resolution, compilation, signing or publication."""
    commit = spec["commit"]
    repository = spec["repository"]
    base = spec["hosting_base_path"]
    if not re.fullmatch(r"[0-9a-f]{40}", commit):
        raise ValueError("DocC requires the launcher-provided full source commit")
    if repository not in {"stephenlclarke/devcontainer", "stephenlclarke/container-compose"}:
        raise ValueError("DocC source repository is outside the product allowlist")
    if not re.fullmatch(r"[a-z0-9-]+", base):
        raise ValueError("DocC hosting base path must be one literal path component")
    modules = sorted(spec["modules"])
    output = Path(spec["output"])
    if spec["mode"] == "convert":
        arguments = conversion_arguments(spec, modules)
    elif spec["mode"] == "merge":
        found = []
        for archive in spec["archives"]:
            identity = json.loads((Path(archive) / "build-identity.json").read_text())
            if (identity["commit"], identity["repository"], identity["hostingBasePath"]) != (commit, repository, base):
                raise ValueError("Cannot merge documentation with different source or hosting identity")
            found.extend(identity["modules"])
        if not modules or sorted(found) != modules:
            raise ValueError("Merged documentation module inventory mismatch")
        arguments = ["merge", *spec["archives"], "--output-path", str(output),
                     "--synthesized-landing-page-name", base]
    else:
        raise ValueError("Unknown documentation operation")
    subprocess.run(["/usr/bin/xcrun", "docc", *arguments], check=True, timeout=300)
    materialize_links(output, spec["archives"], spec.get("catalog_files", []))
    # Keep the compiler's application shell: DocC uses it for client-side routes.
    # A root redirect is unnecessary on the current DocC renderer.
    if not (output / "index.html").is_file():
        raise ValueError("DocC did not produce a static site")
    (output / "theme-settings.json").write_text("{}\n")
    (output / "build-identity.json").write_text(json.dumps({
        "schema": 1, "commit": commit, "repository": repository,
        "modules": modules, "hostingBasePath": base,
    }, sort_keys=True, indent=2) + "\n")


def materialize_links(output, archives, resources=()):
    """DocC merge preserves Bazel's input symlinks; a published site must not."""
    allowed = {path.resolve(strict=True) for archive in archives
               for path in Path(archive).rglob("*") if path.is_file()}
    allowed.update(Path(path).resolve(strict=True) for path in resources)
    links = [(path, path.resolve(strict=True)) for path in output.rglob("*") if path.is_symlink()]
    for path, target in links:
        if target not in allowed or not target.is_file():
            raise ValueError("DocC output contains a link outside declared archive files")
    for path, target in links:
        path.unlink()
        shutil.copyfile(target, path)


def conversion_arguments(spec, modules):
    graphs = Path(spec["symbol_graphs"])
    found = sorted({json.loads(path.read_text())["module"]["name"]
                    for path in graphs.glob("*.symbols.json")})
    if len(modules) != 1 or found != modules:
        raise ValueError(f"DocC module inventory mismatch: expected {modules}, found {found}")
    arguments = ["convert"]
    if spec["catalog"]:
        arguments.append(spec["catalog"])
    arguments.extend([
        "--additional-symbol-graph-dir", str(graphs),
        "--output-path", spec["output"], "--warnings-as-errors",
        "--transform-for-static-hosting", "--hosting-base-path", spec["hosting_base_path"],
        "--fallback-display-name", modules[0],
        "--fallback-bundle-identifier", "com.github." + spec["repository"].replace("/", ".") + "." + modules[0],
        "--source-service", "github",
        "--source-service-base-url", f"https://github.com/{spec['repository']}/blob/{spec['commit']}",
        "--checkout-path", str(Path.cwd()), "--enable-experimental-external-link-support",
    ])
    for archive in spec["archives"]:
        arguments.extend(["--dependency", archive])
    return arguments


if __name__ == "__main__":
    compile_site(json.loads(Path(sys.argv[1]).read_text()))
