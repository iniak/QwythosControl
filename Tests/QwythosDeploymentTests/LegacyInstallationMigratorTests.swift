import Darwin
import Foundation
import XCTest
@testable import QwythosDeployment
@testable import QwythosCore

final class LegacyInstallationMigratorTests: XCTestCase {
    func testReusesVerifiedDigestNamedCacheBlobWithoutDeletingSource() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appending(path: "cache/blobs")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let payload = Data("verified model".utf8)
        let digest = hash(of: payload)
        let blob = source.appending(path: digest)
        try payload.write(to: blob)
        let layout = InstallationLayout(root: root.appending(path: "managed"))
        try FileManager.default.createDirectory(at: layout.root, withIntermediateDirectories: true)

        let locator = LegacyModelLocator(cacheRoots: [source.deletingLastPathComponent()])
        let candidate = try XCTUnwrap(locator.locate(modelSHA256: digest))
        let result = try ModelReuser().reuse(candidate, at: layout.modelFile, expectedSHA256: digest)

        XCTAssertEqual(result, .reused)
        XCTAssertEqual(try Data(contentsOf: layout.modelFile), payload)
        XCTAssertTrue(FileManager.default.fileExists(atPath: blob.path))
        XCTAssertEqual(try SHA256Hasher().sha256(file: layout.modelFile), digest)
    }

    func testModelReuseRejectsRelativeDestinationWithoutMutation() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appending(path: "source.gguf")
        let payload = Data("relative destination model".utf8)
        try payload.write(to: source)
        let managedRoot = root.appending(path: "managed")
        try FileManager.default.createDirectory(
            at: managedRoot,
            withIntermediateDirectories: true
        )
        let base = URL(fileURLWithPath: root.path, isDirectory: true)
        let relativeDestination = URL(
            fileURLWithPath:
                "managed/models/\(InstallationLayout.modelFilename)",
            relativeTo: base
        )
        let resolvedDestination = InstallationLayout(
            root: managedRoot
        ).modelFile
        XCTAssertEqual(
            relativeDestination.standardizedFileURL.path,
            resolvedDestination.path
        )

        XCTAssertThrowsError(
            try ModelReuser().reuse(
                source,
                at: relativeDestination,
                expectedSHA256: hash(of: payload)
            )
        )

        XCTAssertFalse(
            FileManager.default.fileExists(atPath: resolvedDestination.path)
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: managedRoot.appending(path: "staging").path
            )
        )
    }

    func testCloneHardLinkAndCopyStrategiesReuseAndValidateTheModel() throws {
        for strategy in ModelReuser.StagingStrategy.allCases {
            let root = try makeRoot()
            defer { try? FileManager.default.removeItem(at: root) }
            let source = root.appending(path: "source.gguf")
            let payload = Data("model via \(strategy)".utf8)
            try payload.write(to: source)
            let digest = hash(of: payload)
            let layout = InstallationLayout(root: root.appending(path: "managed"))
            try FileManager.default.createDirectory(
                at: layout.root,
                withIntermediateDirectories: true
            )

            let result = try ModelReuser(strategy: strategy).reuse(
                source,
                at: layout.modelFile,
                expectedSHA256: digest
            )

            XCTAssertEqual(result, .reused, "\(strategy)")
            XCTAssertEqual(try Data(contentsOf: source), payload, "\(strategy)")
            XCTAssertEqual(
                try SHA256Hasher().sha256(file: layout.modelFile),
                digest,
                "\(strategy)"
            )
            XCTAssertFalse(containsModelTemporaryFile(under: layout.root))
            if strategy == .hardLink {
                XCTAssertEqual(
                    try fileIdentity(source),
                    try fileIdentity(layout.modelFile)
                )
            } else {
                XCTAssertNotEqual(
                    try fileIdentity(source),
                    try fileIdentity(layout.modelFile)
                )
            }
        }
    }

    func testLiveClonePublishesBeforeHardLinkFallback() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appending(path: "source.gguf")
        let payload = Data("clone metadata".utf8)
        try payload.write(to: source)
        let attributeName = "com.qwythos.clone-marker"
        let attributeValue = Data("preserved".utf8)
        let setResult = attributeValue.withUnsafeBytes {
            setxattr(
                source.path,
                attributeName,
                $0.baseAddress,
                $0.count,
                0,
                0
            )
        }
        XCTAssertEqual(setResult, 0)
        let layout = InstallationLayout(root: root.appending(path: "managed"))
        try FileManager.default.createDirectory(
            at: layout.root,
            withIntermediateDirectories: true
        )
        let events = MigrationEventLog()
        let live = ModelReuser.FileOperations.live
        let operations = ModelReuser.FileOperations(
            clone: {
                sourceDescriptor,
                directoryDescriptor,
                name in
                events.append("clone")
                return live.clone(
                    sourceDescriptor,
                    directoryDescriptor,
                    name
                )
            },
            hardLink: {
                sourceDirectory,
                sourceName,
                destinationDirectory,
                destinationName in
                events.append("hard-link")
                return live.hardLink(
                    sourceDirectory,
                    sourceName,
                    destinationDirectory,
                    destinationName
                )
            },
            renameNoReplace: {
                sourceDirectory,
                sourceName,
                destinationDirectory,
                destinationName in
                events.append("rename")
                return live.renameNoReplace(
                    sourceDirectory,
                    sourceName,
                    destinationDirectory,
                    destinationName
                )
            },
            syncDirectory: live.syncDirectory
        )

        _ = try ModelReuser(operations: operations).reuse(
            source,
            at: layout.modelFile,
            expectedSHA256: hash(of: payload)
        )

        XCTAssertEqual(events.snapshot(), ["clone", "rename"])
        XCTAssertNotEqual(
            try fileIdentity(layout.modelFile),
            try fileIdentity(source)
        )
        var buffer = [UInt8](repeating: 0, count: attributeValue.count)
        let count = buffer.withUnsafeMutableBytes {
            getxattr(
                layout.modelFile.path,
                attributeName,
                $0.baseAddress,
                $0.count,
                0,
                0
            )
        }
        XCTAssertEqual(count, attributeValue.count)
        XCTAssertEqual(Data(buffer), attributeValue)
    }

    func testCloneAndHardLinkReplacementBeforeFirstOpenIsPreserved() throws {
        for strategy in [
            ModelReuser.StagingStrategy.clone,
            .hardLink,
        ] {
            let root = try makeRoot()
            defer { try? FileManager.default.removeItem(at: root) }
            let source = root.appending(path: "source.gguf")
            let payload = Data("model via \(strategy)".utf8)
            try payload.write(to: source)
            let digest = hash(of: payload)
            let layout = InstallationLayout(root: root.appending(path: "managed"))
            try FileManager.default.createDirectory(
                at: layout.root,
                withIntermediateDirectories: true
            )
            let replacement = ReplaceInstalledModel()
            let reuser = ModelReuser(
                strategy: strategy,
                afterStageCreation: replacement.replace
            )

            XCTAssertThrowsError(
                try reuser.reuse(
                    source,
                    at: layout.modelFile,
                    expectedSHA256: digest
                ),
                "\(strategy)"
            )

            XCTAssertEqual(try Data(contentsOf: source), payload, "\(strategy)")
            XCTAssertFalse(
                FileManager.default.fileExists(atPath: layout.modelFile.path),
                "\(strategy)"
            )
            XCTAssertTrue(
                containsPayload(replacement.payload, under: layout.stagingDirectory),
                "\(strategy)"
            )
        }
    }

    func testCloneReplacementBeforeCloneOperationReturnsIsPreserved() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appending(path: "source.gguf")
        let payload = Data("clone operation race".utf8)
        try payload.write(to: source)
        let digest = hash(of: payload)
        let layout = InstallationLayout(root: root.appending(path: "managed"))
        try FileManager.default.createDirectory(
            at: layout.root,
            withIntermediateDirectories: true
        )
        let replacement = ReplaceInstalledModel()
        let live = ModelReuser.FileOperations.live
        let operations = ModelReuser.FileOperations(
            clone: {
                sourceDescriptor,
                directoryDescriptor,
                name in
                let destinationDescriptor = openat(
                    directoryDescriptor,
                    name,
                    O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
                    0o600
                )
                guard destinationDescriptor >= 0 else {
                    return .failed(errno)
                }
                let destination = POSIXFileDescriptor(destinationDescriptor)
                do {
                    let identity = POSIXFileIdentity(
                        try destination.metadata()
                    )
                    guard fcopyfile(
                        sourceDescriptor,
                        destinationDescriptor,
                        nil,
                        copyfile_flags_t(COPYFILE_DATA)
                    ) == 0 else {
                        return .failed(errno)
                    }
                    try replacement.replace(
                        directoryDescriptor: directoryDescriptor,
                        name: name
                    )
                    return .created(identity)
                } catch {
                    return .failed(EIO)
                }
            },
            hardLink: live.hardLink,
            renameNoReplace: live.renameNoReplace,
            syncDirectory: live.syncDirectory
        )

        XCTAssertThrowsError(
            try ModelReuser(operations: operations).reuse(
                source,
                at: layout.modelFile,
                expectedSHA256: digest
            )
        )

        XCTAssertEqual(try Data(contentsOf: source), payload)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: layout.modelFile.path)
        )
        XCTAssertTrue(
            containsPayload(replacement.payload, under: layout.stagingDirectory)
        )
    }

    func testUnsupportedCloneAndHardLinkFallBackToCopyAndRenamePublication() throws {
        for hardLinkError in [EXDEV, EOPNOTSUPP] {
            let root = try makeRoot()
            defer { try? FileManager.default.removeItem(at: root) }
            let source = root.appending(path: "source.gguf")
            let payload = Data("fallback copy model".utf8)
            try payload.write(to: source)
            let digest = hash(of: payload)
            let layout = InstallationLayout(root: root.appending(path: "managed"))
            try FileManager.default.createDirectory(
                at: layout.root,
                withIntermediateDirectories: true
            )
            let events = MigrationEventLog()
            let operations = ModelReuser.FileOperations(
                clone: { _, _, _ in
                    events.append("clone")
                    return .failed(ENOTSUP)
                },
                hardLink: { _, _, _, _ in
                    events.append("hard-link")
                    errno = hardLinkError
                    return -1
                },
                renameNoReplace: {
                    sourceDirectory,
                    sourceName,
                    destinationDirectory,
                    destinationName in
                    events.append("rename")
                    return renameatx_np(
                        sourceDirectory,
                        sourceName,
                        destinationDirectory,
                        destinationName,
                        UInt32(RENAME_EXCL)
                    )
                },
                syncDirectory: { fsync($0) }
            )

            let result = try ModelReuser(operations: operations).reuse(
                source,
                at: layout.modelFile,
                expectedSHA256: digest
            )

            XCTAssertEqual(result, .reused, "\(hardLinkError)")
            XCTAssertEqual(
                events.snapshot(),
                ["clone", "hard-link", "rename"],
                "\(hardLinkError)"
            )
            XCTAssertEqual(
                try Data(contentsOf: layout.modelFile),
                payload,
                "\(hardLinkError)"
            )
            XCTAssertEqual(
                try Data(contentsOf: source),
                payload,
                "\(hardLinkError)"
            )
            XCTAssertNotEqual(
                try fileIdentity(source),
                try fileIdentity(layout.modelFile),
                "\(hardLinkError)"
            )
        }
    }

    func testModelDirectorySyncFailureRemovesPublicationAndPreservesSource() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appending(path: "source.gguf")
        let payload = Data("directory sync model".utf8)
        try payload.write(to: source)
        let digest = hash(of: payload)
        let layout = InstallationLayout(root: root.appending(path: "managed"))
        try FileManager.default.createDirectory(
            at: layout.root,
            withIntermediateDirectories: true
        )
        let live = ModelReuser.FileOperations.live
        let operations = ModelReuser.FileOperations(
            clone: live.clone,
            hardLink: live.hardLink,
            renameNoReplace: live.renameNoReplace,
            syncDirectory: {
                _ in
                errno = EIO
                return -1
            }
        )

        XCTAssertThrowsError(
            try ModelReuser(operations: operations).reuse(
                source,
                at: layout.modelFile,
                expectedSHA256: digest
            )
        ) { error in
            XCTAssertEqual(error as? ModelReuserError, .copyFailed)
        }

        XCTAssertEqual(try Data(contentsOf: source), payload)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: layout.modelFile.path)
        )
        XCTAssertFalse(containsModelTemporaryFile(under: layout.root))
    }

    func testConfiguredCachePrecedesBothDefaultCacheRoots() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let configured = root.appending(path: "configured")
        let library = root.appending(path: "Library/Caches/llama.cpp")
        let dotCache = root.appending(path: ".cache/llama.cpp")
        let payload = Data("same verified model".utf8)
        let digest = hash(of: payload)
        for cache in [configured, library, dotCache] {
            let blob = cache.appending(path: "blobs/\(digest)")
            try FileManager.default.createDirectory(
                at: blob.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try payload.write(to: blob)
        }
        try payload.write(to: configured.appending(path: digest))
        let legacy = LegacyLaunchAgent(
            plistURL: root.appending(path: "legacy.plist"),
            label: LaunchAgentInstaller.defaultLabel,
            program: "/opt/bin/llama-server",
            arguments: [],
            environment: ["LLAMA_CACHE": configured.path]
        )

        let locator = LegacyModelLocator(
            legacyPlist: legacy,
            homeDirectory: root
        )

        XCTAssertEqual(
            try locator.locate(modelSHA256: digest),
            configured.appending(path: "blobs/\(digest)")
        )
        try FileManager.default.removeItem(at: configured)
        XCTAssertEqual(
            try locator.locate(modelSHA256: digest),
            library.appending(path: "blobs/\(digest)")
        )
        try FileManager.default.removeItem(at: library)
        XCTAssertEqual(
            try locator.locate(modelSHA256: digest),
            dotCache.appending(path: "blobs/\(digest)")
        )
    }

    func testRejectsMismatchedBlobAndChoosesDownload() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appending(path: "cache/blobs")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let expected = hash(of: Data("expected".utf8))
        try Data("wrong".utf8).write(to: source.appending(path: expected))

        XCTAssertNil(try LegacyModelLocator(cacheRoots: [source.deletingLastPathComponent()]).locate(modelSHA256: expected))
    }

    func testLocatesDigestBlobInHuggingFaceRepositoryCache() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let payload = Data("verified model".utf8)
        let digest = hash(of: payload)
        let blob = root.appending(path: "models--author--qwythos/blobs/\(digest)")
        try FileManager.default.createDirectory(at: blob.deletingLastPathComponent(), withIntermediateDirectories: true)
        try payload.write(to: blob)

        let candidate = try LegacyModelLocator(cacheRoots: [root]).locate(modelSHA256: digest)
        XCTAssertEqual(candidate?.lastPathComponent, digest)
        XCTAssertEqual(try candidate.map { try Data(contentsOf: $0) }, payload)
    }

    func testDownloadRequiredDoesNotMutateLegacyServiceOrPlist() async throws {
        let fixture = try MigrationFixture()
        defer { fixture.remove() }
        let runner = MigrationRunner(initiallyLoaded: true)
        let migrator = fixture.migrator(
            runner: runner,
            reuser: DownloadRequiredReuser(),
            health: MigrationHealth(healthy: true)
        )

        do {
            try await migrator.migrate(options: fixture.options)
            XCTFail("Expected download-required migration failure")
        } catch {
            XCTAssertEqual(error as? LegacyMigrationError, .modelDownloadRequired)
        }
        let commands = await runner.commands()
        XCTAssertEqual(commands.map(\.arguments), [["print", "gui/501/com.local.qwythos-9b"]])
        XCTAssertEqual(try Data(contentsOf: fixture.legacyPlist), fixture.legacyData)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.layout.legacyPlistBackup.path))
    }

    func testVerifiedManagedModelIsReusedWithoutAnotherCacheLookup() async throws {
        let fixture = try MigrationFixture()
        defer { fixture.remove() }
        try FileManager.default.createDirectory(
            at: fixture.layout.modelsDirectory,
            withIntermediateDirectories: true
        )
        try fixture.sourceData.write(to: fixture.layout.modelFile)
        let runner = MigrationRunner(initiallyLoaded: true)

        try await fixture.migrator(
            runner: runner,
            modelLocator: MissingModelLocator(),
            reuser: RejectingModelReuser(),
            health: MigrationHealth(healthy: true)
        ).migrate(options: fixture.options)

        XCTAssertEqual(
            try SHA256Hasher().sha256(file: fixture.layout.modelFile),
            fixture.manifest.model.sha256
        )
        XCTAssertNotNil(try InstallationRecordStore().load(layout: fixture.layout))
    }

    func testNonPreparingInstallerIsRejectedBeforeMigrationMutation() async throws {
        let fixture = try MigrationFixture()
        defer { fixture.remove() }
        let runner = MigrationRunner(initiallyLoaded: true)
        let migrator = fixture.migrator(
            runner: runner,
            installer: NonPreparingLaunchAgentInstaller(),
            health: MigrationHealth(healthy: true)
        )

        do {
            try await migrator.migrate(options: fixture.options)
            XCTFail("Expected safe preparation requirement")
        } catch {
            XCTAssertEqual(error as? LegacyMigrationError, .legacyBackupFailed)
        }

        let commands = await runner.commandArguments()
        XCTAssertTrue(commands.isEmpty)
        XCTAssertEqual(try Data(contentsOf: fixture.legacyPlist), fixture.legacyData)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.layout.modelFile.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.layout.legacyPlistBackup.path))
    }

    func testHealthFailureRestoresLegacyPlistAndOnlyRebootsInitiallyLoadedService() async throws {
        let fixture = try MigrationFixture()
        defer { fixture.remove() }
        let runner = MigrationRunner(initiallyLoaded: true)
        let migrator = fixture.migrator(runner: runner, health: MigrationHealth(healthy: false))

        do {
            try await migrator.migrate(options: fixture.options)
            XCTFail("Expected health failure")
        } catch {
            XCTAssertEqual(error as? LegacyMigrationError, .healthCheckFailed)
        }
        XCTAssertEqual(try Data(contentsOf: fixture.legacyPlist), fixture.legacyData)
        let commands = await runner.commandArguments()
        XCTAssertEqual(commands, [
            ["print", "gui/501/com.local.qwythos-9b"],
            ["bootout", "gui/501/com.local.qwythos-9b"],
            ["bootstrap", "gui/501", fixture.legacyPlist.path],
            ["print", "gui/501/com.local.qwythos-9b"],
            ["bootout", "gui/501/com.local.qwythos-9b"],
            ["print", "gui/501/com.local.qwythos-9b"],
            ["bootstrap", "gui/501", fixture.legacyPlist.path],
            ["print", "gui/501/com.local.qwythos-9b"],
        ])
        let serviceLoaded = await runner.serviceLoaded()
        XCTAssertTrue(serviceLoaded)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.layout.modelFile.path))
        XCTAssertNil(try InstallationRecordStore().load(layout: fixture.layout))
    }

    func testRollbackDoesNotClaimModelInstalledByOpaqueReuser() async throws {
        let fixture = try MigrationFixture()
        defer { fixture.remove() }
        let reuser = OpaqueReplacingModelReuser()
        let runner = MigrationRunner(initiallyLoaded: true)

        do {
            try await fixture.migrator(
                runner: runner,
                reuser: reuser,
                health: MigrationHealth(healthy: false)
            ).migrate(options: fixture.options)
            XCTFail("Expected health failure")
        } catch {
            XCTAssertEqual(
                error as? LegacyMigrationError,
                .healthCheckFailed
            )
        }

        XCTAssertTrue(
            FileManager.default.fileExists(atPath: fixture.layout.modelFile.path)
        )
        XCTAssertEqual(
            try fileIdentity(fixture.layout.modelFile),
            try XCTUnwrap(reuser.replacementIdentity())
        )
        XCTAssertEqual(
            try Data(contentsOf: fixture.layout.modelFile),
            fixture.sourceData
        )
    }

    func testHealthFailureDoesNotBootstrapInitiallyUnloadedLegacyService() async throws {
        let fixture = try MigrationFixture()
        defer { fixture.remove() }
        let runner = MigrationRunner(initiallyLoaded: false)
        let migrator = fixture.migrator(runner: runner, health: MigrationHealth(healthy: false))

        do {
            try await migrator.migrate(options: fixture.options)
            XCTFail("Expected health failure")
        } catch {
            XCTAssertEqual(error as? LegacyMigrationError, .healthCheckFailed)
        }

        let commands = await runner.commandArguments()
        XCTAssertEqual(commands, [
            ["print", "gui/501/com.local.qwythos-9b"],
            ["bootstrap", "gui/501", fixture.legacyPlist.path],
            ["print", "gui/501/com.local.qwythos-9b"],
            ["bootout", "gui/501/com.local.qwythos-9b"],
            ["print", "gui/501/com.local.qwythos-9b"],
            ["print", "gui/501/com.local.qwythos-9b"],
        ])
        let serviceLoaded = await runner.serviceLoaded()
        XCTAssertFalse(serviceLoaded)
        XCTAssertEqual(try Data(contentsOf: fixture.legacyPlist), fixture.legacyData)
        XCTAssertEqual(try fileMode(fixture.legacyPlist), fixture.legacyMode)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.layout.modelFile.path))
        XCTAssertNil(try InstallationRecordStore().load(layout: fixture.layout))
    }

    func testSuccessfulMigrationPreservesSourceAndBackupAndRecordsAfterHealth() async throws {
        let fixture = try MigrationFixture()
        defer { fixture.remove() }
        let events = MigrationEventLog()
        let records = RecordingRecordStore(events: events)
        let runner = MigrationRunner(initiallyLoaded: true, events: events)
        let installer = EventLaunchAgentInstaller(
            delegate: LaunchAgentInstaller(
                launchAgentsDirectory: fixture.agents
            ),
            events: events
        )
        let migrator = fixture.migrator(
            runner: runner,
            records: records,
            reuser: EventModelReuser(events: events),
            installer: installer,
            health: MigrationHealth(healthy: true, events: events),
            beforeBackupInstall: { _, _ in events.append("backup") }
        )

        try await migrator.migrate(options: fixture.options)

        XCTAssertEqual(try Data(contentsOf: fixture.source), fixture.sourceData)
        XCTAssertEqual(try SHA256Hasher().sha256(file: fixture.layout.modelFile), fixture.manifest.model.sha256)
        XCTAssertEqual(try Data(contentsOf: fixture.layout.legacyPlistBackup), fixture.legacyData)
        XCTAssertEqual(try fileMode(fixture.layout.legacyPlistBackup), fixture.legacyMode)
        XCTAssertNotEqual(try Data(contentsOf: fixture.legacyPlist), fixture.legacyData)
        XCTAssertNotNil(try InstallationRecordStore().load(layout: fixture.layout))
        let commands = await runner.commandArguments()
        XCTAssertEqual(commands, [
            ["print", "gui/501/com.local.qwythos-9b"],
            ["bootout", "gui/501/com.local.qwythos-9b"],
            ["bootstrap", "gui/501", fixture.legacyPlist.path],
        ])
        let recordedEvents = events.snapshot()
        let ordered = [
            "model",
            "backup",
            "command:bootout gui/501/com.local.qwythos-9b",
            "install",
            "command:bootstrap gui/501 \(fixture.legacyPlist.path)",
            "health",
            "record-save",
        ]
        let indexes = try ordered.map {
            try XCTUnwrap(recordedEvents.firstIndex(of: $0), "\($0) missing")
        }
        XCTAssertEqual(indexes, indexes.sorted())
    }

    func testMigrationPollsHealthUntilManagedServiceBecomesReady() async throws {
        let fixture = try MigrationFixture()
        defer { fixture.remove() }
        let health = SequencedMigrationHealth(
            results: [false, false, true]
        )

        try await fixture.migrator(
            runner: MigrationRunner(initiallyLoaded: true),
            health: health,
            sleeper: ImmediateDeploymentSleeper(),
            healthPollAttempts: 3
        ).migrate(options: fixture.options)

        XCTAssertEqual(health.callCount, 3)
        XCTAssertNotNil(try InstallationRecordStore().load(layout: fixture.layout))
    }

    func testBackupPublishesWithNoReplaceRename() async throws {
        let fixture = try MigrationFixture()
        defer { fixture.remove() }
        let events = MigrationEventLog()
        let operations = LegacyInstallationMigrator.FileOperations(
            renameNoReplace: {
                sourceDirectory,
                sourceName,
                destinationDirectory,
                destinationName in
                events.append("backup-rename")
                return renameatx_np(
                    sourceDirectory,
                    sourceName,
                    destinationDirectory,
                    destinationName,
                    UInt32(RENAME_EXCL)
                )
            },
            syncDirectory: { fsync($0) }
        )

        try await fixture.migrator(
            runner: MigrationRunner(initiallyLoaded: true),
            health: MigrationHealth(healthy: true),
            fileOperations: operations
        ).migrate(options: fixture.options)

        XCTAssertEqual(
            events.snapshot().filter { $0 == "backup-rename" },
            ["backup-rename"]
        )
        XCTAssertEqual(
            try Data(contentsOf: fixture.layout.legacyPlistBackup),
            fixture.legacyData
        )
    }

    func testBackupDirectorySyncFailureRollsBackOwnedPublication() async throws {
        let fixture = try MigrationFixture()
        defer { fixture.remove() }
        let live = LegacyInstallationMigrator.FileOperations.live
        let syncFailure = DirectorySyncFailure(failingCall: 1)
        let operations = LegacyInstallationMigrator.FileOperations(
            renameNoReplace: live.renameNoReplace,
            syncDirectory: syncFailure.sync
        )
        let runner = MigrationRunner(initiallyLoaded: true)

        do {
            try await fixture.migrator(
                runner: runner,
                health: MigrationHealth(healthy: true),
                fileOperations: operations
            ).migrate(options: fixture.options)
            XCTFail("Expected backup directory sync failure")
        } catch {
            XCTAssertEqual(
                error as? LegacyMigrationError,
                .legacyBackupFailed
            )
        }

        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: fixture.layout.legacyPlistBackup.path
            )
        )
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: fixture.layout.modelFile.path)
        )
        XCTAssertEqual(try Data(contentsOf: fixture.source), fixture.sourceData)
        let commands = await runner.commandArguments()
        XCTAssertEqual(
            commands,
            [["print", "gui/501/com.local.qwythos-9b"]]
        )
    }

    func testManagedPlistDirectorySyncFailureRestoresLegacyBeforeThrowing() async throws {
        let fixture = try MigrationFixture()
        defer { fixture.remove() }
        let syncFailure = DirectorySyncFailure(failingCall: 2)
        let operations = LegacyInstallationMigrator.FileOperations(
            renameNoReplace: LegacyInstallationMigrator.FileOperations.live
                .renameNoReplace,
            syncDirectory: syncFailure.sync
        )
        let runner = MigrationRunner(initiallyLoaded: true)

        do {
            try await fixture.migrator(
                runner: runner,
                health: MigrationHealth(healthy: true),
                fileOperations: operations
            ).migrate(options: fixture.options)
            XCTFail("Expected managed plist directory sync failure")
        } catch {
            XCTAssertEqual(
                error as? LegacyMigrationError,
                .legacyBackupFailed
            )
        }

        XCTAssertEqual(
            try Data(contentsOf: fixture.legacyPlist),
            fixture.legacyData
        )
        let serviceLoaded = await runner.serviceLoaded()
        XCTAssertTrue(serviceLoaded)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: fixture.layout.modelFile.path)
        )
        XCTAssertEqual(
            try Data(contentsOf: fixture.layout.legacyPlistBackup),
            fixture.legacyData
        )
    }

    func testPersistentPlistSyncFailureSkipsUnsafeLegacyBootstrap() async throws {
        let fixture = try MigrationFixture()
        defer { fixture.remove() }
        let syncFailure = PersistentDirectorySyncFailure(startingAt: 2)
        let operations = LegacyInstallationMigrator.FileOperations(
            renameNoReplace: LegacyInstallationMigrator.FileOperations.live
                .renameNoReplace,
            syncDirectory: syncFailure.sync
        )
        let runner = MigrationRunner(initiallyLoaded: true)

        do {
            try await fixture.migrator(
                runner: runner,
                health: MigrationHealth(healthy: true),
                fileOperations: operations
            ).migrate(options: fixture.options)
            XCTFail("Expected rollback durability diagnostic")
        } catch {
            guard case .rollbackFailed(let message) =
                    error as? LegacyMigrationError else {
                return XCTFail("Expected rollback failure, received \(error)")
            }
            XCTAssertTrue(message.contains("legacy plist restore failed"))
        }

        let serviceLoaded = await runner.serviceLoaded()
        XCTAssertFalse(serviceLoaded)
        XCTAssertEqual(
            try Data(contentsOf: fixture.legacyPlist),
            fixture.legacyData
        )
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: fixture.layout.modelFile.path)
        )
    }

    func testLegacyRestoreDirectorySyncFailureSurfacesRollbackDiagnostic() async throws {
        let fixture = try MigrationFixture()
        defer { fixture.remove() }
        let syncFailure = DirectorySyncFailure(failingCall: 3)
        let operations = LegacyInstallationMigrator.FileOperations(
            renameNoReplace: LegacyInstallationMigrator.FileOperations.live
                .renameNoReplace,
            syncDirectory: syncFailure.sync
        )
        let runner = MigrationRunner(initiallyLoaded: true)

        do {
            try await fixture.migrator(
                runner: runner,
                health: MigrationHealth(healthy: false),
                fileOperations: operations
            ).migrate(options: fixture.options)
            XCTFail("Expected rollback diagnostic")
        } catch {
            guard case .rollbackFailed(let message) =
                    error as? LegacyMigrationError else {
                return XCTFail("Expected rollback failure, received \(error)")
            }
            XCTAssertTrue(message.contains("legacy plist restore failed"))
        }

        XCTAssertEqual(
            try Data(contentsOf: fixture.legacyPlist),
            fixture.legacyData
        )
        let serviceLoaded = await runner.serviceLoaded()
        XCTAssertFalse(serviceLoaded)
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: fixture.layout.modelFile.path)
        )
    }

    func testModelCleanupDirectorySyncFailureSurfacesRollbackDiagnostic() async throws {
        let fixture = try MigrationFixture()
        defer { fixture.remove() }
        let syncFailure = DirectorySyncFailure(failingCall: 4)
        let operations = LegacyInstallationMigrator.FileOperations(
            renameNoReplace: LegacyInstallationMigrator.FileOperations.live
                .renameNoReplace,
            syncDirectory: syncFailure.sync
        )

        do {
            try await fixture.migrator(
                runner: MigrationRunner(initiallyLoaded: true),
                health: MigrationHealth(healthy: false),
                fileOperations: operations
            ).migrate(options: fixture.options)
            XCTFail("Expected rollback model cleanup durability failure")
        } catch {
            guard case .rollbackFailed(let message) =
                    error as? LegacyMigrationError else {
                return XCTFail("Expected rollback failure, received \(error)")
            }
            XCTAssertTrue(message.contains("model cleanup failed"))
        }

        XCTAssertEqual(
            try Data(contentsOf: fixture.legacyPlist),
            fixture.legacyData
        )
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: fixture.layout.modelFile.path)
        )
    }

    func testCancellationAfterServiceQueryCausesNoMutation() async throws {
        let fixture = try MigrationFixture()
        defer { fixture.remove() }
        let runner = MigrationRunner(initiallyLoaded: false, cancelAfterFirstQuery: true)
        let migrator = fixture.migrator(runner: runner, health: MigrationHealth(healthy: true))
        let options = fixture.options

        let result = await Task {
            try await migrator.migrate(options: options)
        }.result

        guard case .failure(let error) = result else {
            return XCTFail("Expected cancellation")
        }
        XCTAssertTrue(error is CancellationError)
        let commands = await runner.commandArguments()
        XCTAssertEqual(commands, [
            ["print", "gui/501/com.local.qwythos-9b"],
        ])
        XCTAssertEqual(try Data(contentsOf: fixture.legacyPlist), fixture.legacyData)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.layout.modelFile.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.layout.legacyPlistBackup.path))
    }

    func testServiceQueryErrorCausesNoMutation() async throws {
        let fixture = try MigrationFixture()
        defer { fixture.remove() }
        let runner = MigrationRunner(initiallyLoaded: true, failFirstQuery: true)
        let migrator = fixture.migrator(runner: runner, health: MigrationHealth(healthy: true))

        do {
            try await migrator.migrate(options: fixture.options)
            XCTFail("Expected service query failure")
        } catch {
            XCTAssertEqual(error as? LegacyMigrationError, .serviceControlFailed)
        }

        let commands = await runner.commandArguments()
        XCTAssertEqual(commands, [
            ["print", "gui/501/com.local.qwythos-9b"],
        ])
        XCTAssertEqual(try Data(contentsOf: fixture.legacyPlist), fixture.legacyData)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.layout.modelFile.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.layout.legacyPlistBackup.path))
    }

    func testCancellationOrTimeoutAfterEffectiveBootoutRestoresLoadedLegacyService() async throws {
        for outcome in [MigrationRunner.BootoutOutcome.cancelledAfterEffect, .timedOutAfterEffect] {
            let fixture = try MigrationFixture()
            defer { fixture.remove() }
            let runner = MigrationRunner(initiallyLoaded: true, bootoutOutcomes: [outcome])
            let migrator = fixture.migrator(runner: runner, health: MigrationHealth(healthy: true))
            let options = fixture.options

            let result = await Task {
                try await migrator.migrate(options: options)
            }.result

            guard case .failure(let error) = result else {
                XCTFail("Expected interrupted bootout")
                continue
            }
            switch outcome {
            case .cancelledAfterEffect:
                XCTAssertTrue(error is CancellationError)
            default:
                XCTAssertEqual(error as? LegacyMigrationError, .serviceControlFailed)
            }
            let serviceLoaded = await runner.serviceLoaded()
            XCTAssertTrue(serviceLoaded)
            XCTAssertEqual(try Data(contentsOf: fixture.legacyPlist), fixture.legacyData)
            XCTAssertEqual(try fileMode(fixture.legacyPlist), fixture.legacyMode)
            XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.layout.modelFile.path))
            let commands = await runner.commandArguments()
            XCTAssertEqual(commands, [
                ["print", "gui/501/com.local.qwythos-9b"],
                ["bootout", "gui/501/com.local.qwythos-9b"],
                ["print", "gui/501/com.local.qwythos-9b"],
                ["bootstrap", "gui/501", fixture.legacyPlist.path],
                ["print", "gui/501/com.local.qwythos-9b"],
            ])
        }
    }

    func testCancellationDuringHealthCheckRollsBackAndSurfacesCancellation() async throws {
        let fixture = try MigrationFixture()
        defer { fixture.remove() }
        let runner = MigrationRunner(initiallyLoaded: true)
        let migrator = fixture.migrator(
            runner: runner,
            health: MigrationHealth(healthy: false, cancelOnCheck: true)
        )

        let result = await Task {
            try await migrator.migrate(options: fixture.options)
        }.result

        guard case .failure(let error) = result else {
            return XCTFail("Expected cancellation")
        }
        XCTAssertTrue(error is CancellationError)
        XCTAssertEqual(try Data(contentsOf: fixture.legacyPlist), fixture.legacyData)
        XCTAssertEqual(try fileMode(fixture.legacyPlist), fixture.legacyMode)
        let serviceLoaded = await runner.serviceLoaded()
        XCTAssertTrue(serviceLoaded)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.layout.modelFile.path))
    }

    func testInstallerFailureBeforeMutationRestoresServiceAndCleansModel() async throws {
        let fixture = try MigrationFixture()
        defer { fixture.remove() }
        let runner = MigrationRunner(initiallyLoaded: true)
        let migrator = fixture.migrator(
            runner: runner,
            installer: FailingLaunchAgentInstaller(),
            health: MigrationHealth(healthy: true)
        )

        do {
            try await migrator.migrate(options: fixture.options)
            XCTFail("Expected installer failure")
        } catch {
            XCTAssertTrue(error is FailingLaunchAgentInstaller.Failure)
        }

        let serviceLoaded = await runner.serviceLoaded()
        XCTAssertTrue(serviceLoaded)
        XCTAssertEqual(try Data(contentsOf: fixture.legacyPlist), fixture.legacyData)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.layout.modelFile.path))
    }

    func testMutatingPreparerFailureIsNotClaimedByContent() async throws {
        let fixture = try MigrationFixture()
        defer { fixture.remove() }
        let runner = MigrationRunner(initiallyLoaded: true)
        let delegate = LaunchAgentInstaller(
            launchAgentsDirectory: fixture.agents
        )
        let managedData = try delegate.makePlist(
            layout: fixture.layout,
            options: fixture.options,
            manifest: fixture.manifest
        )
        let installer = WriteThenFailLaunchAgentInstaller(delegate: delegate)
        let migrator = fixture.migrator(
            runner: runner,
            installer: installer,
            health: MigrationHealth(healthy: true)
        )

        do {
            try await migrator.migrate(options: fixture.options)
            XCTFail("Expected installer failure")
        } catch {
            guard case .rollbackFailed(let message) = error as? LegacyMigrationError else {
                return XCTFail("Expected rollback failure, received \(error)")
            }
            XCTAssertTrue(message.contains("legacy plist restore failed"))
        }

        let serviceLoaded = await runner.serviceLoaded()
        XCTAssertFalse(serviceLoaded)
        XCTAssertEqual(try Data(contentsOf: fixture.legacyPlist), managedData)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.layout.modelFile.path))
    }

    func testManagedBootstrapFailureRestoresLegacyServiceAndCleansModel() async throws {
        let fixture = try MigrationFixture()
        defer { fixture.remove() }
        let runner = MigrationRunner(
            initiallyLoaded: true,
            bootstrapOutcomes: [.failure, .success]
        )
        let migrator = fixture.migrator(
            runner: runner,
            health: MigrationHealth(healthy: true)
        )

        do {
            try await migrator.migrate(options: fixture.options)
            XCTFail("Expected managed bootstrap failure")
        } catch {
            XCTAssertEqual(error as? LegacyMigrationError, .serviceControlFailed)
        }

        let serviceLoaded = await runner.serviceLoaded()
        XCTAssertTrue(serviceLoaded)
        XCTAssertEqual(try Data(contentsOf: fixture.legacyPlist), fixture.legacyData)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.layout.modelFile.path))
    }

    func testRollbackBootoutFailureRetainsManagedArtifacts() async throws {
        let fixture = try MigrationFixture()
        defer { fixture.remove() }
        let records = RecordingRecordStore(failSave: true, writeBeforeFailure: true)
        let runner = MigrationRunner(
            initiallyLoaded: true,
            bootoutOutcomes: [.success, .failureWithoutEffect]
        )
        let migrator = fixture.migrator(
            runner: runner,
            records: records,
            health: MigrationHealth(healthy: true)
        )

        do {
            try await migrator.migrate(options: fixture.options)
            XCTFail("Expected rollback failure")
        } catch {
            guard case .rollbackFailed(let message) = error as? LegacyMigrationError else {
                return XCTFail("Expected rollback failure, received \(error)")
            }
            XCTAssertTrue(message.contains("managed bootout failed"))
        }

        let serviceLoaded = await runner.serviceLoaded()
        XCTAssertTrue(serviceLoaded)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.layout.modelFile.path))
        XCTAssertNotNil(try InstallationRecordStore().load(layout: fixture.layout))
    }

    func testRecordWrittenThenSaveThrowsIsRemovedAfterSuccessfulRollback() async throws {
        let fixture = try MigrationFixture()
        defer { fixture.remove() }
        let records = RecordingRecordStore(
            failSave: true,
            writeBeforeFailure: true
        )
        let runner = MigrationRunner(initiallyLoaded: true)
        let migrator = fixture.migrator(
            runner: runner,
            records: records,
            health: MigrationHealth(healthy: true)
        )

        do {
            try await migrator.migrate(options: fixture.options)
            XCTFail("Expected record save failure")
        } catch {
            XCTAssertTrue(error is RecordingRecordStore.Failure)
        }

        let serviceLoaded = await runner.serviceLoaded()
        XCTAssertTrue(serviceLoaded)
        XCTAssertEqual(try Data(contentsOf: fixture.legacyPlist), fixture.legacyData)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.layout.modelFile.path))
        XCTAssertNil(try InstallationRecordStore().load(layout: fixture.layout))
    }

    func testConcurrentRecordReplacementDuringRollbackIsPreserved() async throws {
        let fixture = try MigrationFixture()
        defer { fixture.remove() }
        let replacement = InstallationRecord(
            manifestSchemaVersion: fixture.manifest.schemaVersion,
            root: fixture.layout.root,
            runtimeVersion: "unrelated-runtime",
            modelSHA256: String(repeating: "f", count: 64),
            contextSize: 4_096,
            accessMode: .shared,
            installedAt: Date(timeIntervalSince1970: 1)
        )
        let records = try ReplacingRollbackRecordStore(
            replacement: replacement
        )

        do {
            try await fixture.migrator(
                runner: MigrationRunner(initiallyLoaded: true),
                records: records,
                health: MigrationHealth(healthy: true)
            ).migrate(options: fixture.options)
            XCTFail("Expected record save failure")
        } catch {
            guard case .rollbackFailed(let message) =
                    error as? LegacyMigrationError else {
                return XCTFail("Expected rollback failure, received \(error)")
            }
            XCTAssertTrue(message.contains("record cleanup failed"))
        }

        XCTAssertEqual(
            try InstallationRecordStore().load(layout: fixture.layout),
            replacement
        )
    }

    func testRollbackRestoreFailureDoesNotBootstrapOrDeleteManagedArtifacts() async throws {
        let fixture = try MigrationFixture()
        defer { fixture.remove() }
        let records = RecordingRecordStore(failSave: true, writeBeforeFailure: true)
        let runner = MigrationRunner(initiallyLoaded: true)
        let migrator = fixture.migrator(
            runner: runner,
            records: records,
            health: MigrationHealth(healthy: true),
            beforeLegacyRestore: { throw CocoaError(.fileWriteUnknown) }
        )

        do {
            try await migrator.migrate(options: fixture.options)
            XCTFail("Expected rollback failure")
        } catch {
            guard case .rollbackFailed(let message) = error as? LegacyMigrationError else {
                return XCTFail("Expected rollback failure, received \(error)")
            }
            XCTAssertTrue(message.contains("legacy plist restore failed"))
        }

        let serviceLoaded = await runner.serviceLoaded()
        XCTAssertFalse(serviceLoaded)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.layout.modelFile.path))
        XCTAssertNotNil(try InstallationRecordStore().load(layout: fixture.layout))
        let commands = await runner.commandArguments()
        XCTAssertEqual(commands.filter { $0.first == "bootstrap" }.count, 1)
    }

    func testRollbackRequeriesLegacyBootstrapBeforeCleaningArtifacts() async throws {
        let fixture = try MigrationFixture()
        defer { fixture.remove() }
        let records = RecordingRecordStore(
            failSave: true,
            writeBeforeFailure: true
        )
        let runner = MigrationRunner(
            initiallyLoaded: true,
            bootstrapOutcomes: [.success, .successThenUnload]
        )
        let migrator = fixture.migrator(
            runner: runner,
            records: records,
            health: MigrationHealth(healthy: true)
        )

        do {
            try await migrator.migrate(options: fixture.options)
            XCTFail("Expected rollback failure")
        } catch {
            guard case .rollbackFailed(let message) = error as? LegacyMigrationError else {
                return XCTFail("Expected rollback failure, received \(error)")
            }
            XCTAssertTrue(message.contains("legacy bootstrap failed"))
        }

        let serviceLoaded = await runner.serviceLoaded()
        XCTAssertFalse(serviceLoaded)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.layout.modelFile.path))
        XCTAssertNotNil(try InstallationRecordStore().load(layout: fixture.layout))
    }

    func testConcurrentPlistReplacementSurvivesRollback() async throws {
        let fixture = try MigrationFixture()
        defer { fixture.remove() }
        let replacement = Data("concurrent plist replacement".utf8)
        let runner = MigrationRunner(initiallyLoaded: true)
        let health = MigrationHealth(healthy: false) {
            try! replacement.write(to: fixture.legacyPlist, options: .atomic)
        }
        let migrator = fixture.migrator(runner: runner, health: health)

        do {
            try await migrator.migrate(options: fixture.options)
            XCTFail("Expected rollback failure")
        } catch {
            guard case .rollbackFailed(let message) = error as? LegacyMigrationError else {
                return XCTFail("Expected rollback failure, received \(error)")
            }
            XCTAssertTrue(message.contains("legacy plist restore failed"))
        }

        XCTAssertEqual(try Data(contentsOf: fixture.legacyPlist), replacement)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.layout.modelFile.path))
    }

    func testCanonicalManagedReplacementBeforePublishIsPreservedByIdentity() async throws {
        let fixture = try MigrationFixture()
        defer { fixture.remove() }
        let delegate = LaunchAgentInstaller(
            launchAgentsDirectory: fixture.agents
        )
        let replacement = try delegate.makePlist(
            layout: fixture.layout,
            options: fixture.options,
            manifest: fixture.manifest
        )
        let runner = MigrationRunner(initiallyLoaded: true)
        let installer = ReplaceBeforePublishLaunchAgentInstaller(
            delegate: delegate,
            plistURL: fixture.legacyPlist,
            replacement: replacement
        )
        let migrator = fixture.migrator(
            runner: runner,
            installer: installer,
            health: MigrationHealth(healthy: true)
        )

        do {
            try await migrator.migrate(options: fixture.options)
            XCTFail("Expected identity-safe publish failure")
        } catch {
            guard case .rollbackFailed(let message) = error as? LegacyMigrationError else {
                return XCTFail("Expected rollback failure, received \(error)")
            }
            XCTAssertTrue(message.contains("legacy plist restore failed"))
        }

        let serviceLoaded = await runner.serviceLoaded()
        XCTAssertFalse(serviceLoaded)
        XCTAssertEqual(try Data(contentsOf: fixture.legacyPlist), replacement)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.layout.modelFile.path))
    }

    func testOpenRootRejectsSymlinkInAncestorPath() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let real = root.appending(path: "real")
        let child = real.appending(path: "child")
        try FileManager.default.createDirectory(
            at: child,
            withIntermediateDirectories: true
        )
        let link = root.appending(path: "link")
        try FileManager.default.createSymbolicLink(
            atPath: link.path,
            withDestinationPath: real.path
        )

        XCTAssertNoThrow(try POSIXDirectoryDescriptor.openRoot(child))
        XCTAssertThrowsError(
            try POSIXDirectoryDescriptor.openRoot(
                link.appending(path: "child")
            )
        ) { error in
            XCTAssertEqual(error as? POSIXTransactionError, .unsafePath)
        }
    }

    func testMigrationRejectsLaunchAgentsDirectoryWithSymlinkAncestorWithoutMutation() async throws {
        let fixture = try MigrationFixture()
        defer { fixture.remove() }
        let linkedRoot = fixture.root.appending(path: "linked-root")
        try FileManager.default.createSymbolicLink(
            atPath: linkedRoot.path,
            withDestinationPath: fixture.root.path
        )
        let linkedAgents = linkedRoot.appending(path: "LaunchAgents")
        let runner = MigrationRunner(initiallyLoaded: false)
        let migrator = LegacyInstallationMigrator(
            layout: fixture.layout,
            manifest: fixture.manifest,
            launchAgentsDirectory: linkedAgents,
            modelLocator: FixedModelLocator(source: fixture.source),
            commandRunner: runner,
            healthChecker: MigrationHealth(healthy: true),
            uid: 501
        )

        do {
            try await migrator.migrate(options: fixture.options)
            XCTFail("Expected the launch-agent ancestor symlink to be rejected")
        } catch {
            XCTAssertEqual(
                error as? LegacyMigrationError,
                .legacyInstallationNotRecognized
            )
        }

        XCTAssertEqual(
            try Data(contentsOf: fixture.legacyPlist),
            fixture.legacyData
        )
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: fixture.layout.modelFile.path)
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: fixture.layout.legacyPlistBackup.path
            )
        )
        let commandArguments = await runner.commandArguments()
        XCTAssertEqual(commandArguments, [])
    }

    func testMigrationRejectsRelativeLaunchAgentsDirectoryWithoutMutation() async throws {
        let fixture = try MigrationFixture()
        defer { fixture.remove() }
        let base = URL(
            fileURLWithPath: fixture.root.path,
            isDirectory: true
        )
        let relativeAgents = URL(
            fileURLWithPath: "LaunchAgents",
            relativeTo: base
        )
        XCTAssertEqual(
            relativeAgents.standardizedFileURL.path,
            fixture.agents.path
        )
        let runner = MigrationRunner(initiallyLoaded: false)
        let migrator = LegacyInstallationMigrator(
            layout: fixture.layout,
            manifest: fixture.manifest,
            launchAgentsDirectory: relativeAgents,
            modelLocator: FixedModelLocator(source: fixture.source),
            commandRunner: runner,
            healthChecker: MigrationHealth(healthy: true),
            uid: 501
        )

        do {
            try await migrator.migrate(options: fixture.options)
            XCTFail("Expected relative launch-agent path rejection")
        } catch {
            XCTAssertEqual(
                error as? LegacyMigrationError,
                .legacyInstallationNotRecognized
            )
        }

        XCTAssertEqual(
            try Data(contentsOf: fixture.legacyPlist),
            fixture.legacyData
        )
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: fixture.layout.modelFile.path)
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: fixture.layout.legacyPlistBackup.path
            )
        )
        let commandArguments = await runner.commandArguments()
        XCTAssertEqual(commandArguments, [])
    }

    func testOpenRootAcceptsFilesystemRoot() throws {
        XCTAssertNoThrow(
            try POSIXDirectoryDescriptor.openRoot(
                URL(fileURLWithPath: "/")
            )
        )
    }

    func testOpenRootFailsClosedForNoncanonicalRoots() throws {
        let roots = [
            URL(fileURLWithPath: ""),
            URL(fileURLWithPath: "."),
            URL(fileURLWithPath: "relative"),
            URL(string: "file:")!,
            URL(string: "file:.")!,
            URL(string: "relative")!,
            URL(string: "file:///private/../private/tmp")!,
            URL(string: "file:////private//tmp")!,
            URL(string: "file://example.com/private/tmp")!,
            URL(string: "file:///private/tmp?query=1")!,
            URL(string: "file:///private/tmp#fragment")!,
        ]

        for root in roots {
            XCTAssertThrowsError(
                try POSIXDirectoryDescriptor.openRoot(root),
                root.absoluteString
            ) { error in
                XCTAssertEqual(
                    error as? POSIXTransactionError,
                    .unsafePath,
                    root.absoluteString
                )
            }
        }
    }

    func testOwnedCleanupPreservesReplacementInstalledImmediatelyBeforeRemoval() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let ownedURL = root.appending(path: "owned.tmp")
        try Data("owned".utf8).write(to: ownedURL)
        let directory = try POSIXDirectoryDescriptor.openRoot(root)
        let owned = try directory.openFile("owned.tmp", flags: O_RDONLY | O_NOFOLLOW)
        let ownedIdentity = POSIXFileIdentity(try owned.metadata())
        let replacement = Data("replacement".utf8)

        XCTAssertThrowsError(
            try directory.unlinkIfOwned(
                "owned.tmp",
                identity: ownedIdentity,
                beforeQuarantine: {
                    try FileManager.default.removeItem(at: ownedURL)
                    try replacement.write(to: ownedURL)
                }
            )
        )
        XCTAssertEqual(try Data(contentsOf: ownedURL), replacement)
    }

    func testPostLinkHashFailureRemovesOwnedModelAndAllowsRetry() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let layout = InstallationLayout(root: root.appending(path: "managed"))
        try FileManager.default.createDirectory(at: layout.root, withIntermediateDirectories: true)
        let source = root.appending(path: "source.gguf")
        let payload = Data("verified model".utf8)
        try payload.write(to: source)
        let digest = hash(of: payload)
        let reuser = ModelReuser(hasher: FailOnHashCall(failingCall: 3))

        XCTAssertThrowsError(
            try reuser.reuse(source, at: layout.modelFile, expectedSHA256: digest)
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: layout.modelFile.path))
        XCTAssertFalse(containsModelTemporaryFile(under: layout.root))

        XCTAssertEqual(
            try ModelReuser().reuse(source, at: layout.modelFile, expectedSHA256: digest),
            .reused
        )
        XCTAssertEqual(try Data(contentsOf: layout.modelFile), payload)
    }

    func testPostLinkIdentityFailurePreservesReplacementAndAllowsRetryAfterRemoval() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let layout = InstallationLayout(root: root.appending(path: "managed"))
        try FileManager.default.createDirectory(at: layout.root, withIntermediateDirectories: true)
        let source = root.appending(path: "source.gguf")
        let payload = Data("verified model".utf8)
        try payload.write(to: source)
        let digest = hash(of: payload)
        let replacement = ReplaceInstalledModel()
        let reuser = ModelReuser(afterInstall: replacement.replace)

        XCTAssertThrowsError(
            try reuser.reuse(source, at: layout.modelFile, expectedSHA256: digest)
        )
        XCTAssertEqual(try Data(contentsOf: layout.modelFile), replacement.payload)
        XCTAssertFalse(containsModelTemporaryFile(under: layout.root))

        try FileManager.default.removeItem(at: layout.modelFile)
        XCTAssertEqual(
            try ModelReuser().reuse(source, at: layout.modelFile, expectedSHA256: digest),
            .reused
        )
        XCTAssertEqual(try Data(contentsOf: layout.modelFile), payload)
    }

    func testReplacementDuringFinalDescriptorHashIsPreservedAndRejected() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let layout = InstallationLayout(root: root.appending(path: "managed"))
        try FileManager.default.createDirectory(
            at: layout.root,
            withIntermediateDirectories: true
        )
        let source = root.appending(path: "source.gguf")
        let payload = Data("verified model".utf8)
        try payload.write(to: source)
        let digest = hash(of: payload)
        let replacement = ReplaceOnHashCall(path: layout.modelFile, call: 3)

        XCTAssertThrowsError(
            try ModelReuser(hasher: replacement).reuse(
                source,
                at: layout.modelFile,
                expectedSHA256: digest
            )
        )

        XCTAssertEqual(
            try Data(contentsOf: layout.modelFile),
            replacement.payload
        )
        XCTAssertEqual(try Data(contentsOf: source), payload)
    }

    func testBackupInstallCollisionCleansTemporaryAndAllowsRetry() async throws {
        let fixture = try MigrationFixture()
        defer { fixture.remove() }
        let collision = OneShotBackupCollision()
        let firstRunner = MigrationRunner(initiallyLoaded: true)
        let first = fixture.migrator(
            runner: firstRunner,
            health: MigrationHealth(healthy: true),
            beforeBackupInstall: collision.install
        )

        do {
            try await first.migrate(options: fixture.options)
            XCTFail("Expected backup collision")
        } catch {
            XCTAssertEqual(error as? LegacyMigrationError, .legacyBackupConflict)
        }

        XCTAssertFalse(containsBackupTemporaryFile(under: fixture.layout.configDirectory))
        XCTAssertEqual(
            try Data(contentsOf: fixture.layout.legacyPlistBackup),
            collision.payload
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.layout.modelFile.path))

        try FileManager.default.removeItem(at: fixture.layout.legacyPlistBackup)
        let retryRunner = MigrationRunner(initiallyLoaded: true)
        try await fixture.migrator(
            runner: retryRunner,
            health: MigrationHealth(healthy: true)
        ).migrate(options: fixture.options)

        XCTAssertEqual(
            try Data(contentsOf: fixture.layout.legacyPlistBackup),
            fixture.legacyData
        )
        XCTAssertFalse(containsBackupTemporaryFile(under: fixture.layout.configDirectory))
    }

    func testRecordSaveFailureRollsBackAndRollbackFailureIsSurfaced() async throws {
        do {
            let fixture = try MigrationFixture()
            defer { fixture.remove() }
            let records = RecordingRecordStore(failSave: true)
            let runner = MigrationRunner(initiallyLoaded: true)
            let migrator = fixture.migrator(
                runner: runner,
                records: records,
                health: MigrationHealth(healthy: true)
            )

            do {
                try await migrator.migrate(options: fixture.options)
                XCTFail("Expected record save failure")
            } catch {
                XCTAssertTrue(error is RecordingRecordStore.Failure)
            }
            let serviceLoaded = await runner.serviceLoaded()
            XCTAssertTrue(serviceLoaded)
            XCTAssertEqual(try Data(contentsOf: fixture.legacyPlist), fixture.legacyData)
            XCTAssertEqual(try fileMode(fixture.legacyPlist), fixture.legacyMode)
            XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.layout.modelFile.path))
            XCTAssertNil(try InstallationRecordStore().load(layout: fixture.layout))
        }

        do {
            let fixture = try MigrationFixture()
            defer { fixture.remove() }
            let records = RecordingRecordStore(failSave: true)
            let runner = MigrationRunner(
                initiallyLoaded: true,
                bootstrapOutcomes: [.success, .failure]
            )
            let migrator = fixture.migrator(
                runner: runner,
                records: records,
                health: MigrationHealth(healthy: true)
            )

            do {
                try await migrator.migrate(options: fixture.options)
                XCTFail("Expected rollback failure")
            } catch {
                guard case .rollbackFailed(let message) = error as? LegacyMigrationError else {
                    return XCTFail("Expected rollback failure, received \(error)")
                }
                XCTAssertTrue(message.contains("legacy bootstrap failed"))
            }
        }
    }

    func testRejectsSymlinkRootAndIntermediateConfigDirectory() async throws {
        do {
            let fixture = try MigrationFixture()
            defer { fixture.remove() }
            let realRoot = fixture.root.appending(path: "managed-real")
            try FileManager.default.moveItem(at: fixture.layout.root, to: realRoot)
            try FileManager.default.createSymbolicLink(
                atPath: fixture.layout.root.path,
                withDestinationPath: realRoot.path
            )
            let runner = MigrationRunner(initiallyLoaded: true)

            await XCTAssertThrowsErrorAsync {
                try await fixture.migrator(
                    runner: runner,
                    health: MigrationHealth(healthy: true)
                ).migrate(options: fixture.options)
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: realRoot.appending(path: "models/\(InstallationLayout.modelFilename)").path))
            let commands = await runner.commandArguments()
            XCTAssertTrue(commands.isEmpty)
        }

        do {
            let fixture = try MigrationFixture()
            defer { fixture.remove() }
            let outside = fixture.root.appending(path: "outside-config")
            try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(
                atPath: fixture.layout.configDirectory.path,
                withDestinationPath: outside.path
            )
            let runner = MigrationRunner(initiallyLoaded: true)

            await XCTAssertThrowsErrorAsync {
                try await fixture.migrator(
                    runner: runner,
                    health: MigrationHealth(healthy: true)
                ).migrate(options: fixture.options)
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: outside.appending(path: "legacy-launch-agent.plist").path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.layout.modelFile.path))
            let commands = await runner.commandArguments()
            XCTAssertTrue(commands.isEmpty)
        }
    }

    private func makeRoot() throws -> URL {
        try makeLegacyMigrationTestRoot()
    }

    private func hash(of data: Data) -> String {
        let file = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try! data.write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        return try! SHA256Hasher().sha256(file: file)
    }

    private func fileMode(_ url: URL) throws -> mode_t {
        var metadata = stat()
        guard lstat(url.path, &metadata) == 0 else { throw CocoaError(.fileReadUnknown) }
        return metadata.st_mode & 0o777
    }

    private func fileIdentity(_ url: URL) throws -> POSIXFileIdentity {
        var metadata = stat()
        guard lstat(url.path, &metadata) == 0 else {
            throw CocoaError(.fileReadUnknown)
        }
        return POSIXFileIdentity(metadata)
    }

    private func containsModelTemporaryFile(under root: URL) -> Bool {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: nil
        ) else { return false }
        return enumerator.compactMap { ($0 as? URL)?.lastPathComponent }
            .contains { $0.hasPrefix(".model-") && $0.hasSuffix(".tmp") }
    }

    private func containsPayload(_ payload: Data, under root: URL) -> Bool {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey]
        ) else { return false }
        return enumerator.compactMap { $0 as? URL }.contains { candidate in
            (try? candidate.resourceValues(forKeys: [.isRegularFileKey])
                .isRegularFile) == true
                && (try? Data(contentsOf: candidate)) == payload
        }
    }

    private func containsBackupTemporaryFile(under directory: URL) -> Bool {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else {
            return false
        }
        return names.contains {
            $0.hasPrefix(".legacy-backup-") && $0.hasSuffix(".tmp")
        }
    }
}

