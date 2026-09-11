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
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"
	"syscall"
	"time"

	"golang.org/x/sys/unix"
)

const (
	stagePrefix            = ".compose-volume-init-stage-"
	journalPrefix          = ".compose-volume-init-journal-"
	journalPhasePrepared   = "prepared"
	journalPhasePublishing = "publishing"
)

var (
	errSourceMissing       = errors.New("image volume source does not exist")
	errDestinationNotEmpty = errors.New("image volume destination is not empty")
)

// main copies an image-mounted directory into a newly created named volume.
func main() {
	os.Exit(run(os.Args[1:], os.Stderr))
}

// run validates the command contract and maps copy-up outcomes to stable
// helper exit codes that the host provider can interpret.
func run(arguments []string, stderr io.Writer) int {
	if len(arguments) != 4 {
		fmt.Fprintln(stderr, "usage: compose-volume-initializer SOURCE DESTINATION TRANSACTION RECOVERY")
		return 2
	}
	if err := initialize(arguments[0], arguments[1], arguments[2], arguments[3]); err != nil {
		fmt.Fprintln(stderr, err)
		switch {
		case errors.Is(err, errSourceMissing):
			return 44
		case errors.Is(err, errDestinationNotEmpty):
			return 45
		default:
			return 1
		}
	}
	return 0
}

// initialize stages the complete tree and rolls back every published entry on
// failure. The host provider holds the cross-process volume lock.
func initialize(source, destination, transaction, recovery string) error {
	if !filepath.IsAbs(source) || !filepath.IsAbs(destination) || !filepath.IsAbs(recovery) {
		return errors.New("source, destination, and recovery must be absolute paths")
	}
	if !validTransactionID(transaction) {
		return errors.New("transaction must be a lowercase UUID")
	}
	resolvedSource, resolvedDestination, resolvedRecovery, err := resolveInitializationPaths(
		source,
		destination,
		recovery,
	)
	if err != nil {
		return err
	}
	source = resolvedSource
	destination = resolvedDestination
	recovery = resolvedRecovery
	if info, statErr := os.Stat(destination); statErr != nil || !info.IsDir() {
		if statErr != nil {
			return fmt.Errorf("inspect destination: %w", statErr)
		}
		return errors.New("image volume destination is not a directory")
	}
	if info, statErr := os.Stat(recovery); statErr != nil || !info.IsDir() {
		if statErr != nil {
			return fmt.Errorf("inspect recovery directory: %w", statErr)
		}
		return errors.New("image volume recovery path is not a directory")
	}

	journal := filepath.Join(recovery, journalPrefix+transaction)
	if err := recoverTransaction(destination, transaction, journal); err != nil {
		return err
	}
	sourceInfo, err := os.Stat(source)
	if errors.Is(err, os.ErrNotExist) {
		return errSourceMissing
	}
	if err != nil {
		return fmt.Errorf("inspect source: %w", err)
	}
	if !sourceInfo.IsDir() {
		return errors.New("image volume source is not a directory")
	}
	empty, err := destinationIsLogicallyEmpty(destination)
	if err != nil {
		return err
	}
	if !empty {
		return errDestinationNotEmpty
	}

	entries, err := os.ReadDir(source)
	if err != nil {
		return fmt.Errorf("read source: %w", err)
	}
	destinationMetadata, err := captureRootMetadata(destination)
	if err != nil {
		return fmt.Errorf("inspect destination attributes: %w", err)
	}
	sourceMetadata, err := captureRootMetadata(source)
	if err != nil {
		return fmt.Errorf("inspect source attributes: %w", err)
	}
	if err := writeJournal(journal, transaction, entries, destinationMetadata); err != nil {
		return err
	}
	if err := removeEmptyExt4Scaffolding(destination); err != nil {
		return err
	}
	empty, err = destinationIsEmpty(destination)
	if err != nil {
		return err
	}
	if !empty {
		return errDestinationNotEmpty
	}

	stage := filepath.Join(destination, stagePrefix+transaction)
	if err := os.Mkdir(stage, 0o700); err != nil {
		return fmt.Errorf("create initialization stage: %w", err)
	}
	hardlinks := make(map[fileIdentity]string)
	for _, entry := range entries {
		if err := copyEntry(
			filepath.Join(source, entry.Name()),
			filepath.Join(stage, entry.Name()),
			hardlinks,
		); err != nil {
			return err
		}
	}
	publishingEntries, err := capturePublishingEntries(stage, entries)
	if err != nil {
		return err
	}
	if err := replacePublishingJournal(
		journal,
		transaction,
		publishingEntries,
		destinationMetadata,
		sourceMetadata,
	); err != nil {
		return err
	}
	return completePublishingTransaction(
		destination,
		stage,
		journal,
		publishingEntries,
		sourceMetadata,
	)
}

