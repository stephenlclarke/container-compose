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
	"bytes"
	"errors"
	"net"
	"os"
	"path/filepath"
	"syscall"
	"testing"

	"golang.org/x/sys/unix"
)

const testTransactionID = "01234567-89ab-cdef-0123-456789abcdef"

func TestInitializeCopiesMetadataLinksAndFiles(t *testing.T) {
	t.Parallel()
	root := t.TempDir()
	source := filepath.Join(root, "source")
	destination := filepath.Join(root, "destination")
	mustMkdir(t, source, 0o750)
	mustMkdir(t, destination, 0o700)
	mustWrite(t, filepath.Join(source, "value.txt"), "volume-data\n", 0o640)
	xattrName := "io.github.stephenlclarke.container-compose.test"
	xattrValue := []byte("preserved")
	if err := unix.Setxattr(filepath.Join(source, "value.txt"), xattrName, xattrValue, 0); err != nil {
		t.Fatal(err)
	}
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

	if err := initialize(source, destination, testTransactionID); err != nil {
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
	copiedXattr := make([]byte, len(xattrValue))
	if _, err := unix.Getxattr(filepath.Join(destination, "value.txt"), xattrName, copiedXattr); err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(copiedXattr, xattrValue) {
		t.Fatalf("unexpected extended attribute %q", copiedXattr)
	}
	pipe, err := os.Lstat(filepath.Join(destination, "events"))
	if err != nil || pipe.Mode()&os.ModeNamedPipe == 0 {
		t.Fatalf("named pipe was not preserved: %v", err)
	}
}

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

	if err := initialize(source, destination, testTransactionID); err != nil {
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
	assertMode(destination, 0o750|os.ModeSetgid)
	assertMode(filepath.Join(destination, "privileged"), 0o750|os.ModeSetuid|os.ModeSetgid)
	assertMode(filepath.Join(destination, "shared"), 0o770|os.ModeSticky|os.ModeSetgid)
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

	err := initialize(source, destination, testTransactionID)
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

	if err := initialize(filepath.Join(root, "missing"), destination, testTransactionID); !errors.Is(err, errSourceMissing) {
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

	if err := initialize(source, destination, testTransactionID); err == nil {
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
		{name: "relative", arguments: []string{"source", "destination", testTransactionID}, code: 1},
		{name: "invalid transaction", arguments: []string{source, destination, "not-a-uuid"}, code: 1},
		{name: "missing", arguments: []string{filepath.Join(root, "missing"), destination, testTransactionID}, code: 44},
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
	if code := run([]string{source, destination, testTransactionID}, &stderr); code != 45 {
		t.Fatalf("expected nonempty code 45, got %d (%s)", code, stderr.String())
	}
	if err := os.Remove(filepath.Join(destination, "existing")); err != nil {
		t.Fatal(err)
	}
	stderr.Reset()
	if code := run([]string{source, destination, testTransactionID}, &stderr); code != 0 {
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

	if err := initialize(source, destination, testTransactionID); err != nil {
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

	if err := initialize(source, destination, testTransactionID); !errors.Is(err, errDestinationNotEmpty) {
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

	if err := initialize(sourceFile, root, testTransactionID); err == nil {
		t.Fatal("expected a non-directory source error")
	}
	if err := initialize(root, destinationFile, testTransactionID); err == nil {
		t.Fatal("expected a non-directory destination error")
	}
	if err := initialize(root, filepath.Join(root, "missing"), testTransactionID); err == nil {
		t.Fatal("expected a missing destination error")
	}
}

func TestInitializeRecoversAuthenticatedStaleStage(t *testing.T) {
	t.Parallel()
	root := t.TempDir()
	source := filepath.Join(root, "source")
	destination := filepath.Join(root, "destination")
	mustMkdir(t, source, 0o755)
	mustMkdir(t, destination, 0o755)
	mustWrite(t, filepath.Join(source, "current"), "current", 0o644)
	stale := filepath.Join(destination, stagePrefix+testTransactionID)
	mustMkdir(t, stale, 0o700)
	mustWrite(t, filepath.Join(stale, "partial"), "partial", 0o600)

	if err := initialize(source, destination, testTransactionID); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(stale); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("stale transaction stage remains: %v", err)
	}
	if value, err := os.ReadFile(filepath.Join(destination, "current")); err != nil || string(value) != "current" {
		t.Fatalf("current source was not published: %q, %v", value, err)
	}
}

func TestInitializeRecoversInterruptedPublication(t *testing.T) {
	t.Parallel()
	root := t.TempDir()
	source := filepath.Join(root, "source")
	destination := filepath.Join(root, "destination")
	mustMkdir(t, source, 0o755)
	mustMkdir(t, destination, 0o755)
	mustWrite(t, filepath.Join(source, "first"), "new-first", 0o644)
	mustWrite(t, filepath.Join(source, "second"), "new-second", 0o644)
	mustWrite(t, filepath.Join(destination, "first"), "partial-old", 0o644)
	stage := filepath.Join(destination, stagePrefix+testTransactionID)
	mustMkdir(t, stage, 0o700)
	mustWrite(t, filepath.Join(stage, "second"), "staged-old", 0o644)
	entries, err := os.ReadDir(source)
	if err != nil {
		t.Fatal(err)
	}
	journal := filepath.Join(destination, journalPrefix+testTransactionID)
	if err := writeJournal(journal, testTransactionID, entries); err != nil {
		t.Fatal(err)
	}

	if err := initialize(source, destination, testTransactionID); err != nil {
		t.Fatal(err)
	}
	for name, expected := range map[string]string{
		"first": "new-first", "second": "new-second",
	} {
		value, err := os.ReadFile(filepath.Join(destination, name))
		if err != nil || string(value) != expected {
			t.Fatalf("unexpected recovered %s: %q, %v", name, value, err)
		}
	}
	for _, path := range []string{stage, journal, journal + ".tmp"} {
		if _, err := os.Stat(path); !errors.Is(err, os.ErrNotExist) {
			t.Fatalf("transaction artefact remains at %s: %v", path, err)
		}
	}
}

func TestInitializeRecoversBeforeAcceptingMissingSource(t *testing.T) {
	t.Parallel()
	root := t.TempDir()
	destination := filepath.Join(root, "destination")
	mustMkdir(t, destination, 0o755)
	mustWrite(t, filepath.Join(destination, "partial"), "published", 0o644)
	stage := filepath.Join(destination, stagePrefix+testTransactionID)
	mustMkdir(t, stage, 0o700)
	journal := filepath.Join(destination, journalPrefix+testTransactionID)
	mustWrite(
		t,
		journal,
		`{"version":1,"transaction":"01234567-89ab-cdef-0123-456789abcdef","entries":["partial"]}`,
		0o600,
	)

	err := initialize(filepath.Join(root, "missing"), destination, testTransactionID)
	if !errors.Is(err, errSourceMissing) {
		t.Fatalf("expected missing source after recovery, got %v", err)
	}
	for _, path := range []string{filepath.Join(destination, "partial"), stage, journal} {
		if _, statErr := os.Stat(path); !errors.Is(statErr, os.ErrNotExist) {
			t.Fatalf("interrupted transaction artefact remains at %s: %v", path, statErr)
		}
	}
}

func TestTransactionRecoveryRejectsUntrustedJournals(t *testing.T) {
	t.Parallel()
	for name, payload := range map[string]string{
		"malformed":      `{`,
		"wrong identity": `{"version":1,"transaction":"aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee","entries":[]}`,
		"wrong version":  `{"version":2,"transaction":"01234567-89ab-cdef-0123-456789abcdef","entries":[]}`,
		"unsafe entry":   `{"version":1,"transaction":"01234567-89ab-cdef-0123-456789abcdef","entries":["../escape"]}`,
	} {
		t.Run(name, func(t *testing.T) {
			destination := t.TempDir()
			journal := filepath.Join(destination, journalPrefix+testTransactionID)
			mustWrite(t, journal, payload, 0o600)
			if err := recoverTransaction(destination, testTransactionID); err == nil {
				t.Fatal("expected untrusted journal failure")
			}
			if _, err := os.Stat(journal); err != nil {
				t.Fatalf("untrusted journal was changed: %v", err)
			}
		})
	}
}

func TestTransactionHelpersValidateInputsAndFailures(t *testing.T) {
	t.Parallel()
	valid := []string{
		testTransactionID,
		"aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee",
	}
	for _, value := range valid {
		if !validTransactionID(value) {
			t.Fatalf("valid transaction was rejected: %s", value)
		}
	}
	for _, value := range []string{
		"", "short", "0123456789ab-cdef-0123-456789abcdef",
		"01234567x89ab-cdef-0123-456789abcdef",
		"01234567-89AB-cdef-0123-456789abcdef",
	} {
		if validTransactionID(value) {
			t.Fatalf("invalid transaction was accepted: %s", value)
		}
	}

	root := t.TempDir()
	if err := syncDirectory(filepath.Join(root, "missing")); err == nil {
		t.Fatal("expected missing directory sync failure")
	}
	journal := filepath.Join(root, journalPrefix+testTransactionID)
	mustWrite(t, journal+".tmp", "occupied", 0o600)
	if err := writeJournal(journal, testTransactionID, nil); err == nil {
		t.Fatal("expected occupied temporary journal failure")
	}
}

func TestInitializePreservesStageLikeUserEntries(t *testing.T) {
	t.Parallel()
	root := t.TempDir()
	source := filepath.Join(root, "source")
	destination := filepath.Join(root, "destination")
	mustMkdir(t, source, 0o755)
	mustMkdir(t, destination, 0o755)
	stageLikeFile := filepath.Join(destination, stagePrefix+"user-file")
	mustWrite(t, stageLikeFile, "keep", 0o600)
	stageLikeDirectory := filepath.Join(destination, stagePrefix+"shared-directory")
	mustMkdir(t, stageLikeDirectory, 0o700)

	if err := initialize(source, destination, testTransactionID); !errors.Is(err, errDestinationNotEmpty) {
		t.Fatalf("expected non-empty destination, got %v", err)
	}
	if value, err := os.ReadFile(stageLikeFile); err != nil || string(value) != "keep" {
		t.Fatalf("stage-like file was changed: %q, %v", value, err)
	}
	if _, err := os.Stat(stageLikeDirectory); err != nil {
		t.Fatalf("stage-like directory was changed: %v", err)
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
	if err := recoverTransaction(occupied, testTransactionID); err == nil {
		t.Fatal("expected transaction recovery failure")
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
	if err := applyMetadata(occupied, missing, info, true); err == nil {
		t.Fatal("expected missing metadata destination failure")
	}
	if err := applyMetadata(
		occupied, occupied, fileInfoWithoutSystemMetadata{FileInfo: info}, true,
	); err == nil {
		t.Fatal("expected unavailable metadata failure")
	}
	if err := copyExtendedAttributes(missing, occupied); err == nil {
		t.Fatal("expected missing extended-attribute source failure")
	}
	if err := unix.Setxattr(occupied, "io.github.stephenlclarke.container-compose.test", []byte("value"), 0); err != nil {
		t.Fatal(err)
	}
	if err := copyExtendedAttributes(occupied, missing); err == nil {
		t.Fatal("expected missing extended-attribute destination failure")
	}
	if err := syncPublishedPath(missing); err == nil {
		t.Fatal("expected missing published path failure")
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
	if err := initialize(source, destination, testTransactionID); err == nil {
		t.Fatal("expected unreadable source failure")
	}
	if err := os.Chmod(source, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.Chmod(destination, 0o555); err != nil {
		t.Fatal(err)
	}
	if err := initialize(source, destination, testTransactionID); err == nil {
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
