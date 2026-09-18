"""Bundle declared plain test fixtures with SwiftPM's processed-file flattening."""

def _fixture_bundle_impl(ctx):
    names = [source.basename for source in ctx.files.srcs]
    if len(names) != len({name: True for name in names}):
        fail("Processed fixture basenames must be unique")
    bundle = ctx.actions.declare_directory(ctx.label.name + ".bundle")
    plist = ctx.actions.declare_file(ctx.label.name + "-Info.plist")
    ctx.actions.write(plist, """<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict><key>CFBundleIdentifier</key><string>local.compose.test-fixtures</string><key>CFBundlePackageType</key><string>BNDL</string></dict></plist>
""")
    ctx.actions.run_shell(
        inputs = ctx.files.srcs + [plist],
        outputs = [bundle],
        arguments = [bundle.path, plist.path] + [source.path for source in ctx.files.srcs],
        command = """set -eu
bundle="$1"
plist="$2"
shift 2
/bin/mkdir -p "$bundle/Contents/Resources"
/bin/cp "$plist" "$bundle/Contents/Info.plist"
for source in "$@"; do
  /bin/cp "$source" "$bundle/Contents/Resources/"
done
""",
        mnemonic = "ComposeFixtureBundle",
    )
    accessor = ctx.actions.declare_file(ctx.label.name + "-Accessor.swift")
    ctx.actions.write(accessor, """import Foundation

extension Bundle {
    static let module: Bundle = {
        let environment = ProcessInfo.processInfo.environment
        guard let root = environment["TEST_SRCDIR"],
              let workspace = environment["TEST_WORKSPACE"],
              let bundle = Bundle(path: root + "/" + workspace + "/%s") else {
            preconditionFailure("Missing declared Bazel fixture bundle")
        }
        return bundle
    }()
}
""" % bundle.short_path)
    return [
        DefaultInfo(files = depset([bundle, accessor])),
        OutputGroupInfo(bundle = depset([bundle]), accessor = depset([accessor])),
    ]

fixture_bundle = rule(
    implementation = _fixture_bundle_impl,
    attrs = {"srcs": attr.label_list(allow_files = True, mandatory = True)},
)