// resolveInitializationPaths rejects paths whose guest-side symlink resolution
// makes a source or helper mount overlap. It runs before transaction recovery so
// an invalid image path cannot mutate either mounted volume.
func resolveInitializationPaths(source, destination, recovery string) (string, string, string, error) {
	resolvedSource, err := filepath.EvalSymlinks(source)
	if errors.Is(err, os.ErrNotExist) {
		// A missing source cannot overlap a mounted helper path. Preserve the
		// existing contract that completes an interrupted transaction before
		// reporting the missing image path.
		resolvedSource = filepath.Clean(source)
		err = nil
	}
	if err != nil {
		return "", "", "", fmt.Errorf("resolve source: %w", err)
	}
	resolvedDestination, err := filepath.EvalSymlinks(destination)
	if err != nil {
		return "", "", "", fmt.Errorf("resolve destination: %w", err)
	}
	resolvedRecovery, err := filepath.EvalSymlinks(recovery)
	if err != nil {
		return "", "", "", fmt.Errorf("resolve recovery directory: %w", err)
	}
	if pathsOverlap(resolvedSource, resolvedDestination) ||
		pathsOverlap(resolvedSource, resolvedRecovery) ||
		pathsOverlap(resolvedDestination, resolvedRecovery) {
		return "", "", "", errors.New("image volume helper paths overlap after symlink resolution")
	}
	return resolvedSource, resolvedDestination, resolvedRecovery, nil
}

func pathsOverlap(first, second string) bool {
	return pathContains(first, second) || pathContains(second, first)
}

func pathContains(parent, child string) bool {
	relative, err := filepath.Rel(parent, child)
	if err != nil {
		return false
	}
	return relative == "." ||
		(relative != ".." && !strings.HasPrefix(relative, ".."+string(filepath.Separator)))
}

type transactionJournal struct {
	Version     int                       `json:"version"`
	Transaction string                    `json:"transaction"`
	Phase       string                    `json:"phase"`
	Entries     []transactionJournalEntry `json:"entries"`
	Root        transactionRootMetadata   `json:"root"`
	FinalRoot   *transactionRootMetadata  `json:"finalRoot,omitempty"`
}

type transactionJournalEntry struct {
	Name       string `json:"name"`
	Device     uint64 `json:"device,omitempty"`
	Inode      uint64 `json:"inode,omitempty"`
	NodeCount  uint64 `json:"nodeCount,omitempty"`
	TreeDigest string `json:"treeDigest,omitempty"`
}

type transactionRootMetadata struct {
	UID                  uint32            `json:"uid"`
	GID                  uint32            `json:"gid"`
	Mode                 uint32            `json:"mode"`
	ModificationUnixNano int64             `json:"modificationUnixNano"`
	ExtendedAttributes   map[string][]byte `json:"extendedAttributes,omitempty"`
}

// writeJournal records a prepared transaction before the first destination
// mutation. Prepared entry names never authorize removal during recovery.
func writeJournal(
	path, transaction string,
	entries []os.DirEntry,
	root transactionRootMetadata,
) error {
	records := make([]transactionJournalEntry, 0, len(entries))
	for _, entry := range entries {
		records = append(records, transactionJournalEntry{Name: entry.Name()})
	}
	return publishJournal(path, transactionJournal{
		Version: 5, Transaction: transaction, Phase: journalPhasePrepared,
		Entries: records, Root: root,
	}, false)
}

