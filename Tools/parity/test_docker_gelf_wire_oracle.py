#!/usr/bin/env python3
##===----------------------------------------------------------------------===##
## Copyright © 2026 container-compose project authors.
##
## Licensed under the Apache License, Version 2.0 (the "License");
## you may not use this file except in compliance with the License.
## You may obtain a copy of the License at
##
##   https://www.apache.org/licenses/LICENSE-2.0
##
## Unless required by applicable law or agreed to in writing, software
## distributed under the License is distributed on an "AS IS" BASIS,
## WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
## See the License for the specific language governing permissions and
## limitations under the License.
##===----------------------------------------------------------------------===##

"""Focused unit tests for Docker GELF wire, configuration, and metadata normalizers."""

from __future__ import annotations

import gzip
import importlib.util
import json
from pathlib import Path
import unittest


REPOSITORY = Path(__file__).resolve().parents[2]
ORACLE_PATH = REPOSITORY / "Tools/parity/capture-docker-logging-driver-oracle.py"
SPECIFICATION = importlib.util.spec_from_file_location(
    "docker_logging_driver_oracle",
    ORACLE_PATH,
)
assert SPECIFICATION is not None
assert SPECIFICATION.loader is not None
ORACLE = importlib.util.module_from_spec(SPECIFICATION)
SPECIFICATION.loader.exec_module(ORACLE)


