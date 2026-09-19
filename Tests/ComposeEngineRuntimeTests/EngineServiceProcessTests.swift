// Copyright 2026 container-compose project authors. SPDX-License-Identifier: Apache-2.0

import ComposeCore
@testable import ComposeEngineRuntime
import ComposeRuntimeSPI
import Foundation
import Testing

struct EngineServiceProcessTests {
    @Test(arguments: [nil, [], ["/custom", "flag with spaces"]] as [[String]?],
          [nil, [], ["argument", "--network", ""]] as [[String]?])
    func resolvesComposeDefaults(entrypoint: [String]?, command: [String]?) throws {
        let image = try imageConfiguration()
        let expectedEntrypoint = entrypoint ?? ["/image-entry"]
        let expectedCommand = command ?? (entrypoint == nil ? ["image-arg"] : [])
        let overrides = ComposeProcessOverrides(command: command, entrypoint: entrypoint)
        if expectedEntrypoint.isEmpty && expectedCommand.isEmpty {
            #expect(throws: ComposeError.self) { try EngineServiceProcess(overrides, image: image) }
            return
        }
        let process = try EngineServiceProcess(overrides, image: image)
        #expect(process.entrypoint == (expectedEntrypoint.isEmpty ? [""] : expectedEntrypoint))
        #expect(process.command == expectedCommand)
        // Apply Docker's merge/reset policy to the encoded values, not just a
        // Codable round trip. It must preserve the Compose-effective process.
        var mergedEntrypoint = process.entrypoint
        var mergedCommand = process.command
        if mergedCommand.isEmpty && mergedEntrypoint.isEmpty { mergedCommand = image.command ?? [] }
        if mergedEntrypoint.isEmpty { mergedEntrypoint = image.entrypoint ?? [] }
        if mergedEntrypoint == [""] { mergedEntrypoint = [] }
        #expect(mergedEntrypoint + mergedCommand == expectedEntrypoint + expectedCommand)
    }

    @Test func encodesProcessSettingsWithoutLosingEnvironmentRemovals() throws {
        let process = try EngineServiceProcess(.init(
            environment: ["REMOVE": nil, "EMPTY": "", "VALUE": "a=b c"],
            workingDirectory: "/work space", user: "1000:1001", terminal: true, openStandardInput: true
        ), image: imageConfiguration())
        let object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(process)) as? [String: Any])
        #expect(object["Entrypoint"] as? [String] == ["/image-entry"])
        #expect(object["Cmd"] as? [String] == ["image-arg"])
        #expect(object["Env"] as? [String] == ["EMPTY=", "REMOVE", "VALUE=a=b c"])
        #expect(object["WorkingDir"] as? String == "/work space")
        #expect(object["User"] as? String == "1000:1001")
        #expect(object["Tty"] as? Bool == true)
        #expect(object["OpenStdin"] as? Bool == true)
    }

    @Test func inheritsImageUserAndDirectoryWithoutCopyingItsEnvironment() throws {
        let process = try EngineServiceProcess(.init(), image: imageConfiguration())
        #expect(process.workingDirectory == "/image")
        #expect(process.user == "worker")
        #expect(process.environment.isEmpty)
        #expect(!process.terminal && !process.openStandardInput)
    }

    @Test func commandOnlyImageUsesResetSentinel() throws {
        let image = try JSONDecoder().decode(EngineImageConfig.self, from: Data(#"{"Cmd":["/bin/true"]}"#.utf8))
        let process = try EngineServiceProcess(.init(), image: image)
        #expect(process.entrypoint == [""])
        #expect(process.command == ["/bin/true"])
        #expect(throws: ComposeError.self) { try EngineServiceProcess(.init(command: []), image: image) }
        #expect(throws: ComposeError.self) { try EngineServiceProcess(.init(entrypoint: [""]), image: image) }
    }

    private func imageConfiguration() throws -> EngineImageConfig {
        let json = #"{"Entrypoint":["/image-entry"],"Cmd":["image-arg"],"User":"worker","WorkingDir":"/image","#
            + #""Env":["REMOVE=old"]}"#
        return try JSONDecoder().decode(EngineImageConfig.self, from: Data(json.utf8))
    }
}
