// Copyright 2026 container-compose project authors. SPDX-License-Identifier: Apache-2.0

import ComposeCore
@testable import ComposeEngineRuntime
import ComposeRuntimeSPI
import Foundation
import Testing

struct EngineServiceEnvironmentTests {
    @Test func parsesLiteralValuesAndHostLookups() throws {
        let text = "\u{FEFF} # comment\r\n KEY= value # literal \r\nEMPTY=\nHOST\nMISSING\nQUOTE=\"$HOME\"\nEQUAL=a=b\n"
        #expect(try EngineServiceEnvironment.parse(Data(text.utf8), hostEnvironment: ["HOST": "inherited"]) == [
            "KEY": " value # literal ", "EMPTY": "", "HOST": "inherited", "QUOTE": "\"$HOME\"", "EQUAL": "a=b",
        ])
    }

    @Test func preparesAllFilesInOrderBeforeRequestEncoding() throws {
        var plan = ContainerServiceCreatePlan(identity: .init(name: "app", imageReference: "image"))
        plan.environmentFiles = ["first", "second"]
        plan.resolvedMounts = []
        plan.publishedPorts = []
        plan.processOverrides.environment = ["EXPLICIT": "winner", "EMPTY": "", "HOST": nil, "REMOVE": nil]
        let image = try JSONDecoder().decode(EngineImageConfig.self, from: Data(#"{"Cmd":["/bin/true"]}"#.utf8))
        let request = try EngineServiceCreateRequest(
            plan: plan, image: image,
            environmentFileContents: [Data("ORDER=first\nEXPLICIT=old\nEMPTY=old\nREMOVE=old".utf8),
                                      Data("ORDER=second\nHOST\nABSENT".utf8)],
            hostEnvironment: ["HOST": "host-value"]
        )
        #expect(request.process.environment == [
            "EMPTY=", "EXPLICIT=winner", "HOST=host-value", "ORDER=second", "REMOVE",
        ])
        #expect(plan.environmentFiles == ["first", "second"])
        #expect(throws: ComposeError.self) { try EngineServiceCreateRequest(plan: plan, image: image) }
    }

    @Test func missingFileLookupDoesNotEraseEarlierValue() throws {
        let data = Data("VALUE=earlier\nVALUE\n".utf8)
        #expect(try EngineServiceEnvironment.parse(data, hostEnvironment: [:]) == ["VALUE": "earlier"])
    }

    @Test(arguments: ["=bad", "BAD KEY=value", "KEY =value", "KEY\t=value", "KEY=bad\0value"])
    func invalidFilesFailWithoutLeakingValues(_ value: String) {
        do {
            _ = try EngineServiceEnvironment.parse(Data(value.utf8), hostEnvironment: [:])
            Issue.record("Invalid environment was accepted")
        } catch {
            #expect(!String(describing: error).contains(value))
        }
    }

    @Test func invalidUTF8Fails() {
        #expect(throws: ComposeError.self) {
            try EngineServiceEnvironment.parse(Data([0xff]), hostEnvironment: [:])
        }
    }

    @Test func oversizedLineFailsWithoutDumpingItsContents() {
        let value = "KEY=" + String(repeating: "x", count: 65_532)
        invalidFilesFailWithoutLeakingValues(value)
    }
}
