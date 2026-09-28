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

"""Request compiled package interfaces in the configured //:compose closure."""

_LayerFiles = provider(fields = ["files"])
_BINARY_SUFFIXES = (".swiftmodule", ".swiftdoc", ".a", ".lo")
_FOUNDATION_EXCLUDED = {
    "swiftpkg_container": True,
    "swiftpkg_containerization": True,
    "swiftpkg_container_engine_api": True,
    "swiftpkg_swift_argument_parser": True,
    "swiftpkg_swift_docc_plugin": True,
    "swiftpkg_swift_docc_symbolkit": True,
}
_GROUP_REPOSITORIES = {
    "containerization": "swiftpkg_containerization",
    "engine-api": "swiftpkg_container_engine_api",
    "container-sdk": "swiftpkg_container",
}


def _selected(target, group):
    repository = target.label.workspace_name
    if not repository.startswith("+dependencies+swiftpkg_"):
        return False
    package = repository[len("+dependencies+"):]
    if group == "foundation":
        return package not in _FOUNDATION_EXCLUDED
    return package == _GROUP_REPOSITORIES[group]


def _collect(target, ctx, group):
    transitive = []
    if ctx.rule and hasattr(ctx.rule.attr, "deps"):
        for dependency in ctx.rule.attr.deps:
            if _LayerFiles in dependency:
                transitive.append(dependency[_LayerFiles].files)
    direct = []
    if _selected(target, group) and DefaultInfo in target:
        direct = [file for file in target[DefaultInfo].files.to_list()
                  if any([file.basename.endswith(suffix) for suffix in _BINARY_SUFFIXES])]
    files = depset(direct = direct, transitive = transitive)
    return [_LayerFiles(files = files), OutputGroupInfo(layer_compiled = files)]


def _foundation(target, ctx):
    return _collect(target, ctx, "foundation")


def _containerization(target, ctx):
    return _collect(target, ctx, "containerization")


def _engine_api(target, ctx):
    return _collect(target, ctx, "engine-api")


def _container_sdk(target, ctx):
    return _collect(target, ctx, "container-sdk")


foundation_outputs = aspect(implementation = _foundation, attr_aspects = ["deps"])
containerization_outputs = aspect(implementation = _containerization, attr_aspects = ["deps"])
engine_api_outputs = aspect(implementation = _engine_api, attr_aspects = ["deps"])
container_sdk_outputs = aspect(implementation = _container_sdk, attr_aspects = ["deps"])