private final class MigrationFixture: @unchecked Sendable {
    let root: URL
    let layout: InstallationLayout
    let manifest: DeploymentManifest
    let options: DeploymentOptions
    let agents: URL
    let legacyPlist: URL
    let legacyData: Data
    let legacyMode: mode_t
    let source: URL
    let sourceData: Data

    init() throws {
        root = try makeLegacyMigrationTestRoot()
        layout = InstallationLayout(root: root.appending(path: "managed"))
        sourceData = Data("migration model".utf8)
        let sourceHash = try MigrationFixture.hash(sourceData)
        manifest = DeploymentManifest(
            schemaVersion: 1,
            runtime: .init(version: "runtime-1", archive: .init(filename: "runtime", sourceURL: URL(string: "https://example.com/runtime")!, size: 1, sha256: String(repeating: "a", count: 64)), directoryName: "runtime-1", serverRelativePath: "llama-server"),
            model: .init(filename: InstallationLayout.modelFilename, sourceURL: URL(string: "https://example.com/model")!, size: Int64(sourceData.count), sha256: sourceHash),
            service: .init(label: "com.local.qwythos-9b", port: 18_080)
        )
        options = .init(root: layout.root, contextSize: 8_192, accessMode: .local)
        let server = layout.runtimeServer(version: manifest.runtime.version)
        try FileManager.default.createDirectory(at: server.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("server".utf8).write(to: server)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: server.path)
        try FileManager.default.createDirectory(at: layout.runtimeDirectory, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            atPath: layout.runtimeCurrent.path,
            withDestinationPath: layout.runtimeVersion(manifest.runtime.version).path
        )
        agents = root.appending(path: "LaunchAgents")
        legacyPlist = agents.appending(path: "com.local.qwythos-9b.plist")
        legacyData = try PropertyListSerialization.data(fromPropertyList: ["Label": "com.local.qwythos-9b", "Program": "/opt/bin/llama-server"], format: .xml, options: 0)
        legacyMode = 0o640
        try FileManager.default.createDirectory(at: agents, withIntermediateDirectories: true)
        try legacyData.write(to: legacyPlist)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: legacyMode)],
            ofItemAtPath: legacyPlist.path
        )
        source = root.appending(path: "cache/blobs/\(sourceHash)")
        try FileManager.default.createDirectory(at: source.deletingLastPathComponent(), withIntermediateDirectories: true)
        try sourceData.write(to: source)
    }

    func migrator(
        runner: MigrationRunner,
        records: any InstallationRecordStoring = InstallationRecordStore(),
        modelLocator: (any LegacyModelLocating)? = nil,
        reuser: any ModelReusing = ModelReuser(),
        installer: (any LaunchAgentInstalling)? = nil,
        health: any HealthChecking,
        sleeper: any DeploymentSleeping = ImmediateDeploymentSleeper(),
        healthPollAttempts: Int = 1,
        beforeBackupInstall: LegacyInstallationMigrator.BackupInstallHook? = nil,
        beforeLegacyRestore: LegacyInstallationMigrator.BeforeLegacyRestoreHook? = nil,
        fileOperations: LegacyInstallationMigrator.FileOperations = .live
    ) -> LegacyInstallationMigrator {
        return LegacyInstallationMigrator(
            layout: layout, manifest: manifest, launchAgentsDirectory: agents,
            records: records,
            modelLocator: modelLocator ?? FixedModelLocator(source: source),
            modelReuser: reuser,
            launchAgentInstaller: installer,
            commandRunner: runner,
            healthChecker: health,
            uid: 501,
            beforeBackupInstall: beforeBackupInstall ?? { _, _ in },
            beforeLegacyRestore: beforeLegacyRestore ?? {},
            fileOperations: fileOperations,
            sleeper: sleeper,
            healthPollAttempts: healthPollAttempts
        )
    }

    func remove() { try? FileManager.default.removeItem(at: root) }

    private static func hash(_ data: Data) throws -> String {
        let file = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try data.write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        return try SHA256Hasher().sha256(file: file)
    }
}

