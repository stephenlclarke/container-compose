"""Import sealed Swift and C outputs while retaining SwiftPM's dependency graph.

Generated package BUILD files call these macros in place of the two compiler
rules. All other generated rules, including resource bundles, metadata,
module-map generation and minimum-OS wrappers, retain their original edges.
"""

load("@build_bazel_rules_swift//swift:swift.bzl", _swift_import = "swift_import")
load("@rules_cc//cc:defs.bzl", _cc_import = "cc_import", _cc_library = "cc_library")

def import_swift_library(artifacts, name, module_name, deps = [], data = [], private_deps = [], plugins = [], **kwargs):
    artifact = artifacts.get(name)
    common = {"tags": kwargs.get("tags", [])}
    if kwargs.get("visibility") != None:
        common["visibility"] = kwargs["visibility"]
    if kwargs.get("features") != None:
        common["features"] = kwargs["features"]
    if artifact == None:
        # Generated BUILD files also describe test-only modules. Keep their
        # labels for package loading, but never compile source as a fallback.
        native.filegroup(name = name, srcs = [], **common)
        return
    if kwargs.get("alwayslink") != True:
        fail("sealed Swift import requires the original library's alwayslink semantics: " + name)
    _cc_library(name = name + ".prebuilt_linkopts", linkopts = kwargs.get("linkopts", []))
    deps = deps + [":" + name + ".prebuilt_linkopts"]
    imported = {
        "name": name,
        "module_name": module_name,
        "swiftmodule": artifact["swiftmodule"],
        "archives": [artifact["archive"]],
        "deps": deps + private_deps,
        "data": data,
        "plugins": plugins,
    }
    if artifact.get("swiftdoc") != None:
        imported["swiftdoc"] = artifact["swiftdoc"]
    imported.update(common)
    _swift_import(**imported)

def import_cc_library(artifacts, header_only, name, deps = [], **kwargs):
    artifact = artifacts.get(name)
    if artifact == None and name not in header_only:
        # An inactive source target may be present in SwiftPM's generated
        # BUILD. If it becomes reachable, it must fail for lack of CcInfo.
        common = {"tags": kwargs.get("tags", [])}
        if kwargs.get("visibility") != None:
            common["visibility"] = kwargs["visibility"]
        native.filegroup(name = name, srcs = [], **common)
        return
    if artifact != None:
        _cc_import(
            name = name + ".prebuilt_archive",
            static_library = artifact,
            alwayslink = kwargs.get("alwayslink", False),
        )
        deps = deps + [":" + name + ".prebuilt_archive"]
    # srcs may contain implementation code, so it is deliberately omitted.
    # The original hdrs/textual_hdrs, include paths, defines, linkopts,
    # aspect hints and dependencies still construct the C compilation and
    # linking providers consumed by Swift and upper C targets.
    attrs = {key: value for key, value in kwargs.items() if key != "srcs"}
    _cc_library(name = name, deps = deps, srcs = kwargs.get("srcs", []) if artifact == None else [], **attrs)
