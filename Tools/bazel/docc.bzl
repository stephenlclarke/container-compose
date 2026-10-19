# Copyright 2026 devcontainer project authors. SPDX-License-Identifier: Apache-2.0
"""Generate a static DocC site from native Bazel modules, without SwiftPM."""

load("@apple_support//lib:apple_support.bzl", "apple_support")
load("@build_bazel_rules_swift//swift:swift_extract_symbol_graph.bzl", "swift_extract_symbol_graph")
load("@rules_shell//shell:sh_test.bzl", "sh_test")

def _docc_impl(ctx):
    if ctx.var["COMPILATION_MODE"] != "opt":
        fail("Documentation requires --config=release to reuse release modules and bind source identity")
    if ctx.var.get("DEVCONTAINER_SOURCE_DIRTY", "unknown") != "false":
        fail("Documentation requires a captured clean source checkpoint; commit changes before generating a revision-labelled site")
    output = ctx.actions.declare_directory(ctx.label.name + ".doccarchive")
    manifest = ctx.actions.declare_file(ctx.label.name + ".inputs.json")
    ctx.actions.write(manifest, json.encode({
        "mode": ctx.attr.mode,
        "catalog": ctx.attr.catalog_path,
        "catalog_files": [file.path for file in ctx.files.catalog],
        "commit": ctx.var.get("DEVCONTAINER_COMMIT", "unspecified"),
        "hosting_base_path": ctx.attr.hosting_base_path,
        "modules": ctx.attr.modules,
        "repository": ctx.attr.repository,
        "symbol_graphs": ctx.file.symbol_graphs.path if ctx.file.symbol_graphs else None,
        "archives": [file.path for file in ctx.files.archives],
        "output": output.path,
    }))
    apple_support.run(
        actions = ctx.actions,
        apple_fragment = ctx.fragments.apple,
        xcode_config = ctx.attr._xcode_config[apple_common.XcodeVersionConfig],
        executable = "/usr/bin/python3",
        arguments = [ctx.file._runner.path, manifest.path],
        inputs = [manifest, ctx.file._runner] + ctx.files.symbol_graphs + ctx.files.catalog + ctx.files.archives,
        outputs = [output],
        env = {
            "PYTHONDONTWRITEBYTECODE": "1",
            "TMPDIR": ctx.configuration.default_shell_env.get("TMPDIR", ""),
        },
        mnemonic = "NativeDocC",
        progress_message = "Generating native DocC site for " + ctx.attr.repository,
    )
    return [DefaultInfo(files = depset([output]))]

_docc = rule(
    implementation = _docc_impl,
    fragments = ["apple"],
    attrs = dict(apple_support.action_required_attrs(), **{
        "catalog": attr.label_list(allow_files = True),
        "mode": attr.string(values = ["convert", "merge"], default = "convert"),
        "catalog_path": attr.string(),
        "hosting_base_path": attr.string(mandatory = True),
        "modules": attr.string_list(mandatory = True),
        "repository": attr.string(mandatory = True),
        "symbol_graphs": attr.label(allow_single_file = True),
        "archives": attr.label_list(allow_files = True),
        "_runner": attr.label(default = Label("//Tools/bazel:documentation/action.py"), allow_single_file = True),
    }),
)

def native_docc(name, modules, catalog, catalog_path, catalog_module, repository, hosting_base_path):
    """Document only the explicitly listed product modules and catalog."""
    if catalog_module not in modules:
        fail("The catalog module must be included in the documented inventory")
    for module in modules:
        target = name + "_" + module if len(modules) > 1 else name
        swift_extract_symbol_graph(
            name = target + "_symbols",
            targets = [":" + module],
            minimum_access_level = "public",
        )
        _docc(
            name = target,
            modules = [module],
            catalog = catalog if module == catalog_module else [],
            catalog_path = catalog_path if module == catalog_module else "",
            repository = repository,
            hosting_base_path = hosting_base_path,
            symbol_graphs = ":" + target + "_symbols",
            archives = [":" + name + "_" + dependency for dependency in modules if dependency != module] if module == catalog_module else [],
        )
    if len(modules) > 1:
        _docc(
            name = name,
            mode = "merge",
            modules = modules,
            archives = [":" + name + "_" + module for module in modules],
            repository = repository,
            hosting_base_path = hosting_base_path,
        )
    sh_test(
        name = name + "_tests",
        srcs = ["//Tools/bazel:documentation/test.sh"],
        args = ["$(location //Tools/bazel:documentation/test_action.py)", "$(location :" + name + ")"],
        data = [":" + name, "//Tools/bazel:documentation/test_action.py", "//Tools/bazel:documentation/action.py"],
        size = "small",
    )