func replacePublishingJournal(
	path, transaction string,
	entries []transactionJournalEntry,
	root transactionRootMetadata,
	finalRoot transactionRootMetadata,
) error {
	return publishJournal(path, transactionJournal{
		Version: 5, Transaction: transaction, Phase: journalPhasePublishing,
		Entries: entries, Root: root, FinalRoot: &finalRoot,
	}, true)
}

func publishJournal(path string, record transactionJournal, replace bool) error {
	payload, err := json.Marshal(record)
	if err != nil {
		return fmt.Errorf("encode initialization journal: %w", err)
	}
	temporary := path + ".tmp"
	file, err := os.OpenFile(temporary, os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0o600)
	if err != nil {
		return fmt.Errorf("create initialization journal: %w", err)
	}
	removeTemporary := true
	defer func() {
		_ = file.Close()
		if removeTemporary {
			_ = os.Remove(temporary)
		}
	}()
	if _, err := file.Write(payload); err != nil {
		return fmt.Errorf("write initialization journal: %w", err)
	}
	if err := file.Sync(); err != nil {
		return fmt.Errorf("sync initialization journal: %w", err)
	}
	if err := file.Close(); err != nil {
		return fmt.Errorf("close initialization journal: %w", err)
	}
	if replace {
		err = os.Rename(temporary, path)
	} else {
		err = renameNoReplace(temporary, path)
	}
	if err != nil {
		return fmt.Errorf("publish initialization journal: %w", err)
	}
	removeTemporary = false
	return syncDirectory(filepath.Dir(path))
}

// recoverTransaction completes an authenticated publication forward. Once any
// entry can have been visible, recovery never recursively deletes volume data.
func recoverTransaction(destination, transaction, journal string) error {
	stage := filepath.Join(destination, stagePrefix+transaction)
	temporary := journal + ".tmp"
	payload, err := os.ReadFile(journal)
	switch {
	case err == nil:
		var record transactionJournal
		if decodeErr := json.Unmarshal(payload, &record); decodeErr != nil {
			return fmt.Errorf("decode initialization journal: %w", decodeErr)
		}
		if record.Version != 5 || record.Transaction != transaction ||
			(record.Phase != journalPhasePrepared && record.Phase != journalPhasePublishing) {
			return errors.New("initialization journal identity does not match")
		}
		seenEntries := make(map[string]struct{}, len(record.Entries))
		for _, entry := range record.Entries {
			if !safeTopLevelName(entry.Name) {
				return errors.New("initialization journal contains an unsafe entry")
			}
			if _, duplicate := seenEntries[entry.Name]; duplicate {
				return errors.New("initialization journal contains a duplicate entry")
			}
			seenEntries[entry.Name] = struct{}{}
			if record.Phase == journalPhasePublishing {
				if entry.Device == 0 || entry.Inode == 0 || entry.NodeCount == 0 ||
					!validTreeDigest(entry.TreeDigest) {
					return errors.New("publishing journal entry has no filesystem identity")
				}
			} else if entry.Device != 0 || entry.Inode != 0 || entry.NodeCount != 0 ||
				entry.TreeDigest != "" {
				return errors.New("prepared journal entry unexpectedly has a filesystem identity")
			}
		}
		if record.Phase == journalPhasePrepared && record.FinalRoot != nil {
			return errors.New("prepared journal unexpectedly has final root metadata")
		}
		if record.Phase == journalPhasePublishing && record.FinalRoot == nil {
			return errors.New("publishing journal has no final root metadata")
		}
		if err := os.Remove(temporary); err != nil && !errors.Is(err, os.ErrNotExist) {
			return fmt.Errorf("remove stale initialization journal temporary: %w", err)
		}
		if record.Phase == journalPhasePrepared {
			return recoverPreparedTransaction(destination, stage, journal, record.Root)
		}
		return completePublishingTransaction(
			destination,
			stage,
			journal,
			record.Entries,
			*record.FinalRoot,
		)
	case errors.Is(err, os.ErrNotExist):
		if _, stageErr := os.Lstat(stage); stageErr == nil {
			return errors.New("initialization stage exists without its recovery journal")
		} else if !errors.Is(stageErr, os.ErrNotExist) {
			return fmt.Errorf("inspect initialization stage: %w", stageErr)
		}
	default:
		return fmt.Errorf("read initialization journal: %w", err)
	}
	if err := os.Remove(temporary); err != nil && !errors.Is(err, os.ErrNotExist) {
		return fmt.Errorf("remove stale initialization journal temporary: %w", err)
	}
	return syncDirectory(filepath.Dir(journal))
}

