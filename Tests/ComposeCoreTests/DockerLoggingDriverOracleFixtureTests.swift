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

import Foundation
import Testing

// This fixture intentionally keeps its evidence assertions together and explicit.
// swiftlint:disable file_length

@Suite("Docker Engine logging-driver oracle fixture")
// swiftlint:disable:next type_body_length
struct DockerLoggingDriverOracleFixtureTests {
    @Test
    func `pins evidence host and monotonic case timings`() throws {
        let fixture = try Self.fixture()

        #expect(try integer(fixture, "schemaVersion") == 3)
        #expect(try string(fixture, "metadata", "composeVersion") == "5.3.1")
        #expect(try string(fixture, "metadata", "engineGitCommit") == "6bc6209")
        #expect(try string(fixture, "metadata", "hostArchitecture") == "arm64")
        #expect(try string(fixture, "metadata", "hostModel") == "Mac17,9")
        #expect(try string(fixture, "metadata", "macOSVersion") == "26.5.2")

        let cases: [String: Any] = try value(fixture, "cases")
        let timings: [String: Any] = try value(fixture, "timings")
        #expect(Set(cases.keys) == Set(timings.keys))
        for name in timings.keys {
            #expect(
                try string(fixture, path: ["timings", name, "clock"])
                    == "time.monotonic",
            )
            #expect(try double(fixture, path: ["timings", name, "durationSeconds"]) > 0)
        }
    }

    @Test
    // swiftlint:disable:next function_body_length
    func `pins identity option quirks and validation phases`() throws {
        let fixture = try Self.fixture()

        #expect(try string(fixture, "metadata", "engineVersion") == "29.2.1")
        #expect(try string(fixture, "metadata", "apiVersion") == "1.53")
        #expect(try string(fixture, "metadata", "context") == "colima")
        #expect(try string(fixture, "metadata", "architecture") == "arm64")
        #expect(try string(fixture, "metadata", "defaultLoggingDriver") == "json-file")

        #expect(
            try string(
                fixture,
                "cases", "omittedDefault", "inspectBeforeRead", "logConfig", "Type",
            ) == "json-file",
        )
        #expect(
            try string(fixture, "cases", "omittedDefault", "inspectBeforeRead", "logPath")
                == "",
        )
        #expect(
            try string(
                fixture,
                "cases", "omittedDefault", "inspectAfterCreatedRead", "logPath",
            ) == "/var/lib/docker/containers/<container-id>/<container-id>-json.log",
        )
        #expect(
            try integer(
                fixture,
                "cases", "omittedDefault", "createdFollowRead", "httpStatus",
            ) == 200,
        )
        #expect(
            try string(
                fixture,
                "cases", "emptyDriver", "inspectAfterCreate", "logConfig", "Type",
            ) == "json-file",
        )

        #expect(
            try string(
                fixture,
                "cases", "noneArbitraryOptions", "inspectAfterExit", "logConfig", "Config",
                "opaque-option",
            ) == "opaque-value",
        )
        #expect(
            try string(
                fixture,
                "cases", "noneArbitraryOptions", "inspectAfterExit", "logConfig", "Config",
                "max-size",
            ) == "1m",
        )
        #expect(
            try integer(
                fixture,
                "cases", "noneArbitraryOptions", "stoppedRead", "httpStatus",
            ) == 501,
        )

        #expect(
            try integer(
                fixture,
                "cases", "validationPhases", "createTimeUnknownLocalOption", "httpStatus",
            ) == 400,
        )
        #expect(
            try boolean(
                fixture,
                "cases", "validationPhases", "createTimeUnknownLocalOption", "containerResidue",
            ) == false,
        )
        #expect(
            try integer(
                fixture,
                "cases", "validationPhases", "startTimeInvalidJSONFileValue", "start",
                "httpStatus",
            ) == 500,
        )
        #expect(
            try string(
                fixture,
                "cases", "validationPhases", "startTimeInvalidJSONFileValue",
                "inspectAfterFailedStart", "state", "status",
            ) == "created",
        )
        #expect(
            try string(
                fixture,
                "cases", "validationPhases", "startTimeInvalidJSONFileValue",
                "inspectAfterFailedStart", "logPath",
            ) == "/var/lib/docker/containers/<container-id>/<container-id>-json.log",
        )
    }

    @Test
    func `pins syslog address and facility validation phases`() throws {
        let fixture = try Self.fixture()

        for label in [
            "emptyUDPPort", "explicitIPv6EmptyPort", "explicitIPv6Port", "leadingZeroPort",
            "opaqueTarget", "uppercaseScheme",
        ] {
            #expect(
                try integer(
                    fixture, "cases", "syslogValidation", "address", label, "create", "httpStatus",
                ) == 201,
            )
            #expect(
                try integer(
                    fixture, "cases", "syslogValidation", "address", label, "start", "httpStatus",
                ) == 204,
            )
        }
        #expect(
            try string(
                fixture, "cases", "syslogValidation", "address", "opaqueTarget",
                "inspectAfterCreate", "logConfig", "Config", "syslog-address",
            ) == "udp:localhost",
        )

        for label in ["ipv6DefaultPortBug", "outOfRangePort", "unixExistingNonSocket"] {
            #expect(
                try integer(
                    fixture, "cases", "syslogValidation", "address", label, "create", "httpStatus",
                ) == 201,
            )
            #expect(
                try integer(
                    fixture, "cases", "syslogValidation", "address", label, "start", "httpStatus",
                ) == 500,
            )
            #expect(
                try string(
                    fixture, "cases", "syslogValidation", "address", label, "inspectAfterStart",
                    "state", "status",
                ) == "created",
            )
        }
        #expect(
            try string(
                fixture, "cases", "syslogValidation", "address", "ipv6DefaultPortBug", "start",
                "message",
            ).contains("address [[::1]]:514: missing port in address"),
        )

        for label in ["servicePort", "signedPort", "unixOpaquePath"] {
            #expect(
                try integer(
                    fixture, "cases", "syslogValidation", "address", label, "create", "httpStatus",
                ) == 400,
            )
            #expect(
                try boolean(
                    fixture, "cases", "syslogValidation", "address", label, "containerResidue",
                ) == false,
            )
        }

        for label in ["leadingPlus", "leadingZero", "maximumNumeric", "negativeZero"] {
            #expect(
                try integer(
                    fixture, "cases", "syslogValidation", "facility", label, "start", "httpStatus",
                ) == 204,
            )
        }
        for label in ["leadingWhitespace", "outOfRange", "uppercaseName"] {
            #expect(
                try integer(
                    fixture, "cases", "syslogValidation", "facility", label, "create", "httpStatus",
                ) == 400,
            )
            #expect(
                try string(
                    fixture, "cases", "syslogValidation", "facility", label, "create", "message",
                ) == "invalid syslog facility",
            )
        }
    }

    @Test
    func `pins syslog format metadata and tag validation phases`() throws {
        let fixture = try Self.fixture()

        #expect(
            try integer(
                fixture, "cases", "syslogValidation", "format", "microseconds", "start", "httpStatus",
            ) == 204,
        )
        #expect(
            try integer(
                fixture, "cases", "syslogValidation", "format", "uppercase", "create", "httpStatus",
            ) == 400,
        )
        #expect(
            try string(
                fixture, "cases", "syslogValidation", "format", "uppercase", "create", "message",
            ) == "Invalid syslog format",
        )

        for label in ["invalidUnusedEnvironment", "invalidUnusedLabels"] {
            #expect(
                try integer(
                    fixture, "cases", "syslogValidation", "metadataRegex", label, "start", "httpStatus",
                ) == 204,
            )
        }
        for label in ["controlAction", "whitespaceTrim"] {
            #expect(
                try integer(
                    fixture, "cases", "syslogValidation", "tagTemplate", label, "start", "httpStatus",
                ) == 204,
            )
        }
        #expect(
            try integer(
                fixture, "cases", "syslogValidation", "tagTemplate", "invalidFunction", "create",
                "httpStatus",
            ) == 201,
        )
        #expect(
            try integer(
                fixture, "cases", "syslogValidation", "tagTemplate", "invalidFunction", "start",
                "httpStatus",
            ) == 500,
        )
        #expect(
            try string(
                fixture, "cases", "syslogValidation", "tagTemplate", "invalidFunction", "start",
                "message",
            ).contains("function \"missing\" not defined"),
        )
    }

    @Test
    func `pins syslog transport dependent TLS validation`() throws {
        let fixture = try Self.fixture()

        #expect(
            try integer(
                fixture, "cases", "syslogValidation", "tlsMaterial",
                "plainTransportIgnoresMissingFiles", "start", "httpStatus",
            ) == 204,
        )
        #expect(
            try integer(
                fixture, "cases", "syslogValidation", "tlsMaterial",
                "tlsTransportLoadsFilesAtStart", "create", "httpStatus",
            ) == 201,
        )
        #expect(
            try integer(
                fixture, "cases", "syslogValidation", "tlsMaterial",
                "tlsTransportLoadsFilesAtStart", "start", "httpStatus",
            ) == 400,
        )
        #expect(
            try string(
                fixture, "cases", "syslogValidation", "tlsMaterial",
                "tlsTransportLoadsFilesAtStart", "inspectAfterStart", "state", "status",
            ) == "created",
        )
        #expect(
            try string(
                fixture, "cases", "syslogValidation", "tlsMaterial",
                "tlsTransportLoadsFilesAtStart", "start", "message",
            ).contains("could not read CA certificate \"/missing/ca\""),
        )
        #expect(
            try integer(
                fixture, "cases", "syslogValidation", "tlsMaterial", "skipVerifyUsesPresence",
                "create", "httpStatus",
            ) == 201,
        )
        #expect(
            try string(
                fixture, "cases", "syslogValidation", "tlsMaterial", "skipVerifyUsesPresence",
                "inspectAfterCreate", "logConfig", "Config", "syslog-tls-skip-verify",
            ) == "not-a-boolean",
        )
    }

    @Test
    // swiftlint:disable:next function_body_length
    func `pins create and start option grammars`() throws {
        let fixture = try Self.fixture()

        #expect(
            try integer(fixture, "cases", "optionSemantics", "sizeUnits", "maxSize4kBytes")
                == 4000,
        )
        #expect(
            try integer(
                fixture,
                "cases", "optionSemantics", "sizeUnits", "maxBufferSize4kBytes",
            ) == 4096,
        )
        #expect(
            try string(
                fixture,
                "cases", "optionSemantics", "sizeUnits", "cachePrefixedLocalOptions",
            ) == "retained-but-ignored",
        )
        #expect(
            try string(fixture, "cases", "optionSemantics", "sizeUnits", "maxSizeParser")
                == "units.FromHumanSize",
        )
        #expect(
            try string(
                fixture,
                "cases", "optionSemantics", "sizeUnits", "maxBufferSizeParser",
            ) == "units.RAMInBytes",
        )
        #expect(
            try integer(
                fixture,
                "cases", "optionSemantics", "sizeUnits", "cacheLocalDefaults", "maxSizeBytes",
            ) == 20 * 1024 * 1024,
        )
        #expect(
            try integer(
                fixture,
                "cases", "optionSemantics", "sizeUnits", "cacheLocalDefaults", "maxFile",
            ) == 5,
        )
        #expect(
            try boolean(
                fixture,
                "cases", "optionSemantics", "sizeUnits", "cacheLocalDefaults", "compress",
            ),
        )

        #expect(
            try integer(
                fixture, "cases", "optionSemantics", "mode", "empty", "create", "httpStatus",
            ) == 201,
        )
        #expect(
            try string(
                fixture, "cases", "optionSemantics", "mode", "empty", "inspectAfterCreate",
                "logConfig", "Config", "mode",
            ) == "",
        )
        #expect(
            try integer(
                fixture, "cases", "optionSemantics", "mode", "uppercase", "create", "httpStatus",
            ) == 400,
        )

        for label in ["trueMixed", "falseUpper", "trueOne", "falseZero", "trueShort", "falseShort"] {
            #expect(
                try integer(
                    fixture, "cases", "optionSemantics", "compress", label, "start", "httpStatus",
                ) == 204,
            )
        }
        for label in ["invalid", "empty", "missingRotation"] {
            #expect(
                try integer(
                    fixture, "cases", "optionSemantics", "compress", label, "start", "httpStatus",
                ) == 500,
            )
        }

        for label in [
            "bytes", "fractionalUnit", "binaryUnit", "spaceSeparator", "leadingPlus", "leadingFraction",
            "exponent",
        ] {
            #expect(
                try integer(
                    fixture, "cases", "optionSemantics", "maxSize", label, "start", "httpStatus",
                ) == 204,
            )
        }
        for label in ["zero", "negative", "outerWhitespace"] {
            #expect(
                try integer(
                    fixture, "cases", "optionSemantics", "maxSize", label, "start", "httpStatus",
                ) == 500,
            )
        }

        for label in ["one", "leadingPlus", "leadingZero"] {
            #expect(
                try integer(
                    fixture, "cases", "optionSemantics", "maxFile", label, "start", "httpStatus",
                ) == 204,
            )
        }
        for label in ["zero", "negative", "fractional", "outerWhitespace"] {
            #expect(
                try integer(
                    fixture, "cases", "optionSemantics", "maxFile", label, "start", "httpStatus",
                ) == 500,
            )
        }

        for label in ["zero", "fractionalUnit", "upperUnit"] {
            #expect(
                try integer(
                    fixture, "cases", "optionSemantics", "maxBufferSize", label, "create", "httpStatus",
                ) == 201,
            )
        }
        for label in ["outerWhitespace", "negative"] {
            #expect(
                try integer(
                    fixture, "cases", "optionSemantics", "maxBufferSize", label, "create", "httpStatus",
                ) == 400,
            )
        }
    }

    @Test
    func `pins cache prefix validation and retention quirks`() throws {
        let fixture = try Self.fixture()

        for label in [
            "trueMixed", "falseUpper", "trueOne", "falseZero", "trueShort", "falseShort", "empty",
        ] {
            #expect(
                try integer(
                    fixture, "cases", "optionSemantics", "cacheDisabled", label, "create", "httpStatus",
                ) == 201,
            )
        }
        #expect(
            try integer(
                fixture, "cases", "optionSemantics", "cacheDisabled", "invalid", "create", "httpStatus",
            ) == 400,
        )

        for driverCase in ["syslogArbitrary", "jsonFileArbitrary"] {
            #expect(
                try integer(
                    fixture, "cases", "optionSemantics", "cachePrefixRetention", driverCase,
                    "start", "httpStatus",
                ) == 204,
            )
            #expect(
                try string(
                    fixture, "cases", "optionSemantics", "cachePrefixRetention", driverCase,
                    "inspectAfterCreate", "logConfig", "Config", "cache-max-size",
                ) == "not-a-size",
            )
        }
    }

    @Test
    // swiftlint:disable:next function_body_length
    func `pins stopped framing json records and restart retention`() throws {
        let fixture = try Self.fixture()

        #expect(
            try string(
                fixture,
                "cases", "jsonFileStoppedReadAndFraming", "combinedRead", "contentType",
            ) == "application/vnd.docker.multiplexed-stream",
        )
        #expect(
            try string(
                fixture,
                "cases", "jsonFileStoppedReadAndFraming", "combinedRead", "framing",
            ) == "docker-multiplexed-8-byte-header",
        )
        #expect(
            try string(
                fixture,
                "cases", "jsonFileStoppedReadAndFraming", "combinedRead", "stdout",
            ) == "stdout-line\n",
        )
        #expect(
            try string(
                fixture,
                "cases", "jsonFileStoppedReadAndFraming", "combinedRead", "stderr",
            ) == "stderr-line\n",
        )

        let frames: [[String: Any]] = try value(
            fixture,
            "cases", "jsonFileStoppedReadAndFraming", "combinedRead", "frames",
        )
        #expect(frames.count == 2)
        #expect(try string(frames[0], "stream") == "stdout")
        #expect(try integer(frames[0], "header", "streamID") == 1)
        #expect(try integer(frames[0], "header", "payloadLength") == 12)
        #expect(try string(frames[1], "stream") == "stderr")
        #expect(try integer(frames[1], "header", "streamID") == 2)

        #expect(
            try string(
                fixture,
                "cases", "ttyRawMergedFraming", "combinedRead", "contentType",
            ) == "application/vnd.docker.raw-stream",
        )
        #expect(
            try string(
                fixture,
                "cases", "ttyRawMergedFraming", "combinedRead", "bytes",
            ) == "stdout-line\r\nstderr-line\r\n",
        )
        #expect(
            try string(
                fixture,
                "cases", "ttyRawMergedFraming", "stderrOnlyRead", "bytes",
            ) == "",
        )
        #expect(
            try string(
                fixture,
                "cases", "ttyRawMergedFraming", "stdoutOnlyRead", "bytes",
            ) == "stdout-line\r\nstderr-line\r\n",
        )

        let records: [[String: Any]] = try value(
            fixture,
            "cases", "jsonFileStoppedReadAndFraming", "jsonFileRecords",
        )
        #expect(records.count == 2)
        let recordsByStream = try Dictionary(
            uniqueKeysWithValues: records.map { record in
                try (string(record, "stream"), record)
            },
        )
        let stdoutRecord = try #require(recordsByStream["stdout"])
        let stderrRecord = try #require(recordsByStream["stderr"])
        #expect(try string(stdoutRecord, "log") == "stdout-line\n")
        #expect(try string(stderrRecord, "log") == "stderr-line\n")
        #expect(try string(stdoutRecord, "time") == "<rfc3339-nano-utc>")
        #expect(try string(stdoutRecord, "attrs", "oracle.label") == "alpha")

        #expect(
            try string(
                fixture,
                "cases", "restartRetention", "retainedRead", "stdout",
            ) == "restart-1\nrestart-2\n",
        )
        #expect(try integer(fixture, "cases", "restartRetention", "restartHTTPStatus") == 204)
        #expect(try integer(fixture, "cases", "restartRetention", "stopHTTPStatus") == 204)
    }

    @Test
    func `pins native readers and non-reader dual cache`() throws {
        let fixture = try Self.fixture()

        #expect(
            try string(
                fixture,
                "cases", "localNativeReader", "inspectAfterExit", "logConfig", "Type",
            ) == "local",
        )
        #expect(
            try string(fixture, "cases", "localNativeReader", "inspectAfterExit", "logPath")
                == "",
        )
        #expect(
            try string(fixture, "cases", "localNativeReader", "stoppedRead", "stdout")
                == "local-line\n",
        )

        #expect(
            try integer(
                fixture,
                "cases", "nonReaderDualCache", "defaultCache", "stoppedRead", "httpStatus",
            ) == 200,
        )
        #expect(
            try string(
                fixture,
                "cases", "nonReaderDualCache", "defaultCache", "stoppedRead", "stdout",
            ) == "cached-out\n",
        )
        #expect(
            try string(
                fixture,
                "cases", "nonReaderDualCache", "defaultCache", "stoppedRead", "stderr",
            ) == "cached-err\n",
        )
        #expect(
            try integer(
                fixture,
                "cases", "nonReaderDualCache", "cacheDisabled", "stoppedRead", "httpStatus",
            ) == 501,
        )
        #expect(
            try string(
                fixture,
                "cases", "nonReaderDualCache", "cacheDisabled", "stoppedRead", "message",
            ) == "configured logging driver does not support reading",
        )
    }

    @Test
    // swiftlint:disable:next function_body_length
    func `pins sustained rotation compression and retained ranges`() throws {
        let fixture = try Self.fixture()

        for driverCase in [
            "jsonFileSustainedRotationCompression",
            "localSustainedRotationCompression",
        ] {
            #expect(
                try boolean(
                    fixture,
                    path: ["cases", driverCase, "activeFileExceedsConfiguredMaximum"],
                ),
            )
            #expect(
                try integer(fixture, path: ["cases", driverCase, "configuredMaximumBytes"])
                    == 4000,
            )
            #expect(
                try integer(fixture, path: ["cases", driverCase, "retainedRead", "recordCount"])
                    == 15,
            )
            #expect(
                try integer(fixture, path: ["cases", driverCase, "retainedRead", "firstRecord"])
                    == 26,
            )
            #expect(
                try integer(fixture, path: ["cases", driverCase, "retainedRead", "lastRecord"])
                    == 40,
            )
            #expect(
                try boolean(
                    fixture,
                    path: ["cases", driverCase, "retainedRead", "recordsAreContiguous"],
                ),
            )

            let files: [[String: Any]] = try value(
                fixture,
                path: ["cases", driverCase, "files"],
            )
            #expect(files.count == 3)
            #expect(try string(files[0], "compression") == "none")
            #expect(try string(files[1], "compression") == "gzip")
            #expect(try boolean(files[1], "gzipStreamValid"))
            #expect(try string(files[2], "compression") == "gzip")
            #expect(try boolean(files[2], "gzipStreamValid"))
        }

        #expect(
            try integers(
                fixture,
                path: [
                    "cases", "jsonFileSustainedRotationCompression", "segmentRecords", "active",
                ],
            ) == [36, 37, 38, 39, 40],
        )
        #expect(
            try integers(
                fixture,
                path: [
                    "cases", "jsonFileSustainedRotationCompression", "segmentRecords", "rotated1",
                ],
            ) == [31, 32, 33, 34, 35],
        )
        #expect(
            try integers(
                fixture,
                path: [
                    "cases", "jsonFileSustainedRotationCompression", "segmentRecords", "rotated2",
                ],
            ) == [26, 27, 28, 29, 30],
        )
    }

    @Test
    func `pins non-blocking pressure invariants`() throws {
        let fixture = try Self.fixture()

        #expect(
            try integer(fixture, "cases", "nonBlockingPressureDrop", "configuredBufferBytes")
                == 4096,
        )
        #expect(
            try integer(fixture, "cases", "nonBlockingPressureDrop", "sourceRecordCount")
                == 5000,
        )
        #expect(
            try boolean(
                fixture,
                "cases", "nonBlockingPressureDrop", "workloadWriteCompletedBeforeReceiverRelease",
            ),
        )
        #expect(
            try integer(
                fixture,
                "cases", "nonBlockingPressureDrop", "receiver", "firstRecord",
            ) == 1,
        )
        for invariant in [
            "deliveredFewerThanSource",
            "dropGapObserved",
            "recordsAreOrdered",
            "recordsAreUnique",
            "sourceFinalRecordWasDropped",
        ] {
            #expect(
                try boolean(
                    fixture,
                    path: ["cases", "nonBlockingPressureDrop", "receiver", invariant],
                ),
            )
        }
    }

    @Test
    // swiftlint:disable:next function_body_length
    func `pins syslog remote wire transports framing and cleanup`() throws {
        let fixture = try Self.fixture()

        let expectedContent: [String: [String]] = [
            "tcp": [
                "7374646f75742d6173636969",
                "7374646572722d757466382de29883",
                "7374646f75742d62696e6172792dff002d656e64",
            ],
            "tls": [
                "7374646f75742d61736369690a",
                "7374646572722d757466382de298830a",
                "7374646f75742d62696e6172792dff002d656e640a",
            ],
            "udp": [
                "7374646f75742d61736369690a",
                "7374646572722d757466382de298830a",
                "7374646f75742d62696e6172792dff002d656e640a",
            ],
            "unix": [
                "7374646f75742d6173636969",
                "7374646572722d757466382de29883",
                "7374646f75742d62696e6172792dff002d656e64",
            ],
        ]
        for transport in ["tcp", "tls", "udp", "unix"] {
            #expect(
                try boolean(
                    fixture,
                    "cases", "syslogRemoteWire", transport, "phase",
                    "configurationAcceptedAtCreate",
                ),
            )
            #expect(
                try boolean(
                    fixture,
                    "cases", "syslogRemoteWire", transport, "phase",
                    "connectionEstablishedAtStart",
                ),
            )
            #expect(
                try integer(
                    fixture,
                    "cases", "syslogRemoteWire", transport, "phase", "containerExitCode",
                ) == 0,
            )
            #expect(
                try boolean(
                    fixture,
                    "cases", "syslogRemoteWire", transport, "cleanup",
                    "receiverProcessRunning",
                ) == false,
            )
            let residue: [Any] = try value(
                fixture,
                "cases", "syslogRemoteWire", transport, "cleanup", "vmPathsRemaining",
            )
            #expect(residue.isEmpty)

            let frames: [[String: Any]] = try value(
                fixture,
                "cases", "syslogRemoteWire", transport, "wire", "frames",
            )
            #expect(frames.count == 3)
            #expect(try frames.map { try string($0, "contentHex") } == expectedContent[transport])
            #expect(try frames.map { try integer($0, "priority") } == [142, 139, 142])
            #expect(try frames.map { try integer($0, "severity") } == [6, 3, 6])
            for frame in frames {
                #expect(try integer(frame, "facility") == 17)
                #expect(try integer(frame, "timestampFractionDigits") == 6)
                #expect(try string(frame, "timestamp") == "<rfc3339-micro-utc>")
                #expect(try string(frame, "structuredData") == "-")
                #expect(try string(frame, "hostname") == "colima")
                #expect(try integer(frame, "normalizedMessageByteCount") > 0)
            }
            #expect(
                try boolean(
                    fixture,
                    "cases", "syslogRemoteWire", transport, "wire",
                    "readChunkBoundariesNormalizedAway",
                ),
            )
        }

        #expect(
            try string(
                fixture,
                "cases", "syslogRemoteWire", "udp", "wire", "framing", "framing",
            ) == "one RFC 5424 message per UDP datagram; no delimiter",
        )
        for transport in ["tcp", "unix"] {
            #expect(
                try string(
                    fixture,
                    "cases", "syslogRemoteWire", transport, "wire", "framing", "framing",
                ) == "RFC 6587 non-transparent LF delimiter",
            )
            #expect(
                try boolean(
                    fixture,
                    "cases", "syslogRemoteWire", transport, "wire",
                    "peerClosedAfterContainerExit",
                ),
            )
        }
        #expect(
            try string(
                fixture,
                "cases", "syslogRemoteWire", "tls", "wire", "framing", "framing",
            ) == "RFC 6587 octet counting",
        )
        #expect(
            try boolean(
                fixture,
                "cases", "syslogRemoteWire", "tls", "wire", "framing",
                "octetCountsMatchPayloadByteCounts",
            ),
        )
    }

    @Test
    // swiftlint:disable:next function_body_length
    func `pins Fluentd MessagePack metadata timestamps acknowledgements and shutdown`() throws {
        let fixture = try Self.fixture()

        for transport in [
            "tcpAcknowledgedEventTime", "unixAsyncReconnect", "unixIntegerTime",
        ] {
            #expect(
                try boolean(
                    fixture,
                    "cases", "fluentdRemoteWire", transport, "phase",
                    "configurationAcceptedAtCreate",
                ),
            )
            if transport != "unixAsyncReconnect" {
                #expect(
                    try boolean(
                        fixture,
                        "cases", "fluentdRemoteWire", transport, "phase",
                        "connectionEstablishedAtStart",
                    ),
                )
            }
            #expect(
                try boolean(
                    fixture,
                    "cases", "fluentdRemoteWire", transport, "wire",
                    "decodedByteCountEqualsRawByteCount",
                ),
            )
            #expect(
                try boolean(
                    fixture,
                    "cases", "fluentdRemoteWire", transport, "wire",
                    "peerClosedAfterContainerExit",
                ),
            )
            #expect(
                try integer(
                    fixture,
                    "cases", "fluentdRemoteWire", transport, "wire", "trailingByteCount",
                ) == 0,
            )
            #expect(
                try boolean(
                    fixture,
                    "cases", "fluentdRemoteWire", transport, "cleanup",
                    "receiverProcessRunning",
                ) == false,
            )

            let records: [[String: Any]] = try value(
                fixture,
                "cases", "fluentdRemoteWire", transport, "wire", "records",
            )
            #expect(records.count == 3)
            for record in records {
                #expect(try integer(record, "normalizedMessagePackByteCount") > 0)
                let envelope: [Any] = try value(record, "semanticEnvelope")
                #expect(envelope.count == 4)
                #expect(envelope[0] as? String == "oracle.<container-name>.<container-id-short>")
                let payload = try #require(envelope[2] as? [String: Any])
                #expect(payload["container_id"] as? String == "<container-id>")
                #expect(payload["container_name"] as? String == "<container-name>")
                #expect(payload["oracle.label"] as? String == "alpha")
                #expect(payload["ORACLE_ENV"] as? String == "bravo")
            }
        }

        let acknowledgedRecords: [[String: Any]] = try value(
            fixture,
            "cases", "fluentdRemoteWire", "tcpAcknowledgedEventTime", "wire", "records",
        )
        let acknowledgedTypes: [String] = try value(
            fixture,
            "cases", "fluentdRemoteWire", "tcpAcknowledgedEventTime", "wire",
            "acknowledgedChunkTypes",
        )
        #expect(acknowledgedTypes == ["fixstr", "fixstr", "fixstr"])
        for record in acknowledgedRecords {
            #expect(try string(record, "chunkIdentifierWireType") == "fixstr")
            #expect(
                try string(record, "timestamp", "encoding")
                    == "MessagePack EventTime extension type 0",
            )
            #expect(try string(record, "timestamp", "wireType") == "fixext8")
            #expect(try boolean(record, "timestamp", "nanosecondsInRange"))
        }

        for transport in ["unixAsyncReconnect", "unixIntegerTime"] {
            let unixRecords: [[String: Any]] = try value(
                fixture,
                "cases", "fluentdRemoteWire", transport, "wire", "records",
            )
            let unixAcknowledgements: [String] = try value(
                fixture,
                "cases", "fluentdRemoteWire", transport, "wire",
                "acknowledgedChunkTypes",
            )
            #expect(unixAcknowledgements.isEmpty)
            for record in unixRecords {
                #expect(
                    try string(record, "timestamp", "encoding")
                        == "MessagePack integer Unix seconds",
                )
                #expect(try string(record, "timestamp", "wireType") == "int32")
            }
        }

        #expect(
            try boolean(
                fixture,
                "cases", "fluentdRemoteWire", "unixAsyncReconnect", "phase",
                "receiverSocketAbsentAtStart",
            ),
        )
        #expect(
            try boolean(
                fixture,
                "cases", "fluentdRemoteWire", "unixAsyncReconnect", "phase",
                "startSucceededWithoutReceiver",
            ),
        )
        #expect(
            try double(
                fixture,
                path: [
                    "cases", "fluentdRemoteWire", "unixAsyncReconnect", "phase",
                    "listenerDelaySeconds",
                ],
            ) == 0.75,
        )

        #expect(
            try integer(
                fixture,
                "cases", "fluentdRemoteWire", "tlsLocalTrustFailure", "phase",
                "startHTTPStatus",
            ) == 500,
        )
        #expect(
            try string(
                fixture,
                "cases", "fluentdRemoteWire", "tlsLocalTrustFailure", "phase",
                "containerStateAfterFailedStart",
            ) == "created",
        )
        #expect(
            try string(
                fixture,
                "cases", "fluentdRemoteWire", "tlsLocalTrustFailure", "phase",
                "startMessage",
            ) == "failed to create task for container: failed to initialize logging driver: "
                + "tls: failed to verify certificate: x509: certificate signed by unknown authority",
        )
        #expect(
            try boolean(
                fixture,
                "cases", "fluentdRemoteWire", "tlsLocalTrustFailure", "evidenceGap",
                "decryptedPayloadCaptured",
            ) == false,
        )
        #expect(
            try boolean(
                fixture,
                "cases", "fluentdRemoteWire", "tlsLocalTrustFailure",
                "receiverObservedBadCertificateAlert",
            ),
        )
        #expect(
            try boolean(
                fixture,
                "cases", "fluentdRemoteWire", "tlsLocalTrustFailure", "cleanup",
                "receiverProcessRunning",
            ) == false,
        )
        let tlsResidue: [Any] = try value(
            fixture,
            "cases", "fluentdRemoteWire", "tlsLocalTrustFailure", "cleanup",
            "vmPathsRemaining",
        )
        #expect(tlsResidue.isEmpty)
    }

    @Test
    // swiftlint:disable:next function_body_length
    func `pins GELF UDP gzip and TCP NUL wire contracts`() throws {
        let fixture = try Self.gelfWireFixture()

        #expect(try integer(fixture, "schemaVersion") == 1)
        #expect(
            try string(fixture, "scope")
                == "direct Docker Engine GELF remote-wire contract",
        )
        #expect(try string(fixture, "metadata", "engineVersion") == "29.2.1")
        #expect(try string(fixture, "metadata", "apiVersion") == "1.53")
        #expect(try string(fixture, "metadata", "context") == "colima")
        #expect(try string(fixture, "metadata", "dockerClientVersion") == "29.7.1")
        #expect(try string(fixture, "metadata", "image") == "alpine:3.20")
        #expect(
            try string(fixture, "timings", "gelfRemoteWire", "clock")
                == "time.monotonic",
        )
        #expect(
            try double(
                fixture,
                path: ["timings", "gelfRemoteWire", "durationSeconds"],
            ) > 0,
        )

        let expectedMessages = [
            "stdout-ascii",
            "stderr-utf8-☃",
            "stdout-binary-�\u{0000}-end",
        ]
        let expectedLevels = [6, 3, 6]
        for transport in ["tcpNULTerminated", "udpDefaultGzip"] {
            #expect(
                try boolean(
                    fixture,
                    "cases", "gelfRemoteWire", transport, "phase",
                    "configurationAcceptedAtCreate",
                ),
            )
            #expect(
                try boolean(
                    fixture,
                    "cases", "gelfRemoteWire", transport, "phase",
                    "connectionEstablishedAtStart",
                ),
            )
            #expect(
                try integer(
                    fixture,
                    "cases", "gelfRemoteWire", transport, "phase", "containerExitCode",
                ) == 0,
            )
            #expect(
                try string(
                    fixture,
                    "cases", "gelfRemoteWire", transport, "inspectAfterExit", "logConfig",
                    "Type",
                ) == "gelf",
            )
            #expect(
                try string(
                    fixture,
                    "cases", "gelfRemoteWire", transport, "inspectAfterExit", "logConfig",
                    "Config", "cache-disabled",
                ) == "true",
            )
            #expect(
                try boolean(
                    fixture,
                    "cases", "gelfRemoteWire", transport, "cleanup",
                    "receiverProcessRunning",
                ) == false,
            )
            let residue: [Any] = try value(
                fixture,
                "cases", "gelfRemoteWire", transport, "cleanup", "vmPathsRemaining",
            )
            #expect(residue.isEmpty)

            let records: [[String: Any]] = try value(
                fixture,
                "cases", "gelfRemoteWire", transport, "wire", "records",
            )
            #expect(try records.map { try string($0, "shortMessage") } == expectedMessages)
            #expect(try records.map { try integer($0, "level") } == expectedLevels)
            for record in records {
                #expect(try string(record, "version") == "1.1")
                #expect(try string(record, "host") == "colima")
                #expect(try string(record, "timestamp") == "<unix-seconds-milliseconds>")
                #expect(
                    try string(record, "timestampPrecision")
                        == "at-most-milliseconds",
                )
                let extras: [String: Any] = try value(record, "extras")
                #expect(extras["_ORACLE_ENV"] as? String == "bravo")
                #expect(extras["_oracle.label"] as? String == "alpha")
                #expect(extras["_container_id"] as? String == "<container-id>")
                #expect(extras["_container_name"] as? String == "<container-name>")
                #expect(extras["_created"] as? String == "<rfc3339-nano-utc>")
                #expect(extras["_image_id"] as? String == "<image-id>")
                #expect(extras["_image_name"] as? String == "alpine:3.20")
                #expect(
                    extras["_tag"] as? String
                        == "oracle.<container-name>.<container-id-short>",
                )
            }
        }

        #expect(
            try string(
                fixture,
                "cases", "gelfRemoteWire", "udpDefaultGzip", "wire", "framing",
                "compression",
            ) == "gzip",
        )
        #expect(
            try boolean(
                fixture,
                "cases", "gelfRemoteWire", "udpDefaultGzip", "wire", "framing",
                "datagramBoundariesAreMessageBoundaries",
            ),
        )
        #expect(
            try string(
                fixture,
                "cases", "gelfRemoteWire", "tcpNULTerminated", "wire", "framing",
                "compression",
            ) == "none",
        )
        #expect(
            try boolean(
                fixture,
                "cases", "gelfRemoteWire", "tcpNULTerminated", "wire", "framing",
                "streamEndsWithNUL",
            ),
        )
        #expect(
            try boolean(
                fixture,
                "cases", "gelfRemoteWire", "tcpNULTerminated", "wire",
                "peerClosedAfterContainerExit",
            ),
        )
    }

    @Test
    // swiftlint:disable:next function_body_length
    func `pins GELF option validation phases and transport boundaries`() throws {
        let fixture = try Self.gelfConfigFixture()

        #expect(try integer(fixture, "schemaVersion") == 1)
        #expect(
            try string(fixture, "scope")
                == "direct Docker Engine GELF option and validation-phase contract",
        )
        #expect(try string(fixture, "metadata", "engineVersion") == "29.2.1")
        #expect(try string(fixture, "metadata", "apiVersion") == "1.53")
        #expect(try string(fixture, "metadata", "context") == "colima")
        #expect(try string(fixture, "metadata", "image") == "alpine:3.20")
        #expect(
            try string(fixture, "timings", "gelfConfig", "clock") == "time.monotonic",
        )
        #expect(
            try double(fixture, path: ["timings", "gelfConfig", "durationSeconds"]) > 0,
        )
        #expect(try boolean(fixture, "cleanup", "containersRemoved"))

        let rejected = [
            ("missingAddress", "gelf-address is a required parameter"),
            ("malformedAddress", "gelf: please provide gelf-address as proto://host:port"),
            ("unknownOption", "unknown log opt \"opaque\" for gelf log driver"),
            (
                "udpBadCompressionLevel",
                "unknown value \"10\" for log opt \"gelf-compression-level\" for gelf log driver",
            ),
            ("udpTCPReconnect", "\"gelf-tcp-max-reconnect\" is only valid for TCP"),
            ("tcpCompression", "compression is only supported on UDP"),
            ("tcpBadReconnect", "\"gelf-tcp-max-reconnect\" must be a positive integer"),
        ]
        for (label, message) in rejected {
            #expect(
                try integer(fixture, "cases", label, "create", "httpStatus") == 400,
            )
            #expect(try string(fixture, "cases", label, "create", "message") == message)
            #expect(
                try boolean(fixture, "cases", label, "phase", "configurationRejectedAtCreate"),
            )
        }

        for label in ["udpDefault", "udpZlibMaximum", "udpNoneMinimum", "tcpReconnect"] {
            #expect(
                try integer(fixture, "cases", label, "create", "httpStatus") == 201,
            )
            #expect(
                try string(fixture, "cases", label, "inspectAfterExit", "Type") == "gelf",
            )
            #expect(
                try boolean(
                    fixture, "cases", label, "phase", "configurationAcceptedAtCreate",
                ),
            )
            #expect(
                try boolean(fixture, "cases", label, "phase", "startSucceeded"),
            )
            #expect(
                try integer(fixture, "cases", label, "phase", "containerExitCode") == 0,
            )
        }

        #expect(
            try string(
                fixture, "cases", "udpDefault", "inspectAfterExit", "Config", "gelf-address",
            ) == "udp://127.0.0.1:1",
        )
        #expect(
            try string(
                fixture, "cases", "udpZlibMaximum", "inspectAfterExit", "Config",
                "gelf-compression-type",
            ) == "zlib",
        )
        #expect(
            try string(
                fixture, "cases", "udpZlibMaximum", "inspectAfterExit", "Config",
                "gelf-compression-level",
            ) == "9",
        )
        #expect(
            try string(
                fixture, "cases", "udpNoneMinimum", "inspectAfterExit", "Config",
                "gelf-address",
            ) == "UDP://127.0.0.1:1",
        )
        #expect(
            try string(
                fixture, "cases", "udpNoneMinimum", "inspectAfterExit", "Config",
                "gelf-compression-type",
            ) == "none",
        )
        #expect(
            try string(
                fixture, "cases", "udpNoneMinimum", "inspectAfterExit", "Config",
                "gelf-compression-level",
            ) == "-1",
        )
        #expect(
            try string(
                fixture, "cases", "tcpReconnect", "inspectAfterExit", "Config", "gelf-address",
            ) == "tcp://<colima-oracle-receiver>",
        )
        #expect(
            try string(
                fixture, "cases", "tcpReconnect", "inspectAfterExit", "Config",
                "gelf-tcp-max-reconnect",
            ) == "+1",
        )
        #expect(
            try string(
                fixture, "cases", "tcpReconnect", "inspectAfterExit", "Config",
                "gelf-tcp-reconnect-delay",
            ) == "0",
        )
        #expect(
            try boolean(
                fixture, "cases", "tcpReconnect", "receiver", "peerClosedAfterContainerExit",
            ),
        )
        #expect(
            try boolean(fixture, "cases", "tcpReconnect", "receiver", "receivedPayload"),
        )
        #expect(
            try boolean(
                fixture, "cases", "tcpReconnect", "cleanup", "receiverProcessRunning",
            ) == false,
        )
        let tcpResidue: [Any] = try value(
            fixture,
            "cases", "tcpReconnect", "cleanup", "vmPathsRemaining",
        )
        #expect(tcpResidue.isEmpty)
    }

    @Test
    // swiftlint:disable:next function_body_length
    func `pins GELF tag template metadata precedence and deferred validation`() throws {
        let fixture = try Self.gelfMetadataFixture()

        #expect(try integer(fixture, "schemaVersion") == 1)
        #expect(
            try string(fixture, "scope")
                == "direct Docker Engine GELF metadata and tag validation contract",
        )
        #expect(try string(fixture, "metadata", "engineVersion") == "29.2.1")
        #expect(try string(fixture, "metadata", "apiVersion") == "1.53")
        #expect(try string(fixture, "metadata", "context") == "colima")
        #expect(try string(fixture, "metadata", "image") == "alpine:3.20")
        #expect(
            try string(fixture, "timings", "gelfMetadata", "clock") == "time.monotonic",
        )
        #expect(
            try double(fixture, path: ["timings", "gelfMetadata", "durationSeconds"]) > 0,
        )
        #expect(try boolean(fixture, "cleanup", "containersRemoved"))

        let metadataPath = ["cases", "metadataPrecedenceAndTag"]
        #expect(
            try boolean(
                fixture,
                path: metadataPath + ["phase", "configurationAcceptedAtCreate"],
            ),
        )
        #expect(
            try boolean(
                fixture,
                path: metadataPath + ["phase", "connectionEstablishedAtStart"],
            ),
        )
        #expect(
            try integer(fixture, path: metadataPath + ["phase", "containerExitCode"]) == 0,
        )
        #expect(
            try string(
                fixture,
                path: metadataPath + ["inspectAfterExit", "logConfig", "Type"],
            ) == "gelf",
        )
        #expect(
            try string(
                fixture,
                path: metadataPath + ["inspectAfterExit", "logConfig", "Config", "tag"],
            ) == "{{.Name}}/{{.ID}}",
        )
        #expect(
            try string(
                fixture,
                path: metadataPath + ["inspectAfterExit", "logConfig", "Config", "env"],
            ) == "shared,container_id",
        )
        #expect(
            try string(
                fixture,
                path: metadataPath + ["inspectAfterExit", "logConfig", "Config", "labels"],
            ) == "team,shared",
        )
        #expect(
            try string(
                fixture,
                path: metadataPath + ["inspectAfterExit", "logConfig", "Config", "env-regex"],
            ) == "^MATCH_",
        )
        #expect(
            try string(
                fixture,
                path: metadataPath + ["inspectAfterExit", "logConfig", "Config", "labels-regex"],
            ) == "^com\\.",
        )
        #expect(
            try string(
                fixture,
                path: metadataPath + ["inspectAfterExit", "logConfig", "Config", "gelf-address"],
            ) == "udp://<colima-oracle-receiver>",
        )
        #expect(
            try boolean(fixture, path: metadataPath + ["cleanup", "receiverProcessRunning"])
                == false,
        )
        let metadataResidue: [Any] = try value(
            fixture,
            path: metadataPath + ["cleanup", "vmPathsRemaining"],
        )
        #expect(metadataResidue.isEmpty)

        let records: [[String: Any]] = try value(
            fixture,
            path: metadataPath + ["wire", "records"],
        )
        #expect(
            try records.map { try string($0, "shortMessage") }
                == ["stdout-ascii", "stderr-utf8-☃", "stdout-binary-�\u{0000}-end"],
        )
        #expect(try records.map { try integer($0, "level") } == [6, 3, 6])
        for record in records {
            let extras: [String: Any] = try value(record, "extras")
            #expect(extras["_MATCH_ONE"] as? String == "matched")
            #expect(extras["_com.example.role"] as? String == "frontend")
            #expect(extras["_container_id"] as? String == "metadata-id")
            #expect(extras["_shared"] as? String == "environment")
            #expect(extras["_team"] as? String == "runtime")
            #expect(extras["_tag"] as? String == "<container-name>/<container-id-short>")
            #expect(extras["_ignored"] == nil)
            #expect(try string(record, "timestampPrecision") == "at-most-milliseconds")
        }

        let rejections = [
            ("tagMissingField", "can't evaluate field Missing"),
            ("labelsRegexLookahead", "invalid or unsupported Perl syntax"),
            ("envRegexSyntax", "missing closing )"),
        ]
        for (label, message) in rejections {
            let path = ["cases", "startTimeInvalid", label]
            #expect(try integer(fixture, path: path + ["create", "httpStatus"]) == 201)
            #expect(try integer(fixture, path: path + ["start", "httpStatus"]) == 500)
            #expect(
                try boolean(
                    fixture,
                    path: path + ["phase", "configurationAcceptedAtCreate"],
                ),
            )
            #expect(
                try boolean(
                    fixture,
                    path: path + ["phase", "configurationRejectedAtStart"],
                ),
            )
            #expect(
                try boolean(fixture, path: path + ["phase", "containerRemainsCreated"]),
            )
            #expect(
                try string(
                    fixture,
                    path: path + ["inspectAfterFailedStart", "state", "status"],
                ) == "created",
            )
            #expect(
                try string(fixture, path: path + ["start", "message"]).contains(message),
            )
        }
    }

    @Test
    // swiftlint:disable:next function_body_length
    func `pins Compose foreground independence from historical readers`() throws {
        let fixture = try Self.fixture()

        for driverCase in ["jsonFileReadable", "none", "syslogCacheDisabled"] {
            #expect(
                try integer(
                    fixture,
                    path: ["cases", "composeForeground", driverCase, "foreground", "exitCode"],
                ) == 0,
            )
            #expect(
                try boolean(
                    fixture,
                    path: [
                        "cases", "composeForeground", driverCase, "foreground", "markers",
                        "allMarkersExactlyOnce",
                    ],
                ),
            )
            #expect(
                try integer(
                    fixture,
                    path: ["cases", "composeForeground", driverCase, "historicalRead", "exitCode"],
                ) == 0,
            )
            #expect(
                try integer(
                    fixture,
                    path: [
                        "cases", "composeForeground", driverCase, "foreground", "markers",
                        "stderrMarkers", "early-err",
                    ],
                ) == 1,
            )
            for marker in ["early-out", "early-err", "late-out"] {
                #expect(
                    try integer(
                        fixture,
                        path: [
                            "cases", "composeForeground", driverCase, "foreground", "markers", "counts",
                            marker,
                        ],
                    ) == 1,
                )
            }
        }

        #expect(
            try boolean(
                fixture,
                "cases", "composeForeground", "jsonFileReadable", "historicalRead", "markers",
                "allMarkersExactlyOnce",
            ),
        )
        #expect(
            try boolean(
                fixture,
                "cases", "composeForeground", "jsonFileReadable", "historicalRead",
                "unsupportedReaderWarning",
            ) == false,
        )
        for driverCase in ["none", "syslogCacheDisabled"] {
            #expect(
                try boolean(
                    fixture,
                    path: [
                        "cases", "composeForeground", driverCase, "historicalRead",
                        "unsupportedReaderWarning",
                    ],
                ),
            )
            #expect(
                try boolean(
                    fixture,
                    path: [
                        "cases", "composeForeground", driverCase, "historicalRead", "markers",
                        "allMarkersExactlyOnce",
                    ],
                ) == false,
            )
            for marker in ["early-out", "early-err", "late-out"] {
                #expect(
                    try integer(
                        fixture,
                        path: [
                            "cases", "composeForeground", driverCase, "historicalRead", "markers", "counts",
                            marker,
                        ],
                    ) == 0,
                )
            }
        }
    }

    private static func fixture() throws -> [String: Any] {
        guard
            let url = Bundle.module.url(
                forResource: "docker-engine-29.2.1-logging",
                withExtension: "json",
            )
        else {
            throw FixtureError.missing(
                "Fixtures/logging/docker-engine-29.2.1-logging.json",
            )
        }
        let data = try Data(contentsOf: url)
        guard let fixture = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw FixtureError.invalid("root is not a JSON object")
        }
        return fixture
    }

    private static func gelfWireFixture() throws -> [String: Any] {
        guard
            let url = Bundle.module.url(
                forResource: "docker-engine-29.2.1-gelf-wire",
                withExtension: "json",
            )
        else {
            throw FixtureError.missing(
                "Fixtures/logging/docker-engine-29.2.1-gelf-wire.json",
            )
        }
        let data = try Data(contentsOf: url)
        guard let fixture = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw FixtureError.invalid("GELF wire root is not a JSON object")
        }
        return fixture
    }

    private static func gelfConfigFixture() throws -> [String: Any] {
        guard
            let url = Bundle.module.url(
                forResource: "docker-engine-29.2.1-gelf-config",
                withExtension: "json",
            )
        else {
            throw FixtureError.missing(
                "Fixtures/logging/docker-engine-29.2.1-gelf-config.json",
            )
        }
        let data = try Data(contentsOf: url)
        guard let fixture = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw FixtureError.invalid("GELF configuration root is not a JSON object")
        }
        return fixture
    }

    private static func gelfMetadataFixture() throws -> [String: Any] {
        guard
            let url = Bundle.module.url(
                forResource: "docker-engine-29.2.1-gelf-metadata",
                withExtension: "json",
            )
        else {
            throw FixtureError.missing(
                "Fixtures/logging/docker-engine-29.2.1-gelf-metadata.json",
            )
        }
        let data = try Data(contentsOf: url)
        guard let fixture = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw FixtureError.invalid("GELF metadata root is not a JSON object")
        }
        return fixture
    }
}

