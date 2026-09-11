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

func TestPublishingJournalPreservesInPlaceFileChanges(t *testing.T) {
	t.Parallel()
	root := t.TempDir()
	destination := filepath.Join(root, "destination")
	recovery := filepath.Join(root, "recovery")
	mustMkdir(t, destination, 0o755)
	mustMkdir(t, recovery, 0o700)
	mustMkdir(t, filepath.Join(destination, stagePrefix+testTransactionID), 0o700)
	published := filepath.Join(destination, "payload")
	mustWrite(t, published, "initializer", 0o600)
	metadata, err := captureRootMetadata(destination)
	if err != nil {
		t.Fatal(err)
	}
	info, err := os.Stat(published)
	if err != nil {
		t.Fatal(err)
	}
	journal := filepath.Join(recovery, journalPrefix+testTransactionID)
	if err := replacePublishingJournal(
		journal,
		testTransactionID,
		[]transactionJournalEntry{mustJournalEntry(t, published, "payload")},
		metadata,
		metadata,
	); err != nil {
		t.Fatal(err)
	}
	mustWrite(t, published, "user-change", 0o600)
	if err := os.Chtimes(published, info.ModTime(), info.ModTime()); err != nil {
		t.Fatal(err)
	}

	if err := recoverTransaction(destination, testTransactionID, journal); err == nil {
		t.Fatal("expected modified published content to fail closed")
	}
	value, err := os.ReadFile(published)
	if err != nil || string(value) != "user-change" {
		t.Fatalf("publishing recovery changed modified content: %q, %v", value, err)
	}
}

func TestPublishingCompletionPublishesOnlyVerifiedTrees(t *testing.T) {
	t.Parallel()
	root := t.TempDir()
	destination := filepath.Join(root, "destination")
	mustMkdir(t, destination, 0o755)
	metadata, err := captureRootMetadata(destination)
	if err != nil {
		t.Fatal(err)
	}
	stage := filepath.Join(destination, stagePrefix+testTransactionID)
	mustMkdir(t, stage, 0o700)
	staged := filepath.Join(stage, "staged")
	mustWrite(t, staged, "staged", 0o600)
	published := filepath.Join(destination, "published")
	mustMkdir(t, published, 0o700)
	mustWrite(t, filepath.Join(published, "child"), "child", 0o600)
	entries := []transactionJournalEntry{
		mustJournalEntry(t, published, "published"),
		mustJournalEntry(t, staged, "staged"),
	}

	journal := filepath.Join(root, journalPrefix+testTransactionID)
	mustWrite(t, journal, "journal", 0o600)
	if err := completePublishingTransaction(
		destination, stage, journal, entries, metadata,
	); err != nil {
		t.Fatal(err)
	}
	for name, expected := range map[string]string{
		"published/child": "child", "staged": "staged",
	} {
		value, err := os.ReadFile(filepath.Join(destination, name))
		if err != nil || string(value) != expected {
			t.Fatalf("unexpected completed publication %s: %q, %v", name, value, err)
		}
	}
	for _, path := range []string{stage, journal} {
		if _, err := os.Lstat(path); !os.IsNotExist(err) {
			t.Fatalf("completed transaction artefact remains at %s: %v", path, err)
		}
	}
}

func TestPublishingCompletionPreservesConcurrentChanges(t *testing.T) {
	t.Parallel()
	root := t.TempDir()
	destination := filepath.Join(root, "destination")
	stage := filepath.Join(destination, stagePrefix+testTransactionID)
	published := filepath.Join(destination, "payload")
	mustMkdir(t, destination, 0o755)
	mustMkdir(t, stage, 0o700)
	mustMkdir(t, published, 0o700)
	mustWrite(t, filepath.Join(published, "initializer"), "initializer", 0o600)
	entry := mustJournalEntry(t, published, "payload")
	concurrent := filepath.Join(published, "concurrent-user-data")
	mustWrite(t, concurrent, "keep", 0o600)
	journal := filepath.Join(root, journalPrefix+testTransactionID)
	mustWrite(t, journal, "journal", 0o600)
	metadata, err := captureRootMetadata(destination)
	if err != nil {
		t.Fatal(err)
	}

	if err := completePublishingTransaction(
		destination, stage, journal,
		[]transactionJournalEntry{entry}, metadata,
	); err == nil {
		t.Fatal("expected a concurrently changed publication to fail closed")
	}
	value, err := os.ReadFile(concurrent)
	if err != nil || string(value) != "keep" {
		t.Fatalf("completion changed concurrent user data: %q, %v", value, err)
	}
	if _, err := os.Lstat(journal); err != nil {
		t.Fatalf("failed completion removed its journal: %v", err)
	}
}