private struct FixedModelLocator: LegacyModelLocating {
    let source: URL
    func locate(modelSHA256: String) throws -> URL? { source }
}

private struct MissingModelLocator: LegacyModelLocating {
    func locate(modelSHA256: String) throws -> URL? { nil }
}

private struct RejectingModelReuser: ModelReusing {
    func reuse(
        _ source: URL,
        at destination: URL,
        expectedSHA256: String
    ) throws -> ModelReuseResult {
        XCTFail("A verified retained model must not be copied again")
        return .downloadRequired
    }
}

private struct DownloadRequiredReuser: ModelReusing {
    func reuse(_ source: URL, at destination: URL, expectedSHA256: String) throws -> ModelReuseResult { .downloadRequired }
}

private struct EventModelReuser: ModelReusing {
    let events: MigrationEventLog

    func reuse(
        _ source: URL,
        at destination: URL,
        expectedSHA256: String
    ) throws -> ModelReuseResult {
        events.append("model")
        return try ModelReuser().reuse(
            source,
            at: destination,
            expectedSHA256: expectedSHA256
        )
    }
}

private final class OpaqueReplacingModelReuser: ModelReusing, @unchecked Sendable {
    private let lock = NSLock()
    private var identity: POSIXFileIdentity?

    func reuse(
        _ source: URL,
        at destination: URL,
        expectedSHA256: String
    ) throws -> ModelReuseResult {
        _ = try ModelReuser().reuse(
            source,
            at: destination,
            expectedSHA256: expectedSHA256
        )
        let data = try Data(contentsOf: source)
        try FileManager.default.removeItem(at: destination)
        try data.write(to: destination)
        var metadata = stat()
        guard lstat(destination.path, &metadata) == 0 else {
            throw POSIXError(
                POSIXErrorCode(rawValue: errno) ?? .EIO
            )
        }
        lock.lock()
        identity = POSIXFileIdentity(metadata)
        lock.unlock()
        return .reused
    }

