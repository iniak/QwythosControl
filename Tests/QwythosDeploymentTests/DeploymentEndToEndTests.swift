import Darwin
import Foundation
import QwythosCore
import XCTest
@testable import QwythosDeployment

final class DeploymentEndToEndTests: XCTestCase {
    func testCleanDeploymentReachesHealthyManagedStateAndCompletesLifecycle() async throws {
        let fixture = try DeploymentEndToEndFixture(
            healthResults: [false, true, true, true, true],
            healthPollAttempts: 2
        )
        defer { fixture.cleanUp() }

        let deploymentSnapshots = try await captureSnapshots(
            from: fixture.coordinator
        ) {
            try await fixture.coordinator.deploy(options: fixture.localOptions)
        }

        XCTAssertEqual(deploymentSnapshots.last?.phase, .installed)
        XCTAssertTrue(
            deploymentSnapshots.map(\.phase).contains(.checkingHealth)
        )
        let installedRecord = try XCTUnwrap(
            try fixture.recordStore.load(layout: fixture.layout)
        )
        XCTAssertEqual(installedRecord.accessMode, .local)
        XCTAssertEqual(
            try fixture.hasher.sha256(file: fixture.layout.modelFile),
            fixture.manifest.model.sha256
        )
        XCTAssertTrue(
            FileManager.default.isExecutableFile(
                atPath: fixture.layout.runtimeServer(
                    version: fixture.manifest.runtime.version
                ).path
            )
        )

        guard case .managedHealthy(let inspectedRecord) =
            await fixture.coordinator.inspect()
        else {
            return XCTFail(
                "A completed deployment must be ready for the management menu"
            )
        }
        XCTAssertEqual(inspectedRecord, installedRecord)

        let localArguments = try fixture.installedArguments()
        XCTAssertEqual(
            argumentValue("--host", in: localArguments),
            "127.0.0.1"
        )
        XCTAssertFalse(localArguments.contains("--api-key-file"))
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: fixture.layout.apiKeyFile.path
            )
        )

        let sharedSnapshots = try await captureSnapshots(
            from: fixture.coordinator
        ) {
            try await fixture.coordinator.setAccessMode(.shared)
        }
        let sharedArguments = try fixture.installedArguments()
        let apiKeyFile = argumentValue(
            "--api-key-file",
            in: sharedArguments
        )
        XCTAssertEqual(
            argumentValue("--host", in: sharedArguments),
            "0.0.0.0"
        )
        XCTAssertTrue(sharedArguments.contains("--api-key-file"))
        XCTAssertFalse(
            sharedArguments.contains("0.0.0.0") && apiKeyFile == nil
        )
        XCTAssertEqual(apiKeyFile, fixture.layout.apiKeyFile.path)

        let apiKey = try XCTUnwrap(
            APIKeyStore(fileURL: fixture.layout.apiKeyFile).load()
        )
        XCTAssertEqual(try decodedBase64URL(apiKey).count, 32)
        let apiKeyPermissions = try XCTUnwrap(
            FileManager.default.attributesOfItem(
                atPath: fixture.layout.apiKeyFile.path
            )[.posixPermissions] as? NSNumber
        ).intValue & 0o777
        XCTAssertEqual(apiKeyPermissions, 0o600)

        let plistData = try Data(contentsOf: fixture.launchAgent.plistURL)
        let snapshotText = (deploymentSnapshots + sharedSnapshots)
            .map {
                [
                    $0.statusText,
                    $0.failure?.reason ?? "",
                    $0.failure?.diagnostic ?? "",
                ].joined(separator: "\n")
            }
            .joined(separator: "\n")
        let logText = try fixture.managedLogText()
        let recordText = String(
            decoding: try Data(contentsOf: fixture.layout.deploymentRecord),
            as: UTF8.self
        )
        XCTAssertFalse(String(decoding: plistData, as: UTF8.self).contains(apiKey))
        XCTAssertFalse(snapshotText.contains(apiKey))
        XCTAssertFalse(logText.contains(apiKey))
        XCTAssertFalse(recordText.contains(apiKey))

        try Data("damaged-model".utf8).write(to: fixture.layout.modelFile)
        let modelRequestCount = fixture.modelServer.requests.count
        try await fixture.coordinator.repair()
        XCTAssertEqual(
            try fixture.hasher.sha256(file: fixture.layout.modelFile),
            fixture.manifest.model.sha256
        )
        XCTAssertEqual(
            fixture.modelServer.requests.count,
            modelRequestCount,
            "Repair should reuse the verified retained partial"
        )

        let runtimeInstallCount = fixture.commandRunner.commands.filter {
            $0.arguments == ["--version"]
        }.count
        try await fixture.coordinator.reinstallRuntime()
        XCTAssertEqual(
            fixture.commandRunner.commands.filter {
                $0.arguments == ["--version"]
            }.count,
            runtimeInstallCount + 1
        )
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: fixture.layout.modelFile.path
            )
        )

        try await fixture.coordinator.setAccessMode(.local)
        let restoredLocalArguments = try fixture.installedArguments()
        XCTAssertEqual(
            argumentValue("--host", in: restoredLocalArguments),
            "127.0.0.1"
        )
        XCTAssertFalse(restoredLocalArguments.contains("--api-key-file"))

        assertNoUnsafeCommands(
            fixture.commandRunner.commands,
            managedRoot: fixture.layout.root
        )

        fixture.events.removeAll()
        fixture.files.removeAllDeletedURLs()
        try await fixture.coordinator.uninstall(deleteModel: false)

        XCTAssertEqual(
            fixture.events.values,
            [
                "service.stop",
                "launch-agent.uninstall",
                "files.remove:current",
                "files.remove:api-keys.txt",
                "files.remove:legacy-launch-agent.plist",
                "files.remove:fixture-runtime.tar.gz.partial",
                "files.remove:Qwythos-9B-Claude-Mythos-5-1M-uncensored-heretic-Q4_K_M.gguf.partial",
                "files.remove:llama-server.stdout.log",
                "files.remove:llama-server.stderr.log",
                "files.remove:fixture-b10159",
                "files.prune:versions",
                "files.prune:runtime",
                "files.prune:downloads",
                "files.prune:logs",
                "files.prune:staging",
                "record.remove",
                "files.prune:config",
                "locator.remove",
            ]
        )
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: fixture.layout.modelFile.path
            )
        )
        for directory in [
            fixture.layout.runtimeDirectory,
            fixture.layout.configDirectory,
            fixture.layout.downloadsDirectory,
            fixture.layout.logsDirectory,
            fixture.layout.stagingDirectory,
        ] {
            XCTAssertFalse(
                FileManager.default.fileExists(atPath: directory.path),
                "Empty managed directory should be pruned: \(directory.path)"
            )
        }
        XCTAssertNil(try fixture.locator.load())
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: fixture.launchAgent.plistURL.path
            )
        )
        XCTAssertTrue(
            fixture.files.deletedURLs.allSatisfy {
                (try? fixture.layout.requireManaged($0)) != nil
            }
        )
    }

    func testHealthFailureKeepsResumeStateAndRetryUsesVerifiedPartials() async throws {
        let fixture = try DeploymentEndToEndFixture(
            healthResults: [false, true],
            healthPollAttempts: 1
        )
        defer { fixture.cleanUp() }
        let seededByteCount = 7
        try fixture.seedModelPartial(byteCount: seededByteCount)

        do {
            try await fixture.coordinator.deploy(
                options: fixture.localOptions
            )
            XCTFail("An unhealthy service must fail deployment")
        } catch let error as DeploymentCoordinatorError {
            XCTAssertEqual(error, .healthTimedOut)
        }

        let failedSnapshot = await firstSnapshot(
            from: fixture.coordinator
        )
        XCTAssertEqual(failedSnapshot.phase, .failed)
        XCTAssertEqual(
            failedSnapshot.failure?.recoveryActions,
            [.retry, .viewLogs]
        )
        XCTAssertNil(try fixture.recordStore.load(layout: fixture.layout))
        XCTAssertEqual(
            try fixture.locator.load()?.root,
            fixture.layout.root
        )
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: fixture.layout.modelFile.path
            )
        )
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: fixture.layout.partialFile(
                    for: fixture.manifest.runtime.archive
                ).path
            )
        )
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: fixture.layout.partialFile(
                    for: fixture.manifest.model
                ).path
            )
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: fixture.launchAgent.plistURL.path
            )
        )
        XCTAssertEqual(
            fixture.modelServer.requests.first?.rangeHeader,
            "bytes=\(seededByteCount)-"
        )

        let runtimeRequests = fixture.runtimeServer.requests.count
        let modelRequests = fixture.modelServer.requests.count
        try await fixture.coordinator.deploy(options: fixture.localOptions)

        XCTAssertEqual(fixture.runtimeServer.requests.count, runtimeRequests)
        XCTAssertEqual(fixture.modelServer.requests.count, modelRequests)
        XCTAssertNotNil(
            try fixture.recordStore.load(layout: fixture.layout)
        )
        guard case .managedHealthy =
            await fixture.coordinator.inspect()
        else {
            return XCTFail("Retry must finish in a healthy managed state")
        }
    }

    func testExplicitModelDeletionRemovesOnlyManagedLifecyclePaths() async throws {
        let fixture = try DeploymentEndToEndFixture(
            healthResults: [true],
            healthPollAttempts: 1
        )
        defer { fixture.cleanUp() }
        let unrelatedManagedDirectoryFiles = [
            fixture.layout.configDirectory.appending(path: "user-config.json"),
            fixture.layout.modelsDirectory.appending(path: "user-model.gguf"),
            fixture.layout.runtimeDirectory.appending(path: "user-runtime.txt"),
            fixture.layout.downloadsDirectory.appending(path: "user-download.bin"),
            fixture.layout.logsDirectory.appending(path: "user.log"),
            fixture.layout.stagingDirectory.appending(path: "user-staging.bin"),
        ]
        for file in unrelatedManagedDirectoryFiles {
            try FileManager.default.createDirectory(
                at: file.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data(file.lastPathComponent.utf8).write(to: file)
        }
        try await fixture.coordinator.deploy(options: fixture.localOptions)
        for file in unrelatedManagedDirectoryFiles {
            XCTAssertEqual(
                try Data(contentsOf: file),
                Data(file.lastPathComponent.utf8),
                "Deploy must preserve unknown content at \(file.path)"
            )
        }
        let installationParent = fixture.layout.root.deletingLastPathComponent()
        let unrelated = installationParent.appending(path: "unrelated.txt")
        try Data("preserve".utf8).write(to: unrelated)

        fixture.events.removeAll()
        fixture.files.removeAllDeletedURLs()
        try await fixture.coordinator.uninstall(deleteModel: true)

        XCTAssertEqual(
            fixture.events.values,
            [
                "service.stop",
                "launch-agent.uninstall",
                "files.remove:current",
                "files.remove:api-keys.txt",
                "files.remove:legacy-launch-agent.plist",
                "files.remove:fixture-runtime.tar.gz.partial",
                "files.remove:Qwythos-9B-Claude-Mythos-5-1M-uncensored-heretic-Q4_K_M.gguf.partial",
                "files.remove:llama-server.stdout.log",
                "files.remove:llama-server.stderr.log",
                "files.remove:fixture-b10159",
                "files.remove:Qwythos-9B-Claude-Mythos-5-1M-uncensored-heretic-Q4_K_M.gguf",
                "files.prune:versions",
                "files.prune:runtime",
                "files.prune:downloads",
                "files.prune:logs",
                "files.prune:staging",
                "files.prune:models",
                "record.remove",
                "files.prune:config",
                "locator.remove",
            ]
        )
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: fixture.layout.modelFile.path)
        )
        XCTAssertEqual(try Data(contentsOf: unrelated), Data("preserve".utf8))
        for file in unrelatedManagedDirectoryFiles {
            XCTAssertEqual(
                try Data(contentsOf: file),
                Data(file.lastPathComponent.utf8),
                "Uninstall must preserve unknown content at \(file.path)"
            )
        }
        for directory in [
            fixture.layout.configDirectory,
            fixture.layout.modelsDirectory,
            fixture.layout.runtimeDirectory,
            fixture.layout.downloadsDirectory,
            fixture.layout.logsDirectory,
            fixture.layout.stagingDirectory,
        ] {
            XCTAssertTrue(
                FileManager.default.fileExists(atPath: directory.path),
                "A nonempty selected directory must remain: \(directory.path)"
            )
        }
        XCTAssertTrue(
            fixture.files.deletedURLs.allSatisfy {
                (try? fixture.layout.requireManaged($0)) != nil
            }
        )
        XCTAssertFalse(
            fixture.files.deletedURLs.contains(fixture.layout.root)
        )
    }

    func testOlderRecordedInstallationCanUninstallAndPreserveUnknownContent() async throws {
        try await assertNonCurrentRecordCanUninstall(
            runtimeVersion: "fixture-runtime-older",
            manifestSchemaVersion: 1,
            recordedModel: Data("older recorded model".utf8)
        )
    }

    func testNewerRecordedInstallationCanUninstallAndPreserveUnknownContent() async throws {
        try await assertNonCurrentRecordCanUninstall(
            runtimeVersion: "fixture-runtime-newer",
            manifestSchemaVersion: 2,
            recordedModel: Data("newer recorded model".utf8)
        )
    }

    func testManagedPathValidationIsStableAsTemporaryRootAppears() throws {
        let base = URL(fileURLWithPath: "/private/tmp")
            .appending(path: "Qwythos-layout-\(UUID().uuidString)")
        let layout = InstallationLayout(
            root: base.appending(path: "installation")
        )
        let managed = layout.downloadsDirectory.appending(path: "file.partial")
        defer { try? FileManager.default.removeItem(at: base) }

        XCTAssertNoThrow(try layout.requireManaged(managed))
        try FileManager.default.createDirectory(
            at: layout.downloadsDirectory,
            withIntermediateDirectories: true
        )
        XCTAssertNoThrow(try layout.requireManaged(managed))
        XCTAssertThrowsError(try layout.requireManaged(layout.root))
        XCTAssertThrowsError(
            try layout.requireManaged(base.appending(path: "outside"))
        )
        XCTAssertThrowsError(
            try layout.requireManaged(
                URL(string: "file://example.com\(managed.path)")!
            )
        )
        XCTAssertThrowsError(
            try layout.requireManaged(
                URL(
                    fileURLWithPath: "downloads/file.partial",
                    relativeTo: layout.root
                )
            )
        )
    }

    func testUnsafeCommandDetectionIncludesEnvironmentAndDownloadedScripts() {
        let root = URL(fileURLWithPath: "/private/tmp/managed-fixture")
        let downloadedScript = root.appending(
            path: "downloads/install.py"
        ).path

        XCTAssertNotNil(
            unsafeCommandReason(
                .init(
                    executable: "/usr/bin/env",
                    arguments: ["PATH=/usr/bin:/bin", "sudo", "true"]
                ),
                managedRoot: root
            )
        )
        XCTAssertNotNil(
            unsafeCommandReason(
                .init(
                    executable: "/usr/bin/python3",
                    arguments: [downloadedScript]
                ),
                managedRoot: root
            )
        )
        XCTAssertNil(
            unsafeCommandReason(
                .init(
                    executable: "/usr/bin/tar",
                    arguments: ["-xzf", "/private/tmp/runtime.tar.gz"]
                ),
                managedRoot: root
            )
        )
    }

    func testRuntimeCleanupPersistsIntentBeforeQuarantineRename() throws {
        let fixture = try RuntimeRemovalFixture()
        defer { fixture.cleanUp() }
        let observations = LockedCallLog()
        let files = LiveDeploymentFileManager(
            hasher: SHA256Hasher(),
            beforeDirectoryQuarantine: { _ in
                let tombstone = try RuntimeCleanupTombstoneStore().load(
                    layout: fixture.layout
                )
                if tombstone?.record == fixture.record,
                   FileManager.default.fileExists(
                    atPath: fixture.version.path
                   ),
                   try fixture.quarantineNames().isEmpty {
                    observations.append("durable-intent")
                }
                throw EndToEndFixtureError.injectedRuntimeCleanupFailure
            }
        )

        XCTAssertThrowsError(
            try files.removeManagedRuntimeVersion(
                record: fixture.record,
                layout: fixture.layout
            )
        )
        XCTAssertEqual(observations.values, ["durable-intent"])
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: fixture.version.path)
        )
    }

    func testPostQuarantineFailureRestoresVacantRuntimeForRetry() throws {
        let fixture = try RuntimeRemovalFixture()
        defer { fixture.cleanUp() }
        let originalIdentity = try fixture.versionIdentity()
        let failingFiles = LiveDeploymentFileManager(
            hasher: SHA256Hasher(),
            afterDirectoryQuarantine: { _ in
                throw EndToEndFixtureError.injectedRuntimeCleanupFailure
            }
        )

        XCTAssertThrowsError(
            try failingFiles.removeManagedRuntimeVersion(
                record: fixture.record,
                layout: fixture.layout
            )
        )
        XCTAssertEqual(
            try Data(contentsOf: fixture.managedRuntimeFile),
            Data("managed".utf8)
        )
        XCTAssertEqual(try fixture.versionIdentity(), originalIdentity)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: fixture.layout.runtimeCleanupTombstone.path
            )
        )

        let retryFiles = LiveDeploymentFileManager(
            hasher: SHA256Hasher()
        )
        try retryFiles.removeManagedRuntimeVersion(
            record: fixture.record,
            layout: fixture.layout
        )
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: fixture.version.path)
        )
        try retryFiles.finalizeManagedRuntimeCleanup(
            layout: fixture.layout
        )
    }

    func testPostQuarantineReplacementUsesTombstoneForSafeRetry() throws {
        let fixture = try RuntimeRemovalFixture()
        defer { fixture.cleanUp() }
        let failingFiles = LiveDeploymentFileManager(
            hasher: SHA256Hasher(),
            afterDirectoryQuarantine: { _ in
                try fixture.installReplacement()
                throw EndToEndFixtureError.injectedRuntimeCleanupFailure
            }
        )

        XCTAssertThrowsError(
            try failingFiles.removeManagedRuntimeVersion(
                record: fixture.record,
                layout: fixture.layout
            )
        )
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: fixture.layout.runtimeCleanupTombstone.path
            )
        )
        let tombstone = try XCTUnwrap(
            RuntimeCleanupTombstoneStore().load(layout: fixture.layout)
        )
        XCTAssertEqual(tombstone.record, fixture.record)
        XCTAssertEqual(
            tombstone.quarantineName,
            try XCTUnwrap(fixture.quarantineNames().first)
        )

        try LiveDeploymentFileManager(
            hasher: SHA256Hasher()
        ).removeManagedRuntimeVersion(
            record: fixture.record,
            layout: fixture.layout
        )

        XCTAssertEqual(
            try Data(contentsOf: fixture.replacementFile),
            Data("unrelated-replacement".utf8)
        )
        XCTAssertTrue(try fixture.quarantineNames().isEmpty)
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: fixture.layout.runtimeCleanupTombstone.path
            )
        )
        try LiveDeploymentFileManager(
            hasher: SHA256Hasher()
        ).removeManagedRuntimeVersion(
            record: fixture.record,
            layout: fixture.layout
        )
        XCTAssertEqual(
            try Data(contentsOf: fixture.replacementFile),
            Data("unrelated-replacement".utf8)
        )
        try LiveDeploymentFileManager(
            hasher: SHA256Hasher()
        ).finalizeManagedRuntimeCleanup(layout: fixture.layout)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: fixture.layout.runtimeCleanupTombstone.path
            )
        )
        XCTAssertTrue(try fixture.quarantineNames().isEmpty)
    }

    func testRuntimeCleanupTombstoneMismatchFailsClosed() throws {
        let fixture = try RuntimeRemovalFixture()
        defer { fixture.cleanUp() }
        let failingFiles = LiveDeploymentFileManager(
            hasher: SHA256Hasher(),
            afterDirectoryQuarantine: { _ in
                try fixture.installReplacement()
                throw EndToEndFixtureError.injectedRuntimeCleanupFailure
            }
        )
        XCTAssertThrowsError(
            try failingFiles.removeManagedRuntimeVersion(
                record: fixture.record,
                layout: fixture.layout
            )
        )
        let quarantineName = try XCTUnwrap(
            fixture.quarantineNames().first
        )
        let quarantine = fixture.layout.runtimeVersionsDirectory.appending(
            path: quarantineName
        )
        try FileManager.default.removeItem(at: quarantine)
        try FileManager.default.createDirectory(
            at: quarantine,
            withIntermediateDirectories: true
        )
        let mismatch = quarantine.appending(path: "unrelated.txt")
        try Data("preserve-mismatch".utf8).write(to: mismatch)

        XCTAssertThrowsError(
            try LiveDeploymentFileManager(
                hasher: SHA256Hasher()
            ).removeManagedRuntimeVersion(
                record: fixture.record,
                layout: fixture.layout
            )
        ) { error in
            XCTAssertEqual(
                error as? POSIXTransactionError,
                .ownershipChanged
            )
        }
        XCTAssertEqual(
            try Data(contentsOf: mismatch),
            Data("preserve-mismatch".utf8)
        )
        XCTAssertEqual(
            try Data(contentsOf: fixture.replacementFile),
            Data("unrelated-replacement".utf8)
        )
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: fixture.layout.runtimeCleanupTombstone.path
            )
        )
    }

    private func captureSnapshots(
        from coordinator: DeploymentCoordinator,
        operation: @escaping @Sendable () async throws -> Void
    ) async throws -> [DeploymentSnapshot] {
        let stream = await coordinator.snapshots()
        let collector = Task { () -> [DeploymentSnapshot] in
            var iterator = stream.makeAsyncIterator()
            _ = await iterator.next()
            var snapshots: [DeploymentSnapshot] = []
            while let snapshot = await iterator.next() {
                snapshots.append(snapshot)
                if snapshot.phase == .installed
                    || snapshot.phase == .failed
                    || snapshot.phase == .paused {
                    break
                }
            }
            return snapshots
        }
        do {
            try await operation()
            return await collector.value
        } catch {
            _ = await collector.value
            throw error
        }
    }

    private func assertNonCurrentRecordCanUninstall(
        runtimeVersion: String,
        manifestSchemaVersion: Int,
        recordedModel: Data
    ) async throws {
        let fixture = try DeploymentEndToEndFixture(
            healthResults: [true],
            healthPollAttempts: 1
        )
        defer { fixture.cleanUp() }
        try await fixture.coordinator.deploy(options: fixture.localOptions)
        try recordedModel.write(to: fixture.layout.modelFile)
        try fixture.replaceInstalledRecord(
            runtimeVersion: runtimeVersion,
            manifestSchemaVersion: manifestSchemaVersion,
            modelSHA256: try fixture.hasher.sha256(file: fixture.layout.modelFile)
        )

        let unknownFiles = [
            fixture.layout.configDirectory.appending(path: "keep.config"),
            fixture.layout.modelsDirectory.appending(path: "keep.model"),
            fixture.layout.runtimeDirectory.appending(path: "keep.runtime"),
            fixture.layout.downloadsDirectory.appending(path: "keep.download"),
            fixture.layout.logsDirectory.appending(path: "keep.log"),
            fixture.layout.stagingDirectory.appending(path: "keep.staging"),
        ]
        for file in unknownFiles {
            try FileManager.default.createDirectory(
                at: file.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data("preserve".utf8).write(to: file)
        }

        try await fixture.coordinator.uninstall(deleteModel: true)

        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: fixture.layout.runtimeVersion(runtimeVersion).path
            )
        )
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: fixture.layout.modelFile.path)
        )
        for file in unknownFiles {
            XCTAssertEqual(try Data(contentsOf: file), Data("preserve".utf8))
        }
        XCTAssertNil(try fixture.recordStore.load(layout: fixture.layout))
        XCTAssertNil(try fixture.locator.load())
    }

    private func firstSnapshot(
        from coordinator: DeploymentCoordinator
    ) async -> DeploymentSnapshot {
        let stream = await coordinator.snapshots()
        var iterator = stream.makeAsyncIterator()
        return await iterator.next()!
    }

    private func argumentValue(
        _ flag: String,
        in arguments: [String]
    ) -> String? {
        guard let index = arguments.firstIndex(of: flag),
              index + 1 < arguments.count else {
            return nil
        }
        return arguments[index + 1]
    }

    private func decodedBase64URL(_ value: String) throws -> Data {
        let base64 = value
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let padding = String(
            repeating: "=",
            count: (4 - base64.count % 4) % 4
        )
        guard let decoded = Data(base64Encoded: base64 + padding) else {
            throw EndToEndFixtureError.invalidBase64URL
        }
        return decoded
    }

    private func assertNoUnsafeCommands(
        _ commands: [FixtureCommandRunner.Command],
        managedRoot: URL,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        for command in commands {
            XCTAssertNil(
                unsafeCommandReason(command, managedRoot: managedRoot),
                "Unsafe command: \(command.executable) \(command.arguments)",
                file: file,
                line: line
            )
        }
    }

    private func unsafeCommandReason(
        _ command: FixtureCommandRunner.Command,
        managedRoot: URL
    ) -> String? {
        let invocation = effectiveInvocation(command)
        let executable = invocation.executable.lowercased()
        let executableName = URL(
            fileURLWithPath: executable
        ).lastPathComponent
        let arguments = invocation.arguments.map { $0.lowercased() }
        let shellNames = ["sh", "bash", "zsh"]
        let interpreterNames = Set(
            shellNames + [
                "node", "osascript", "perl", "python", "python3", "ruby",
            ]
        )
        let downloadsPath = managedRoot
            .appending(path: "downloads")
            .path
            .lowercased() + "/"

        if executableName == "sudo" {
            return "sudo invocation"
        }
        if executableName == "brew"
            || arguments.contains(where: {
                URL(fileURLWithPath: $0).lastPathComponent == "brew"
            }) {
            return "Homebrew invocation"
        }
        if shellNames.contains(executableName) {
            return "shell invocation"
        }
        if executable.hasPrefix(downloadsPath) {
            return "downloaded executable"
        }
        if interpreterNames.contains(executableName),
           arguments.contains(where: { $0.hasPrefix(downloadsPath) }) {
            return "downloaded interpreter input"
        }
        return nil
    }

    private func effectiveInvocation(
        _ command: FixtureCommandRunner.Command
    ) -> (executable: String, arguments: [String]) {
        guard URL(
            fileURLWithPath: command.executable
        ).lastPathComponent == "env" else {
            return (command.executable, command.arguments)
        }

        var index = 0
        while index < command.arguments.count {
            let argument = command.arguments[index]
            if argument.contains("=") && !argument.hasPrefix("=") {
                index += 1
                continue
            }
            if argument == "-i" || argument == "--ignore-environment" {
                index += 1
                continue
            }
            if argument == "-u" || argument == "--unset" {
                index += 2
                continue
            }
            break
        }
        guard index < command.arguments.count else {
            return (command.executable, command.arguments)
        }
        return (
            command.arguments[index],
            Array(command.arguments.dropFirst(index + 1))
        )
    }
}

