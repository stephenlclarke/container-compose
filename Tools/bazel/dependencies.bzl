"""Import one pinned package graph, selecting the stock or enhanced lockfile.

Package manifests remain owned by SwiftPM; rules_swift_package_manager generates
their native Bazel targets. This extension only selects immutable repository pins.
"""

load("@rules_swift_package_manager//swiftpkg:defs.bzl", "swift_package")

def _dependencies_impl(ctx):
    profile = ctx.getenv("DEVCONTAINER_RUNTIME_PROFILE", "enhanced")
    if profile not in ["stock", "enhanced"]:
        fail("DEVCONTAINER_RUNTIME_PROFILE must be stock or enhanced")
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
                swift_package(
                    name = name,
                    bazel_package_name = name,
                    remote = pin["location"],
                    commit = revision,
                    version = pin["state"].get("version", ""),
                    publicly_expose_all_targets = True,
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
