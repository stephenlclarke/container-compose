"""Import one pinned package graph, selecting the stock or enhanced lockfile.

Package manifests remain owned by SwiftPM; rules_swift_package_manager generates
their native Bazel targets. This extension only selects immutable repository pins.
"""

load("@rules_swift_package_manager//swiftpkg:defs.bzl", "swift_package")
load("@bazel_tools//tools/build_defs/repo:http.bzl", "http_archive")

def _dependencies_impl(ctx):
    profile = ctx.getenv("DEVCONTAINER_RUNTIME_PROFILE", "enhanced")
    argument_parser_layer = ctx.getenv("COMPOSE_ARGUMENT_PARSER_LAYER", "source")
    layer_mirror = ctx.getenv("COMPOSE_ARGUMENT_PARSER_LAYER_MIRROR", "")
    modes = {
        "foundation": (ctx.getenv("COMPOSE_FOUNDATION_LAYER", "source"), ctx.getenv("COMPOSE_FOUNDATION_LAYER_MIRROR", "")),
        "containerization": (ctx.getenv("COMPOSE_CONTAINERIZATION_LAYER", "source"), ctx.getenv("COMPOSE_CONTAINERIZATION_LAYER_MIRROR", "")),
        "engine-api": (ctx.getenv("COMPOSE_ENGINE_API_LAYER", "source"), ctx.getenv("COMPOSE_ENGINE_API_LAYER_MIRROR", "")),
        "container-sdk": (ctx.getenv("COMPOSE_CONTAINER_SDK_LAYER", "source"), ctx.getenv("COMPOSE_CONTAINER_SDK_LAYER_MIRROR", "")),
    }
    if profile not in ["stock", "enhanced"]:
        fail("DEVCONTAINER_RUNTIME_PROFILE must be stock or enhanced")
    if argument_parser_layer not in ["source", "prebuilt"]:
        fail("COMPOSE_ARGUMENT_PARSER_LAYER must be source or prebuilt")
    if layer_mirror and argument_parser_layer != "prebuilt":
        fail("Binary layer mirror requires the explicit prebuilt profile")
    for group, selection in modes.items():
        if selection[0] not in ["source", "prebuilt"] or (selection[1] and selection[0] != "prebuilt"):
            fail(group + " mode and mirror must be selected explicitly")
    if modes["foundation"][0] == "prebuilt" and argument_parser_layer != "prebuilt":
        fail("foundational bundle requires the published ArgumentParser lower layer")
    for group in ["containerization", "engine-api"]:
        if modes[group][0] == "prebuilt" and modes["foundation"][0] != "prebuilt":
            fail(group + " binary requires the foundational binary")
    if modes["container-sdk"][0] == "prebuilt" and (modes["containerization"][0] != "prebuilt" or modes["engine-api"][0] != "prebuilt"):
        fail("Container SDK binary requires both published SDK lower layers")
    for mod in ctx.modules:
        for config in mod.tags.lockfiles:
            selected = config.stock if profile == "stock" else config.enhanced
            pins = json.decode(ctx.read(selected))["pins"]
            names = []
            for pin in pins:
                if pin["kind"] != "remoteSourceControl":
                    fail("Only immutable source-control package pins are supported")
                revision = pin["state"]["revision"]
                if len(revision) != 40 or any([c not in "0123456789abcdef" for c in revision.elems()]):
                    fail("Package revision must be a lowercase 40-character commit SHA")
                name = "swiftpkg_" + pin["identity"].replace("-", "_").replace(".", "_")
                if name in names:
                    fail("Duplicate package repository: " + name)
                names.append(name)
                group = None
                if pin["identity"] == "containerization":
                    group = "containerization"
                elif pin["identity"] == "container-engine-api":
                    group = "engine-api"
                elif pin["identity"] == "container":
                    group = "container-sdk"
                elif pin["identity"] not in ["swift-argument-parser", "swift-docc-plugin", "swift-docc-symbolkit"]:
                    group = "foundation"
                if group != None and modes[group][0] == "prebuilt":
                    lock = json.decode(ctx.read(Label("//Tools/bazel/artifacts/layer-locks:" + group + "-" + profile + ".json")))
                    if (lock.get("schema") != 1 or lock.get("group") != group or lock.get("profile") != profile or
                        lock.get("sourcePins", {}).get(pin["identity"]) != revision or
                        len(lock.get("archiveSHA256", "")) != 64):
                        fail(group + " bundle does not match the exact profile package pin")
                    mirror = modes[group][1]
                    if not mirror:
                        if lock.get("developmentProof") or not lock.get("repository") or not lock.get("tag") or not lock.get("asset"):
                            fail(group + " bundle requires a verified local archive mirror")
                        mirror = "https://github.com/" + lock["repository"] + "/releases/download/" + lock["tag"] + "/" + lock["asset"]
                    elif not mirror.startswith("/") or ".." in mirror.split("/"):
                        fail(group + " bundle mirror must be an absolute file without traversal")
                    http_archive(
                        name = name,
                        urls = [mirror if mirror.startswith("https://") else "file://" + mirror],
                        sha256 = lock["archiveSHA256"],
                        strip_prefix = group + "/" + name,
                    )
                    continue
                if pin["identity"] == "swift-argument-parser" and argument_parser_layer == "prebuilt":
                    lock = json.decode(ctx.read(Label("//Tools/bazel/artifacts:argument-parser.lock.json")))
                    manifest = lock.get("manifest", {})
                    if (lock.get("repository") != "stephenlclarke/container" or
                        manifest.get("sourceCommit") != revision or
                        manifest.get("package") != "swift-argument-parser" or
                        manifest.get("platform") != "darwin-arm64" or
                        manifest.get("configuration") != "opt" or
                        len(lock.get("archiveSHA256", "")) != 64):
                        fail("Reviewed ArgumentParser binary layer does not match the selected lockfile")
                    remote = "https://github.com/stephenlclarke/container/releases/download/" + lock["tag"] + "/" + lock["asset"]
                    urls = [remote]
                    if layer_mirror:
                        if not layer_mirror.startswith("/") or ".." in layer_mirror.split("/"):
                            fail("Binary layer mirror must be an absolute file without traversal")
                        urls = ["file://" + layer_mirror, remote]
                    http_archive(
                        name = name,
                        urls = urls,
                        sha256 = lock["archiveSHA256"],
                        strip_prefix = "argument-parser",
                        build_file = "//Tools/bazel/artifacts:argument_parser_import.BUILD.bazel",
                    )
                    continue
                patches = []
                if profile == "enhanced" and pin["identity"] == "containerization":
                    patches = ["//Tools/bazel:containerization-ext4-unaligned.patch"]
                if profile == "enhanced" and pin["identity"] == "zstd":
                    patches = ["//Tools/bazel:zstd-public-module.patch"]
                swift_package(
                    name = name,
                    bazel_package_name = name,
                    remote = pin["location"],
                    commit = revision,
                    version = pin["state"].get("version", ""),
                    publicly_expose_all_targets = True,
                    patches = patches,
                    patch_args = ["-p1"],
                )
    # The watched lockfile and profile fully determine immutable rule attributes.
    # Do not write a different generated-repository snapshot into the tracked
    # module lock every time the stock/enhanced profile changes.
    return ctx.extension_metadata(reproducible = True)

dependencies = module_extension(
    implementation = _dependencies_impl,
    tag_classes = {
        "lockfiles": tag_class(attrs = {
            "stock": attr.label(mandatory = True),
            "enhanced": attr.label(mandatory = True),
        }),
    },
)