private func value<T>(_ root: [String: Any], _ path: String...) throws -> T {
    try value(root, path: path)
}

private func value<T>(_ root: [String: Any], path: [String]) throws -> T {
    var current: Any = root
    for component in path {
        guard let object = current as? [String: Any] else {
            throw FixtureError.invalid(
                "\(path.joined(separator: ".")) traverses a non-object at \(component)",
            )
        }
        guard let next = object[component] else {
            throw FixtureError.invalid(
                "missing \(path.joined(separator: "."))",
            )
        }
        current = next
    }
    guard let typed = current as? T else {
        throw FixtureError.invalid(
            "\(path.joined(separator: ".")) has unexpected type \(type(of: current))",
        )
    }
    return typed
}

private func string(_ root: [String: Any], _ path: String...) throws -> String {
    try value(root, path: path)
}

private func string(_ root: [String: Any], path: [String]) throws -> String {
    try value(root, path: path)
}

private func integer(_ root: [String: Any], _ path: String...) throws -> Int {
    let number: NSNumber = try value(root, path: path)
    return number.intValue
}

private func integer(_ root: [String: Any], path: [String]) throws -> Int {
    let number: NSNumber = try value(root, path: path)
    return number.intValue
}

private func integers(_ root: [String: Any], path: [String]) throws -> [Int] {
    let numbers: [NSNumber] = try value(root, path: path)
    return numbers.map(\.intValue)
}

private func double(_ root: [String: Any], path: [String]) throws -> Double {
    let number: NSNumber = try value(root, path: path)
    return number.doubleValue
}

private func boolean(_ root: [String: Any], _ path: String...) throws -> Bool {
    let number: NSNumber = try value(root, path: path)
    return number.boolValue
}

private func boolean(_ root: [String: Any], path: [String]) throws -> Bool {
    let number: NSNumber = try value(root, path: path)
    return number.boolValue
}

private enum FixtureError: Error, CustomStringConvertible {
    case invalid(String)
    case missing(String)

    var description: String {
        switch self {
        case let .invalid(message):
            "Invalid Docker logging oracle fixture: \(message)"
        case let .missing(path):
            "Missing Docker logging oracle fixture: \(path)"
        }
    }
}
