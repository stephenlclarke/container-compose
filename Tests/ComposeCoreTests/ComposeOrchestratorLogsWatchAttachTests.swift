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

import ComposeContainerRuntime
@testable import ComposeCore
import ContainerizationArchive
import ContainerizationError
import ContainerizationExtras
import ContainerizationOCI
import ContainerResource
#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#endif
import Foundation
import Testing

extension ComposeOrchestratorTests {
    @Test("logs treats unreadable driver history as an empty stream")
    func logsTreatsUnreadableDriverHistoryAsEmptyStream() async throws {
        let emitted = MessageRecorder()
        let logManager = RecordingContainerLogManager(
            error: ComposeRuntimeLogError.readingUnsupported
        )
        let project = ComposeProject(
            name: "demo",
            services: [
                "silent": ComposeService(name: "silent", image: "example/silent"),
            ]
        )

        try await ComposeOrchestrator(
            runner: RecordingRunner(),
            options: ComposeExecutionOptions(emit: { emitted.append($0) }),
            logManager: logManager
        ).logs(project: project, services: ["silent"])

        #expect(await logManager.requests == [
            ContainerLogRequest(id: "demo-silent-1", tail: nil, follow: false),
        ])
        #expect(emitted.messages.isEmpty)
    }

    @Test("logs continues readable services after unreadable driver history")
    func logsContinuesReadableServicesAfterUnreadableDriverHistory() async throws {
        let emitted = MessageRecorder()
        let logManager = RecordingContainerLogManager(
            outputs: ["visible"],
            error: ComposeRuntimeLogError.readingUnsupported,
            errorIDs: ["demo-silent-1"]
        )
        let project = ComposeProject(
            name: "demo",
            services: [
                "silent": ComposeService(name: "silent", image: "example/silent"),
                "api": ComposeService(name: "api", image: "example/api"),
            ]
        )

        try await ComposeOrchestrator(
            runner: RecordingRunner(),
            options: ComposeExecutionOptions(emit: { emitted.append($0) }),
            logManager: logManager
        ).logs(project: project, services: ["silent", "api"])

        #expect(await logManager.requests == [
            ContainerLogRequest(id: "demo-silent-1", tail: nil, follow: false),
            ContainerLogRequest(id: "demo-api-1", tail: nil, follow: false),
        ])
        #expect(emitted.messages == ["api-1 | visible"])
    }

    @Test("logs preserves unreadable driver errors for follow requests")
    func logsPreservesUnreadableDriverErrorsForFollowRequests() async throws {
        let logManager = RecordingContainerLogManager(
            error: ComposeRuntimeLogError.readingUnsupported
        )
        let project = ComposeProject(
            name: "demo",
            services: [
                "silent": ComposeService(name: "silent", image: "example/silent"),
            ]
        )

        do {
            try await ComposeOrchestrator(
                runner: RecordingRunner(),
                options: ComposeExecutionOptions(),
                logManager: logManager
            ).logs(
                project: project,
                services: ["silent"],
                options: ComposeLogsOptions { $0.follow = true }
            )
            Issue.record("Expected the unreadable-driver follow error")
        } catch let error as ComposeRuntimeLogError {
            #expect(error == .readingUnsupported)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test("logs accepts Compose all tail value")
    func logsAcceptsComposeAllTailValue() async throws {
        let runner = RecordingRunner()
        let emitted = MessageRecorder()
        let logManager = RecordingContainerLogManager(outputs: ["hello"])
        let project = ComposeProject(
            name: "demo",
            services: [
                "api": ComposeService(name: "api", image: "example/api"),
            ]
        )

        try await ComposeOrchestrator(
            runner: runner,
            options: ComposeExecutionOptions(emit: { emitted.append($0) }),
            logManager: logManager
        ).logs(
            project: project,
            services: ["api"],
            options: ComposeLogsOptions {
                $0.tail = "all"
            }
        )

        #expect(runner.commands.isEmpty)
        #expect(await logManager.requests == [
            ContainerLogRequest(id: "demo-api-1", tail: nil, follow: false),
        ])
        #expect(emitted.messages == ["api-1 | hello"])
    }

    @Test("logs no log prefix emits raw output")
    func logsNoLogPrefixEmitsRawOutput() async throws {
        let runner = RecordingRunner()
        let emitted = MessageRecorder()
        let logManager = RecordingContainerLogManager(outputs: ["hello"])
        let project = ComposeProject(
            name: "demo",
            services: [
                "api": ComposeService(name: "api", image: "example/api"),
            ]
        )

        try await ComposeOrchestrator(
            runner: runner,
            options: ComposeExecutionOptions(emit: { emitted.append($0) }),
            logManager: logManager
        ).logs(
            project: project,
            services: ["api"],
            options: ComposeLogsOptions {
                $0.noLogPrefix = true
                $0.colorPrefixes = true
            }
        )

        #expect(runner.commands.isEmpty)
        #expect(await logManager.requests == [
            ContainerLogRequest(id: "demo-api-1", tail: nil, follow: false),
        ])
        #expect(emitted.messages == ["hello"])
    }

    @Test("logs prefixes every emitted line")
    func logsPrefixesEveryEmittedLine() async throws {
        let emitted = MessageRecorder()
        let logManager = RecordingContainerLogManager(outputs: ["one\ntwo"])
        let project = ComposeProject(
            name: "demo",
            services: [
                "api": ComposeService(name: "api", image: "example/api"),
            ]
        )

        try await ComposeOrchestrator(
            runner: RecordingRunner(),
            options: ComposeExecutionOptions(emit: { emitted.append($0) }),
            logManager: logManager
        ).logs(project: project, services: ["api"])

        #expect(emitted.messages == ["api-1 | one\napi-1 | two"])
    }

    @Test("logs prefixes Compose line boundary fixtures")
    func logsPrefixesComposeLineBoundaryFixtures() async throws {
        let emitted = MessageRecorder()
        let logManager = RecordingContainerLogManager(outputs: ["one\n\npartial"])
        let project = ComposeProject(
            name: "demo",
            services: [
                "api": ComposeService(name: "api", image: "example/api"),
            ]
        )

        try await ComposeOrchestrator(
            runner: RecordingRunner(),
            options: ComposeExecutionOptions(emit: { emitted.append($0) }),
            logManager: logManager
        ).logs(project: project, services: ["api"])

        #expect(emitted.messages == ["api-1 | one\napi-1 | \napi-1 | partial"])
    }

    @Test("logs colorizes prefixes when requested")
    func logsColorizesPrefixesWhenRequested() async throws {
        let emitted = MessageRecorder()
        let logManager = RecordingContainerLogManager(outputs: ["hello"])
        let project = ComposeProject(
            name: "demo",
            services: [
                "api": ComposeService(name: "api", image: "example/api"),
            ]
        )

        try await ComposeOrchestrator(
            runner: RecordingRunner(),
            options: ComposeExecutionOptions(emit: { emitted.append($0) }),
            logManager: logManager
        ).logs(
            project: project,
            services: ["api"],
            options: ComposeLogsOptions {
                $0.colorPrefixes = true
            }
        )

        #expect(emitted.messages == ["\u{001B}[35mapi-1\u{001B}[0m | hello"])
    }

    @Test("logs targets selected container index")
    func logsTargetsSelectedContainerIndex() async throws {
        let emitted = MessageRecorder()
        let logManager = RecordingContainerLogManager(outputs: ["replica-log"])
        let discoveryManager = RecordingContainerDiscoveryManager(containers: [
            ComposeContainerSummary(
                id: "demo-api-2",
                status: "running",
                labels: [
                    composeProjectLabel: "demo",
                    composeServiceLabel: "api",
                ]
            ),
        ])
        let project = ComposeProject(
            name: "demo",
            services: [
                "api": ComposeService(name: "api", image: "example/api"),
            ]
        )

        try await ComposeOrchestrator(
            runner: RecordingRunner(),
            options: ComposeExecutionOptions(emit: { emitted.append($0) }),
            dependencies: orchestratorDependencies {
                $0.discoveryManager = discoveryManager
                $0.logManager = logManager
            }
        ).logs(
            project: project,
            services: ["api"],
            options: ComposeLogsOptions {
                $0.index = 2
            }
        )

        #expect(await discoveryManager.listRequests == [true])
        #expect(await logManager.requests == [
            ContainerLogRequest(id: "demo-api-2", tail: nil, follow: false),
        ])
        #expect(emitted.messages == ["api-2 | replica-log"])
    }

    @Test("logs targets all existing replicas for selected services by default")
    func logsTargetsAllExistingReplicasForSelectedServicesByDefault() async throws {
        let logManager = RecordingContainerLogManager(outputs: ["log"])
        let discoveryManager = RecordingContainerDiscoveryManager(containers: [
            ComposeContainerSummary(
                id: "demo-api-2",
                status: "running",
                labels: [
                    composeProjectLabel: "demo",
                    composeServiceLabel: "api",
                ]
            ),
            ComposeContainerSummary(
                id: "demo-api-1",
                status: "running",
                labels: [
                    composeProjectLabel: "demo",
                    composeServiceLabel: "api",
                ]
            ),
        ])
        let project = ComposeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api") {
                    $0.scale = 2
                },
            ]
        )

        try await ComposeOrchestrator(
            runner: RecordingRunner(),
            options: ComposeExecutionOptions(emit: { _ in }),
            dependencies: orchestratorDependencies {
                $0.discoveryManager = discoveryManager
                $0.logManager = logManager
            }
        ).logs(project: project, services: ["api"])

        #expect(await discoveryManager.listRequests == [true])
        #expect(await logManager.requests == [
            ContainerLogRequest(id: "demo-api-1", tail: nil, follow: false),
            ContainerLogRequest(id: "demo-api-2", tail: nil, follow: false),
        ])
    }

    @Test("logs follow starts selected service replicas concurrently")
    func logsFollowStartsSelectedServiceReplicasConcurrently() async throws {
        let logManager = BlockingContainerLogManager()
        let discoveryManager = RecordingContainerDiscoveryManager(containers: [
            ComposeContainerSummary(
                id: "demo-api-1",
                status: "running",
                labels: [
                    composeProjectLabel: "demo",
                    composeServiceLabel: "api",
                ]
            ),
            ComposeContainerSummary(
                id: "demo-api-2",
                status: "running",
                labels: [
                    composeProjectLabel: "demo",
                    composeServiceLabel: "api",
                ]
            ),
        ])
        let project = ComposeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api") {
                    $0.scale = 2
                },
            ]
        )
        let orchestrator = ComposeOrchestrator(
            runner: RecordingRunner(),
            options: ComposeExecutionOptions(emit: { _ in }),
            dependencies: orchestratorDependencies {
                $0.discoveryManager = discoveryManager
                $0.logManager = logManager
            }
        )
        let followTask = Task {
            try await orchestrator.logs(
                project: project,
                services: ["api"],
                options: ComposeLogsOptions {
                    $0.follow = true
                    $0.tail = "10"
                }
            )
        }

        let startedBothTargets = try await logManager.waitForRequestCount(2)
        await logManager.releaseAll()
        try await followTask.value

        #expect(startedBothTargets)
        #expect(await discoveryManager.listRequests == [true])
        #expect(await logManager.requests.sorted { $0.id < $1.id } == [
            ContainerLogRequest(id: "demo-api-1", tail: 10, follow: true),
            ContainerLogRequest(id: "demo-api-2", tail: 10, follow: true),
        ])
    }

    @Test("logs with no service targets all project service replicas")
    func logsWithNoServiceTargetsAllProjectServiceReplicas() async throws {
        let logManager = RecordingContainerLogManager(outputs: ["log"])
        let discoveryManager = RecordingContainerDiscoveryManager(containers: [
            ComposeContainerSummary(
                id: "demo-worker-1",
                status: "running",
                labels: [
                    composeProjectLabel: "demo",
                    composeServiceLabel: "worker",
                ]
            ),
            ComposeContainerSummary(
                id: "demo-api-2",
                status: "running",
                labels: [
                    composeProjectLabel: "demo",
                    composeServiceLabel: "api",
                ]
            ),
            ComposeContainerSummary(
                id: "demo-api-1",
                status: "running",
                labels: [
                    composeProjectLabel: "demo",
                    composeServiceLabel: "api",
                ]
            ),
        ])
        let project = ComposeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api") {
                    $0.scale = 2
                },
                "worker": ComposeService(name: "worker", image: "example/worker"),
            ]
        )

        try await ComposeOrchestrator(
            runner: RecordingRunner(),
            options: ComposeExecutionOptions(emit: { _ in }),
            dependencies: orchestratorDependencies {
                $0.discoveryManager = discoveryManager
                $0.logManager = logManager
            }
        ).logs(project: project, services: [])

        #expect(await discoveryManager.listRequests == [true])
        #expect(await logManager.requests == [
            ContainerLogRequest(id: "demo-api-1", tail: nil, follow: false),
            ContainerLogRequest(id: "demo-api-2", tail: nil, follow: false),
            ContainerLogRequest(id: "demo-worker-1", tail: nil, follow: false),
        ])
    }

    @Test("logs explicit index narrows selected services")
    func logsExplicitIndexNarrowsSelectedServices() async throws {
        let logManager = RecordingContainerLogManager(outputs: ["log"])
        let discoveryManager = RecordingContainerDiscoveryManager(containers: [
            ComposeContainerSummary(
                id: "demo-api-1",
                status: "running",
                labels: [
                    composeProjectLabel: "demo",
                    composeServiceLabel: "api",
                ]
            ),
            ComposeContainerSummary(
                id: "demo-api-2",
                status: "running",
                labels: [
                    composeProjectLabel: "demo",
                    composeServiceLabel: "api",
                ]
            ),
        ])
        let project = ComposeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api") {
                    $0.scale = 2
                },
            ]
        )

        try await ComposeOrchestrator(
            runner: RecordingRunner(),
            options: ComposeExecutionOptions(emit: { _ in }),
            dependencies: orchestratorDependencies {
                $0.discoveryManager = discoveryManager
                $0.logManager = logManager
            }
        ).logs(
            project: project,
            services: ["api"],
            options: ComposeLogsOptions {
                $0.index = 1
            }
        )

        #expect(await discoveryManager.listRequests == [true])
        #expect(await logManager.requests == [
            ContainerLogRequest(id: "demo-api-1", tail: nil, follow: false),
        ])
    }

    @Test("logs passes timestamp filters to log manager")
    func logsPassesTimestampFiltersToLogManager() async throws {
        let emitted = MessageRecorder()
        let logManager = RecordingContainerLogManager(outputs: ["filtered-log"])
        let now = date("2026-06-18T12:00:00Z")
        let project = ComposeProject(
            name: "demo",
            services: [
                "api": ComposeService(name: "api", image: "example/api"),
            ]
        )

        try await ComposeOrchestrator(
            runner: RecordingRunner(),
            options: ComposeExecutionOptions(
                dryRun: false,
                runtimeHooks: ComposeExecutionOptions.RuntimeHooks(
                    currentDate: { now },
                    emit: { emitted.append($0) },
                    emitData: { emitted.append(String(decoding: $0, as: UTF8.self)) }
                )
            ),
            logManager: logManager
        ).logs(
            project: project,
            services: ["api"],
            options: ComposeLogsOptions {
                $0.tail = "10"
                $0.since = "2026-06-18T10:00:00Z"
                $0.until = "30m"
            }
        )

        #expect(await logManager.requests == [
            ContainerLogRequest(
                id: "demo-api-1",
                tail: 10,
                follow: false,
                since: date("2026-06-18T10:00:00Z"),
                until: date("2026-06-18T11:30:00Z")
            ),
        ])
        #expect(emitted.messages == ["api-1 | filtered-log"])
    }

    @Test("logs accepts Unix timestamp filters")
    func logsAcceptsUnixTimestampFilters() async throws {
        let emitted = MessageRecorder()
        let logManager = RecordingContainerLogManager(outputs: ["filtered-log"])
        let project = ComposeProject(
            name: "demo",
            services: [
                "api": ComposeService(name: "api", image: "example/api"),
            ]
        )

        try await ComposeOrchestrator(
            runner: RecordingRunner(),
            options: ComposeExecutionOptions(
                dryRun: false,
                runtimeHooks: ComposeExecutionOptions.RuntimeHooks(
                    emit: { emitted.append($0) },
                    emitData: { emitted.append(String(decoding: $0, as: UTF8.self)) }
                )
            ),
            logManager: logManager
        ).logs(
            project: project,
            services: ["api"],
            options: ComposeLogsOptions {
                $0.since = "1781776800"
                $0.until = "1781782200.25"
            }
        )

        #expect(await logManager.requests == [
            ContainerLogRequest(
                id: "demo-api-1",
                tail: nil,
                follow: false,
                since: date("2026-06-18T10:00:00Z"),
                until: date("2026-06-18T11:30:00.250Z")
            ),
        ])
        #expect(emitted.messages == ["api-1 | filtered-log"])
    }

    @Test("logs accepts Docker timestamp layout filters")
    func logsAcceptsDockerTimestampLayoutFilters() async throws {
        let emitted = MessageRecorder()
        let logManager = RecordingContainerLogManager(outputs: ["filtered-log"])
        let project = ComposeProject(
            name: "demo",
            services: [
                "api": ComposeService(name: "api", image: "example/api"),
            ]
        )

        try await ComposeOrchestrator(
            runner: RecordingRunner(),
            options: ComposeExecutionOptions(
                runtimeHooks: ComposeExecutionOptions.RuntimeHooks(
                    emit: { emitted.append($0) },
                    emitData: { emitted.append(String(decoding: $0, as: UTF8.self)) }
                )
            ),
            logManager: logManager
        ).logs(
            project: project,
            services: ["api"],
            options: ComposeLogsOptions {
                $0.since = "2026-06-18T10:00:00.123456789Z"
                $0.until = "2026-06-18T11:30"
            }
        )

        let request = try #require(await logManager.requests.first)
        #expect(request.id == "demo-api-1")
        #expect(request.tail == nil)
        #expect(request.follow == false)
        let expectedSince = date("2026-06-18T10:00:00Z").addingTimeInterval(0.123_456_789)
        let expectedUntil = localDate("2026-06-18T11:30", format: "yyyy-MM-dd'T'HH:mm")
        #expect(try abs(#require(request.since).timeIntervalSince(expectedSince)) < 0.001)
        #expect(try abs(#require(request.until).timeIntervalSince(expectedUntil)) < 0.000_001)
        #expect(emitted.messages == ["api-1 | filtered-log"])
    }

    @Test("logs accepts date-only timestamp filters")
    func logsAcceptsDateOnlyTimestampFilters() async throws {
        let emitted = MessageRecorder()
        let logManager = RecordingContainerLogManager(outputs: ["filtered-log"])
        let project = ComposeProject(
            name: "demo",
            services: [
                "api": ComposeService(name: "api", image: "example/api"),
            ]
        )

        try await ComposeOrchestrator(
            runner: RecordingRunner(),
            options: ComposeExecutionOptions(
                runtimeHooks: ComposeExecutionOptions.RuntimeHooks(
                    emit: { emitted.append($0) },
                    emitData: { emitted.append(String(decoding: $0, as: UTF8.self)) }
                )
            ),
            logManager: logManager
        ).logs(
            project: project,
            services: ["api"],
            options: ComposeLogsOptions {
                $0.since = "2026-06-18"
            }
        )

        let request = try #require(await logManager.requests.first)
        #expect(request.id == "demo-api-1")
        #expect(request.since == date("2026-06-18T00:00:00Z"))
        #expect(request.until == nil)
        #expect(emitted.messages == ["api-1 | filtered-log"])
    }

    @Test("logs accepts fractional relative duration filters")
    func logsAcceptsFractionalRelativeDurationFilters() async throws {
        let emitted = MessageRecorder()
        let logManager = RecordingContainerLogManager(outputs: ["filtered-log"])
        let now = date("2026-06-18T12:00:00Z")
        let project = ComposeProject(
            name: "demo",
            services: [
                "api": ComposeService(name: "api", image: "example/api"),
            ]
        )

        try await ComposeOrchestrator(
            runner: RecordingRunner(),
            options: ComposeExecutionOptions(
                runtimeHooks: ComposeExecutionOptions.RuntimeHooks(
                    currentDate: { now },
                    emit: { emitted.append($0) },
                    emitData: { emitted.append(String(decoding: $0, as: UTF8.self)) }
                )
            ),
            logManager: logManager
        ).logs(
            project: project,
            services: ["api"],
            options: ComposeLogsOptions {
                $0.since = "1.5h"
                $0.until = "250ms"
            }
        )

        #expect(await logManager.requests == [
            ContainerLogRequest(
                id: "demo-api-1",
                tail: nil,
                follow: false,
                since: date("2026-06-18T10:30:00Z"),
                until: date("2026-06-18T11:59:59.750Z")
            ),
        ])
        #expect(emitted.messages == ["api-1 | filtered-log"])
    }

    @Test("logs rejects malformed Unix timestamp filters")
    func logsRejectsMalformedUnixTimestampFilters() async throws {
        let project = ComposeProject(
            name: "demo",
            services: [
                "api": ComposeService(name: "api", image: "example/api"),
            ]
        )

        for value in ["1781776800.", ".25", "1781776800.1234567890"] {
            do {
                try await ComposeOrchestrator(runner: RecordingRunner()).logs(
                    project: project,
                    services: ["api"],
                    options: ComposeLogsOptions {
                        $0.since = value
                    }
                )
                Issue.record("Expected invalid Unix timestamp filter error for \(value)")
            } catch let error as ComposeError {
                #expect(error == .invalidProject("logs time filters must be RFC 3339 timestamps, UNIX timestamps, or relative durations"))
            } catch {
                Issue.record("Unexpected error: \(error)")
            }
        }
    }

    @Test("logs rejects malformed relative duration filters")
    func logsRejectsMalformedRelativeDurationFilters() async throws {
        let project = ComposeProject(
            name: "demo",
            services: [
                "api": ComposeService(name: "api", image: "example/api"),
            ]
        )

        for value in ["-1s", "1d", "1ms2", "1..5s"] {
            do {
                try await ComposeOrchestrator(runner: RecordingRunner()).logs(
                    project: project,
                    services: ["api"],
                    options: ComposeLogsOptions {
                        $0.since = value
                    }
                )
                Issue.record("Expected invalid relative duration filter error for \(value)")
            } catch let error as ComposeError {
                #expect(error == .invalidProject("logs time filters must be RFC 3339 timestamps, UNIX timestamps, or relative durations"))
            } catch {
                Issue.record("Unexpected error: \(error)")
            }
        }
    }

    @Test("logs passes timestamps to log manager")
    func logsPassesTimestampsToLogManager() async throws {
        let emitted = MessageRecorder()
        let logManager = RecordingContainerLogManager(outputs: ["timestamped-log"])
        let project = ComposeProject(
            name: "demo",
            services: [
                "api": ComposeService(name: "api", image: "example/api"),
            ]
        )

        try await ComposeOrchestrator(
            runner: RecordingRunner(),
            options: ComposeExecutionOptions(emit: { emitted.append($0) }),
            logManager: logManager
        ).logs(
            project: project,
            services: ["api"],
            options: ComposeLogsOptions {
                $0.timestamps = true
            }
        )

        #expect(await logManager.requests == [
            ContainerLogRequest(id: "demo-api-1", tail: nil, follow: false, timestamps: true),
        ])
        #expect(emitted.messages == ["api-1 | timestamped-log"])
    }

    @Test("logs passes timestamped follow to log manager")
    func logsPassesTimestampedFollowToLogManager() async throws {
        let emitted = MessageRecorder()
        let logManager = RecordingContainerLogManager(outputs: ["timestamped-live"])
        let project = ComposeProject(
            name: "demo",
            services: [
                "api": ComposeService(name: "api", image: "example/api"),
            ]
        )

        try await ComposeOrchestrator(
            runner: RecordingRunner(),
            options: ComposeExecutionOptions(emit: { emitted.append($0) }),
            logManager: logManager
        ).logs(
            project: project,
            services: ["api"],
            options: ComposeLogsOptions {
                $0.follow = true
                $0.timestamps = true
            }
        )

        #expect(await logManager.requests == [
            ContainerLogRequest(id: "demo-api-1", tail: nil, follow: true, timestamps: true),
        ])
        #expect(emitted.messages == ["api-1 | timestamped-live"])
    }

    @Test("logs passes filtered follow to log manager")
    func logsPassesFilteredFollowToLogManager() async throws {
        let emitted = MessageRecorder()
        let logManager = RecordingContainerLogManager(outputs: ["filtered-live"])
        let project = ComposeProject(
            name: "demo",
            services: [
                "api": ComposeService(name: "api", image: "example/api"),
            ]
        )

        try await ComposeOrchestrator(
            runner: RecordingRunner(),
            options: ComposeExecutionOptions(emit: { emitted.append($0) }),
            logManager: logManager
        ).logs(
            project: project,
            services: ["api"],
            options: ComposeLogsOptions {
                $0.follow = true
                $0.since = "2026-06-18T10:00:00Z"
            }
        )

        #expect(await logManager.requests == [
            ContainerLogRequest(
                id: "demo-api-1",
                tail: nil,
                follow: true,
                since: date("2026-06-18T10:00:00Z")
            ),
        ])
        #expect(emitted.messages == ["api-1 | filtered-live"])
    }

    @Test("logs rejects invalid time filters")
    func logsRejectsInvalidTimeFilters() async throws {
        let project = ComposeProject(
            name: "demo",
            services: [
                "api": ComposeService(name: "api", image: "example/api"),
            ]
        )

        do {
            try await ComposeOrchestrator(runner: RecordingRunner()).logs(
                project: project,
                services: ["api"],
                options: ComposeLogsOptions {
                    $0.since = "soon"
                }
            )
            Issue.record("Expected invalid time filter error")
        } catch let error as ComposeError {
            #expect(error == .invalidProject("logs time filters must be RFC 3339 timestamps, UNIX timestamps, or relative durations"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test("logs dry run emits compose runtime operation")
    func logsDryRunEmitsComposeRuntimeOperation() async throws {
        let emitted = MessageRecorder()
        let logManager = RecordingContainerLogManager(outputs: ["ignored"])
        let project = ComposeProject(
            name: "demo",
            services: [
                "api": ComposeService(name: "api", image: "example/api"),
            ]
        )

        try await ComposeOrchestrator(
            runner: RecordingRunner(),
            options: ComposeExecutionOptions(dryRun: true, emit: { emitted.append($0) }),
            logManager: logManager
        ).logs(
            project: project,
            services: ["api"],
            options: ComposeLogsOptions {
                $0.follow = true
                $0.tail = "10"
            }
        )

        #expect(emitted.messages == [
            "+ compose-runtime logs --follow -n 10 demo-api-1",
        ])
        #expect(await logManager.requests.isEmpty)
    }

    @Test("logs dry run emits configured service replicas")
    func logsDryRunEmitsConfiguredServiceReplicas() async throws {
        let emitted = MessageRecorder()
        let logManager = RecordingContainerLogManager(outputs: ["ignored"])
        let project = ComposeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api") {
                    $0.scale = 2
                },
            ]
        )

        try await ComposeOrchestrator(
            runner: RecordingRunner(),
            options: ComposeExecutionOptions(dryRun: true, emit: { emitted.append($0) }),
            logManager: logManager
        ).logs(
            project: project,
            services: ["api"],
            options: ComposeLogsOptions {
                $0.follow = true
                $0.tail = "10"
            }
        )

        #expect(emitted.messages == [
            "+ compose-runtime logs --follow -n 10 demo-api-1",
            "+ compose-runtime logs --follow -n 10 demo-api-2",
        ])
        #expect(await logManager.requests.isEmpty)
    }

    @Test("logs dry run emits timestamp options")
    func logsDryRunEmitsTimestampOptions() async throws {
        let emitted = MessageRecorder()
        let logManager = RecordingContainerLogManager(outputs: ["ignored"])
        let project = ComposeProject(
            name: "demo",
            services: [
                "api": ComposeService(name: "api", image: "example/api"),
            ]
        )

        try await ComposeOrchestrator(
            runner: RecordingRunner(),
            options: ComposeExecutionOptions(dryRun: true, emit: { emitted.append($0) }),
            logManager: logManager
        ).logs(
            project: project,
            services: ["api"],
            options: ComposeLogsOptions {
                $0.follow = true
                $0.since = "2026-06-18T10:00:00Z"
                $0.until = "2026-06-18T11:00:00Z"
                $0.timestamps = true
            }
        )

        #expect(emitted.messages == [
            "+ compose-runtime logs --follow --since 2026-06-18T10:00:00Z --until 2026-06-18T11:00:00Z --timestamps demo-api-1",
        ])
        #expect(await logManager.requests.isEmpty)
    }

    @Test("logs dry run emits indexed compose runtime operation")
    func logsDryRunEmitsIndexedComposeRuntimeOperation() async throws {
        let emitted = MessageRecorder()
        let logManager = RecordingContainerLogManager(outputs: ["ignored"])
        let project = ComposeProject(
            name: "demo",
            services: [
                "api": ComposeService(name: "api", image: "example/api"),
            ]
        )

        try await ComposeOrchestrator(
            runner: RecordingRunner(),
            options: ComposeExecutionOptions(dryRun: true, emit: { emitted.append($0) }),
            logManager: logManager
        ).logs(
            project: project,
            services: ["api"],
            options: ComposeLogsOptions {
                $0.follow = true
                $0.tail = "10"
                $0.index = 2
            }
        )

        #expect(emitted.messages == [
            "+ compose-runtime logs --follow -n 10 demo-api-2",
        ])
        #expect(await logManager.requests.isEmpty)
    }

    @Test("watch dry run emits the validated trigger plan")
    func watchDryRunEmitsValidatedTriggerPlan() async throws {
        let emitted = MessageRecorder()
        let runner = RecordingRunner()
        let project = ComposeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api") {
                    $0.develop = ComposeDevelop(watch: [
                        ComposeDevelopWatch(path: "src", action: "rebuild", ignore: [".build/"]),
                        ComposeDevelopWatch(
                            path: "assets",
                            action: "sync+exec",
                            target: "/app/assets",
                            include: ["*.swift"],
                            initialSync: true,
                            exec: ComposeDevelopWatchExec(command: ["sh", "-c", "touch /tmp/reloaded"])
                        ),
                    ])
                },
            ]
        )

        try await ComposeOrchestrator(
            runner: runner,
            options: ComposeExecutionOptions(dryRun: true, emit: { emitted.append($0) })
        ).watch(
            project: project,
            options: ComposeWatchOptions(services: ["api"], noUp: true, prune: false, quiet: true)
        )

        #expect(emitted.messages == [
            "compose: watch project demo services api",
            "compose: watch initial-up disabled",
            "compose: watch prune disabled",
            "compose: watch quiet enabled",
            "compose: watch api rebuild path=src ignore=.build/",
            "compose: watch api sync+exec path=assets target=/app/assets include=*.swift initial-sync=true exec=sh -c 'touch /tmp/reloaded'",
        ])
        #expect(runner.commands.isEmpty)
    }

    @Test("watch applies initial sync before polling")
    func watchAppliesInitialSyncBeforePolling() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let sourceDirectory = directory.appendingPathComponent("src", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)
        let sourceFile = sourceDirectory.appendingPathComponent("main.swift")
        try "initial".write(to: sourceFile, atomically: true, encoding: .utf8)

        let runner = RecordingRunner()
        let copier = RecordingContainerCopier()
        let sleeper = ThrowingSleeper(throwOnCall: 1)
        let project = ComposeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api") {
                    $0.develop = ComposeDevelop(watch: [
                        ComposeDevelopWatch(
                            path: sourceDirectory.path,
                            action: "sync",
                            target: "/app/src",
                            include: ["*.swift"],
                            initialSync: true
                        ),
                    ])
                },
            ]
        )

        try await ComposeOrchestrator(
            runner: runner,
            options: ComposeExecutionOptions(
                watchPollInterval: .milliseconds(1),
                sleep: { try await sleeper.sleep($0) }
            ),
            copier: copier
        ).watch(project: project, options: ComposeWatchOptions(services: ["api"], noUp: true, quiet: true))

        #expect(runner.commands.isEmpty)
        let copyRequests = await copier.requests
        #expect(copyRequests.count == 1)
        if case let .into(id, source, destination) = copyRequests.first {
            #expect(id == "demo-api-1")
            #expect(source.hasSuffix("/src/main.swift"))
            #expect(destination == "/app/src/main.swift")
        } else {
            Issue.record("Expected initial watch sync copy")
        }
    }

    @Test("watch syncs changed files and runs sync exec hooks")
    func watchSyncsChangedFilesAndRunsSyncExecHooks() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let sourceDirectory = directory.appendingPathComponent("src", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)
        let sourceFile = sourceDirectory.appendingPathComponent("main.swift")
        try "before".write(to: sourceFile, atomically: true, encoding: .utf8)

        let runner = RecordingRunner()
        let copier = RecordingContainerCopier()
        let execManager = RecordingContainerExecManager()
        let sleeper = FileMutationSleeper(file: sourceFile, contents: "after")
        let discoveryManager = RecordingContainerDiscoveryManager(containers: [
            ComposeContainerSummary(
                id: "demo-api-1",
                status: "running",
                labels: [
                    composeProjectLabel: "demo",
                    composeServiceLabel: "api",
                ]
            ),
        ])
        let project = ComposeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api") {
                    $0.develop = ComposeDevelop(watch: [
                        ComposeDevelopWatch(
                            path: sourceDirectory.path,
                            action: "sync+exec",
                            target: "/app/src",
                            include: ["*.swift"],
                            exec: ComposeDevelopWatchExec(
                                command: ["sh", "-c", "touch /tmp/reloaded"],
                                user: "1000",
                                privileged: true,
                                workingDir: "/app",
                                environment: ["A": "1", "B": nil]
                            )
                        ),
                    ])
                },
            ]
        )
        let dependencies = orchestratorDependencies {
            $0.copier = copier
            $0.discoveryManager = discoveryManager
            $0.execManager = execManager
        }

        try await ComposeOrchestrator(
            runner: runner,
            options: ComposeExecutionOptions(
                watchPollInterval: .milliseconds(1),
                sleep: { try await sleeper.sleep($0) }
            ),
            dependencies: dependencies
        ).watch(project: project, options: ComposeWatchOptions(services: ["api"], noUp: true, quiet: true))

        #expect(runner.commands.isEmpty)
        let copyRequests = await copier.requests
        #expect(copyRequests.count == 1)
        if case let .into(id, source, destination) = copyRequests.first {
            #expect(id == "demo-api-1")
            #expect(source.hasSuffix("/src/main.swift"))
            #expect(destination == "/app/src/main.swift")
        } else {
            Issue.record("Expected changed file watch sync copy")
        }
        #expect(await execManager.attachedRequests == [
            ContainerAttachedExecRequest(
                id: "demo-api-1",
                command: ["sh", "-c", "touch /tmp/reloaded"],
                environment: ["A=1", "B"],
                user: "1000",
                workingDirectory: "/app",
                privileged: true,
                terminal: .init(interactive: false, tty: false)
            ),
        ])
    }

    @Test("watch removes deleted synced files")
    func watchRemovesDeletedSyncedFiles() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let sourceDirectory = directory.appendingPathComponent("src", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)
        let sourceFile = sourceDirectory.appendingPathComponent("main.swift")
        try "before".write(to: sourceFile, atomically: true, encoding: .utf8)

        let execManager = RecordingContainerExecManager()
        let sleeper = FileDeletionSleeper(file: sourceFile)
        let discoveryManager = RecordingContainerDiscoveryManager(containers: [
            ComposeContainerSummary(
                id: "demo-api-1",
                status: "running",
                labels: [
                    composeProjectLabel: "demo",
                    composeServiceLabel: "api",
                ]
            ),
        ])
        let project = ComposeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api", image: "example/api") {
                    $0.develop = ComposeDevelop(watch: [
                        ComposeDevelopWatch(path: sourceDirectory.path, action: "sync", target: "/app/src"),
                    ])
                },
            ]
        )
        let dependencies = orchestratorDependencies {
            $0.discoveryManager = discoveryManager
            $0.execManager = execManager
        }

        try await ComposeOrchestrator(
            runner: RecordingRunner(),
            options: ComposeExecutionOptions(
                watchPollInterval: .milliseconds(1),
                sleep: { try await sleeper.sleep($0) }
            ),
            dependencies: dependencies
        ).watch(project: project, options: ComposeWatchOptions(services: ["api"], noUp: true, quiet: true))

        #expect(await execManager.attachedRequests == [
            ContainerAttachedExecRequest(
                id: "demo-api-1",
                command: ["sh", "-c", "rm -rf -- /app/src/main.swift"],
                terminal: .init(interactive: false, tty: false)
            ),
        ])
    }

    @Test("watch rebuilds services and prunes images")
    func watchRebuildsServicesAndPrunesImages() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let sourceFile = directory.appendingPathComponent("Dockerfile")
        try "FROM scratch\n".write(to: sourceFile, atomically: true, encoding: .utf8)

        let runner = RecordingRunner()
        let sleeper = FileMutationSleeper(file: sourceFile, contents: "FROM busybox\n")
        let project = composeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api") {
                    $0.build = ComposeBuild(context: directory.path)
                    $0.develop = ComposeDevelop(watch: [
                        ComposeDevelopWatch(path: sourceFile.path, action: "rebuild"),
                    ])
                },
            ]
        )

        try await ComposeOrchestrator(
            runner: runner,
            options: ComposeExecutionOptions(
                watchPollInterval: .milliseconds(1),
                sleep: { try await sleeper.sleep($0) }
            ),
            discoveryManager: RecordingContainerDiscoveryManager()
        ).watch(project: project, options: ComposeWatchOptions(services: ["api"], noUp: true, quiet: true))

        let commands = runner.commands.map(\.arguments)
        #expect(commands.count == 3)
        #expect(commands[0].containsSequence(["build", "--tag", "demo_api:latest", "--quiet", directory.path]))
        #expect(commands[1].containsSequence(["run", "--name", "demo-api-1"]))
        #expect(commands[2].containsSequence(["image", "prune"]))
    }

    @Test("watch applies provided initial up options")
    func watchAppliesProvidedInitialUpOptions() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let sourceFile = directory.appendingPathComponent("Dockerfile")
        try "FROM scratch\n".write(to: sourceFile, atomically: true, encoding: .utf8)

        let runner = RecordingRunner()
        let sleeper = ThrowingSleeper(throwOnCall: 1)
        let project = composeProject(
            name: "demo",
            services: [
                "api": composeService(name: "api") {
                    $0.build = ComposeBuild(context: directory.path)
                    $0.dependsOn = ["db": ComposeDependency(condition: "service_started")]
                    $0.develop = ComposeDevelop(watch: [
                        ComposeDevelopWatch(path: sourceFile.path, action: "rebuild"),
                    ])
                },
                "db": composeService(name: "db", image: "postgres"),
            ]
        )

        try await ComposeOrchestrator(
            runner: runner,
            options: ComposeExecutionOptions(
                watchPollInterval: .milliseconds(1),
                sleep: { try await sleeper.sleep($0) }
            ),
            discoveryManager: RecordingContainerDiscoveryManager()
        ).watch(
            project: project,
            options: ComposeWatchOptions(
                services: ["api"],
                initialUpOptions: ComposeUpOptions {
                    $0.services = ["api"]
                    $0.noDeps = true
                    $0.build = true
                    $0.quietBuild = true
                    $0.scales = ["api=2"]
                }
            )
        )

        let commands = runner.commands.map(\.arguments)
        #expect(commands.count == 3)
        #expect(commands[0].containsSequence(["build", "--tag", "demo_api:latest", "--quiet", directory.path]))
        #expect(commands[1].containsSequence(["run", "--name", "demo-api-1", "--detach"]))
        #expect(commands[2].containsSequence(["run", "--name", "demo-api-2", "--detach"]))
        #expect(commands.allSatisfy { !$0.contains("demo-db-1") })
    }

    @Test("watch rejects services without develop triggers")
    func watchRejectsServicesWithoutDevelopTriggers() async throws {
        let runner = RecordingRunner()
        let project = ComposeProject(
            name: "demo",
            services: [
                "api": ComposeService(name: "api", image: "example/api"),
            ]
        )

        do {
            try await ComposeOrchestrator(runner: runner).watch(project: project, options: ComposeWatchOptions(services: ["api"]))
            Issue.record("Expected missing watch trigger error")
        } catch let error as ComposeError {
            #expect(error == .invalidProject("selected services does not declare develop.watch triggers"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(runner.commands.isEmpty)
    }

    @Test("watch rejects malformed develop triggers")
    func watchRejectsMalformedDevelopTriggers() async throws {
        let cases: [(trigger: ComposeDevelopWatch, error: ComposeError)] = [
            (
                ComposeDevelopWatch(path: "", action: "rebuild"),
                .invalidProject("service 'api' has a develop.watch trigger without a path")
            ),
            (
                ComposeDevelopWatch(path: "src", action: "sync"),
                .invalidProject("service 'api' develop.watch action 'sync' requires a target")
            ),
            (
                ComposeDevelopWatch(path: "src", action: "sync+exec", target: "/app/src"),
                .invalidProject("service 'api' develop.watch action 'sync+exec' requires exec metadata")
            ),
            (
                ComposeDevelopWatch(path: "src", action: "sync+exec", target: "/app/src", exec: ComposeDevelopWatchExec()),
                .invalidProject("service 'api' develop.watch action 'sync+exec' requires an exec command")
            ),
        ]

        for testCase in cases {
            let runner = RecordingRunner()
            let project = ComposeProject(
                name: "demo",
                services: [
                    "api": composeService(name: "api", image: "example/api") {
                        $0.develop = ComposeDevelop(watch: [testCase.trigger])
                    },
                ]
            )

            do {
                try await ComposeOrchestrator(runner: runner).watch(project: project)
                Issue.record("Expected malformed watch trigger error")
            } catch let error as ComposeError {
                #expect(error == testCase.error)
            } catch {
                Issue.record("Unexpected error: \(error)")
            }

            #expect(runner.commands.isEmpty)
        }
    }

    @Test("attach output-only mode uses the independent runtime relay")
    func attachOutputOnlyModeUsesIndependentRuntimeRelay() async throws {
        let emitted = MessageRecorder()
        let logManager = RecordingContainerLogManager(outputs: ["attached"])
        let attachManager = RecordingContainerAttachManager(outputs: [
            ComposeLogRecord(stream: .stdout, payload: Data("attached".utf8)),
        ])
        let project = ComposeProject(
            name: "demo",
            services: [
                "api": ComposeService(name: "api", image: "example/api"),
            ]
        )

        try await ComposeOrchestrator(
            runner: RecordingRunner(),
            options: ComposeExecutionOptions { $0.emitAttachedData = { emitted.append(String(decoding: $0, as: UTF8.self)) } },
            dependencies: orchestratorDependencies {
                $0.attachManager = attachManager
                $0.discoveryManager = RecordingContainerDiscoveryManager(containers: runtimeServiceContainers())
                $0.logManager = logManager
            }
        ).attach(
            project: project,
            serviceName: "api",
            options: ComposeAttachOptions {
                $0.noStdin = true
                $0.sigProxy = "false"
            }
        )

        #expect(await attachManager.requests == [
            ContainerAttachRequest(id: "demo-api-1", stdout: true, stderr: true, mode: .runningProcess),
        ])
        #expect(await logManager.requests.isEmpty)
        #expect(emitted.messages == ["attached"])
    }

    @Test("attach output-only mode ignores detach keys")
    func attachOutputOnlyModeIgnoresDetachKeys() async throws {
        let emitted = MessageRecorder()
        let logManager = RecordingContainerLogManager(outputs: ["attached"])
        let attachManager = RecordingContainerAttachManager(outputs: [
            ComposeLogRecord(stream: .stdout, payload: Data("attached".utf8)),
        ])
        let project = ComposeProject(
            name: "demo",
            services: [
                "api": ComposeService(name: "api", image: "example/api"),
            ]
        )

        try await ComposeOrchestrator(
            runner: RecordingRunner(),
            options: ComposeExecutionOptions { $0.emitAttachedData = { emitted.append(String(decoding: $0, as: UTF8.self)) } },
            dependencies: orchestratorDependencies {
                $0.attachManager = attachManager
                $0.discoveryManager = RecordingContainerDiscoveryManager(containers: runtimeServiceContainers())
                $0.logManager = logManager
            }
        ).attach(
            project: project,
            serviceName: "api",
            options: ComposeAttachOptions {
                $0.noStdin = true
                $0.detachKeys = "ctrl-x"
                $0.sigProxy = "false"
            }
        )

        #expect(await attachManager.requests == [
            ContainerAttachRequest(id: "demo-api-1", stdout: true, stderr: true, mode: .runningProcess),
        ])
        #expect(await logManager.requests.isEmpty)
        #expect(emitted.messages == ["attached"])
    }

    @Test("attach interactive mode invokes the runtime attach relay")
    func attachInteractiveModeInvokesRuntimeAttachRelay() async throws {
        let runner = RecordingRunner()
        let logManager = RecordingContainerLogManager()
        let project = ComposeProject(
            name: "demo",
            services: [
                "api": ComposeService(name: "api", image: "example/api"),
            ]
        )

        try await ComposeOrchestrator(
            runner: runner,
            options: ComposeExecutionOptions(),
            logManager: logManager
        ).attach(
            project: project,
            serviceName: "api",
            options: ComposeAttachOptions()
        )

        #expect(runner.commands.map(\.arguments) == [["container", "attach", "--sig-proxy=true", "demo-api-1"]])
        #expect(runner.commands.map(\.io) == [.inherited])
        #expect(await logManager.requests.isEmpty)
    }

    @Test("attach interactive mode forwards disabled signal proxy")
    func attachInteractiveModeForwardsDisabledSignalProxy() async throws {
        let runner = RecordingRunner()
        let project = ComposeProject(
            name: "demo",
            services: [
                "api": ComposeService(name: "api", image: "example/api"),
            ]
        )

        try await ComposeOrchestrator(
            runner: runner,
            options: ComposeExecutionOptions(),
            logManager: RecordingContainerLogManager()
        ).attach(
            project: project,
            serviceName: "api",
            options: ComposeAttachOptions { $0.sigProxy = "false" }
        )

        #expect(runner.commands.map(\.arguments) == [["container", "attach", "--sig-proxy=false", "demo-api-1"]])
    }

    @Test("attach interactive mode forwards custom detach keys")
    func attachInteractiveModeForwardsCustomDetachKeys() async throws {
        let runner = RecordingRunner()
        let project = ComposeProject(
            name: "demo",
            services: [
                "api": ComposeService(name: "api", image: "example/api"),
            ]
        )

        try await ComposeOrchestrator(
            runner: runner,
            options: ComposeExecutionOptions(),
            logManager: RecordingContainerLogManager()
        ).attach(
            project: project,
            serviceName: "api",
            options: ComposeAttachOptions { $0.detachKeys = "ctrl-x,x" }
        )

        #expect(runner.commands.map(\.arguments) == [["container", "attach", "--sig-proxy=true", "--detach-keys=ctrl-x,x", "demo-api-1"]])
    }

    @Test("attach output-only mode proxies received signals by default")
    func attachOutputOnlyModeProxiesReceivedSignalsByDefault() async throws {
        let emitted = MessageRecorder()
        let lifecycleManager = RecordingContainerLifecycleManager()
        let logManager = RecordingContainerLogManager(outputs: ["attached"])
        let attachManager = RecordingContainerAttachManager(outputs: [
            ComposeLogRecord(stream: .stdout, payload: Data("attached".utf8)),
        ])
        let signalProxy = RecordingComposeSignalProxy(forwardedSignals: ["SIGINT", "SIGTERM"])
        let project = ComposeProject(
            name: "demo",
            services: [
                "api": ComposeService(name: "api", image: "example/api"),
            ]
        )

        try await ComposeOrchestrator(
            runner: RecordingRunner(),
            options: ComposeExecutionOptions { $0.emitAttachedData = { emitted.append(String(decoding: $0, as: UTF8.self)) } },
            dependencies: orchestratorDependencies {
                $0.attachManager = attachManager
                $0.discoveryManager = RecordingContainerDiscoveryManager(containers: runtimeServiceContainers())
                $0.lifecycleManager = lifecycleManager
                $0.logManager = logManager
                $0.signalProxy = signalProxy
            }
        ).attach(
            project: project,
            serviceName: "api",
            options: ComposeAttachOptions {
                $0.noStdin = true
            }
        )

        #expect(await signalProxy.requests == [
            ["SIGHUP", "SIGINT", "SIGQUIT", "SIGTERM"],
        ])
        #expect(await lifecycleManager.requests == [
            .kill(id: "demo-api-1", signal: "SIGINT"),
            .kill(id: "demo-api-1", signal: "SIGTERM"),
        ])
        #expect(await attachManager.requests == [
            ContainerAttachRequest(id: "demo-api-1", stdout: true, stderr: true, mode: .runningProcess),
        ])
        #expect(await logManager.requests.isEmpty)
        #expect(emitted.messages == ["attached"])
    }

    @Test("attach output-only mode skips signal proxy when disabled")
    func attachOutputOnlyModeSkipsSignalProxyWhenDisabled() async throws {
        let lifecycleManager = RecordingContainerLifecycleManager()
        let logManager = RecordingContainerLogManager(outputs: ["attached"])
        let attachManager = RecordingContainerAttachManager(outputs: [
            ComposeLogRecord(stream: .stdout, payload: Data("attached".utf8)),
        ])
        let signalProxy = RecordingComposeSignalProxy(forwardedSignals: ["SIGINT"])
        let project = ComposeProject(
            name: "demo",
            services: [
                "api": ComposeService(name: "api", image: "example/api"),
            ]
        )

        try await ComposeOrchestrator(
            runner: RecordingRunner(),
            dependencies: orchestratorDependencies {
                $0.attachManager = attachManager
                $0.discoveryManager = RecordingContainerDiscoveryManager(containers: runtimeServiceContainers())
                $0.lifecycleManager = lifecycleManager
                $0.logManager = logManager
                $0.signalProxy = signalProxy
            }
        ).attach(
            project: project,
            serviceName: "api",
            options: ComposeAttachOptions {
                $0.noStdin = true
                $0.sigProxy = "false"
            }
        )

        #expect(await signalProxy.requests.isEmpty)
        #expect(await lifecycleManager.requests.isEmpty)
        #expect(await attachManager.requests == [
            ContainerAttachRequest(id: "demo-api-1", stdout: true, stderr: true, mode: .runningProcess),
        ])
        #expect(await logManager.requests.isEmpty)
    }

    @Test("attach output-only mode targets selected container index")
    func attachOutputOnlyModeTargetsSelectedContainerIndex() async throws {
        let emitted = MessageRecorder()
        let logManager = RecordingContainerLogManager(outputs: ["replica"])
        let attachManager = RecordingContainerAttachManager(outputs: [
            ComposeLogRecord(stream: .stdout, payload: Data("replica".utf8)),
        ])
        let discoveryManager = RecordingContainerDiscoveryManager(containers: [
            ComposeContainerSummary(
                id: "demo-api-2",
                status: "running",
                labels: [
                    composeProjectLabel: "demo",
                    composeServiceLabel: "api",
                ]
            ),
        ])
        let project = ComposeProject(
            name: "demo",
            services: [
                "api": ComposeService(name: "api", image: "example/api"),
            ]
        )

        try await ComposeOrchestrator(
            runner: RecordingRunner(),
            options: ComposeExecutionOptions { $0.emitAttachedData = { emitted.append(String(decoding: $0, as: UTF8.self)) } },
            dependencies: orchestratorDependencies {
                $0.attachManager = attachManager
                $0.discoveryManager = discoveryManager
                $0.logManager = logManager
            }
        ).attach(
            project: project,
            serviceName: "api",
            options: ComposeAttachOptions {
                $0.noStdin = true
                $0.index = 2
                $0.sigProxy = "false"
            }
        )

        #expect(await discoveryManager.listRequests == [true])
        #expect(await attachManager.requests == [
            ContainerAttachRequest(id: "demo-api-2", stdout: true, stderr: true, mode: .runningProcess),
        ])
        #expect(await logManager.requests.isEmpty)
        #expect(emitted.messages == ["replica"])
    }

    @Test("attach dry run emits compose runtime output attach")
    func attachDryRunEmitsComposeRuntimeOutputAttach() async throws {
        let emitted = MessageRecorder()
        let logManager = RecordingContainerLogManager(outputs: ["ignored"])
        let project = ComposeProject(
            name: "demo",
            services: [
                "api": ComposeService(name: "api", image: "example/api"),
            ]
        )

        try await ComposeOrchestrator(
            runner: RecordingRunner(),
            options: ComposeExecutionOptions(dryRun: true, emit: { emitted.append($0) }),
            logManager: logManager
        ).attach(
            project: project,
            serviceName: "api",
            options: ComposeAttachOptions {
                $0.noStdin = true
                $0.sigProxy = "false"
            }
        )

        #expect(emitted.messages == [
            "+ compose-runtime attach --no-stdin demo-api-1",
        ])
        #expect(await logManager.requests.isEmpty)
    }

    @Test("attach dry run emits indexed compose runtime output attach")
    func attachDryRunEmitsIndexedComposeRuntimeOutputAttach() async throws {
        let emitted = MessageRecorder()
        let logManager = RecordingContainerLogManager(outputs: ["ignored"])
        let project = ComposeProject(
            name: "demo",
            services: [
                "api": ComposeService(name: "api", image: "example/api"),
            ]
        )

        try await ComposeOrchestrator(
            runner: RecordingRunner(),
            options: ComposeExecutionOptions(dryRun: true, emit: { emitted.append($0) }),
            logManager: logManager
        ).attach(
            project: project,
            serviceName: "api",
            options: ComposeAttachOptions {
                $0.noStdin = true
                $0.index = 2
                $0.sigProxy = "false"
            }
        )

        #expect(emitted.messages == [
            "+ compose-runtime attach --no-stdin demo-api-2",
        ])
        #expect(await logManager.requests.isEmpty)
    }

    @Test("attach validates signal-proxy before runtime commands")
    func attachValidatesSignalProxyBeforeRuntimeCommands() async throws {
        let cases: [(options: ComposeAttachOptions, error: ComposeError)] = [
            (
                ComposeAttachOptions {
                    $0.noStdin = true
                    $0.sigProxy = "maybe"
                },
                .invalidProject("attach --sig-proxy must be true or false")
            ),
        ]
        let project = ComposeProject(
            name: "demo",
            services: [
                "api": ComposeService(name: "api", image: "example/api"),
            ]
        )

        for testCase in cases {
            let runner = RecordingRunner()
            let logManager = RecordingContainerLogManager()
            do {
                try await ComposeOrchestrator(
                    runner: runner,
                    options: ComposeExecutionOptions(),
                    logManager: logManager
                ).attach(
                    project: project,
                    serviceName: "api",
                    options: testCase.options
                )
                Issue.record("Expected attach option validation error")
            } catch let error as ComposeError {
                #expect(error == testCase.error)
            } catch {
                Issue.record("Unexpected error: \(error)")
            }

            #expect(runner.commands.isEmpty)
            #expect(await logManager.requests.isEmpty)
        }
    }

    @Test("logs rejects invalid tail values before runtime commands")
    func logsRejectsInvalidTailValuesBeforeRuntimeCommands() async throws {
        let runner = RecordingRunner()
        let project = ComposeProject(
            name: "demo",
            services: [
                "api": ComposeService(name: "api", image: "example/api"),
            ]
        )

        do {
            try await ComposeOrchestrator(runner: runner).logs(
                project: project,
                services: ["api"],
                options: ComposeLogsOptions {
                    $0.tail = "latest"
                }
            )
            Issue.record("Expected invalid tail error")
        } catch let error as ComposeError {
            #expect(error == .invalidProject("logs --tail must be 'all' or a non-negative integer"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(runner.commands.isEmpty)
    }

}
