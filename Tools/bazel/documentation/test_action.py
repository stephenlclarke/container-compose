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

"""Action fault tests and real DocC artifact smoke checks (no runtime services)."""

import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

from action import compile_site, materialize_links


class ActionTests(unittest.TestCase):
    def setUp(self):
        scratch = tempfile.TemporaryDirectory(prefix="native-docc-test-")
        self.addCleanup(scratch.cleanup)
        self.root = Path(scratch.name)
        self.graphs = self.root / "graphs"
        self.graphs.mkdir()
        (self.graphs / "Module.symbols.json").write_text(json.dumps({"module": {"name": "Module"}}))
        self.output = self.root / "site"
        self.spec = {
            "mode": "convert", "catalog": "Sources/Module/Module.docc",
            "commit": "a" * 40, "repository": "stephenlclarke/devcontainer",
            "hosting_base_path": "devcontainer", "modules": ["Module"],
            "symbol_graphs": str(self.graphs), "output": str(self.output), "archives": [],
        }

    def fake_compile(self, arguments, **kwargs):
        self.output.mkdir()
        (self.output / "index.html").write_text("<html>DocC application</html>")

    def test_convert_declared_native_inputs_and_preserve_application(self):
        with patch("action.subprocess.run", side_effect=self.fake_compile) as run:
            compile_site(self.spec)
        args = run.call_args.args[0]
        self.assertEqual(args[:3], ["/usr/bin/xcrun", "docc", "convert"])
        self.assertIn("--warnings-as-errors", args)
        self.assertIn("https://github.com/stephenlclarke/devcontainer/blob/" + "a" * 40, args)
        self.assertEqual(run.call_args.kwargs, {"check": True, "timeout": 300})
        self.assertEqual((self.output / "index.html").read_text(), "<html>DocC application</html>")
        identity = json.loads((self.output / "build-identity.json").read_text())
        self.assertEqual(identity["modules"], ["Module"])
        self.assertEqual(identity["commit"], "a" * 40)

    def test_no_catalog_and_explicit_dependency(self):
        self.spec["catalog"] = ""
        self.spec["archives"] = [str(self.root / "dependency")]
        with patch("action.subprocess.run", side_effect=self.fake_compile) as run:
            compile_site(self.spec)
        args = run.call_args.args[0]
        self.assertNotIn("", args)
        self.assertEqual(args[-2:], ["--dependency", self.spec["archives"][0]])

    def test_reject_invalid_identity_before_tool_execution(self):
        for key, value in [("commit", "main"), ("repository", "other/project"),
                           ("hosting_base_path", "../elsewhere"), ("mode", "publish"),
                           ("modules", []), ("modules", ["Other"])]:
            spec = dict(self.spec, **{key: value})
            with self.subTest(key=key, value=value), patch("action.subprocess.run") as run:
                with self.assertRaises(ValueError):
                    compile_site(spec)
                run.assert_not_called()

    def test_tool_failure_or_timeout_never_creates_success_identity(self):
        for error in [subprocess.CalledProcessError(1, "docc"), subprocess.TimeoutExpired("docc", 300)]:
            with self.subTest(error=type(error).__name__), patch("action.subprocess.run", side_effect=error):
                with self.assertRaises(type(error)):
                    compile_site(self.spec)
                self.assertFalse((self.output / "build-identity.json").exists())

    def test_missing_static_site_is_failure(self):
        with patch("action.subprocess.run"):
            with self.assertRaisesRegex(ValueError, "static site"):
                compile_site(self.spec)

    def make_archive(self, name):
        root = self.root / name
        root.mkdir()
        (root / "build-identity.json").write_text(json.dumps({
            "commit": "a" * 40, "repository": self.spec["repository"],
            "hostingBasePath": "devcontainer", "modules": [name],
        }))
        (root / "index.html").write_text("original")
        return root

    def test_merge_materializes_input_links_without_modifying_inputs(self):
        archives = [self.make_archive("One"), self.make_archive("Two")]
        self.spec.update(mode="merge", modules=["One", "Two"], archives=list(map(str, archives)))

        def merge(arguments, **kwargs):
            self.output.mkdir()
            (self.output / "index.html").symlink_to(archives[0] / "index.html")
            (self.output / "build-identity.json").symlink_to(archives[0] / "build-identity.json")

        with patch("action.subprocess.run", side_effect=merge):
            compile_site(self.spec)
        self.assertFalse((self.output / "index.html").is_symlink())
        self.assertEqual((archives[0] / "index.html").read_text(), "original")
        self.assertEqual(json.loads((archives[0] / "build-identity.json").read_text())["modules"], ["One"])
        self.assertEqual(json.loads((self.output / "build-identity.json").read_text())["modules"], ["One", "Two"])

    def test_merge_refuses_wrong_identity_or_inventory(self):
        archive = self.make_archive("One")
        self.spec.update(mode="merge", modules=["One"], archives=[str(archive)])
        for key, value in [("commit", "b" * 40), ("modules", ["One", "Two"])]:
            spec = dict(self.spec, **{key: value})
            with self.subTest(key=key), patch("action.subprocess.run") as run:
                with self.assertRaises(ValueError):
                    compile_site(spec)
                run.assert_not_called()

    def test_external_or_directory_links_are_rejected_without_mutation(self):
        archive = self.make_archive("One")
        foreign = self.root / "foreign"
        foreign.write_text("not a declared input")
        self.output.mkdir()
        link = self.output / "unsafe"
        for target in [foreign, archive]:
            link.symlink_to(target)
            with self.subTest(target=target.name):
                with self.assertRaisesRegex(ValueError, "outside declared"):
                    materialize_links(self.output, [str(archive)])
                self.assertTrue(link.is_symlink())
            link.unlink()

    def test_catalog_image_link_becomes_standalone_file(self):
        image = self.root / "icon.png"
        image.write_bytes(b"declared catalog resource")
        self.output.mkdir()
        link = self.output / "icon.png"
        link.symlink_to(image)
        materialize_links(self.output, [], [str(image)])
        self.assertFalse(link.is_symlink())
        self.assertEqual(link.read_bytes(), image.read_bytes())


if __name__ == "__main__":
    site = Path(sys.argv.pop(1))

    class ArtifactTests(unittest.TestCase):
        def test_all_declared_modules_rendered(self):
            identity = json.loads((site / "build-identity.json").read_text())
            self.assertRegex(identity["commit"], r"^[a-f0-9]{40}$")
            self.assertTrue(identity["modules"])
            for module in identity["modules"]:
                document = json.loads((site / "data/documentation" / (module.lower() + ".json")).read_text())
                self.assertEqual(document["metadata"]["title"], module)
                self.assertTrue((site / "documentation" / module.lower() / "index.html").is_file())

        def test_no_local_source_paths_or_unpinned_source_links(self):
            identity = json.loads((site / "build-identity.json").read_text())
            for path in (site / "data").rglob("*.json"):
                text = path.read_text().replace("\\/", "/")
                self.assertNotIn("/Users/sclarke/", text, path.name)
                self.assertNotIn("/Volumes/SSD/cf/", text, path.name)
                if "sourceFileURI" in text:
                    self.assertIn("/blob/" + identity["commit"] + "/", text, path.name)

        def test_static_assets_present(self):
            self.assertTrue((site / "index.html").is_file())
            self.assertTrue(list((site / "js").glob("*.js")))
            self.assertTrue(list((site / "css").glob("*.css")))

    unittest.main()