func recoverPreparedTransaction(
	destination, stage, journal string,
	root transactionRootMetadata,
) error {
	if err := removeEmptyStage(stage); err != nil {
		return err
	}
	empty, err := destinationIsLogicallyEmpty(destination)
	if err != nil {
		return err
	}
	if empty {
		if err := applyRootMetadata(destination, root); err != nil {
			return fmt.Errorf("restore volume root metadata: %w", err)
		}
	}
	if err := syncDirectory(destination); err != nil {
		return err
	}
	return completeJournal(journal)
}

func capturePublishingEntries(
	stage string,
	entries []os.DirEntry,
) ([]transactionJournalEntry, error) {
	records := make([]transactionJournalEntry, 0, len(entries))
	for _, entry := range entries {
		identity, err := captureTreeIdentity(filepath.Join(stage, entry.Name()))
		if err != nil {
			return nil, fmt.Errorf("inspect staged entry %s: %w", entry.Name(), err)
		}
		records = append(records, transactionJournalEntry{
			Name: entry.Name(), Device: identity.device, Inode: identity.inode,
			NodeCount: identity.nodeCount, TreeDigest: identity.digest,
		})
	}
	return records, nil
}

func completePublishingTransaction(
	destination, stage, journal string,
	entries []transactionJournalEntry,
	finalRoot transactionRootMetadata,
) error {
	if err := verifyDestinationContents(
		destination,
		entries,
		filepath.Base(stage),
	); err != nil {
		return err
	}
	if err := verifyStageContents(stage, entries); err != nil {
		return err
	}
	for _, entry := range entries {
		if err := publishOrVerifyEntry(destination, stage, entry); err != nil {
			return err
		}
	}
	for _, entry := range entries {
		identity, err := captureTreeIdentity(filepath.Join(destination, entry.Name))
		if err != nil {
			return fmt.Errorf("verify published initialization entry: %w", err)
		}
		if !entry.matches(identity) {
			return errors.New("published initialization entry identity changed")
		}
	}
	if err := removeEmptyStage(stage); err != nil {
		return err
	}
	if err := verifyDestinationContents(destination, entries, ""); err != nil {
		return err
	}
	for _, entry := range entries {
		if err := syncPublishedPath(filepath.Join(destination, entry.Name)); err != nil {
			return err
		}
	}
	if err := applyRootMetadata(destination, finalRoot); err != nil {
		return fmt.Errorf("apply destination metadata: %w", err)
	}
	if err := syncDirectory(destination); err != nil {
		return err
	}
	return completeJournal(journal)
}

func verifyDestinationContents(
	destination string,
	entries []transactionJournalEntry,
	allowedStage string,
) error {
	expected := make(map[string]struct{}, len(entries)+1)
	for _, entry := range entries {
		expected[entry.Name] = struct{}{}
	}
	if allowedStage != "" {
		expected[allowedStage] = struct{}{}
	}
	actual, err := os.ReadDir(destination)
	if err != nil {
		return fmt.Errorf("inspect initialization destination: %w", err)
	}
	for _, item := range actual {
		if _, ok := expected[item.Name()]; !ok {
			return errors.New("initialization destination contains an unjournaled entry")
		}
	}
	return nil
}