func TestPublishingTreeIdentitySurvivesAtomicRename(t *testing.T) {
	t.Parallel()
	root := t.TempDir()
	stage := filepath.Join(root, "stage")
	mustMkdir(t, stage, 0o700)
	for _, name := range []string{"file", "directory"} {
		source := filepath.Join(stage, name)
		if name == "directory" {
			mustMkdir(t, source, 0o700)
			mustWrite(t, filepath.Join(source, "child"), "child", 0o600)
		} else {
			mustWrite(t, source, "file", 0o600)
		}
		entry := mustJournalEntry(t, source, name)
		destination := filepath.Join(root, name)
		if err := renameNoReplace(source, destination); err != nil {
			t.Fatal(err)
		}
		identity, err := captureTreeIdentity(destination)
		if err != nil {
			t.Fatal(err)
		}
		if !entry.matches(identity) {
			t.Fatalf("%s tree identity changed during publication", name)
		}
	}
}

func TestTransactionRecoveryRejectsUntrustedJournals(t *testing.T) {
	t.Parallel()
	for name, payload := range map[string]string{
		"malformed":           `{`,
		"wrong identity":      `{"version":5,"transaction":"aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee","phase":"prepared","entries":[]}`,
		"wrong version":       `{"version":2,"transaction":"01234567-89ab-cdef-0123-456789abcdef","phase":"prepared","entries":[]}`,
		"unsafe entry":        `{"version":5,"transaction":"01234567-89ab-cdef-0123-456789abcdef","phase":"prepared","entries":[{"name":"../escape"}]}`,
		"duplicate entry":     `{"version":5,"transaction":"01234567-89ab-cdef-0123-456789abcdef","phase":"prepared","entries":[{"name":"payload"},{"name":"payload"}]}`,
		"prepared identity":   `{"version":5,"transaction":"01234567-89ab-cdef-0123-456789abcdef","phase":"prepared","entries":[{"name":"payload","device":1}]}`,
		"prepared final root": `{"version":5,"transaction":"01234567-89ab-cdef-0123-456789abcdef","phase":"prepared","entries":[],"finalRoot":{}}`,
		"missing identity":    `{"version":5,"transaction":"01234567-89ab-cdef-0123-456789abcdef","phase":"publishing","entries":[{"name":"payload"}]}`,
		"invalid digest":      `{"version":5,"transaction":"01234567-89ab-cdef-0123-456789abcdef","phase":"publishing","entries":[{"name":"payload","device":1,"inode":1,"nodeCount":1,"treeDigest":"not-a-digest"}]}`,
		"missing final root":  `{"version":5,"transaction":"01234567-89ab-cdef-0123-456789abcdef","phase":"publishing","entries":[{"name":"payload","device":1,"inode":1,"nodeCount":1,"treeDigest":"0000000000000000000000000000000000000000000000000000000000000000"}]}`,
	} {
		t.Run(name, func(t *testing.T) {
			destination := t.TempDir()
			recovery := t.TempDir()
			journal := filepath.Join(recovery, journalPrefix+testTransactionID)
			mustWrite(t, journal, payload, 0o600)
			if err := recoverTransaction(destination, testTransactionID, journal); err == nil {
				t.Fatal("expected untrusted journal failure")
			}
			if _, err := os.Stat(journal); err != nil {
				t.Fatalf("untrusted journal was changed: %v", err)
			}
		})
	}
}
