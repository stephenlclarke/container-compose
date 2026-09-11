// Copyright 2026 container-compose project authors.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     https://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

package main

import (
	"bytes"
	"errors"
	"net"
	"os"
	"path/filepath"
	"syscall"
	"testing"
)

func TestInitializeCopiesMetadataLinksAndFiles(t *testing.T) {
	t.Parallel()
	root := t.TempDir()
	source := filepath.Join(root, "source")
	destination := filepath.Join(root, "destination")
	mustMkdir(t, source, 0o750)
	mustMkdir(t, destination, 0o700)
	mustWrite(t, filepath.Join(source, "value.txt"), "volume-data\n", 0o640)
	mustMkdir(t, filepath.Join(source, "nested"), 0o755)
	mustWrite(t, filepath.Join(source, "nested", "child"), "child\n", 0o600)
	if err := os.Link(filepath.Join(source, "value.txt"), filepath.Join(source, "hardlink")); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink("value.txt", filepath.Join(source, "symlink")); err != nil {
		t.Fatal(err)
	}
	if err := syscall.Mkfifo(filepath.Join(source, "events"), 0o620); err != nil {
		t.Fatal(err)
	}

	if err := initialize(source, destination); err != nil {
		t.Fatal(err)
	}
	contents, err := os.ReadFile(filepath.Join(destination, "value.txt"))
	if err != nil || string(contents) != "volume-data\n" {
		t.Fatalf("unexpected copied contents %q: %v", contents, err)
	}
	link, err := os.Readlink(filepath.Join(destination, "symlink"))
	if err != nil || link != "value.txt" {
		t.Fatalf("unexpected symlink %q: %v", link, err)
	}
	first, _ := os.Stat(filepath.Join(destination, "value.txt"))
	second, _ := os.Stat(filepath.Join(destination, "hardlink"))
	if !os.SameFile(first, second) {
		t.Fatal("hard link identity was not preserved")
	}
	if first.Mode().Perm() != 0o640 {
		t.Fatalf("unexpected mode %o", first.Mode().Perm())
	}
	pipe, err := os.Lstat(filepath.Join(destination, "events"))
	if err != nil || pipe.Mode()&os.ModeNamedPipe == 0 {
		t.Fatalf("named pipe was not preserved: %v", err)
	}
}

func TestInitializePreservesExistingDestination(t *testing.T) {
	t.Parallel()
	root := t.TempDir()
	source := filepath.Join(root, "source")
	destination := filepath.Join(root, "destination")
	mustMkdir(t, source, 0o755)
	mustMkdir(t, destination, 0o755)
	mustWrite(t, filepath.Join(source, "new"), "new", 0o644)
	mustWrite(t, filepath.Join(destination, "existing"), "keep", 0o644)

	err := initialize(source, destination)
	if !errors.Is(err, errDestinationNotEmpty) {
		t.Fatalf("expected nonempty error, got %v", err)
	}
	if _, err := os.Stat(filepath.Join(destination, "new")); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("source content was unexpectedly published: %v", err)
	}
}

func TestInitializeRejectsMissingSourceWithoutMutatingDestination(t *testing.T) {
	t.Parallel()
	root := t.TempDir()
	destination := filepath.Join(root, "destination")
	mustMkdir(t, destination, 0o755)
	stale := filepath.Join(destination, stagePrefix+"stale")
	mustMkdir(t, stale, 0o700)

	if err := initialize(filepath.Join(root, "missing"), destination); !errors.Is(err, errSourceMissing) {
		t.Fatalf("expected source error, got %v", err)
	}
	if _, err := os.Stat(stale); err != nil {
		t.Fatalf("source validation should not mutate destination: %v", err)
	}
}