func publishOrVerifyEntry(
	destination, stage string,
	entry transactionJournalEntry,
) error {
	staged := filepath.Join(stage, entry.Name)
	identity, err := captureTreeIdentity(staged)
	switch {
	case err == nil:
		if !entry.matches(identity) {
			return errors.New("staged initialization entry identity changed")
		}
		if err := renameNoReplace(
			staged,
			filepath.Join(destination, entry.Name),
		); err != nil {
			return fmt.Errorf("publish %s: %w", entry.Name, err)
		}
		return syncDirectory(destination)
	case !errors.Is(err, os.ErrNotExist):
		return fmt.Errorf("inspect staged initialization entry: %w", err)
	}
	published := filepath.Join(destination, entry.Name)
	identity, err = captureTreeIdentity(published)
	switch {
	case errors.Is(err, os.ErrNotExist):
		return errors.New("journaled initialization entry is missing")
	case err != nil:
		return fmt.Errorf("inspect published initialization entry: %w", err)
	case !entry.matches(identity):
		return errors.New("published initialization entry identity changed")
	}
	return nil
}

func removeEmptyStage(stage string) error {
	contents, err := os.ReadDir(stage)
	switch {
	case errors.Is(err, os.ErrNotExist):
		return nil
	case err != nil:
		return fmt.Errorf("inspect initialization stage: %w", err)
	case len(contents) != 0:
		return errors.New("initialization stage contains data that cannot be safely removed")
	}
	if err := os.Remove(stage); err != nil {
		return fmt.Errorf("remove empty initialization stage: %w", err)
	}
	return nil
}

func completeJournal(journal string) error {
	if err := os.Remove(journal); err != nil {
		return fmt.Errorf("complete initialization transaction: %w", err)
	}
	return syncDirectory(filepath.Dir(journal))
}

func captureRootMetadata(path string) (transactionRootMetadata, error) {
	info, err := os.Stat(path)
	if err != nil {
		return transactionRootMetadata{}, fmt.Errorf("inspect volume root metadata: %w", err)
	}
	stat, ok := info.Sys().(*syscall.Stat_t)
	if !ok {
		return transactionRootMetadata{}, errors.New("volume root metadata is unavailable")
	}
	extendedAttributes, err := readExtendedAttributes(path)
	if err != nil {
		return transactionRootMetadata{}, err
	}
	return transactionRootMetadata{
		UID:                  stat.Uid,
		GID:                  stat.Gid,
		Mode:                 uint32(preservedMode(info.Mode())),
		ModificationUnixNano: info.ModTime().UnixNano(),
		ExtendedAttributes:   extendedAttributes,
	}, nil
}

func applyRootMetadata(path string, metadata transactionRootMetadata) error {
	if err := os.Chown(path, int(metadata.UID), int(metadata.GID)); err != nil &&
		!metadataAlreadyMatches(path, metadata.UID, metadata.GID, true) {
		return err
	}
	mode := os.FileMode(metadata.Mode)
	if err := os.Chmod(path, mode); err != nil && !modeAlreadyMatches(path, mode) {
		return err
	}
	timestamp := time.Unix(0, metadata.ModificationUnixNano)
	if err := os.Chtimes(path, timestamp, timestamp); err != nil && !errors.Is(err, syscall.EPERM) {
		return err
	}
	return replaceExtendedAttributes(path, metadata.ExtendedAttributes)
}

// syncDirectory makes the journal rename durable before publication begins.
func syncDirectory(path string) error {
	directory, err := os.Open(path)
	if err != nil {
		return fmt.Errorf("open initialization directory: %w", err)
	}
	defer directory.Close()
	if err := directory.Sync(); err != nil {
		return fmt.Errorf("sync initialization directory: %w", err)
	}
	return nil
}

func safeTopLevelName(name string) bool {
	return name != "" && name != "." && name != ".." && filepath.Base(name) == name
}

