# Copyright 2026 container-compose project authors. SPDX-License-Identifier: Apache-2.0
"""Expose finite license texts without changing selected package BUILD files."""

NOTICE_FILES = {
    "swiftpkg_containerization": ["Sources/ContainerizationArchive/CArchive/COPYING"],
    "swiftpkg_swift_crypto": ["NOTICE.txt"],
    "swiftpkg_swift_nio": ["Sources/CNIOLLHTTP/LICENSE"],
    "swiftpkg_swift_nio_ssl": ["NOTICE.txt"],
    "swiftpkg_swift_protobuf": [
        "Sources/protobuf/abseil/LICENSE",
        "Sources/protobuf/protobuf/LICENSE",
        "Sources/protobuf/protobuf/third_party/utf8_range/LICENSE",
    ],
}

def _notice_exports_impl(ctx):
    if sorted(ctx.attr.packages.values()) != sorted(NOTICE_FILES):
        fail("Notice exports require the exact selected package inventory")
    files = []
    for label, repository in ctx.attr.packages.items():
        root = ctx.path(label).dirname
        for relative in NOTICE_FILES[repository]:
            source = root.get_child(relative)
            if not source.exists or not str(source.realpath).startswith(str(root.realpath) + "/"):
                fail("Selected package notice is missing or leaves its source root")
            content = ctx.read(source)
            if not content.strip():
                fail("Selected package notice is empty")
            target = repository + "/" + relative
            ctx.file(target, content, executable = False)
            files.append(target)
    ctx.file("BUILD.bazel", "exports_files(" + json.encode(sorted(files)) + ")\n" +
             "filegroup(name = \"notices\", srcs = " + json.encode(sorted(files)) +
             ", visibility = [\"//visibility:public\"])\n", executable = False)

_notice_exports = repository_rule(
    implementation = _notice_exports_impl,
    attrs = {"packages": attr.label_keyed_string_dict(mandatory = True)},
)

def compose_notice_exports(name):
    """Locate files through public metadata labels for source or native imports."""
    _notice_exports(
        name = name,
        packages = {"@" + repository + "//:pkg_info.json": repository for repository in NOTICE_FILES},
    )