func TestInitializeRollsBackAFailedStagedCopy(t *testing.T) {
	t.Parallel()
	root, err := os.MkdirTemp("/private/tmp", "volume-init-")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = os.RemoveAll(root) })
	source := filepath.Join(root, "source")
	destination := filepath.Join(root, "destination")
	mustMkdir(t, source, 0o755)
	mustMkdir(t, destination, 0o755)
	mustWrite(t, filepath.Join(source, "a-valid"), "staged", 0o644)
	listener, err := net.Listen("unix", filepath.Join(source, "z-unsupported"))
	if err != nil {
		t.Fatal(err)
	}
	defer listener.Close()

	if err := initialize(source, destination); err == nil {
		t.Fatal("expected unsupported entry failure")
	}
	entries, err := os.ReadDir(destination)
	if err != nil {
		t.Fatal(err)
	}
	if len(entries) != 0 {
		t.Fatalf("failed initialization left destination entries: %v", entries)
	}
}

func TestRunMapsStableExitCodes(t *testing.T) {
	t.Parallel()
	root := t.TempDir()
	source := filepath.Join(root, "source")
	destination := filepath.Join(root, "destination")
	mustMkdir(t, source, 0o755)
	mustMkdir(t, destination, 0o755)

	tests := []struct {
		name      string
		arguments []string
		code      int
	}{
		{name: "usage", arguments: nil, code: 2},
		{name: "relative", arguments: []string{"source", "destination"}, code: 1},
		{name: "missing", arguments: []string{filepath.Join(root, "missing"), destination}, code: 44},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			var stderr bytes.Buffer
			if code := run(test.arguments, &stderr); code != test.code {
				t.Fatalf("expected code %d, got %d (%s)", test.code, code, stderr.String())
			}
			if stderr.Len() == 0 {
				t.Fatal("failure did not explain itself")
			}
		})
	}

	mustWrite(t, filepath.Join(destination, "existing"), "keep", 0o644)
	var stderr bytes.Buffer
	if code := run([]string{source, destination}, &stderr); code != 45 {
		t.Fatalf("expected nonempty code 45, got %d (%s)", code, stderr.String())
	}
	if err := os.Remove(filepath.Join(destination, "existing")); err != nil {
		t.Fatal(err)
	}
	stderr.Reset()
	if code := run([]string{source, destination}, &stderr); code != 0 {
		t.Fatalf("expected success, got %d (%s)", code, stderr.String())
	}
}

func TestInitializeRemovesOnlyEmptyExt4Scaffolding(t *testing.T) {
	t.Parallel()
	root := t.TempDir()
	source := filepath.Join(root, "source")
	destination := filepath.Join(root, "destination")
	mustMkdir(t, source, 0o755)
	mustMkdir(t, destination, 0o755)
	mustWrite(t, filepath.Join(source, "payload"), "copied", 0o644)
	mustMkdir(t, filepath.Join(destination, "lost+found"), 0o700)

	if err := initialize(source, destination); err != nil {
		t.Fatal(err)
	}
	if contents, err := os.ReadFile(filepath.Join(destination, "payload")); err != nil {
		t.Fatal(err)
	} else if string(contents) != "copied" {
		t.Fatalf("unexpected copied payload %q", contents)
	}
	if _, err := os.Stat(filepath.Join(destination, "lost+found")); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("empty ext4 scaffolding was retained: %v", err)
	}
}

func TestInitializePreservesPopulatedExt4Scaffolding(t *testing.T) {
	t.Parallel()
	root := t.TempDir()
	source := filepath.Join(root, "source")
	destination := filepath.Join(root, "destination")
	mustMkdir(t, source, 0o755)
	mustMkdir(t, destination, 0o755)
	recovery := filepath.Join(destination, "lost+found")
	mustMkdir(t, recovery, 0o700)
	mustWrite(t, filepath.Join(recovery, "recovered"), "keep", 0o600)

	if err := initialize(source, destination); !errors.Is(err, errDestinationNotEmpty) {
		t.Fatalf("expected non-empty destination, got %v", err)
	}
	if contents, err := os.ReadFile(filepath.Join(recovery, "recovered")); err != nil {
		t.Fatal(err)
	} else if string(contents) != "keep" {
		t.Fatalf("recovery data changed to %q", contents)
	}
}