func validTransactionID(value string) bool {
	if len(value) != 36 {
		return false
	}
	for index, character := range value {
		if index == 8 || index == 13 || index == 18 || index == 23 {
			if character != '-' {
				return false
			}
			continue
		}
		if !strings.ContainsRune("0123456789abcdef", character) {
			return false
		}
	}
	return true
}

// removeEmptyExt4Scaffolding removes only the empty recovery directory that
// stock Apple container creates when formatting a new named ext4 volume. A
// populated directory is user data and deliberately remains non-empty.
func removeEmptyExt4Scaffolding(destination string) error {
	path := filepath.Join(destination, "lost+found")
	info, err := os.Lstat(path)
	if errors.Is(err, os.ErrNotExist) {
		return nil
	}
	if err != nil {
		return fmt.Errorf("inspect ext4 recovery directory: %w", err)
	}
	if !info.IsDir() || info.Mode()&os.ModeSymlink != 0 {
		return nil
	}
	entries, err := os.ReadDir(path)
	if err != nil {
		return fmt.Errorf("read ext4 recovery directory: %w", err)
	}
	if len(entries) != 0 {
		return nil
	}
	if err := os.Remove(path); err != nil {
		return fmt.Errorf("remove empty ext4 recovery directory: %w", err)
	}
	return nil
}

// destinationIsEmpty treats every entry as user data after exact transaction
// recovery has removed only host-authenticated internal artefacts.
func destinationIsEmpty(destination string) (bool, error) {
	entries, err := os.ReadDir(destination)
	if err != nil {
		return false, fmt.Errorf("read destination: %w", err)
	}
	return len(entries) == 0, nil
}

// destinationIsLogicallyEmpty recognizes only the empty ext4 recovery
// directory created by stock Apple container. It performs no mutation, so the
// untouched root metadata can be journaled before the recovery directory is
// removed.
func destinationIsLogicallyEmpty(destination string) (bool, error) {
	entries, err := os.ReadDir(destination)
	if err != nil {
		return false, fmt.Errorf("read destination: %w", err)
	}
	if len(entries) == 0 {
		return true, nil
	}
	if len(entries) != 1 || entries[0].Name() != "lost+found" {
		return false, nil
	}
	path := filepath.Join(destination, entries[0].Name())
	info, err := os.Lstat(path)
	if err != nil {
		return false, fmt.Errorf("inspect ext4 recovery directory: %w", err)
	}
	if !info.IsDir() || info.Mode()&os.ModeSymlink != 0 {
		return false, nil
	}
	recoveryEntries, err := os.ReadDir(path)
	if err != nil {
		return false, fmt.Errorf("read ext4 recovery directory: %w", err)
	}
	return len(recoveryEntries) == 0, nil
}

type fileIdentity struct {
	device uint64
	inode  uint64
}

// copyEntry reproduces regular files, directories, symbolic links, and hard links.
func copyEntry(source, destination string, hardlinks map[fileIdentity]string) error {
	info, err := os.Lstat(source)
	if err != nil {
		return fmt.Errorf("inspect %s: %w", source, err)
	}
	if info.Mode()&os.ModeSymlink != 0 {
		target, err := os.Readlink(source)
		if err != nil {
			return fmt.Errorf("read link %s: %w", source, err)
		}
		if err := os.Symlink(target, destination); err != nil {
			return fmt.Errorf("create link %s: %w", destination, err)
		}
		return applyMetadata(source, destination, info, false)
	}
	if identity, linked := regularFileIdentity(info); linked {
		if first, exists := hardlinks[identity]; exists {
			if err := os.Link(first, destination); err != nil {
				return fmt.Errorf("create hard link %s: %w", destination, err)
			}
			return nil
		}
		hardlinks[identity] = destination
	}
	switch {
	case info.IsDir():
		if err := os.Mkdir(destination, 0o700); err != nil {
			return fmt.Errorf("create directory %s: %w", destination, err)
		}
		entries, err := os.ReadDir(source)
		if err != nil {
			return fmt.Errorf("read directory %s: %w", source, err)
		}
		for _, entry := range entries {
			if err := copyEntry(
				filepath.Join(source, entry.Name()),
				filepath.Join(destination, entry.Name()),
				hardlinks,
			); err != nil {
				return err
			}
		}
		return applyMetadata(source, destination, info, true)
	case info.Mode().IsRegular():
		if err := copyRegularFile(source, destination, info.Mode().Perm()); err != nil {
			return err
		}
		return applyMetadata(source, destination, info, true)
	case info.Mode()&os.ModeNamedPipe != 0:
		if err := syscall.Mkfifo(destination, uint32(info.Mode().Perm())); err != nil {
			return fmt.Errorf("create named pipe %s: %w", destination, err)
		}
		return applyMetadata(source, destination, info, true)
	default:
		return fmt.Errorf("unsupported image-volume entry type %s", source)
	}
}