private enum EndToEndFixtureError: Error {
    case archiveCreationFailed(Int32)
    case injectedRuntimeCleanupFailure
    case invalidBase64URL
    case invalidPlist
}

private final class RuntimeRemovalFixture: @unchecked Sendable {
    let base: URL
    let layout: InstallationLayout
    let record: InstallationRecord

    var version: URL {
        layout.runtimeVersion(record.runtimeVersion)
    }

    var managedRuntimeFile: URL {
        version.appending(path: "nested/llama-server")
    }

    var replacementFile: URL {
        version.appending(path: "replacement.txt")
    }

    init() throws {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        base = packageRoot
            .appending(path: ".build/runtime-removal-race-tests")
            .appending(path: UUID().uuidString)
        layout = InstallationLayout(
            root: base.appending(path: "installation")
        )
        record = InstallationRecord(
            manifestSchemaVersion: 1,
            root: layout.root,
            runtimeVersion: "fixture-runtime",
            modelSHA256: String(repeating: "a", count: 64),
            contextSize: 8_192,
            accessMode: .local,
            installedAt: Date(timeIntervalSince1970: 1)
        )
        try FileManager.default.createDirectory(
            at: layout.configDirectory,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: managedRuntimeFile.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("managed".utf8).write(to: managedRuntimeFile)
    }

    func installReplacement() throws {
        try FileManager.default.createDirectory(
            at: version,
            withIntermediateDirectories: true
        )
        try Data("unrelated-replacement".utf8).write(to: replacementFile)
    }

    func quarantineNames() throws -> [String] {
        let contents = try FileManager.default.contentsOfDirectory(
            at: layout.runtimeVersionsDirectory,
            includingPropertiesForKeys: nil
        )
        return contents.map(\.lastPathComponent).filter {
            $0.hasPrefix(RuntimeCleanupTombstone.quarantinePrefix)
        }
    }

    func versionIdentity() throws -> POSIXFileIdentity {
        var metadata = stat()
        guard lstat(version.path, &metadata) == 0 else {
            throw POSIXTransactionError.operationFailed(errno)
        }
        return POSIXFileIdentity(metadata)
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: base)
    }
}

