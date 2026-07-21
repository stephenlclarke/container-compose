/*
   Copyright 2020 Docker Compose CLI authors

   Licensed under the Apache License, Version 2.0 (the "License");
   you may not use this file except in compliance with the License.
   You may obtain a copy of the License at

       http://www.apache.org/licenses/LICENSE-2.0

   Unless required by applicable law or agreed to in writing, software
   distributed under the License is distributed on an "AS IS" BASIS,
   WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
   See the License for the specific language governing permissions and
   limitations under the License.
*/

package remote

import (
	"os"
	"path/filepath"
	"testing"
)

func TestCacheDirUsesXDGCacheHome(t *testing.T) {
	cacheHome := t.TempDir()
	t.Setenv("XDG_CACHE_HOME", cacheHome)

	cache, err := cacheDir()
	if err != nil {
		t.Fatalf("cacheDir returned error: %v", err)
	}
	if want := filepath.Join(cacheHome, cacheDirectoryName); cache != want {
		t.Fatalf("cacheDir = %q, want %q", cache, want)
	}
}

func TestCacheDirUsesMacOSHomeCache(t *testing.T) {
	home := t.TempDir()
	t.Setenv("XDG_CACHE_HOME", "")
	t.Setenv("HOME", home)

	cache, err := cacheDir()
	if err != nil {
		t.Fatalf("cacheDir returned error: %v", err)
	}
	want := filepath.Join(home, "Library", "Caches", cacheDirectoryName)
	if cache != want {
		t.Fatalf("cacheDir = %q, want %q", cache, want)
	}
	info, err := os.Stat(cache)
	if err != nil {
		t.Fatalf("stat cache directory: %v", err)
	}
	if !info.IsDir() {
		t.Fatalf("cache path %q is not a directory", cache)
	}
}
