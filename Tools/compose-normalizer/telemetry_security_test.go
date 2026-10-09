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
	"context"
	"encoding/json"
	"strings"
	"testing"

	sdktrace "go.opentelemetry.io/otel/sdk/trace"
)

// An exported configuration field models an exporter with a sensitive endpoint.
// The sentinel is fictional and never contacts a collector or configures a logger.
type telemetrySecretProbe struct {
	Endpoint string
}

func (*telemetrySecretProbe) ExportSpans(context.Context, []sdktrace.ReadOnlySpan) error {
	// No spans are exported by this diagnostic-marshalling regression.
	return nil
}

func (*telemetrySecretProbe) Shutdown(context.Context) error {
	// The fixture owns no network connections or other external resources.
	return nil
}

func TestTelemetryDiagnosticsDoNotExposeExporterConfiguration(t *testing.T) {
	const sentinel = "never-log-fixture-endpoint"
	for name, create := range map[string]func(sdktrace.SpanExporter) sdktrace.SpanProcessor{
		"batch": func(exporter sdktrace.SpanExporter) sdktrace.SpanProcessor {
			return sdktrace.NewBatchSpanProcessor(exporter)
		},
		"simple": sdktrace.NewSimpleSpanProcessor,
	} {
		t.Run(name, func(t *testing.T) {
			processor := create(&telemetrySecretProbe{Endpoint: sentinel})
			t.Cleanup(func() {
				if err := processor.Shutdown(context.Background()); err != nil {
					t.Errorf("shutdown diagnostic fixture: %v", err)
				}
			})
			marshaler, ok := processor.(interface{ MarshalLog() any })
			if !ok {
				t.Fatal("SDK no longer exposes the diagnostic boundary; review this contract")
			}
			data, err := json.Marshal(marshaler.MarshalLog())
			if err != nil {
				t.Fatalf("marshal SDK diagnostics: %v", err)
			}
			if strings.Contains(string(data), sentinel) || strings.Contains(string(data), "Endpoint") {
				t.Fatal("SDK diagnostics expose exporter configuration (GHSA-8wmf-6v46-5gfg)")
			}
			if !strings.Contains(string(data), "telemetrySecretProbe") {
				t.Fatal("expected exporter type identity, not empty or missing diagnostics")
			}
		})
	}
}
