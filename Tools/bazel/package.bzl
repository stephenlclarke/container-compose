# Copyright 2026 container-compose project authors. SPDX-License-Identifier: Apache-2.0
"""Native unsigned package layout; no builds, signing or publication subprocesses."""

load("@rules_pkg//pkg:mappings.bzl", "pkg_attributes", "pkg_files", "strip_prefix")
load("@rules_pkg//pkg:tar.bzl", "pkg_tar")
load("@rules_license//rules:gather_licenses_info.bzl", "gather_licenses_info", "write_licenses_info")

def _metadata_impl(ctx):
    if ctx.var["COMPILATION_MODE"] != "opt":
        fail("Candidate packaging requires --config=release")
    manifest = ctx.actions.declare_file(ctx.label.name + ".inputs.json")
    info = ctx.actions.declare_file(ctx.label.name + "/build-info.json")
    identity = ctx.actions.declare_file(ctx.label.name + "/candidate.json")
    notices = ctx.actions.declare_file(ctx.label.name + "/THIRD-PARTY-NOTICES.txt")
    licenses = ctx.actions.declare_file(ctx.label.name + ".licenses.json")
    license_files = write_licenses_info(ctx, ctx.attr.binaries, licenses)
    binaries = [target[DefaultInfo].files_to_run.executable for target in ctx.attr.binaries]
    if None in binaries:
        fail("Candidate inputs must be executable targets")
    ctx.actions.write(manifest, json.encode({
        "binaries": {binary.basename: binary.path for binary in binaries},
        "makefile": ctx.file.makefile.path,
        "resolved": ctx.file.resolved.path,
        "go_mod": ctx.file.go_mod.path,
        "go_sum": ctx.file.go_sum.path,
        "capabilities": ctx.file.capabilities.path,
        "profile": ctx.attr.profile,
        "commit": ctx.var.get("DEVCONTAINER_COMMIT", "unspecified"),
        "licenses": licenses.path,
        "go_inventory": ctx.file.go_inventory.path,
        "sdk_notices": [file.path for file in ctx.files.sdk_notices],
        "vendor_inventory": ctx.file.vendor_inventory.path,
        "vendor_notices": [file.path for file in ctx.files.vendor_notices],
    }))
    ctx.actions.run(
        executable = "/usr/bin/python3",
        arguments = [ctx.file._tool.path, "metadata", manifest.path, info.path, identity.path, ctx.file._build_info.path, notices.path],
        inputs = [manifest, ctx.file.makefile, ctx.file.resolved, ctx.file.go_mod, ctx.file.go_sum,
                  ctx.file.capabilities, ctx.file._tool, ctx.file._build_info, licenses, ctx.file.go_inventory,
                  ctx.file.vendor_inventory] + binaries + license_files + ctx.files.sdk_notices + ctx.files.vendor_notices,
        outputs = [info, identity, notices],
        mnemonic = "ComposePackageIdentity",
        env = {"PYTHONDONTWRITEBYTECODE": "1"},
    )
    return [DefaultInfo(files = depset([info, identity, notices])), OutputGroupInfo(identity = depset([identity]))]

_metadata = rule(
    implementation = _metadata_impl,
    attrs = {
        "binaries": attr.label_list(aspects = [gather_licenses_info], mandatory = True),
        "go_inventory": attr.label(allow_single_file = True, mandatory = True),
        "sdk_notices": attr.label_list(allow_files = True, mandatory = True),
        "vendor_inventory": attr.label(allow_single_file = True, mandatory = True),
        "vendor_notices": attr.label_list(allow_files = True, mandatory = True),
        "makefile": attr.label(allow_single_file = True, mandatory = True),
        "resolved": attr.label(allow_single_file = True, mandatory = True),
        "go_mod": attr.label(allow_single_file = True, mandatory = True),
        "go_sum": attr.label(allow_single_file = True, mandatory = True),
        "capabilities": attr.label(allow_single_file = True, mandatory = True),
        "profile": attr.string(values = ["stock", "enhanced"], mandatory = True),
        "_tool": attr.label(default = Label("//Tools/bazel:package.py"), allow_single_file = True),
        "_build_info": attr.label(default = Label("//:Tools/release/write-build-info.py"), allow_single_file = True),
    },
)