// copyRegularFile copies bytes without retaining a second full in-memory image.
func copyRegularFile(source, destination string, mode os.FileMode) error {
	input, err := os.Open(source)
	if err != nil {
		return fmt.Errorf("open %s: %w", source, err)
	}
	defer input.Close()
	output, err := os.OpenFile(destination, os.O_CREATE|os.O_EXCL|os.O_WRONLY, mode)
	if err != nil {
		return fmt.Errorf("create %s: %w", destination, err)
	}
	_, copyErr := io.Copy(output, input)
	closeErr := output.Close()
	if copyErr != nil {
		return fmt.Errorf("copy %s: %w", source, copyErr)
	}
	if closeErr != nil {
		return fmt.Errorf("close %s: %w", destination, closeErr)
	}
	return nil
}

// applyMetadata preserves ownership, permissions, timestamps, and supported xattrs.
func applyMetadata(source, path string, info os.FileInfo, followLink bool) error {
	stat, ok := info.Sys().(*syscall.Stat_t)
	if !ok {
		return errors.New("file metadata is unavailable")
	}
	if followLink {
		if err := os.Chown(path, int(stat.Uid), int(stat.Gid)); err != nil &&
			!metadataAlreadyMatches(path, stat.Uid, stat.Gid, true) {
			return err
		}
		mode := preservedMode(info.Mode())
		if err := os.Chmod(path, mode); err != nil &&
			!modeAlreadyMatches(path, mode) {
			return err
		}
		if err := os.Chtimes(path, info.ModTime(), info.ModTime()); err != nil {
			return err
		}
		return copyExtendedAttributes(source, path)
	}
	if err := os.Lchown(path, int(stat.Uid), int(stat.Gid)); err != nil &&
		!metadataAlreadyMatches(path, stat.Uid, stat.Gid, false) {
		return err
	}
	timestamp := unix.NsecToTimeval(info.ModTime().UnixNano())
	if err := unix.Lutimes(path, []unix.Timeval{timestamp, timestamp}); err != nil {
		return fmt.Errorf("set symbolic link timestamps for %s: %w", path, err)
	}
	return nil
}

// copyExtendedAttributes retains Linux capabilities and other image metadata.
func copyExtendedAttributes(source, destination string) error {
	attributes, err := readExtendedAttributes(source)
	if err != nil {
		return err
	}
	return replaceExtendedAttributes(destination, attributes)
}

func readExtendedAttributes(path string) (map[string][]byte, error) {
	size, err := unix.Listxattr(path, nil)
	if errors.Is(err, syscall.ENOTSUP) {
		return map[string][]byte{}, nil
	}
	if err != nil {
		return nil, fmt.Errorf("list extended attributes for %s: %w", path, err)
	}
	if size == 0 {
		return map[string][]byte{}, nil
	}
	names := make([]byte, size)
	size, err = unix.Listxattr(path, names)
	if err != nil {
		return nil, fmt.Errorf("read extended attribute names for %s: %w", path, err)
	}
	attributes := make(map[string][]byte)
	for _, name := range strings.Split(string(names[:size]), "\x00") {
		if name == "" {
			continue
		}
		valueSize, err := unix.Getxattr(path, name, nil)
		if err != nil {
			return nil, fmt.Errorf("size extended attribute %s for %s: %w", name, path, err)
		}
		value := make([]byte, valueSize)
		valueSize, err = unix.Getxattr(path, name, value)
		if err != nil {
			return nil, fmt.Errorf("read extended attribute %s for %s: %w", name, path, err)
		}
		attributes[name] = value[:valueSize]
	}
	return attributes, nil
}