private final class DeploymentEndToEndFixture: @unchecked Sendable {
    let base: URL
    let layout: InstallationLayout
    let localOptions: DeploymentOptions
    let manifest: DeploymentManifest
    let runtimeServer: RangeHTTPServer
    let modelServer: RangeHTTPServer
    let coordinator: DeploymentCoordinator
    let hasher = SHA256Hasher()
    let events: FixtureEventLog
    let commandRunner: FixtureCommandRunner
    let locator: RecordingInstallationLocator
    let recordStore: RecordingInstallationRecordStore
    let launchAgent: RecordingLaunchAgentInstaller
    let files: RecordingDeploymentFileManager

    private let modelPayload: Data

    init(
        healthResults: [Bool],
        healthPollAttempts: Int
    ) throws {
        let fileManager = FileManager.default
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let base = packageRoot
            .appending(path: ".build/deployment-end-to-end-tests")
            .appending(path: UUID().uuidString)
        try fileManager.createDirectory(
            at: base,
            withIntermediateDirectories: true
        )
        let root = base.appending(path: "installation")
        let layout = InstallationLayout(root: root)
        let archive = try Self.makeRuntimeArchive(in: base)
        let runtimePayload = try Data(contentsOf: archive)
        let modelPayload = Data(
            "GGUF fixture model payload for deployment acceptance".utf8
        )
        let hasher = SHA256Hasher()
        let runtimeDigest = try hasher.sha256(file: archive)
        let modelDigest = try Self.sha256(modelPayload, in: base)
        let runtimeServer = try RangeHTTPServer(payload: runtimePayload)
        let modelServer = try RangeHTTPServer(payload: modelPayload)
        do {
            try runtimeServer.start()
            try modelServer.start()
        } catch {
            runtimeServer.stop()
            modelServer.stop()
            try? fileManager.removeItem(at: base)
            throw error
        }

        let manifest = DeploymentManifest(
            schemaVersion: 1,
            runtime: RuntimeArtifact(
                version: "fixture-b10159",
                archive: DeploymentArtifact(
                    filename: "fixture-runtime.tar.gz",
                    sourceURL: runtimeServer.url,
                    size: Int64(runtimePayload.count),
                    sha256: runtimeDigest
                ),
                directoryName: "fixture-runtime",
                serverRelativePath: "llama-server"
            ),
            model: DeploymentArtifact(
                filename: InstallationLayout.modelFilename,
                sourceURL: modelServer.url,
                size: Int64(modelPayload.count),
                sha256: modelDigest
            ),
            service: ServiceDefaults(
                label: LaunchAgentInstaller.defaultLabel,
                port: 18_080
            )
        )

        let events = FixtureEventLog()
        let commandRunner = FixtureCommandRunner()
        let locator = RecordingInstallationLocator(
            delegate: InstallationLocator(
                supportDirectory: base.appending(path: "app-support")
            ),
            events: events
        )
        let recordStore = RecordingInstallationRecordStore(
            delegate: InstallationRecordStore(),
            events: events
        )
        let launchAgent = RecordingLaunchAgentInstaller(
            delegate: LaunchAgentInstaller(
                launchAgentsDirectory: base.appending(path: "LaunchAgents")
            ),
            events: events
        )
        let files = RecordingDeploymentFileManager(
            delegate: LiveDeploymentFileManager(hasher: hasher),
            events: events
        )
        let service = RecordingManagedService(
            logURL: layout.logsDirectory.appending(
                path: "llama-server.stdout.log"
            ),
            events: events
        )
        let healthChecker = FixtureHealthChecker(
            results: healthResults,
            events: events
        )

        self.base = base
        self.layout = layout
        self.localOptions = DeploymentOptions(
            root: root,
            contextSize: 8_192,
            accessMode: .local
        )
        self.manifest = manifest
        self.runtimeServer = runtimeServer
        self.modelServer = modelServer
        self.modelPayload = modelPayload
        self.events = events
        self.commandRunner = commandRunner
        self.locator = locator
        self.recordStore = recordStore
        self.launchAgent = launchAgent
        self.files = files
        self.coordinator = DeploymentCoordinator(
            manifest: manifest,
            locator: locator,
            preflight: .passingFixture,
            downloader: ResumableDownloader(hasher: hasher),
            hasher: hasher,
            runtimeInstaller: RuntimeInstaller(commandRunner: commandRunner),
            launchAgentInstaller: launchAgent,
            inspectorFactory: { inspectedLayout in
                InstallationInspector(
                    layout: inspectedLayout,
                    manifest: manifest,
                    records: recordStore,
                    hasher: hasher,
                    launchAgentsDirectory: launchAgent.delegate.launchAgentsDirectory,
                    healthChecker: HealthyInstallationChecker(),
                    serviceChecker: LoadedInstallationServiceChecker()
                )
            },
            migratorFactory: { _ in FakeLegacyMigrator() },
            recordStore: recordStore,
            service: service,
            healthChecker: healthChecker,
            files: files,
            sleeper: ImmediateDeploymentSleeper(),
            healthPollAttempts: healthPollAttempts
        )
    }

