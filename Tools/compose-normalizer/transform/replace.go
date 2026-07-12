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

import (
	"fmt"

	"go.yaml.in/yaml/v4"
)

// ReplaceExtendsFile changes service.extends.file in an input YAML stream.
func ReplaceExtendsFile(in []byte, service string, value string) ([]byte, error) {
	var doc yaml.Node
	if err := yaml.Unmarshal(in, &doc); err != nil {
		return nil, err
	}
	if doc.Kind != yaml.DocumentNode {
		return nil, fmt.Errorf("expected document kind %v, got %v", yaml.DocumentNode, doc.Kind)
	}
	root := doc.Content[0]
	if root.Kind != yaml.MappingNode {
		return nil, fmt.Errorf("expected document root to be a mapping, got %v", root.Kind)
	}

	services, err := getMapping(root, "services")
	if err != nil {
		return nil, err
	}
	target, err := getMapping(services, service)
	if err != nil {
		return nil, err
	}
	extends, err := getMapping(target, "extends")
	if err != nil {
		return nil, err
	}
	file, err := getMapping(extends, "file")
	if err != nil {
		return nil, err
	}
	return replace(in, file.Line, file.Column, value), nil
}

// ReplaceEnvFile changes service.env_file in an input YAML stream.
func ReplaceEnvFile(in []byte, service string, index int, value string) ([]byte, error) {
	var doc yaml.Node
	if err := yaml.Unmarshal(in, &doc); err != nil {
		return nil, err
	}
	if doc.Kind != yaml.DocumentNode {
		return nil, fmt.Errorf("expected document kind %v, got %v", yaml.DocumentNode, doc.Kind)
	}
	root := doc.Content[0]
	if root.Kind != yaml.MappingNode {
		return nil, fmt.Errorf("expected document root to be a mapping, got %v", root.Kind)
	}

	services, err := getMapping(root, "services")
	if err != nil {
		return nil, err
	}
	target, err := getMapping(services, service)
	if err != nil {
		return nil, err
	}
	envFile, err := getMapping(target, "env_file")
	if err != nil {
		return nil, err
	}

	if envFile.Kind == yaml.SequenceNode {
		envFile = envFile.Content[index]
		if envFile.Kind == yaml.MappingNode {
			envFile, err = getMapping(envFile, "path")
			if err != nil {
				return nil, err
			}
		}
		return replace(in, envFile.Line, envFile.Column, value), nil
	}
	return replace(in, envFile.Line, envFile.Column, value), nil
}

func getMapping(root *yaml.Node, key string) (*yaml.Node, error) {
	for index := 0; index < len(root.Content); index += 2 {
		k := root.Content[index]
		if k.Kind != yaml.ScalarNode || k.Tag != "!!str" {
			return nil, fmt.Errorf("expected mapping key to be a string, got %v %v", root.Kind, k.Tag)
		}
		if k.Value == key {
			return root.Content[index+1], nil
		}
	}
	return nil, fmt.Errorf("key %v not found", key)
}

func replace(in []byte, line int, column int, value string) []byte {
	var out []byte
	currentLine := 1
	position := 0
	for _, b := range in {
		if b == '\n' {
			currentLine++
			if currentLine == line {
				break
			}
		}
		position++
	}
	position += column
	out = append(out, in[0:position]...)
	out = append(out, []byte(value)...)
	for ; position < len(in); position++ {
		if in[position] == '\n' {
			break
		}
	}
	out = append(out, in[position:]...)
	return out
}