func setExtendedAttributes(destination string, attributes map[string][]byte) error {
	for name, value := range attributes {
		if err := unix.Setxattr(destination, name, value, 0); err != nil {
			return fmt.Errorf("write extended attribute %s for %s: %w", name, destination, err)
		}
	}
	return nil
}

func replaceExtendedAttributes(destination string, desired map[string][]byte) error {
	current, err := readExtendedAttributes(destination)
	if err != nil {
		return err
	}
	for name := range current {
		if _, retained := desired[name]; retained {
			continue
		}
		if err := unix.Removexattr(destination, name); err != nil &&
			!errors.Is(err, syscall.ENODATA) && !errors.Is(err, syscall.ENOTSUP) {
			return fmt.Errorf("remove extended attribute %s for %s: %w", name, destination, err)
		}
	}
	return setExtendedAttributes(destination, desired)
}

// syncPublishedEntries makes copied bytes and directory entries durable.
func syncPublishedEntries(destination string, entries []os.DirEntry) error {
	for _, entry := range entries {
		if err := syncPublishedPath(filepath.Join(destination, entry.Name())); err != nil {
			return err
		}
	}
	return nil
}

func syncPublishedPath(path string) error {
	info, err := os.Lstat(path)
	if err != nil {
		return fmt.Errorf("inspect published entry %s: %w", path, err)
	}
	if info.IsDir() {
		entries, err := os.ReadDir(path)
		if err != nil {
			return fmt.Errorf("read published directory %s: %w", path, err)
		}
		if err := syncPublishedEntries(path, entries); err != nil {
			return err
		}
		return syncDirectory(path)
	}
	if !info.Mode().IsRegular() {
		return nil
	}
	file, err := os.Open(path)
	if err != nil {
		return fmt.Errorf("open published file %s: %w", path, err)
	}
	defer file.Close()
	if err := file.Sync(); err != nil {
		return fmt.Errorf("sync published file %s: %w", path, err)
	}
	return nil
}

// metadataAlreadyMatches accepts a transport-denied redundant ownership
// update only when an immediate guest-side inspection proves the exact IDs.
func metadataAlreadyMatches(path string, uid, gid uint32, followLink bool) bool {
	var info os.FileInfo
	var err error
	if followLink {
		info, err = os.Stat(path)
	} else {
		info, err = os.Lstat(path)
	}
	if err != nil {
		return false
	}
	stat, ok := info.Sys().(*syscall.Stat_t)
	return ok && stat.Uid == uid && stat.Gid == gid
}

// modeAlreadyMatches applies the same verify-after-EPERM rule to a redundant
// VirtioFS permission update.
func modeAlreadyMatches(path string, mode os.FileMode) bool {
	info, err := os.Stat(path)
	return err == nil && preservedMode(info.Mode()) == preservedMode(mode)
}

// preservedMode returns the permission and special bits that chmod can
// reproduce without carrying file-type bits from the source inode.
func preservedMode(mode os.FileMode) os.FileMode {
	return mode.Perm() | mode&(os.ModeSetuid|os.ModeSetgid|os.ModeSticky)
}

// regularFileIdentity returns a hard-link identity only for linked regular files.
func regularFileIdentity(info os.FileInfo) (fileIdentity, bool) {
	stat, ok := info.Sys().(*syscall.Stat_t)
	if !ok || !info.Mode().IsRegular() || stat.Nlink < 2 {
		return fileIdentity{}, false
	}
	return fileIdentity{device: uint64(stat.Dev), inode: stat.Ino}, true
}