func TestInitializeRejectsNonDirectoryEndpoints(t *testing.T) {
	t.Parallel()
	root := t.TempDir()
	sourceFile := filepath.Join(root, "source-file")
	destinationFile := filepath.Join(root, "destination-file")
	mustWrite(t, sourceFile, "source", 0o644)
	mustWrite(t, destinationFile, "destination", 0o644)

	if err := initialize(sourceFile, root); err == nil {
		t.Fatal("expected a non-directory source error")
	}
	if err := initialize(root, destinationFile); err == nil {
		t.Fatal("expected a non-directory destination error")
	}
	if err := initialize(root, filepath.Join(root, "missing")); err == nil {
		t.Fatal("expected a missing destination error")
	}
}

func TestInitializeRemovesOwnedStaleStage(t *testing.T) {
	t.Parallel()
	root := t.TempDir()
	source := filepath.Join(root, "source")
	destination := filepath.Join(root, "destination")
	mustMkdir(t, source, 0o755)
	mustMkdir(t, destination, 0o755)
	mustWrite(t, filepath.Join(source, "current"), "current", 0o644)
	stale := filepath.Join(destination, stagePrefix+"stale")
	mustMkdir(t, stale, 0o700)
	mustWrite(t, filepath.Join(stale, "partial"), "partial", 0o600)

	if err := initialize(source, destination); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(stale); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("stale transaction stage remains: %v", err)
	}
	if value, err := os.ReadFile(filepath.Join(destination, "current")); err != nil || string(value) != "current" {
		t.Fatalf("current source was not published: %q, %v", value, err)
	}
}

func TestFilesystemFailuresRemainExplicit(t *testing.T) {
	t.Parallel()
	root := t.TempDir()
	missing := filepath.Join(root, "missing")
	occupied := filepath.Join(root, "occupied")
	mustWrite(t, occupied, "occupied", 0o644)

	if _, err := destinationIsEmpty(occupied); err == nil {
		t.Fatal("expected destination read failure")
	}
	if err := removeStaleStages(occupied); err == nil {
		t.Fatal("expected stale-stage read failure")
	}
	if err := copyEntry(missing, filepath.Join(root, "copy"), nil); err == nil {
		t.Fatal("expected missing copy source failure")
	}
	if err := copyRegularFile(missing, filepath.Join(root, "copy"), 0o644); err == nil {
		t.Fatal("expected missing regular-file source failure")
	}
	if err := copyRegularFile(occupied, occupied, 0o644); err == nil {
		t.Fatal("expected exclusive destination create failure")
	}
	info, err := os.Stat(occupied)
	if err != nil {
		t.Fatal(err)
	}
	if err := applyMetadata(missing, info, true); err == nil {
		t.Fatal("expected missing metadata destination failure")
	}
	if err := applyMetadata(occupied, fileInfoWithoutSystemMetadata{FileInfo: info}, true); err == nil {
		t.Fatal("expected unavailable metadata failure")
	}
}

func TestCopyEntryRejectsOccupiedTargets(t *testing.T) {
	t.Parallel()
	root := t.TempDir()
	occupied := filepath.Join(root, "occupied")
	mustWrite(t, occupied, "occupied", 0o644)

	directory := filepath.Join(root, "directory")
	mustMkdir(t, directory, 0o755)
	if err := copyEntry(directory, occupied, make(map[fileIdentity]string)); err == nil {
		t.Fatal("expected occupied directory target failure")
	}

	symlink := filepath.Join(root, "symlink")
	if err := os.Symlink("target", symlink); err != nil {
		t.Fatal(err)
	}
	if err := copyEntry(symlink, occupied, make(map[fileIdentity]string)); err == nil {
		t.Fatal("expected occupied symlink target failure")
	}

	regular := filepath.Join(root, "regular")
	mustWrite(t, regular, "regular", 0o644)
	if err := copyEntry(regular, occupied, make(map[fileIdentity]string)); err == nil {
		t.Fatal("expected occupied regular-file target failure")
	}

	pipe := filepath.Join(root, "pipe")
	if err := syscall.Mkfifo(pipe, 0o600); err != nil {
		t.Fatal(err)
	}
	if err := copyEntry(pipe, occupied, make(map[fileIdentity]string)); err == nil {
		t.Fatal("expected occupied named-pipe target failure")
	}

	linked := filepath.Join(root, "linked")
	linkedAgain := filepath.Join(root, "linked-again")
	mustWrite(t, linked, "linked", 0o644)
	if err := os.Link(linked, linkedAgain); err != nil {
		t.Fatal(err)
	}
	hardlinks := make(map[fileIdentity]string)
	firstTarget := filepath.Join(root, "first-link-target")
	if err := copyEntry(linked, firstTarget, hardlinks); err != nil {
		t.Fatal(err)
	}
	if err := copyEntry(linkedAgain, occupied, hardlinks); err == nil {
		t.Fatal("expected occupied hard-link target failure")
	}
}