    func replacementIdentity() -> POSIXFileIdentity? {
        lock.lock()
        defer { lock.unlock() }
        return identity
    }
}

private struct EventLaunchAgentInstaller: LaunchAgentInstalling, LaunchAgentPreparing {
    let delegate: LaunchAgentInstaller
    let events: MigrationEventLog

    func install(
        layout: InstallationLayout,
        options: DeploymentOptions,
        manifest: DeploymentManifest
    ) throws {
        events.append("install")
        try delegate.install(
            layout: layout,
            options: options,
            manifest: manifest
        )
    }

    func prepareInstallation(
        layout: InstallationLayout,
        options: DeploymentOptions,
        manifest: DeploymentManifest
    ) throws -> Data {
        events.append("install")
        return try delegate.prepareInstallation(
            layout: layout,
            options: options,
            manifest: manifest
        )
    }

    func restoreLegacyPlist(layout: InstallationLayout) throws {
        try delegate.restoreLegacyPlist(layout: layout)
    }

    func uninstall() throws {
        try delegate.uninstall()
    }
}

private struct FailingLaunchAgentInstaller: LaunchAgentInstalling, LaunchAgentPreparing {
    enum Failure: Error {
        case install
    }

    func install(
        layout: InstallationLayout,
        options: DeploymentOptions,
        manifest: DeploymentManifest
    ) throws {
        throw Failure.install
    }

