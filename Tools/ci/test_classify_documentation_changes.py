#!/usr/bin/env python3
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

"""Tests for documentation change classification."""

import importlib.util
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


MODULE_PATH = Path(__file__).with_name("classify-documentation-changes.py")
SPEC = importlib.util.spec_from_file_location("classify_documentation_changes", MODULE_PATH)
assert SPEC and SPEC.loader
CLASSIFIER = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = CLASSIFIER
SPEC.loader.exec_module(CLASSIFIER)


class DocumentationChangeClassifierTests(unittest.TestCase):
    """The classifier skips only changes proven not to affect DocC output."""

    def setUp(self) -> None:
        self.temporary_directory = tempfile.TemporaryDirectory()
        self.repository = Path(self.temporary_directory.name)
        self.git("init", "-q")
        self.git("config", "user.email", "tests@example.com")
        self.git("config", "user.name", "Tests")
        self.git("config", "commit.gpgsign", "false")

    def tearDown(self) -> None:
        self.temporary_directory.cleanup()

    def git(self, *arguments: str) -> str:
        result = subprocess.run(
            ["git", "-C", str(self.repository), *arguments],
            check=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )
        return result.stdout.strip()

    def commit(self, files: dict[str, str], message: str) -> str:
        for relative_path, contents in files.items():
            path = self.repository / relative_path
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(contents, encoding="utf-8")
        self.git("add", "--all")
        self.git("commit", "-q", "-m", message)
        return self.git("rev-parse", "HEAD")

    def test_implementation_only_change_skips_docc(self) -> None:
        base = self.commit(
            {
                "Sources/App/Feature.swift": """
public struct Feature {
    public init() {}

    public func value() -> Int {
        let internalValue = 1
        return internalValue
    }
}
"""
            },
            "base",
        )
        head = self.commit(
            {
                "Sources/App/Feature.swift": """
public struct Feature {
    public init() {}

    public func value() -> Int {
        let internalValue = 2
        return internalValue
    }
}
"""
            },
            "implementation",
        )

        result = CLASSIFIER.classify(self.repository, base, head)

        self.assertFalse(result.build_docc)
        self.assertEqual(result.reason, "implementation-only Swift change")
        self.assertEqual(result.base_api_fingerprint, result.head_api_fingerprint)

    def test_multiline_public_signature_change_builds_docc(self) -> None:
        base = self.commit(
            {
                "Sources/App/Feature.swift": """
public func render(
    value: String
) -> String {
    value
}
"""
            },
            "base",
        )
        head = self.commit(
            {
                "Sources/App/Feature.swift": """
public func render(
    value: String,
    suffix: String
) -> String {
    value + suffix
}
"""
            },
            "api",
        )

        result = CLASSIFIER.classify(self.repository, base, head)

        self.assertTrue(result.build_docc)
        self.assertEqual(result.reason, "documented Swift API changed")

    def test_public_documentation_change_builds_docc(self) -> None:
        base = self.commit(
            {"Sources/App/Feature.swift": "/// Old.\npublic struct Feature {}\n"},
            "base",
        )
        head = self.commit(
            {"Sources/App/Feature.swift": "/// New.\npublic struct Feature {}\n"},
            "docs",
        )

        result = CLASSIFIER.classify(self.repository, base, head)

        self.assertTrue(result.build_docc)

    def test_protocol_requirement_and_enum_case_are_documented_api(self) -> None:
        base = self.commit(
            {
                "Sources/App/Feature.swift": """
public protocol Feature {
    func start()
}

public enum State {
    case ready
}
"""
            },
            "base",
        )
        head = self.commit(
            {
                "Sources/App/Feature.swift": """
public protocol Feature {
    func start(options: Int)
}

public enum State {
    case ready
    case stopped
}
"""
            },
            "api",
        )

        result = CLASSIFIER.classify(self.repository, base, head)

        self.assertTrue(result.build_docc)

    def test_static_public_signature_is_documented_api(self) -> None:
        base = self.commit(
            {
                "Sources/App/Feature.swift": """
public struct Feature {
    public static func value() -> Int { 1 }
}
"""
            },
            "base",
        )
        head = self.commit(
            {
                "Sources/App/Feature.swift": """
public struct Feature {
    public static func value(options: Int) -> Int { options }
}
"""
            },
            "api",
        )

        result = CLASSIFIER.classify(self.repository, base, head)

        self.assertTrue(result.build_docc)
        self.assertEqual(result.reason, "documented Swift API changed")

    def test_static_protocol_requirement_is_documented_api(self) -> None:
        base = self.commit(
            {
                "Sources/App/Feature.swift": """
public protocol Feature {
    static func make() -> Self
}
"""
            },
            "base",
        )
        head = self.commit(
            {
                "Sources/App/Feature.swift": """
public protocol Feature {
    static func make(options: Int) -> Self
}
"""
            },
            "api",
        )

        result = CLASSIFIER.classify(self.repository, base, head)

        self.assertTrue(result.build_docc)

    def test_macro_implementation_fails_safe(self) -> None:
        base = self.commit(
            {"Sources/Macros/Feature.swift": "let implementation = 1\n"},
            "base",
        )
        head = self.commit(
            {
                "Sources/Macros/Feature.swift": (
                    "let implementation = #externalMacro(module: \"M\", type: \"T\")\n"
                )
            },
            "macro",
        )

        result = CLASSIFIER.classify(self.repository, base, head)

        self.assertTrue(result.build_docc)
        self.assertIn("ambiguous Swift API", result.reason)

    def test_benchmark_report_only_skips_docc(self) -> None:
        base = self.commit({"README.md": "root\n"}, "base")
        head = self.commit(
            {"docs/benchmarks/0.14.0-vs-0.13.0.md": "evidence\n"},
            "benchmark",
        )

        result = CLASSIFIER.classify(self.repository, base, head)

        self.assertFalse(result.build_docc)
        self.assertEqual(result.reason, "published benchmark report only")

    def test_package_or_documentation_control_change_builds_docc(self) -> None:
        base = self.commit({"Package.swift": "// old\n"}, "base")
        head = self.commit({"Package.swift": "// new\n"}, "package")

        result = CLASSIFIER.classify(self.repository, base, head)

        self.assertTrue(result.build_docc)
        self.assertEqual(result.reason, "documentation input changed")


if __name__ == "__main__":
    unittest.main()