    func installedArguments() throws -> [String] {
        let data = try Data(contentsOf: launchAgent.plistURL)
        guard let plist = try PropertyListSerialization.propertyList(
            from: data,
            format: nil
        ) as? [String: Any],
              let arguments = plist["ProgramArguments"] as? [String] else {
            throw EndToEndFixtureError.invalidPlist
        }
        return arguments
    }

    func seedModelPartial(byteCount: Int) throws {
        try FileManager.default.createDirectory(
            at: layout.downloadsDirectory,
            withIntermediateDirectories: true
        )
        try Data(modelPayload.prefix(byteCount)).write(
            to: layout.partialFile(for: manifest.model)
        )
    }

    func managedLogText() throws -> String {
        let files = try FileManager.default.contentsOfDirectory(
            at: layout.logsDirectory,
            includingPropertiesForKeys: nil
        )
        return try files.map {
            String(decoding: try Data(contentsOf: $0), as: UTF8.self)
        }.joined(separator: "\n")
    }

    func replaceInstalledRecord(
        runtimeVersion: String,
        manifestSchemaVersion: Int,
        modelSHA256: String
    ) throws {
        let existing = try recordStore.load(layout: layout)
        let currentRecord = try XCTUnwrap(existing)
        let oldRuntime = layout.runtimeVersion(currentRecord.runtimeVersion)
        let replacementRuntime = layout.runtimeVersion(runtimeVersion)
        try FileManager.default.moveItem(
            at: oldRuntime,
            to: replacementRuntime
        )
        try FileManager.default.removeItem(at: layout.runtimeCurrent)
        try FileManager.default.createSymbolicLink(
            at: layout.runtimeCurrent,
            withDestinationURL: replacementRuntime
        )
        try recordStore.save(
            InstallationRecord(
                manifestSchemaVersion: manifestSchemaVersion,
                root: layout.root,
                runtimeVersion: runtimeVersion,
                modelSHA256: modelSHA256,
                contextSize: currentRecord.contextSize,
                accessMode: currentRecord.accessMode,
                installedAt: currentRecord.installedAt
            ),
            layout: layout
        )
    }

