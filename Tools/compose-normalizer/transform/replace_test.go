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

// Portions derived from Docker Compose.
// Copyright 2020 Docker Compose CLI authors.

package transform

import "testing"

func TestReplaceExtendsFile(t *testing.T) {
	tests := []struct {
		name string
		in   string
		want string
	}{
		{
			name: "simple",
			in: `services:
  test:
    extends:
      file: foo.yaml
      service: foo
`,
			want: `services:
  test:
    extends:
      file: REPLACED
      service: foo
`,
		},
		{
			name: "last line",
			in: `services:
  test:
    extends:
      service: foo
      file: foo.yaml
`,
			want: `services:
  test:
    extends:
      service: foo
      file: REPLACED
`,
		},
		{
			name: "last line no newline",
			in: `services:
  test:
    extends:
      service: foo
      file: foo.yaml`,
			want: `services:
  test:
    extends:
      service: foo
      file: REPLACED`,
		},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			got, err := ReplaceExtendsFile([]byte(test.in), "test", "REPLACED")
			if err != nil {
				t.Fatalf("ReplaceExtendsFile returned error: %v", err)
			}
			if string(got) != test.want {
				t.Fatalf("ReplaceExtendsFile() = %q, want %q", string(got), test.want)
			}
		})
	}
}

func TestReplaceEnvFile(t *testing.T) {
	tests := []struct {
		name  string
		in    string
		index int
		want  string
	}{
		{
			name: "string",
			in: `services:
  test:
    env_file: .env
`,
			want: `services:
  test:
    env_file: REPLACED
`,
		},
		{
			name: "sequence string",
			in: `services:
  test:
    env_file:
      - .env
      - .env.prod
`,
			index: 1,
			want: `services:
  test:
    env_file:
      - .env
      - REPLACED
`,
		},
		{
			name: "sequence mapping",
			in: `services:
  test:
    env_file:
      - path: .env
        required: false
      - path: .env.prod
        required: true
`,
			index: 0,
			want: `services:
  test:
    env_file:
      - path: REPLACED
        required: false
      - path: .env.prod
        required: true
`,
		},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			got, err := ReplaceEnvFile([]byte(test.in), "test", test.index, "REPLACED")
			if err != nil {
				t.Fatalf("ReplaceEnvFile returned error: %v", err)
			}
			if string(got) != test.want {
				t.Fatalf("ReplaceEnvFile() = %q, want %q", string(got), test.want)
			}
		})
	}
}
