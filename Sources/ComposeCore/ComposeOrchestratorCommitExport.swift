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

public extension ComposeOrchestrator {
    /// Exports an existing service container filesystem as a tar archive.
    func export(
        project: ComposeProject,
        serviceName: String,
        options export: ComposeExportOptions = ComposeExportOptions(),
    ) async throws {
        guard let service = project.services[serviceName] else {
            throw ComposeError.invalidProject("unknown service '\(serviceName)'")
        }

        var args = ["export"]
        if let output = export.output {
            args.append(contentsOf: ["--output", output])
        }
        let containerID = try await serviceContainerID(project: project, service: service, index: export.index)
        args.append(containerID)
        if options.dryRun {
            emitComposeRuntimeOperation(args)
            return
        }
        let live = (try await discoveryManager.getContainer(id: containerID))?.status.lowercased() == "running"
        try await exporter.exportContainer(id: containerID, output: export.output, live: live)
    }

    /// Creates an image from a stopped service container's filesystem.
    func commit(
        project: ComposeProject,
        serviceName: String,
        options commit: ComposeCommitOptions = ComposeCommitOptions(),
    ) async throws {
        guard let service = project.services[serviceName] else {
            throw ComposeError.invalidProject("unknown service '\(serviceName)'")
        }

        let containerID = try await commitContainerID(project: project, service: service, index: commit.index)
        let rootfsArchive = "/tmp/\(containerID)-commit-rootfs.tar"
        let imageArchive = "/tmp/\(containerID)-commit-image.tar"
        if options.dryRun {
            emitComposeRuntimeOperation(["export", "--output", rootfsArchive, containerID])
            emitComposeRuntimeOperation(
                commitArchiveDryRunArguments(
                    rootfsArchive: rootfsArchive,
                    imageArchive: imageArchive,
                    service: service,
                    options: commit,
                ),
            )
            emitComposeRuntimeOperation(["image", "load", "--input", imageArchive])
            return
        }

        guard let container = try await discoveryManager.getContainer(id: containerID) else {
            throw ComposeError.invalidProject("service '\(service.name)' container '\(containerID)' does not exist")
        }
        let live = try commitUsesLiveExport(container, service: service, pause: commit.pause)
        let baseImageMetadata = await commitBaseImageMetadata(project: project, service: service)

        let tempDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString,
            isDirectory: true,
        )
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: tempDirectory)
        }

        let rootfs = tempDirectory.appendingPathComponent("rootfs.tar")
        let archive = tempDirectory.appendingPathComponent("image.tar")
        try await exporter.exportContainer(id: containerID, output: rootfs.path, live: live)
        try ComposeCommitImageArchive.write(
            rootfsArchive: rootfs,
            output: archive,
            service: service,
            options: commit,
            baseImageMetadata: baseImageMetadata,
        )
        try await imageManager.loadImageArchive(archive.path, emit: options.emit)
    }

    /// Resolves the commit target using Docker Compose's `--index=0` default
    /// semantics, where zero means no explicit replica index was selected.
    func commitContainerID(project: ComposeProject, service: ComposeService, index: Int) async throws -> String {
        guard index >= 0 else {
            throw ComposeError.invalidProject("container index must not be negative")
        }
        guard index == 0 else {
            return try await serviceContainerID(project: project, service: service, index: index)
        }
        guard !options.dryRun else {
            return try serviceContainerName(project: project, service: service, index: 1)
        }

        let containers = try await projectContainers(projectName: project.name, all: true)
        let matches = containers
            .filter { $0.serviceName == service.name && !$0.isOneOff }
            .sorted(by: serviceContainerSummaryOrder(project: project, service: service))
        guard let selected = matches.first else {
            throw ComposeError.invalidProject("service '\(service.name)' has no container to commit")
        }
        return selected.id
    }

    /// Returns image config metadata used to seed Docker-compatible commit config when available.
    func commitBaseImageMetadata(project: ComposeProject, service: ComposeService) async -> ComposeImageMetadata? {
        guard let image = serviceImage(project: project, service: service) else {
            return nil
        }
        return try? await imageManager.imageMetadata(image)
    }

    /// Renders the Compose-owned archive creation step for dry-run output.
    func commitArchiveDryRunArguments(
        rootfsArchive: String,
        imageArchive: String,
        service: ComposeService,
        options commit: ComposeCommitOptions,
    ) -> [String] {
        var args = [
            "commit-archive",
            "--rootfs",
            rootfsArchive,
            "--output",
            imageArchive,
            "--service",
            service.name,
        ]
        if let reference = commit.reference {
            args.append(contentsOf: ["--reference", reference])
        }
        if let author = commit.author {
            args.append(contentsOf: ["--author", author])
        }
        if let message = commit.message {
            args.append(contentsOf: ["--message", message])
        }
        for change in commit.changes {
            args.append(contentsOf: ["--change", change])
        }
        if !commit.pause {
            args.append("--no-pause")
        }
        return args
    }

    /// Chooses a stopped-rootfs export or a consistent snapshot for a running service.
    func commitUsesLiveExport(
        _ container: ComposeContainerSummary,
        service: ComposeService,
        pause: Bool,
    ) throws -> Bool {
        switch container.status.lowercased() {
        case "created", "dead", "exited", "stopped":
            return false
        case "running":
            guard pause else {
                throw ComposeError.unsupported(
                    "commit: service '\(service.name)' container '\(container.id)' is running; --pause=false is unavailable because the runtime cannot safely export a writable filesystem without a brief filesystem freeze. Omit --pause=false (the default takes a filesystem-consistent live snapshot) or stop the service container before committing.",
                )
            }
            return true
        default:
            throw ComposeError.unsupported(
                "commit: service '\(service.name)' container '\(container.id)' is \(container.status); only stopped or running containers can be committed with the current runtime",
            )
        }
    }
}