    func cleanUp() {
        runtimeServer.stop()
        modelServer.stop()
        try? FileManager.default.removeItem(at: base)
    }

    private static func makeRuntimeArchive(in base: URL) throws -> URL {
        let source = base.appending(path: "runtime-archive-source")
        let runtime = source.appending(path: "fixture-runtime")
        try FileManager.default.createDirectory(
            at: runtime,
            withIntermediateDirectories: true
        )
        let server = runtime.appending(path: "llama-server")
        try machO(withRPath: true).write(to: server)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: server.path
        )
        try machO(withRPath: false).write(
            to: runtime.appending(path: "libllama.dylib")
        )

        let archive = base.appending(path: "runtime-fixture.tar.gz")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        process.arguments = [
            "--format",
            "ustar",
            "-czf",
            archive.path,
            "-C",
            source.path,
            runtime.lastPathComponent,
        ]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw EndToEndFixtureError.archiveCreationFailed(
                process.terminationStatus
            )
        }
        return archive
    }

    private static func machO(withRPath: Bool) -> Data {
        var data = Data()
        func append(_ value: UInt32) {
            var littleEndian = value.littleEndian
            withUnsafeBytes(of: &littleEndian) {
                data.append(contentsOf: $0)
            }
        }
        append(0xFEED_FACF)
        append(0x0100_000C)
        append(0)
        append(2)
        append(withRPath ? 1 : 0)
        append(withRPath ? 28 : 0)
        append(0)
        append(0)
        if withRPath {
            append(0x8000_001C)
            append(28)
            append(12)
            data.append(contentsOf: "@loader_path\0".utf8)
            data.append(contentsOf: repeatElement(0, count: 4))
        }
        return data
    }

    private static func sha256(_ data: Data, in base: URL) throws -> String {
        let file = base.appending(path: "model-payload.gguf")
        try data.write(to: file)
        return try SHA256Hasher().sha256(file: file)
    }
}