class GELFOracleTests(unittest.TestCase):
    """Keep normalizer-only failures independent from a live Docker oracle."""

    container_id = "a" * 64
    container_name = "/gelf-oracle"

    def record(self, message: str, level: int) -> bytes:
        """Build one Docker-shaped GELF object with controlled dynamic values."""

        payload = {
            "version": "1.1",
            "host": "colima",
            "short_message": message,
            "timestamp": 1_785_957_109.812,
            "level": level,
            "_ORACLE_ENV": "bravo",
            "_command": " ".join(ORACLE.REMOTE_LOG_COMMAND),
            "_container_id": self.container_id,
            "_container_name": self.container_name.lstrip("/"),
            "_created": "2026-08-05T19:11:49.727848561Z",
            "_image_id": "sha256:" + "b" * 64,
            "_image_name": "alpine:3.20",
            "_oracle.label": "alpha",
            "_tag": "oracle.gelf-oracle." + self.container_id[:12],
        }
        return json.dumps(payload, separators=(",", ":")).encode()

    def records(self) -> list[bytes]:
        """Return the stdout/stderr/binary conversion sequence Docker emits."""

        return [
            self.record("stdout-ascii", 6),
            self.record("stderr-utf8-☃", 3),
            self.record("stdout-binary-�\x00-end", 6),
        ]

    def metadata_record(self, message: str, level: int) -> bytes:
        """Build a Docker-shaped GELF object for selected metadata precedence."""

        payload = {
            "version": "1.1",
            "host": "colima",
            "short_message": message,
            "timestamp": 1_785_957_109.812,
            "level": level,
            "_MATCH_ONE": "matched",
            "_com.example.role": "frontend",
            "_command": " ".join(ORACLE.REMOTE_LOG_COMMAND),
            "_container_id": "metadata-id",
            "_container_name": self.container_name.lstrip("/"),
            "_created": "2026-08-05T19:11:49.727848561Z",
            "_image_id": "sha256:" + "b" * 64,
            "_image_name": "alpine:3.20",
            "_shared": "environment",
            "_tag": self.container_name.lstrip("/") + "/" + self.container_id[:12],
            "_team": "runtime",
        }
        return json.dumps(payload, separators=(",", ":")).encode()

    def metadata_records(self) -> list[bytes]:
        """Return the selected-metadata sequence for the direct Docker oracle."""

        return [
            self.metadata_record("stdout-ascii", 6),
            self.metadata_record("stderr-utf8-☃", 3),
            self.metadata_record("stdout-binary-�\x00-end", 6),
        ]

    def test_udp_gzip_normalizes_each_datagram_without_hiding_semantics(self) -> None:
        raw = {
            "datagramsHex": [
                gzip.compress(record, mtime=0).hex() for record in self.records()
            ],
        }

        normalized = ORACLE.normalize_gelf_wire(
            raw,
            mode="gelf-udp",
            container_id=self.container_id,
            container_name=self.container_name,
        )

        self.assertEqual(normalized["framing"]["compression"], "gzip")
        self.assertTrue(
            normalized["framing"]["datagramBoundariesAreMessageBoundaries"],
        )
        self.assertEqual(
            [record["level"] for record in normalized["records"]],
            [6, 3, 6],
        )
        self.assertEqual(
            normalized["records"][2]["shortMessage"],
            "stdout-binary-�\x00-end",
        )
        self.assertEqual(
            normalized["records"][0]["extras"]["_container_id"],
            "<container-id>",
        )
        self.assertEqual(
            normalized["records"][0]["extras"]["_tag"],
            "oracle.<container-name>.<container-id-short>",
        )
        self.assertEqual(
            normalized["records"][0]["extras"]["_created"],
            "<rfc3339-nano-utc>",
        )
        self.assertEqual(
            normalized["records"][0]["timestampPrecision"],
            "at-most-milliseconds",
        )

    def test_rejects_timestamps_finer_than_milliseconds(self) -> None:
        payload = json.loads(self.records()[0])
        payload["timestamp"] = 1_785_957_109.8123
        raw = {
            "datagramsHex": [
                gzip.compress(json.dumps(payload, separators=(",", ":")).encode()).hex(),
            ],
        }

        with self.assertRaises(ORACLE.OracleFailure):
            ORACLE.normalize_gelf_wire(
                raw,
                mode="gelf-udp",
                container_id=self.container_id,
                container_name=self.container_name,
            )

    def test_tcp_requires_nul_delimiters_and_peer_shutdown(self) -> None:
        raw = {
            "peerClosed": True,
            "streamHex": b"\0".join(self.records()).hex() + "00",
        }

        normalized = ORACLE.normalize_gelf_wire(
            raw,
            mode="gelf-tcp",
            container_id=self.container_id,
            container_name=self.container_name,
        )

        self.assertEqual(normalized["framing"]["compression"], "none")
        self.assertTrue(normalized["framing"]["streamEndsWithNUL"])
        self.assertTrue(normalized["peerClosedAfterContainerExit"])
        self.assertEqual(len(normalized["records"]), 3)

        with self.assertRaises(ORACLE.OracleFailure):
            ORACLE.normalize_gelf_wire(
                {"peerClosed": True, "streamHex": self.records()[0].hex()},
                mode="gelf-tcp",
                container_id=self.container_id,
                container_name=self.container_name,
            )

    def test_metadata_normalizer_pins_selected_values_and_builtin_override(self) -> None:
        raw = {
            "datagramsHex": [
                gzip.compress(record, mtime=0).hex()
                for record in self.metadata_records()
            ],
        }

        normalized = ORACLE.normalize_gelf_metadata_wire(
            raw,
            mode="gelf-udp",
            container_id=self.container_id,
            container_name=self.container_name,
        )

        extras = normalized["records"][0]["extras"]
        self.assertEqual(extras["_MATCH_ONE"], "matched")
        self.assertEqual(extras["_com.example.role"], "frontend")
        self.assertEqual(extras["_container_id"], "metadata-id")
        self.assertEqual(extras["_shared"], "environment")
        self.assertEqual(extras["_team"], "runtime")
        self.assertEqual(
            extras["_tag"],
            "<container-name>/<container-id-short>",
        )

        invalid = json.loads(self.metadata_records()[0])
        invalid["_shared"] = "label"
        with self.assertRaises(ORACLE.OracleFailure):
            ORACLE.normalize_gelf_metadata_wire(
                {
                    "datagramsHex": [
                        gzip.compress(
                            json.dumps(invalid, separators=(",", ":")).encode(),
                            mtime=0,
                        ).hex(),
                    ],
                },
                mode="gelf-udp",
                container_id=self.container_id,
                container_name=self.container_name,
            )

    def test_config_normalization_preserves_docker_option_strings(self) -> None:
        normalized = ORACLE.normalized_gelf_log_config(
            {
                "Config": {
                    "gelf-address": "tcp://127.0.0.1:12201",
                    "gelf-tcp-max-reconnect": "+1",
                    "gelf-tcp-reconnect-delay": "0",
                },
                "Type": "gelf",
            },
            address_placeholder="tcp://<colima-oracle-receiver>",
        )

        self.assertEqual(
            normalized,
            {
                "Config": {
                    "gelf-address": "tcp://<colima-oracle-receiver>",
                    "gelf-tcp-max-reconnect": "+1",
                    "gelf-tcp-reconnect-delay": "0",
                },
                "Type": "gelf",
            },
        )

    def test_config_normalization_rejects_non_gelf_or_non_string_options(self) -> None:
        with self.assertRaises(ORACLE.OracleFailure):
            ORACLE.normalized_gelf_log_config({"Config": {}, "Type": "json-file"})
        with self.assertRaises(ORACLE.OracleFailure):
            ORACLE.normalized_gelf_log_config(
                {"Config": {"gelf-address": 12201}, "Type": "gelf"},
            )


if __name__ == "__main__":
    unittest.main()
