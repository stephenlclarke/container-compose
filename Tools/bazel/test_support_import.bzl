"""Test-support producer: compile only the admitted missing package targets."""

load("@build_bazel_rules_swift//swift:swift.bzl", _source_swift = "swift_library")
load("@rules_cc//cc:defs.bzl", _source_cc = "cc_library")
load("//Tools/bazel/artifacts:foundation_import.bzl", "import_cc_library", "import_swift_library")

def support_swift_library(artifacts, missing, **kwargs):
    if kwargs["name"] in missing:
        if kwargs["name"] in artifacts:
            fail("Test support cannot replace a published Swift target")
        _source_swift(**kwargs)
    else:
        import_swift_library(artifacts, **kwargs)

def support_cc_library(artifacts, header_only, header_sources, missing, **kwargs):
    if kwargs["name"] in missing:
        if kwargs["name"] in artifacts or kwargs["name"] in header_only:
            fail("Test support cannot replace a published C target")
        _source_cc(**kwargs)
    else:
        import_cc_library(artifacts, header_only, header_sources, **kwargs)