private final class FixtureEventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []

    var values: [String] {
        lock.withLock { storage }
    }

    func append(_ value: String) {
        lock.withLock { storage.append(value) }
    }

    func removeAll() {
        lock.withLock { storage.removeAll() }
    }
}

private final class FixtureCommandRunner: CommandRunning, @unchecked Sendable {
    struct Command: Equatable, Sendable {
        let executable: String
        let arguments: [String]
    }

    private let lock = NSLock()
    private var storage: [Command] = []

    var commands: [Command] {
        lock.withLock { storage }
    }

    func run(_ command: LaunchCommand) async -> CommandResult {
        lock.withLock {
            storage.append(
                Command(
                    executable: command.executable,
                    arguments: command.arguments
                )
            )
        }
        if command.executable == "/usr/bin/otool" {
            let serverPath = command.arguments.last ?? "llama-server"
            return CommandResult(
                exitCode: 0,
                output: """
                \(serverPath):
                \t@rpath/libllama.dylib (compatibility version 0.0.0, current version 0.0.0)
                """
            )
        }
        if command.arguments == ["--version"] {
            return CommandResult(exitCode: 0, output: "fixture-b10159")
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: command.executable)
        process.arguments = command.arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        do {
            try process.run()
        } catch {
            return CommandResult(
                exitCode: -1,
                output: error.localizedDescription
            )
        }
        process.waitUntilExit()
        return CommandResult(
            exitCode: process.terminationStatus,
            output: String(
                decoding: output.fileHandleForReading.readDataToEndOfFile(),
                as: UTF8.self
            )
        )
    }
}

