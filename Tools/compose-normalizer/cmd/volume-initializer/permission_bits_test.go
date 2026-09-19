//===----------------------------------------------------------------------===//
// Copyright © 2026 container-compose project authors.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//   https://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
//===----------------------------------------------------------------------===//

package main

import (
	"os"
	"path/filepath"
	"testing"
)

func TestInitializePreservesSpecialPermissionBits(t *testing.T) {
	t.Parallel()
	root := t.TempDir()
	source := filepath.Join(root, "source")
	destination := filepath.Join(root, "destination")
	mustMkdir(t, source, 0o750)
	mustMkdir(t, destination, 0o700)
	executable := filepath.Join(source, "privileged")
	mustWrite(t, executable, "executable\n", 0o750)
	shared := filepath.Join(source, "shared")
	mustMkdir(t, shared, 0o770)
	if err := os.Chmod(source, 0o750|os.ModeSetgid); err != nil {
		t.Fatal(err)
	}
	if err := os.Chmod(executable, 0o750|os.ModeSetuid|os.ModeSetgid); err != nil {
		t.Fatal(err)
	}
	if err := os.Chmod(shared, 0o770|os.ModeSticky|os.ModeSetgid); err != nil {
		t.Fatal(err)
	}

	assertMode := func(path string, expected os.FileMode) {
		t.Helper()
		info, err := os.Stat(path)
		if err != nil {
			t.Fatal(err)
		}
		if actual := preservedMode(info.Mode()); actual != expected {
			t.Fatalf("unexpected mode for %s: got %v, want %v", path, actual, expected)
		}
	}
	// Establish the fixture's actual filesystem capabilities before attributing
	// a lost permission bit to the initializer.
	assertMode(source, 0o750|os.ModeSetgid)
	assertMode(executable, 0o750|os.ModeSetuid|os.ModeSetgid)
	assertMode(shared, 0o770|os.ModeSticky|os.ModeSetgid)
	if err := initialize(source, destination, testTransactionID, t.TempDir()); err != nil {
		t.Fatal(err)
	}
	assertMode(destination, 0o750|os.ModeSetgid)
	assertMode(filepath.Join(destination, "privileged"), 0o750|os.ModeSetuid|os.ModeSetgid)
	assertMode(filepath.Join(destination, "shared"), 0o770|os.ModeSticky|os.ModeSetgid)
}
