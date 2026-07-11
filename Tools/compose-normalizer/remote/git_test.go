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
	"strings"
	"testing"
)

func TestValidateGitSubDir(t *testing.T) {
	base := "/tmp/cache/compose/abc123def456"
	tests := []struct {
		name    string
		subDir  string
		wantErr bool
	}{
		{name: "valid simple directory", subDir: "examples"},
		{name: "valid nested directory", subDir: "examples/nginx"},
		{name: "valid deeply nested directory", subDir: "examples/web/frontend/config"},
		{name: "valid current directory", subDir: "."},
		{name: "valid directory with redundant separators", subDir: "examples//nginx"},
		{name: "valid directory with dots in name", subDir: "examples/nginx.conf.d"},
		{name: "path traversal - parent directory", subDir: "..", wantErr: true},
		{name: "path traversal - multiple parent directories", subDir: "../../../etc/passwd", wantErr: true},
		{name: "path traversal - deeply nested escape", subDir: "../../../../../../../tmp/pwned", wantErr: true},
		{name: "path traversal - mixed with valid path", subDir: "examples/../../etc/passwd", wantErr: true},
		{name: "path traversal - at the end", subDir: "examples/.."},
		{name: "path traversal - in the middle", subDir: "examples/../../../etc/passwd", wantErr: true},
		{name: "path traversal - windows style", subDir: `..\..\..\windows\system32`, wantErr: true},
		{name: "absolute unix path", subDir: "/etc/passwd", wantErr: true},
		{name: "absolute windows path", subDir: `C:\windows\system32\config\sam`, wantErr: true},
		{name: "absolute path with home directory", subDir: "/home/user/.ssh/id_rsa", wantErr: true},
		{name: "normalized path that would escape", subDir: "./../../etc/passwd", wantErr: true},
		{name: "directory name with three dots", subDir: ".../config"},
		{name: "directory name with four dots", subDir: "..../config"},
		{name: "directory name with five dots", subDir: "...../etc/passwd"},
		{name: "directory name starting with two dots and letter", subDir: "..foo/bar"},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			err := validateGitSubDir(base, test.subDir)
			if (err != nil) != test.wantErr {
				t.Fatalf("validateGitSubDir(%q, %q) error = %v, wantErr %v", base, test.subDir, err, test.wantErr)
			}
		})
	}
}

func TestValidateGitSubDirSecurityScenarios(t *testing.T) {
	base := "/var/cache/docker-compose/git/1234567890abcdef"
	for _, maliciousPath := range []string{
		"../../../../../../../tmp/pwned",
		"../../../../../../../../etc/passwd",
	} {
		if err := validateGitSubDir(base, maliciousPath); err == nil || !strings.Contains(err.Error(), "path traversal") {
			t.Fatalf("validateGitSubDir(%q, %q) error = %v, want path traversal error", base, maliciousPath, err)
		}
	}

	if err := validateGitSubDir(base, "examples/docker-compose/nginx/config"); err != nil {
		t.Fatalf("validateGitSubDir returned error for legitimate nested path: %v", err)
	}
}