def _receipt_impl(ctx):
    receipt = ctx.actions.declare_file(ctx.label.name + ".json")
    ctx.actions.run(
        executable = "/usr/bin/python3",
        arguments = [ctx.file._tool.path, "receipt", ctx.file.archive.path, ctx.file.identity.path, receipt.path],
        inputs = [ctx.file._tool, ctx.file.archive, ctx.file.identity],
        outputs = [receipt],
        mnemonic = "ComposePackageReceipt",
        env = {"PYTHONDONTWRITEBYTECODE": "1"},
    )
    return [DefaultInfo(files = depset([ctx.file.archive, receipt]))]

_receipt = rule(
    implementation = _receipt_impl,
    attrs = {
        "archive": attr.label(allow_single_file = True, mandatory = True),
        "identity": attr.label(allow_single_file = True, mandatory = True),
        "_tool": attr.label(default = Label("//Tools/bazel:package.py"), allow_single_file = True),
    },
)

def compose_candidate(name, profile, resolved):
    """Assemble existing native outputs through deterministic rules_pkg actions."""
    cli = "//:compose"
    normalizer = "//Tools/compose-normalizer:compose-normalizer"
    initializers = ["//Tools/compose-normalizer/cmd/volume-initializer:compose-volume-initializer-linux-" + arch for arch in ["arm64", "amd64"]]
    _metadata(
        name = name + "_metadata",
        binaries = [cli, normalizer] + initializers,
        makefile = "//:Makefile",
        resolved = resolved,
        go_mod = "//Tools/compose-normalizer:go.mod",
        go_sum = "//Tools/compose-normalizer:go.sum",
        capabilities = "//:Tools/release/runtime-capabilities.json",
        profile = profile,
        go_inventory = "//Tools/bazel:licenses/inventory.json",
        sdk_notices = ["@main___download_0//:LICENSE", "@main___download_0//:PATENTS"],
        vendor_inventory = "//Tools/bazel:licenses/vendored.json",
        vendor_notices = [
            "//Tools/bazel:licenses/boringssl-0226f30467f540a3f62ef48d453f93927da199b6.txt",
            "//Tools/bazel:licenses/boringssl-817ab07ebb53da35afea409ab9328f578492832d.txt",
        ],
    )
    native.filegroup(name = name + "_identity", srcs = [":" + name + "_metadata"], output_group = "identity")
    groups = []
    for suffix, srcs, prefix, mode in [
        ("cli", [cli], "bin", "0755"),
        ("normalizer", [normalizer], "resources", "0755"),
        ("initializers", initializers, "resources/volume-initializer", "0755"),
        ("config", ["//:config.toml", "//:LICENSE"], "", "0644"),
        ("metadata_files", [":" + name + "_metadata"], "resources", "0644"),
    ]:
        group = name + "_" + suffix
        pkg_files(name = group, srcs = srcs, prefix = prefix, strip_prefix = strip_prefix.files_only(), attributes = pkg_attributes(mode = mode))
        groups.append(":" + group)
    pkg_files(
        name = name + "_icon",
        srcs = ["//:docs/images/container-compose-icon-octopus.png"],
        renames = {"//:docs/images/container-compose-icon-octopus.png": "container-compose-icon.png"},
        prefix = "resources",
        attributes = pkg_attributes(mode = "0644"),
    )
    pkg_tar(
        name = name + "_payload",
        out = name + ".tar.gz",
        srcs = groups + [":" + name + "_icon"],
        package_dir = "compose",
        extension = "tar.gz",
        portable_mtime = True,
        stamp = 0,
        allow_duplicates_with_different_content = False,
    )
    _receipt(name = name, archive = ":" + name + "_payload", identity = ":" + name + "_identity")
