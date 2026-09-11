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
	"crypto/sha256"
	"encoding/binary"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"syscall"
)

type filesystemTreeIdentity struct {
	device    uint64
	inode     uint64
	nodeCount uint64
	digest    string
}

func (entry transactionJournalEntry) matches(identity filesystemTreeIdentity) bool {
	return entry.Device == identity.device && entry.Inode == identity.inode &&
		entry.NodeCount == identity.nodeCount && entry.TreeDigest == identity.digest
}

func validTreeDigest(value string) bool {
	if len(value) != sha256.Size*2 || strings.ToLower(value) != value {
		return false
	}
	_, err := hex.DecodeString(value)
	return err == nil
}

// captureTreeIdentity authenticates every staged inode, its metadata and
// attributes, and the content of a top-level regular file. Descendant ctime
// detects in-place changes while the root ctime is excluded because publication
// itself changes it.
func captureTreeIdentity(path string) (filesystemTreeIdentity, error) {
	root, err := os.Lstat(path)
	if err != nil {
		return filesystemTreeIdentity{}, err
	}
	rootStat, ok := root.Sys().(*syscall.Stat_t)
	if !ok {
		return filesystemTreeIdentity{}, errors.New("filesystem identity is unavailable")
	}
	hasher := sha256.New()
	var nodeCount uint64
	err = filepath.WalkDir(path, func(current string, _ fs.DirEntry, walkErr error) error {
		if walkErr != nil {
			return walkErr
		}
		info, statErr := os.Lstat(current)
		if statErr != nil {
			return statErr
		}
		stat, ok := info.Sys().(*syscall.Stat_t)
		if !ok {
			return errors.New("filesystem identity is unavailable")
		}
		relative, relErr := filepath.Rel(path, current)
		if relErr != nil {
			return relErr
		}
		writeDigestString(hasher, filepath.ToSlash(relative))
		changeTime := int64(0)
		if relative != "." {
			changeTime = changeTimeUnixNano(stat)
		}
		for _, value := range []uint64{
			uint64(stat.Dev), uint64(stat.Ino), uint64(info.Mode()),
			uint64(stat.Uid), uint64(stat.Gid), uint64(info.Size()),
			uint64(info.ModTime().UnixNano()), uint64(changeTime),
		} {
			writeDigestUint64(hasher, value)
		}
		if info.Mode()&os.ModeSymlink == 0 {
			attributes, attributeErr := readExtendedAttributes(current)
			if attributeErr != nil {
				return attributeErr
			}
			writeDigestAttributes(hasher, attributes)
		} else {
			writeDigestUint64(hasher, 0)
		}
		if relative == "." && info.Mode().IsRegular() {
			file, openErr := os.Open(current)
			if openErr != nil {
				return openErr
			}
			_, copyErr := io.Copy(hasher, file)
			closeErr := file.Close()
			if copyErr != nil {
				return copyErr
			}
			if closeErr != nil {
				return closeErr
			}
		}
		nodeCount++
		return nil
	})
	if err != nil {
		return filesystemTreeIdentity{}, err
	}
	return filesystemTreeIdentity{
		device: uint64(rootStat.Dev), inode: uint64(rootStat.Ino),
		nodeCount: nodeCount, digest: hex.EncodeToString(hasher.Sum(nil)),
	}, nil
}

func writeDigestAttributes(writer io.Writer, attributes map[string][]byte) {
	names := make([]string, 0, len(attributes))
	for name := range attributes {
		names = append(names, name)
	}
	sort.Strings(names)
	writeDigestUint64(writer, uint64(len(names)))
	for _, name := range names {
		writeDigestString(writer, name)
		writeDigestUint64(writer, uint64(len(attributes[name])))
		_, _ = writer.Write(attributes[name])
	}
}

func writeDigestString(writer io.Writer, value string) {
	writeDigestUint64(writer, uint64(len(value)))
	_, _ = io.WriteString(writer, value)
}

func writeDigestUint64(writer io.Writer, value uint64) {
	var encoded [8]byte
	binary.BigEndian.PutUint64(encoded[:], value)
	_, _ = writer.Write(encoded[:])
}

func verifyStageContents(stage string, entries []transactionJournalEntry) error {
	actual, err := os.ReadDir(stage)
	if errors.Is(err, os.ErrNotExist) {
		return nil
	}
	if err != nil {
		return fmt.Errorf("inspect initialization stage contents: %w", err)
	}
	expected := make(map[string]transactionJournalEntry, len(entries))
	for _, entry := range entries {
		expected[entry.Name] = entry
	}
	for _, item := range actual {
		entry, ok := expected[item.Name()]
		if !ok {
			return errors.New("initialization stage contains an unjournaled entry")
		}
		identity, captureErr := captureTreeIdentity(filepath.Join(stage, item.Name()))
		if captureErr != nil {
			return fmt.Errorf("inspect staged initialization entry: %w", captureErr)
		}
		if !entry.matches(identity) {
			return errors.New("staged initialization entry identity changed")
		}
	}
	return nil
}
