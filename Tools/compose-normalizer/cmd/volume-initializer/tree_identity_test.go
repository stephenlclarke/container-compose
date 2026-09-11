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

func TestRollbackPublishingEntriesRemovesOnlyVerifiedTrees(t *testing.T) {
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

	if err := rollbackPublishingEntries(destination, stage, entries, metadata); err != nil {
		t.Fatal(err)
	}
	for _, path := range []string{published, stage} {
		if _, err := os.Lstat(path); !os.IsNotExist(err) {
			t.Fatalf("verified rollback path remains at %s: %v", path, err)
		}
	}
}

func TestQuarantinedPublishingEntryRestoresConcurrentChanges(t *testing.T) {
	t.Parallel()
	root := t.TempDir()
	destination := filepath.Join(root, "destination")
	stage := filepath.Join(destination, stagePrefix+testTransactionID)
	published := filepath.Join(destination, "payload")
	staged := filepath.Join(stage, "payload")
	mustMkdir(t, destination, 0o755)
	mustMkdir(t, stage, 0o700)
	mustMkdir(t, published, 0o700)
	mustWrite(t, filepath.Join(published, "initializer"), "initializer", 0o600)
	entry := mustJournalEntry(t, published, "payload")

	if err := renameNoReplace(published, staged); err != nil {
		t.Fatal(err)
	}
	concurrent := filepath.Join(staged, "concurrent-user-data")
	mustWrite(t, concurrent, "keep", 0o600)

	if err := removeQuarantinedPublishingEntry(staged, published, entry); err == nil {
		t.Fatal("expected a concurrently changed quarantine to fail closed")
	}
	value, err := os.ReadFile(filepath.Join(published, "concurrent-user-data"))
	if err != nil || string(value) != "keep" {
		t.Fatalf("rollback did not restore concurrent user data: %q, %v", value, err)
	}
	if _, err := os.Lstat(staged); !os.IsNotExist(err) {
		t.Fatalf("restored quarantine remains at %s: %v", staged, err)
	}
}