    func prepareInstallation(
        layout: InstallationLayout,
        options: DeploymentOptions,
        manifest: DeploymentManifest
    ) throws -> Data {
        throw Failure.install
    }

    func restoreLegacyPlist(layout: InstallationLayout) throws {}
    func uninstall() throws {}
}

private struct NonPreparingLaunchAgentInstaller: LaunchAgentInstalling {
    func install(
        layout: InstallationLayout,
        options: DeploymentOptions,
        manifest: DeploymentManifest
    ) throws {}

    func restoreLegacyPlist(layout: InstallationLayout) throws {}
    func uninstall() throws {}
}

private struct WriteThenFailLaunchAgentInstaller: LaunchAgentInstalling, LaunchAgentPreparing {
    enum Failure: Error {
        case install
    }

    let delegate: LaunchAgentInstaller

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
        throw Failure.install
    }

    func prepareInstallation(
        layout: InstallationLayout,
        options: DeploymentOptions,
        manifest: DeploymentManifest
    ) throws -> Data {
        try delegate.install(
            layout: layout,
            options: options,
            manifest: manifest
        )
        throw Failure.install
    }

    func restoreLegacyPlist(layout: InstallationLayout) throws {
        try delegate.restoreLegacyPlist(layout: layout)
    }

    func uninstall() throws {
        try delegate.uninstall()
    }
}