func TestInitializeReportsUnreadableSourceAndDestination(t *testing.T) {
	root := t.TempDir()
	source := filepath.Join(root, "source")
	destination := filepath.Join(root, "destination")
	mustMkdir(t, source, 0o755)
	mustMkdir(t, destination, 0o755)
	mustWrite(t, filepath.Join(source, "value"), "value", 0o644)

	if err := os.Chmod(source, 0); err != nil {
		t.Fatal(err)
	}
	if err := initialize(source, destination); err == nil {
		t.Fatal("expected unreadable source failure")
	}
	if err := os.Chmod(source, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.Chmod(destination, 0o555); err != nil {
		t.Fatal(err)
	}
	if err := initialize(source, destination); err == nil {
		t.Fatal("expected unwritable destination failure")
	}
}

func TestCopyEntryPropagatesNestedFailure(t *testing.T) {
	root, err := os.MkdirTemp("/private/tmp", "volume-init-nested-")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = os.RemoveAll(root) })
	source := filepath.Join(root, "source")
	destination := filepath.Join(root, "destination")
	mustMkdir(t, source, 0o755)
	listener, err := net.Listen("unix", filepath.Join(source, "unsupported"))
	if err != nil {
		t.Fatal(err)
	}
	defer listener.Close()

	if err := copyEntry(source, destination, make(map[fileIdentity]string)); err == nil {
		t.Fatal("expected nested unsupported entry failure")
	}
}

func TestMetadataVerificationRequiresExactEffectiveValues(t *testing.T) {
	t.Parallel()
	root := t.TempDir()
	path := filepath.Join(root, "value")
	mustWrite(t, path, "value", 0o640)
	info, err := os.Stat(path)
	if err != nil {
		t.Fatal(err)
	}
	stat, ok := info.Sys().(*syscall.Stat_t)
	if !ok {
		t.Fatal("test filesystem did not expose POSIX metadata")
	}
	if !metadataAlreadyMatches(path, stat.Uid, stat.Gid, true) {
		t.Fatal("exact ownership was not recognized")
	}
	if metadataAlreadyMatches(path, stat.Uid+1, stat.Gid, true) {
		t.Fatal("different ownership was accepted")
	}
	if metadataAlreadyMatches(filepath.Join(root, "missing"), stat.Uid, stat.Gid, true) {
		t.Fatal("missing path ownership was accepted")
	}
	if !modeAlreadyMatches(path, 0o640) || modeAlreadyMatches(path, 0o600) {
		t.Fatal("mode verification did not require an exact match")
	}
	if modeAlreadyMatches(filepath.Join(root, "missing"), 0o640) {
		t.Fatal("missing path mode was accepted")
	}
	if err := applyMountRootMetadata(path, info); err != nil {
		t.Fatal(err)
	}
	if err := applyMountRootMetadata(path, fileInfoWithoutSystemMetadata{FileInfo: info}); err == nil {
		t.Fatal("mount metadata without POSIX IDs was accepted")
	}
	if err := applyMountRootMetadata(filepath.Join(root, "missing"), info); err == nil {
		t.Fatal("missing mount root metadata was accepted")
	}
}

type fileInfoWithoutSystemMetadata struct {
	os.FileInfo
}

func (fileInfoWithoutSystemMetadata) Sys() any {
	return nil
}

func mustMkdir(t *testing.T, path string, mode os.FileMode) {
	t.Helper()
	if err := os.Mkdir(path, mode); err != nil {
		t.Fatal(err)
	}
}

func mustWrite(t *testing.T, path, value string, mode os.FileMode) {
	t.Helper()
	if err := os.WriteFile(path, []byte(value), mode); err != nil {
		t.Fatal(err)
	}
}
