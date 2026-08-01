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

@Suite("Docker Engine logging-driver oracle fixture")
struct DockerLoggingDriverOracleFixtureTests {
  @Test
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
        "cases", "omittedDefault", "inspectBeforeRead", "logConfig", "Type"
      ) == "json-file"
    )
    #expect(
      try string(fixture, "cases", "omittedDefault", "inspectBeforeRead", "logPath")
        == ""
    )
    #expect(
      try string(
        fixture,
        "cases", "omittedDefault", "inspectAfterCreatedRead", "logPath"
      ) == "/var/lib/docker/containers/<container-id>/<container-id>-json.log"
    )
    #expect(
      try integer(
        fixture,
        "cases", "omittedDefault", "createdFollowRead", "httpStatus"
      ) == 200
    )
    #expect(
      try string(
        fixture,
        "cases", "emptyDriver", "inspectAfterCreate", "logConfig", "Type"
      ) == "json-file"
    )

    #expect(
      try string(
        fixture,
        "cases", "noneArbitraryOptions", "inspectAfterExit", "logConfig", "Config",
        "opaque-option"
      ) == "opaque-value"
    )
    #expect(
      try string(
        fixture,
        "cases", "noneArbitraryOptions", "inspectAfterExit", "logConfig", "Config",
        "max-size"
      ) == "1m"
    )
    #expect(
      try integer(
        fixture,
        "cases", "noneArbitraryOptions", "stoppedRead", "httpStatus"
      ) == 501
    )

    #expect(
      try integer(
        fixture,
        "cases", "validationPhases", "createTimeUnknownLocalOption", "httpStatus"
      ) == 400
    )
    #expect(
      try boolean(
        fixture,
        "cases", "validationPhases", "createTimeUnknownLocalOption", "containerResidue"
      ) == false
    )
    #expect(
      try integer(
        fixture,
        "cases", "validationPhases", "startTimeInvalidJSONFileValue", "start",
        "httpStatus"
      ) == 500
    )
    #expect(
      try string(
        fixture,
        "cases", "validationPhases", "startTimeInvalidJSONFileValue",
        "inspectAfterFailedStart", "state", "status"
      ) == "created"
    )
    #expect(
      try string(
        fixture,
        "cases", "validationPhases", "startTimeInvalidJSONFileValue",
        "inspectAfterFailedStart", "logPath"
      ) == "/var/lib/docker/containers/<container-id>/<container-id>-json.log"
    )
  }

  @Test
  func `pins create and start option grammars`() throws {
    let fixture = try Self.fixture()

    #expect(
      try integer(
        fixture, "cases", "optionSemantics", "mode", "empty", "create", "httpStatus"
      ) == 201
    )
    #expect(
      try string(
        fixture, "cases", "optionSemantics", "mode", "empty", "inspectAfterCreate",
        "logConfig", "Config", "mode"
      ) == ""
    )
    #expect(
      try integer(
        fixture, "cases", "optionSemantics", "mode", "uppercase", "create", "httpStatus"
      ) == 400
    )

    for label in ["trueMixed", "falseUpper", "trueOne", "falseZero", "trueShort", "falseShort"] {
      #expect(
        try integer(
          fixture, "cases", "optionSemantics", "compress", label, "start", "httpStatus"
        ) == 204
      )
    }
    for label in ["invalid", "empty", "missingRotation"] {
      #expect(
        try integer(
          fixture, "cases", "optionSemantics", "compress", label, "start", "httpStatus"
        ) == 500
      )
    }

    for label in [
      "bytes", "fractionalUnit", "binaryUnit", "spaceSeparator", "leadingPlus", "leadingFraction",
      "exponent",
    ] {
      #expect(
        try integer(
          fixture, "cases", "optionSemantics", "maxSize", label, "start", "httpStatus"
        ) == 204
      )
    }
    for label in ["zero", "negative", "outerWhitespace"] {
      #expect(
        try integer(
          fixture, "cases", "optionSemantics", "maxSize", label, "start", "httpStatus"
        ) == 500
      )
    }

    for label in ["one", "leadingPlus", "leadingZero"] {
      #expect(
        try integer(
          fixture, "cases", "optionSemantics", "maxFile", label, "start", "httpStatus"
        ) == 204
      )
    }
    for label in ["zero", "negative", "fractional", "outerWhitespace"] {
      #expect(
        try integer(
          fixture, "cases", "optionSemantics", "maxFile", label, "start", "httpStatus"
        ) == 500
      )
    }

    for label in ["zero", "fractionalUnit", "upperUnit"] {
      #expect(
        try integer(
          fixture, "cases", "optionSemantics", "maxBufferSize", label, "create", "httpStatus"
        ) == 201
      )
    }
    for label in ["outerWhitespace", "negative"] {
      #expect(
        try integer(
          fixture, "cases", "optionSemantics", "maxBufferSize", label, "create", "httpStatus"
        ) == 400
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
          fixture, "cases", "optionSemantics", "cacheDisabled", label, "create", "httpStatus"
        ) == 201
      )
    }
    #expect(
      try integer(
        fixture, "cases", "optionSemantics", "cacheDisabled", "invalid", "create", "httpStatus"
      ) == 400
    )

    for driverCase in ["syslogArbitrary", "jsonFileArbitrary"] {
      #expect(
        try integer(
          fixture, "cases", "optionSemantics", "cachePrefixRetention", driverCase,
          "start", "httpStatus"
        ) == 204
      )
      #expect(
        try string(
          fixture, "cases", "optionSemantics", "cachePrefixRetention", driverCase,
          "inspectAfterCreate", "logConfig", "Config", "cache-max-size"
        ) == "not-a-size"
      )
    }
  }

  @Test
  func `pins stopped framing json records and restart retention`() throws {
    let fixture = try Self.fixture()

    #expect(
      try string(
        fixture,
        "cases", "jsonFileStoppedReadAndFraming", "combinedRead", "contentType"
      ) == "application/vnd.docker.multiplexed-stream"
    )
    #expect(
      try string(
        fixture,
        "cases", "jsonFileStoppedReadAndFraming", "combinedRead", "framing"
      ) == "docker-multiplexed-8-byte-header"
    )
    #expect(
      try string(
        fixture,
        "cases", "jsonFileStoppedReadAndFraming", "combinedRead", "stdout"
      ) == "stdout-line\n"
    )
    #expect(
      try string(
        fixture,
        "cases", "jsonFileStoppedReadAndFraming", "combinedRead", "stderr"
      ) == "stderr-line\n"
    )

    let frames: [[String: Any]] = try value(
      fixture,
      "cases", "jsonFileStoppedReadAndFraming", "combinedRead", "frames"
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
        "cases", "ttyRawMergedFraming", "combinedRead", "contentType"
      ) == "application/vnd.docker.raw-stream"
    )
    #expect(
      try string(
        fixture,
        "cases", "ttyRawMergedFraming", "combinedRead", "bytes"
      ) == "stdout-line\r\nstderr-line\r\n"
    )
    #expect(
      try string(
        fixture,
        "cases", "ttyRawMergedFraming", "stderrOnlyRead", "bytes"
      ) == ""
    )
    #expect(
      try string(
        fixture,
        "cases", "ttyRawMergedFraming", "stdoutOnlyRead", "bytes"
      ) == "stdout-line\r\nstderr-line\r\n"
    )

    let records: [[String: Any]] = try value(
      fixture,
      "cases", "jsonFileStoppedReadAndFraming", "jsonFileRecords"
    )
    #expect(records.count == 2)
    let recordsByStream = Dictionary(
      uniqueKeysWithValues: try records.map { record in
        (try string(record, "stream"), record)
      }
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
        "cases", "restartRetention", "retainedRead", "stdout"
      ) == "restart-1\nrestart-2\n"
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
        "cases", "localNativeReader", "inspectAfterExit", "logConfig", "Type"
      ) == "local"
    )
    #expect(
      try string(fixture, "cases", "localNativeReader", "inspectAfterExit", "logPath")
        == ""
    )
    #expect(
      try string(fixture, "cases", "localNativeReader", "stoppedRead", "stdout")
        == "local-line\n"
    )

    #expect(
      try integer(
        fixture,
        "cases", "nonReaderDualCache", "defaultCache", "stoppedRead", "httpStatus"
      ) == 200
    )
    #expect(
      try string(
        fixture,
        "cases", "nonReaderDualCache", "defaultCache", "stoppedRead", "stdout"
      ) == "cached-out\n"
    )
    #expect(
      try string(
        fixture,
        "cases", "nonReaderDualCache", "defaultCache", "stoppedRead", "stderr"
      ) == "cached-err\n"
    )
    #expect(
      try integer(
        fixture,
        "cases", "nonReaderDualCache", "cacheDisabled", "stoppedRead", "httpStatus"
      ) == 501
    )
    #expect(
      try string(
        fixture,
        "cases", "nonReaderDualCache", "cacheDisabled", "stoppedRead", "message"
      ) == "configured logging driver does not support reading"
    )
  }

  private static func fixture() throws -> [String: Any] {
    guard
      let url = Bundle.module.url(
        forResource: "docker-engine-29.2.1-logging",
        withExtension: "json",
      )
    else {
      throw FixtureError.missing(
        "Fixtures/logging/docker-engine-29.2.1-logging.json"
      )
    }
    let data = try Data(contentsOf: url)
    guard let fixture = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      throw FixtureError.invalid("root is not a JSON object")
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
        "\(path.joined(separator: ".")) traverses a non-object at \(component)"
      )
    }
    guard let next = object[component] else {
      throw FixtureError.invalid(
        "missing \(path.joined(separator: "."))"
      )
    }
    current = next
  }
  guard let typed = current as? T else {
    throw FixtureError.invalid(
      "\(path.joined(separator: ".")) has unexpected type \(type(of: current))"
    )
  }
  return typed
}

private func string(_ root: [String: Any], _ path: String...) throws -> String {
  try value(root, path: path)
}

private func integer(_ root: [String: Any], _ path: String...) throws -> Int {
  let number: NSNumber = try value(root, path: path)
  return number.intValue
}

private func boolean(_ root: [String: Any], _ path: String...) throws -> Bool {
  let number: NSNumber = try value(root, path: path)
  return number.boolValue
}

private enum FixtureError: Error, CustomStringConvertible {
  case invalid(String)
  case missing(String)

  var description: String {
    switch self {
    case .invalid(let message):
      "Invalid Docker logging oracle fixture: \(message)"
    case .missing(let path):
      "Missing Docker logging oracle fixture: \(path)"
    }
  }
}