private struct ReplaceBeforePublishLaunchAgentInstaller: LaunchAgentInstalling, LaunchAgentPreparing {
    let delegate: LaunchAgentInstaller
    let plistURL: URL
    let replacement: Data

    func prepareInstallation(
        layout: InstallationLayout,
        options: DeploymentOptions,
        manifest: DeploymentManifest
    ) throws -> Data {
        let data = try delegate.prepareInstallation(
            layout: layout,
            options: options,
            manifest: manifest
        )
        try replacement.write(to: plistURL, options: .atomic)
        return data
    }

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
    }

    func restoreLegacyPlist(layout: InstallationLayout) throws {
        try delegate.restoreLegacyPlist(layout: layout)
    }

    func uninstall() throws {
        try delegate.uninstall()
    }
}

private struct MigrationHealth: HealthChecking {
    let healthy: Bool
    let events: MigrationEventLog?
    let cancelOnCheck: Bool
    let onCheck: @Sendable () -> Void

    init(
        healthy: Bool,
        events: MigrationEventLog? = nil,
        cancelOnCheck: Bool = false,
        onCheck: @escaping @Sendable () -> Void = {}
    ) {
        self.healthy = healthy
        self.events = events
        self.cancelOnCheck = cancelOnCheck
        self.onCheck = onCheck
    }