private struct RecordingInstallationLocator:
    InstallationLocating,
    Sendable
{
    let delegate: InstallationLocator
    let events: FixtureEventLog

    func load() throws -> InstallationLocation? {
        try delegate.load()
    }

    func save(_ location: InstallationLocation) throws {
        try delegate.save(location)
        events.append("locator.save")
    }

    func remove() throws {
        try delegate.remove()
        events.append("locator.remove")
    }
}

private struct RecordingInstallationRecordStore:
    InstallationRecordStoring,
    Sendable
{
    let delegate: InstallationRecordStore
    let events: FixtureEventLog

    func load(layout: InstallationLayout) throws -> InstallationRecord? {
        try delegate.load(layout: layout)
    }

    func save(
        _ record: InstallationRecord,
        layout: InstallationLayout
    ) throws {
        try delegate.save(record, layout: layout)
        events.append("record.save")
    }

    func remove(layout: InstallationLayout) throws {
        try delegate.remove(layout: layout)
        events.append("record.remove")
    }

    func remove(
        ifMatching expectedRecord: InstallationRecord,
        layout: InstallationLayout
    ) throws -> Bool {
        let removed = try delegate.remove(
            ifMatching: expectedRecord,
            layout: layout
        )
        if removed {
            events.append("record.remove")
        }
        return removed
    }
}

