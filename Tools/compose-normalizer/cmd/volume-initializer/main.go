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
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"
	"syscall"
)

const (
	stagePrefix = ".compose-volume-init-stage-"
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
	if len(arguments) != 2 {
		fmt.Fprintln(stderr, "usage: compose-volume-initializer SOURCE DESTINATION")
		return 2
	}
	if err := initialize(arguments[0], arguments[1]); err != nil {
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
func initialize(source, destination string) error {
	if !filepath.IsAbs(source) || !filepath.IsAbs(destination) {
		return errors.New("source and destination must be absolute paths")
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
	if info, statErr := os.Stat(destination); statErr != nil || !info.IsDir() {
		if statErr != nil {
			return fmt.Errorf("inspect destination: %w", statErr)
		}
		return errors.New("image volume destination is not a directory")
	}

	if err := removeStaleStages(destination); err != nil {
		return err
	}
	if err := removeEmptyExt4Scaffolding(destination); err != nil {
		return err
	}
	empty, err := destinationIsEmpty(destination)
	if err != nil {
		return err
	}
	if !empty {
		return errDestinationNotEmpty
	}

	stage, err := os.MkdirTemp(destination, stagePrefix)
	if err != nil {
		return fmt.Errorf("create initialization stage: %w", err)
	}
	defer os.RemoveAll(stage)
	hardlinks := make(map[fileIdentity]string)
	entries, err := os.ReadDir(source)
	if err != nil {
		return fmt.Errorf("read source: %w", err)
	}
	for _, entry := range entries {
		if err := copyEntry(
			filepath.Join(source, entry.Name()),
			filepath.Join(stage, entry.Name()),
			hardlinks,
		); err != nil {
			return err
		}
	}

	destinationInfo, err := os.Stat(destination)
	if err != nil {
		return fmt.Errorf("inspect destination attributes: %w", err)
	}
	moved := make([]string, 0, len(entries))
	rollback := func() {
		for index := len(moved) - 1; index >= 0; index-- {
			_ = os.RemoveAll(filepath.Join(destination, moved[index]))
		}
		_ = applyMountRootMetadata(destination, destinationInfo)
	}
	for _, entry := range entries {
		name := entry.Name()
		if err := os.Rename(filepath.Join(stage, name), filepath.Join(destination, name)); err != nil {
			rollback()
			return fmt.Errorf("publish %s: %w", name, err)
		}
		moved = append(moved, name)
	}
	if err := applyMountRootMetadata(destination, sourceInfo); err != nil {
		rollback()
		return fmt.Errorf("apply destination metadata: %w", err)
	}
	return nil
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

// applyMountRootMetadata preserves every attribute that stock Apple VirtioFS
// can represent. It accepts EPERM only for the mount root timestamp; all
// ownership and permission updates still require an exact guest-side match.
func applyMountRootMetadata(path string, info os.FileInfo) error {
	stat, ok := info.Sys().(*syscall.Stat_t)
	if !ok {
		return errors.New("file metadata is unavailable")
	}
	if err := os.Chown(path, int(stat.Uid), int(stat.Gid)); err != nil &&
		!metadataAlreadyMatches(path, stat.Uid, stat.Gid, true) {
		return err
	}
	mode := preservedMode(info.Mode())
	if err := os.Chmod(path, mode); err != nil &&
		!modeAlreadyMatches(path, mode) {
		return err
	}
	if err := os.Chtimes(path, info.ModTime(), info.ModTime()); err != nil &&
		!errors.Is(err, syscall.EPERM) {
		return err
	}
	return nil
}

// destinationIsEmpty ignores only initializer-owned transaction directories.
func destinationIsEmpty(destination string) (bool, error) {
	entries, err := os.ReadDir(destination)
	if err != nil {
		return false, fmt.Errorf("read destination: %w", err)
	}
	for _, entry := range entries {
		owned, err := isOwnedStage(entry)
		if err != nil {
			return false, err
		}
		if !owned {
			return false, nil
		}
	}
	return true, nil
}

// removeStaleStages removes only transaction directories owned by this helper.
func removeStaleStages(destination string) error {
	entries, err := os.ReadDir(destination)
	if err != nil {
		return fmt.Errorf("read destination stages: %w", err)
	}
	for _, entry := range entries {
		owned, err := isOwnedStage(entry)
		if err != nil {
			return err
		}
		if owned {
			if err := os.RemoveAll(filepath.Join(destination, entry.Name())); err != nil {
				return fmt.Errorf("remove stale initialization stage: %w", err)
			}
		}
	}
	return nil
}

// isOwnedStage recognizes the exact private directory shape produced by
// os.MkdirTemp when the helper starts a copy-up transaction.
func isOwnedStage(entry os.DirEntry) (bool, error) {
	if !strings.HasPrefix(entry.Name(), stagePrefix) {
		return false, nil
	}
	info, err := entry.Info()
	if err != nil {
		return false, fmt.Errorf("inspect initialization stage: %w", err)
	}
	stat, ok := info.Sys().(*syscall.Stat_t)
	return ok && info.IsDir() && info.Mode().Perm() == 0o700 &&
		stat.Uid == uint32(os.Geteuid()), nil
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
		return applyMetadata(destination, info, false)
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
		return applyMetadata(destination, info, true)
	case info.Mode().IsRegular():
		if err := copyRegularFile(source, destination, info.Mode().Perm()); err != nil {
			return err
		}
		return applyMetadata(destination, info, true)
	case info.Mode()&os.ModeNamedPipe != 0:
		if err := syscall.Mkfifo(destination, uint32(info.Mode().Perm())); err != nil {
			return fmt.Errorf("create named pipe %s: %w", destination, err)
		}
		return applyMetadata(destination, info, true)
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

// applyMetadata preserves ownership, permissions, and modification time.
func applyMetadata(path string, info os.FileInfo, followLink bool) error {
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
		return os.Chtimes(path, info.ModTime(), info.ModTime())
	}
	if err := os.Lchown(path, int(stat.Uid), int(stat.Gid)); err != nil &&
		!metadataAlreadyMatches(path, stat.Uid, stat.Gid, false) {
		return err
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