    func isHealthy(_ url: URL) async -> Bool {
        events?.append("health")
        onCheck()
        if cancelOnCheck {
            withUnsafeCurrentTask { $0?.cancel() }
        }
        return healthy
    }
}

private final class SequencedMigrationHealth:
    HealthChecking,
    @unchecked Sendable
{
    private let lock = NSLock()
    private var results: [Bool]
    private var calls = 0

    init(results: [Bool]) {
        self.results = results
    }

    var callCount: Int {
        lock.withLock { calls }
    }

    func isHealthy(_ url: URL) async -> Bool {
        lock.withLock {
            calls += 1
            return results.isEmpty ? false : results.removeFirst()
        }
    }
}

private actor MigrationRunner: CommandRunning {
    enum BootoutOutcome: Sendable {
        case success
        case cancelledAfterEffect
        case timedOutAfterEffect
        case failureWithoutEffect
    }

    enum BootstrapOutcome: Sendable {
        case success
        case failure
        case successThenUnload
    }

    private var loaded: Bool
    private let events: MigrationEventLog?
    private let failFirstQuery: Bool
    private let cancelAfterFirstQuery: Bool
    private var queryCount = 0
    private var bootoutOutcomes: [BootoutOutcome]
    private var bootstrapOutcomes: [BootstrapOutcome]
    private var recorded: [LaunchCommand] = []

    init(
        initiallyLoaded: Bool,
        events: MigrationEventLog? = nil,
        failFirstQuery: Bool = false,
        cancelAfterFirstQuery: Bool = false,
        bootoutOutcomes: [BootoutOutcome] = [],
        bootstrapOutcomes: [BootstrapOutcome] = []
    ) {
        loaded = initiallyLoaded
        self.events = events
        self.failFirstQuery = failFirstQuery
        self.cancelAfterFirstQuery = cancelAfterFirstQuery
        self.bootoutOutcomes = bootoutOutcomes
        self.bootstrapOutcomes = bootstrapOutcomes
    }

    func run(_ command: LaunchCommand) async -> CommandResult {
        recorded.append(command)
        events?.append("command:\(command.arguments.joined(separator: " "))")
        switch command.arguments.first {
        case "print":
            queryCount += 1
            if failFirstQuery && queryCount == 1 {
                return .init(exitCode: 1, output: "launchctl failed")
            }
            if cancelAfterFirstQuery && queryCount == 1 {
                withUnsafeCurrentTask { $0?.cancel() }
            }
            return .init(
                exitCode: loaded ? 0 : 113,
                output: loaded ? "state = running" : "Could not find service in domain for user gui: 501"
            )
        case "bootout":
            let outcome = bootoutOutcomes.isEmpty ? .success : bootoutOutcomes.removeFirst()
            switch outcome {
            case .success:
                loaded = false
                return .init(exitCode: 0, output: "")
            case .cancelledAfterEffect:
                loaded = false
                withUnsafeCurrentTask { $0?.cancel() }
                return .init(exitCode: -2, output: "Command cancelled.")
            case .timedOutAfterEffect:
                loaded = false
                return .init(exitCode: -3, output: "Command timed out.")
            case .failureWithoutEffect:
                return .init(exitCode: 1, output: "bootout failed")
            }
        case "bootstrap":
            let outcome = bootstrapOutcomes.isEmpty
                ? BootstrapOutcome.success
                : bootstrapOutcomes.removeFirst()
            switch outcome {
            case .success:
                loaded = true
                return .init(exitCode: 0, output: "")
            case .successThenUnload:
                loaded = false
                return .init(exitCode: 0, output: "")
            case .failure:
                return .init(exitCode: 1, output: "bootstrap failed")
            }
        default:
            return .init(exitCode: 1, output: "unexpected command")
        }
    }

    func commands() -> [LaunchCommand] { recorded }
    func commandArguments() -> [[String]] { recorded.map(\.arguments) }
    func serviceLoaded() -> Bool { loaded }
}