private struct RecordingLaunchAgentInstaller:
    LaunchAgentInstalling,
    Sendable
{
    let delegate: LaunchAgentInstaller
    let events: FixtureEventLog

    var plistURL: URL { delegate.plistURL }

    func install(
        layout: InstallationLayout,
        options: DeploymentOptions,
        manifest: DeploymentManifest
    ) throws {
        try delegate.install(
            layout: layout,
            options: options,
            manifest: manifest
        )
        events.append("launch-agent.install:\(options.accessMode.rawValue)")
    }

    func restoreLegacyPlist(layout: InstallationLayout) throws {
        try delegate.restoreLegacyPlist(layout: layout)
        events.append("launch-agent.restore")
    }

    func uninstall() throws {
        try delegate.uninstall()
        events.append("launch-agent.uninstall")
    }

    func regenerateAPIKey(
        layout: InstallationLayout
    ) throws -> String {
        try delegate.regenerateAPIKey(layout: layout)
    }

    func captureInstallationState(
        layout: InstallationLayout
    ) throws -> LaunchAgentInstallationState {
        try delegate.captureInstallationState(layout: layout)
    }

    func restoreInstallationState(
        _ state: LaunchAgentInstallationState,
        layout: InstallationLayout
    ) throws {
        try delegate.restoreInstallationState(state, layout: layout)
    }

    func restoreAPIKeyState(
        _ state: LaunchAgentInstallationState,
        layout: InstallationLayout
    ) throws {
        try delegate.restoreAPIKeyState(state, layout: layout)
    }

    func restorePlistState(
        _ state: LaunchAgentInstallationState,
        layout: InstallationLayout
    ) throws {
        try delegate.restorePlistState(state, layout: layout)
    }
}

private final class RecordingDeploymentFileManager:
    DeploymentFileManaging,
    @unchecked Sendable
{
    let delegate: LiveDeploymentFileManager
    let events: FixtureEventLog
    private let lock = NSLock()
    private var storage: [URL] = []

    init(
        delegate: LiveDeploymentFileManager,
        events: FixtureEventLog
    ) {
        self.delegate = delegate
        self.events = events
    }

    var deletedURLs: [URL] {
        lock.withLock { storage }
    }

    func promoteModel(
        from source: URL,
        layout: InstallationLayout,
        expectedSHA256: String
    ) throws {
        try delegate.promoteModel(
            from: source,
            layout: layout,
            expectedSHA256: expectedSHA256
        )
    }

    func removeManagedItem(
        _ url: URL,
        layout: InstallationLayout,
        kind: ManagedRemovalKind
    ) throws {
        lock.withLock { storage.append(url.standardizedFileURL) }
        let operation = kind == .emptyDirectory ? "prune" : "remove"
        events.append("files.\(operation):\(url.lastPathComponent)")
        try delegate.removeManagedItem(url, layout: layout, kind: kind)
    }

    func removeManagedRuntimeVersion(
        record: InstallationRecord,
        layout: InstallationLayout
    ) throws {
        let url = layout.runtimeVersion(record.runtimeVersion)
        lock.withLock { storage.append(url.standardizedFileURL) }
        events.append("files.remove:\(url.lastPathComponent)")
        try delegate.removeManagedRuntimeVersion(
            record: record,
            layout: layout
        )
    }

    func finalizeManagedRuntimeCleanup(
        layout: InstallationLayout
    ) throws {
        try delegate.finalizeManagedRuntimeCleanup(layout: layout)
    }

    func managedModelMatches(
        layout: InstallationLayout,
        expectedSHA256: String
    ) throws -> Bool {
        try delegate.managedModelMatches(
            layout: layout,
            expectedSHA256: expectedSHA256
        )
    }

    func removeManagedModel(
        layout: InstallationLayout,
        expectedSHA256: String
    ) throws {
        lock.withLock { storage.append(layout.modelFile.standardizedFileURL) }
        events.append("files.remove:\(layout.modelFile.lastPathComponent)")
        try delegate.removeManagedModel(
            layout: layout,
            expectedSHA256: expectedSHA256
        )
    }

    func removeAllDeletedURLs() {
        lock.withLock { storage.removeAll() }
    }
}

private final class RecordingManagedService:
    ManagedServiceControlling,
    @unchecked Sendable
{
    private let logURL: URL
    private let events: FixtureEventLog
    private let lock = NSLock()
    private var running = false
    private var logLines: [String] = []

    init(logURL: URL, events: FixtureEventLog) {
        self.logURL = logURL
        self.events = events
    }

    func start() async throws {
        try record("service.start")
        lock.withLock { running = true }
    }

    func stop() async throws {
        try record("service.stop")
        lock.withLock { running = false }
    }

    func isRunning() async -> Bool {
        lock.withLock { running }
    }

    private func record(_ value: String) throws {
        events.append(value)
        try lock.withLock {
            logLines.append(value)
            try FileManager.default.createDirectory(
                at: logURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data((logLines.joined(separator: "\n") + "\n").utf8)
                .write(to: logURL, options: .atomic)
        }
    }
}

private final class FixtureHealthChecker:
    HealthChecking,
    @unchecked Sendable
{
    private let lock = NSLock()
    private var results: [Bool]
    private let events: FixtureEventLog

    init(results: [Bool], events: FixtureEventLog) {
        self.results = results
        self.events = events
    }

    func isHealthy(_ url: URL) async -> Bool {
        let result = lock.withLock {
            results.isEmpty ? true : results.removeFirst()
        }
        events.append("health.\(result ? "healthy" : "waiting")")
        return result
    }
}

private struct HealthyInstallationChecker:
    InstallationHealthChecking,
    Sendable
{
    func isHealthy(_ url: URL) async -> Bool { true }
}

private struct LoadedInstallationServiceChecker:
    InstallationServiceChecking,
    Sendable
{
    func isLoaded(label: String) async -> Bool { true }
}