private final class MigrationEventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [String] = []

    func append(_ event: String) {
        lock.lock()
        events.append(event)
        lock.unlock()
    }

    func snapshot() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return events
    }
}

private final class RecordingRecordStore: InstallationRecordStoring, @unchecked Sendable {
    enum Failure: Error {
        case save
    }

    private let store = InstallationRecordStore()
    private let failSave: Bool
    private let writeBeforeFailure: Bool
    private let events: MigrationEventLog?

    init(
        events: MigrationEventLog? = nil,
        failSave: Bool = false,
        writeBeforeFailure: Bool = false
    ) {
        self.events = events
        self.failSave = failSave
        self.writeBeforeFailure = writeBeforeFailure
    }

    func load(layout: InstallationLayout) throws -> InstallationRecord? {
        try store.load(layout: layout)
    }

    func save(_ record: InstallationRecord, layout: InstallationLayout) throws {
        events?.append("record-save")
        if failSave, !writeBeforeFailure { throw Failure.save }
        try store.save(record, layout: layout)
        if failSave { throw Failure.save }
    }

    func remove(layout: InstallationLayout) throws {
        try store.remove(layout: layout)
    }

    func remove(
        ifMatching expectedRecord: InstallationRecord,
        layout: InstallationLayout
    ) throws -> Bool {
        try store.remove(ifMatching: expectedRecord, layout: layout)
    }
}

private struct ReplacingRollbackRecordStore: InstallationRecordStoring {
    enum Failure: Error {
        case save
    }

    private let store: InstallationRecordStore

    init(replacement: InstallationRecord) throws {
        let data = try JSONEncoder().encode(replacement)
        store = InstallationRecordStore(
            beforeRecordRead: { directoryDescriptor, name in
                guard unlinkat(directoryDescriptor, name, 0) == 0 else {
                    throw CocoaError(.fileWriteUnknown)
                }
                let descriptor = openat(
                    directoryDescriptor,
                    name,
                    O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
                    0o600
                )
                guard descriptor >= 0 else {
                    throw CocoaError(.fileWriteUnknown)
                }
                defer { _ = close(descriptor) }
                let written = data.withUnsafeBytes {
                    Darwin.write(descriptor, $0.baseAddress, $0.count)
                }
                guard written == data.count, fsync(descriptor) == 0 else {
                    throw CocoaError(.fileWriteUnknown)
                }
            }
        )
    }

    func load(layout: InstallationLayout) throws -> InstallationRecord? {
        try store.load(layout: layout)
    }

    func save(
        _ record: InstallationRecord,
        layout: InstallationLayout
    ) throws {
        try store.save(record, layout: layout)
        throw Failure.save
    }

    func remove(layout: InstallationLayout) throws {
        try store.remove(layout: layout)
    }

    func remove(
        ifMatching expectedRecord: InstallationRecord,
        layout: InstallationLayout
    ) throws -> Bool {
        try store.remove(ifMatching: expectedRecord, layout: layout)
    }
}

private final class FailOnHashCall: FileHashing, @unchecked Sendable {
    private let lock = NSLock()
    private let failingCall: Int
    private var callCount = 0
    private let hasher = SHA256Hasher()

    init(failingCall: Int) {
        self.failingCall = failingCall
    }

    func sha256(file: URL) throws -> String {
        lock.lock()
        callCount += 1
        let shouldFail = callCount == failingCall
        lock.unlock()
        if shouldFail { return String(repeating: "0", count: 64) }
        return try hasher.sha256(file: file)
    }
}

private final class ReplaceOnHashCall: FileHashing, @unchecked Sendable {
    let payload = Data("replacement during descriptor hash".utf8)

    private let lock = NSLock()
    private let path: URL
    private let replacingCall: Int
    private var callCount = 0
    private let hasher = SHA256Hasher()

    init(path: URL, call: Int) {
        self.path = path
        replacingCall = call
    }

    func sha256(file: URL) throws -> String {
        try hasher.sha256(file: file)
    }

    func sha256(fileDescriptor: Int32) throws -> String {
        lock.lock()
        callCount += 1
        let shouldReplace = callCount == replacingCall
        lock.unlock()
        if shouldReplace {
            try FileManager.default.removeItem(at: path)
            try payload.write(to: path)
        }
        return try hasher.sha256(fileDescriptor: fileDescriptor)
    }
}

private final class OneShotBackupCollision: @unchecked Sendable {
    let payload = Data("concurrent backup".utf8)
    private let lock = NSLock()
    private var installed = false

    func install(directoryDescriptor: Int32, name: String) throws {
        lock.lock()
        let shouldInstall = !installed
        installed = true
        lock.unlock()
        guard shouldInstall else { return }

        let descriptor = openat(
            directoryDescriptor,
            name,
            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
            0o600
        )
        guard descriptor >= 0 else { throw CocoaError(.fileWriteUnknown) }
        defer { _ = close(descriptor) }
        let bytes = [UInt8](payload)
        let count = bytes.withUnsafeBytes {
            write(descriptor, $0.baseAddress, $0.count)
        }
        guard count == bytes.count, fsync(descriptor) == 0 else {
            throw CocoaError(.fileWriteUnknown)
        }
    }
}

private final class ReplaceInstalledModel: @unchecked Sendable {
    let payload = Data("unrelated replacement".utf8)

    func replace(directoryDescriptor: Int32, name: String) throws {
        guard unlinkat(directoryDescriptor, name, 0) == 0 else {
            throw CocoaError(.fileWriteUnknown)
        }
        let descriptor = openat(
            directoryDescriptor,
            name,
            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
            0o600
        )
        guard descriptor >= 0 else { throw CocoaError(.fileWriteUnknown) }
        defer { _ = close(descriptor) }
        let bytes = [UInt8](payload)
        let count = bytes.withUnsafeBytes {
            write(descriptor, $0.baseAddress, $0.count)
        }
        guard count == bytes.count, fsync(descriptor) == 0 else {
            throw CocoaError(.fileWriteUnknown)
        }
    }
}

private final class DirectorySyncFailure: @unchecked Sendable {
    private let lock = NSLock()
    private let failingCall: Int
    private var callCount = 0

    init(failingCall: Int) {
        self.failingCall = failingCall
    }

    func sync(_ descriptor: Int32) -> Int32 {
        lock.lock()
        callCount += 1
        let shouldFail = callCount == failingCall
        lock.unlock()
        if shouldFail {
            errno = EIO
            return -1
        }
        return fsync(descriptor)
    }
}

private final class PersistentDirectorySyncFailure: @unchecked Sendable {
    private let lock = NSLock()
    private let startingCall: Int
    private var callCount = 0

    init(startingAt startingCall: Int) {
        self.startingCall = startingCall
    }

    func sync(_ descriptor: Int32) -> Int32 {
        lock.lock()
        callCount += 1
        let shouldFail = callCount >= startingCall
        lock.unlock()
        if shouldFail {
            errno = EIO
            return -1
        }
        return fsync(descriptor)
    }
}

private func XCTAssertThrowsErrorAsync(
    _ expression: () async throws -> Void,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        try await expression()
        XCTFail("Expected expression to throw", file: file, line: line)
    } catch {
        // Expected.
    }
}

private func makeLegacyMigrationTestRoot() throws -> URL {
    let packageRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let base = packageRoot.appending(path: ".build/legacy-migration-tests")
    let root = base.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(
        at: root,
        withIntermediateDirectories: true
    )
    return root
}
