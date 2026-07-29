import Darwin
import Foundation
import XCTest
import QwythosCore
@testable import QwythosDeployment

final class InstallationInspectorTests: XCTestCase {
    func testClassifiesManagedInstallationAndDoesNotMutateIt() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let layout = InstallationLayout(root: root)
        let manifest = makeManifest(modelHash: hash(of: Data("model".utf8)))
        let record = InstallationRecord(
            manifestSchemaVersion: manifest.schemaVersion,
            root: root,
            runtimeVersion: manifest.runtime.version,
            modelSHA256: manifest.model.sha256,
            contextSize: 8_192,
            accessMode: .local,
            installedAt: Date(timeIntervalSince1970: 1)
        )
        try writeManagedFiles(layout: layout, manifest: manifest)
        try InstallationRecordStore().save(record, layout: layout)
        let plist = root.appending(path: "LaunchAgents")
        try FileManager.default.createDirectory(at: plist, withIntermediateDirectories: true)
        try LaunchAgentInstaller(launchAgentsDirectory: plist).install(
            layout: layout,
            options: .init(root: root, contextSize: 8_192, accessMode: .local),
            manifest: manifest
        )

        let inspector = InstallationInspector(
            layout: layout,
            manifest: manifest,
            launchAgentsDirectory: plist,
            healthChecker: InspectorHealthChecker(healthy: true),
            serviceChecker: InspectorServiceChecker(loaded: true)
        )

        let status = await inspector.inspect()
        XCTAssertEqual(status, .managedHealthy(record))
        XCTAssertEqual(try InstallationRecordStore().load(layout: layout), record)
    }

    func testSharedInstallationWithInsecureAPIKeyIsRepairable() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let layout = InstallationLayout(root: root)
        let manifest = makeManifest(modelHash: hash(of: Data("model".utf8)))
        let record = InstallationRecord(
            manifestSchemaVersion: manifest.schemaVersion,
            root: root,
            runtimeVersion: manifest.runtime.version,
            modelSHA256: manifest.model.sha256,
            contextSize: 8_192,
            accessMode: .shared,
            installedAt: Date()
        )
        try writeManagedFiles(layout: layout, manifest: manifest)
        try InstallationRecordStore().save(record, layout: layout)
        let agents = root.appending(path: "LaunchAgents")
        try LaunchAgentInstaller(launchAgentsDirectory: agents).install(
            layout: layout,
            options: .init(root: root, contextSize: 8_192, accessMode: .shared),
            manifest: manifest
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o644],
            ofItemAtPath: layout.apiKeyFile.path
        )

        let status = await InstallationInspector(
            layout: layout,
            manifest: manifest,
            launchAgentsDirectory: agents,
            healthChecker: InspectorHealthChecker(healthy: true),
            serviceChecker: InspectorServiceChecker(loaded: true)
        ).inspect()

        XCTAssertEqual(status, .managedRepairable(record, [.configuration]))
    }

    func testServicePortOwnershipRequiresLaunchdPIDAndMatchingListener() async {
        let runner = InspectorCommandRunner(
            launchctl: .init(exitCode: 0, output: "pid = 123\n"),
            lsof: .init(exitCode: 0, output: "llama-server 123 user 3u IPv4 TCP 127.0.0.1:18080 (LISTEN)\n")
        )
        let checker = SystemInstallationServicePortChecker(
            runner: runner,
            uid: 501
        )

        let ownsPort = await checker.ownsServicePort(
            18_080,
            label: "com.local.qwythos-9b"
        )
        XCTAssertTrue(ownsPort)
        XCTAssertEqual(
            runner.commands,
            [
                .init(
                    executable: "/bin/launchctl",
                    arguments: ["print", "gui/501/com.local.qwythos-9b"]
                ),
                .init(
                    executable: "/usr/sbin/lsof",
                    arguments: [
                        "-nP", "-a", "-p", "123",
                        "-iTCP:18080", "-sTCP:LISTEN",
                    ]
                ),
            ]
        )
    }

    func testManagedInspectionFailsClosedWhenRootGenerationChanges() async throws {
        let container = try makeRoot()
        defer { try? FileManager.default.removeItem(at: container) }
        let root = container.appending(path: "managed")
        let replacementRoot = container.appending(path: "replacement")
        let detachedRoot = container.appending(path: "detached")
        let layout = InstallationLayout(root: root)
        let replacementLayout = InstallationLayout(root: replacementRoot)
        let model = Data("model".utf8)
        let manifest = makeManifest(modelHash: hash(of: model))
        let record = InstallationRecord(
            manifestSchemaVersion: manifest.schemaVersion,
            root: root,
            runtimeVersion: manifest.runtime.version,
            modelSHA256: manifest.model.sha256,
            contextSize: 8_192,
            accessMode: .local,
            installedAt: Date(timeIntervalSince1970: 1)
        )

        try FileManager.default.createDirectory(
            at: layout.modelsDirectory,
            withIntermediateDirectories: true
        )
        try model.write(to: layout.modelFile)
        try writeManagedFiles(
            layout: replacementLayout,
            manifest: manifest
        )
        try FileManager.default.removeItem(at: replacementLayout.modelFile)
        try FileManager.default.removeItem(at: replacementLayout.runtimeCurrent)
        try FileManager.default.createSymbolicLink(
            atPath: replacementLayout.runtimeCurrent.path,
            withDestinationPath: layout
                .runtimeVersion(manifest.runtime.version)
                .path
        )
        let agents = container.appending(path: "LaunchAgents")
        try LaunchAgentInstaller(launchAgentsDirectory: agents).install(
            layout: layout,
            options: .init(
                root: root,
                contextSize: 8_192,
                accessMode: .local
            ),
            manifest: manifest
        )

        let status = await InstallationInspector(
            layout: layout,
            manifest: manifest,
            records: ReplacingInspectorRootRecordStore(
                record: record,
                root: root,
                replacementRoot: replacementRoot,
                detachedRoot: detachedRoot
            ),
            launchAgentsDirectory: agents,
            healthChecker: InspectorHealthChecker(healthy: true),
            serviceChecker: InspectorServiceChecker(loaded: true)
        ).inspect()

        XCTAssertEqual(status, .installationRootUnavailable(root))
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: layout.modelFile.path)
        )
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: detachedRoot
                    .appending(path: "models")
                    .appending(path: InstallationLayout.modelFilename)
                    .path
            )
        )
    }

    func testClassifiesPartialDownloadBeforeLegacyInstall() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let layout = InstallationLayout(root: root)
        let manifest = makeManifest()
        try FileManager.default.createDirectory(at: layout.downloadsDirectory, withIntermediateDirectories: true)
        try Data("partial".utf8).write(to: layout.partialFile(for: manifest.model))
        let agents = root.appending(path: "LaunchAgents")
        try writeLegacyPlist(at: agents.appending(path: "com.local.qwythos-9b.plist"))

        let inspector = InstallationInspector(layout: layout, manifest: manifest, launchAgentsDirectory: agents)

        let status = await inspector.inspect()
        XCTAssertEqual(status, .partiallyDownloaded)
    }

    func testDetectsOnlyRecognizedLegacyLaunchAgent() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let agents = root.appending(path: "LaunchAgents")
        try FileManager.default.createDirectory(at: root.appending(path: "managed"), withIntermediateDirectories: true)
        try writeLegacyPlist(at: agents.appending(path: "com.local.qwythos-9b.plist"))
        let inspector = InstallationInspector(
            layout: .init(root: root.appending(path: "managed")),
            manifest: makeManifest(),
            launchAgentsDirectory: agents
        )
        let legacyStatus = await inspector.inspect()
        XCTAssertEqual(legacyStatus, .legacyDetected)

        try writePlist(
            ["Label": "not-qwythos", "ProgramArguments": ["/opt/llama-server", "--port", "18080"]],
            to: agents.appending(path: "not-qwythos.plist")
        )
        try FileManager.default.removeItem(at: agents.appending(path: "com.local.qwythos-9b.plist"))
        try FileManager.default.createDirectory(at: root.appending(path: "managed"), withIntermediateDirectories: true)
        let emptyStatus = await inspector.inspect()
        XCTAssertEqual(emptyStatus, .notInstalled)
    }

    func testRejectsRelativeLaunchAgentDirectory() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let managedRoot = root.appending(path: "managed")
        try FileManager.default.createDirectory(
            at: managedRoot,
            withIntermediateDirectories: true
        )
        let agents = root.appending(path: "LaunchAgents")
        try writeLegacyPlist(
            at: agents.appending(path: "com.local.qwythos-9b.plist")
        )
        let base = URL(fileURLWithPath: root.path, isDirectory: true)
        let relativeAgents = URL(
            fileURLWithPath: "LaunchAgents",
            relativeTo: base
        )
        XCTAssertEqual(relativeAgents.standardizedFileURL.path, agents.path)

        let status = await InstallationInspector(
            layout: .init(root: managedRoot),
            manifest: makeManifest(),
            launchAgentsDirectory: relativeAgents
        ).inspect()

        XCTAssertEqual(status, .notInstalled)
    }

    func testPreservesUnavailableCustomRootAsItsOwnStatus() async {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let inspector = InstallationInspector(
            layout: .init(root: root),
            manifest: makeManifest(),
            launchAgentsDirectory: root.appending(path: "LaunchAgents")
        )
        let status = await inspector.inspect()
        XCTAssertEqual(status, .installationRootUnavailable(root.standardizedFileURL))
    }

    func testUnlocatedDiscoveryTreatsMissingDefaultRootAsCleanOrLegacy() async throws {
        let container = try makeRoot()
        defer { try? FileManager.default.removeItem(at: container) }
        let missingRoot = container.appending(path: "missing-managed-root")
        let agents = container.appending(path: "LaunchAgents")
        let inspector = InstallationInspector(
            layout: .init(root: missingRoot),
            manifest: makeManifest(),
            launchAgentsDirectory: agents
        )

        let cleanStatus = await inspector.inspectUnlocatedDefaultRoot()
        XCTAssertEqual(cleanStatus, .notInstalled)

        try writeLegacyPlist(
            at: agents.appending(path: "com.local.qwythos-9b.plist")
        )
        let legacyStatus = await inspector.inspectUnlocatedDefaultRoot()
        XCTAssertEqual(legacyStatus, .legacyDetected)
    }

    func testReportsRuntimeDamageAsRepairable() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let layout = InstallationLayout(root: root)
        let manifest = makeManifest(modelHash: hash(of: Data("model".utf8)))
        let record = InstallationRecord(
            manifestSchemaVersion: manifest.schemaVersion, root: root,
            runtimeVersion: manifest.runtime.version, modelSHA256: manifest.model.sha256,
            contextSize: 8_192, accessMode: .local, installedAt: Date()
        )
        try FileManager.default.createDirectory(at: layout.modelsDirectory, withIntermediateDirectories: true)
        try Data("model".utf8).write(to: layout.modelFile)
        try InstallationRecordStore().save(record, layout: layout)

        try writeManagedFiles(layout: layout, manifest: manifest)
        let agents = root.appending(path: "LaunchAgents")
        try LaunchAgentInstaller(launchAgentsDirectory: agents).install(
            layout: layout,
            options: .init(root: root, contextSize: 8_192, accessMode: .local),
            manifest: manifest
        )
        try FileManager.default.removeItem(at: layout.runtimeCurrent)
        let inspector = InstallationInspector(
            layout: layout,
            manifest: manifest,
            launchAgentsDirectory: agents,
            healthChecker: InspectorHealthChecker(healthy: true),
            serviceChecker: InspectorServiceChecker(loaded: true)
        )
        let status = await inspector.inspect()
        XCTAssertEqual(status, .managedRepairable(record, [.runtime]))
    }

    func testRuntimeVersionDriftRetainsManagedRecordForUpdateActions() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let layout = InstallationLayout(root: root)
        let modelHash = hash(of: Data("model".utf8))
        let installedManifest = makeManifest(modelHash: modelHash)
        let bundledManifest = DeploymentManifest(
            schemaVersion: installedManifest.schemaVersion,
            runtime: .init(
                version: "runtime-2",
                archive: installedManifest.runtime.archive,
                directoryName: "runtime-2",
                serverRelativePath: installedManifest.runtime.serverRelativePath
            ),
            model: installedManifest.model,
            service: installedManifest.service
        )
        let record = InstallationRecord(
            manifestSchemaVersion: bundledManifest.schemaVersion,
            root: root,
            runtimeVersion: installedManifest.runtime.version,
            modelSHA256: bundledManifest.model.sha256,
            contextSize: 8_192,
            accessMode: .local,
            installedAt: Date()
        )
        try writeManagedFiles(
            layout: layout,
            manifest: installedManifest
        )
        try InstallationRecordStore().save(record, layout: layout)
        let agents = root.appending(path: "LaunchAgents")
        try LaunchAgentInstaller(launchAgentsDirectory: agents).install(
            layout: layout,
            options: .init(
                root: root,
                contextSize: record.contextSize,
                accessMode: record.accessMode
            ),
            manifest: bundledManifest
        )

        let status = await InstallationInspector(
            layout: layout,
            manifest: bundledManifest,
            launchAgentsDirectory: agents,
            healthChecker: InspectorHealthChecker(healthy: true),
            serviceChecker: InspectorServiceChecker(loaded: true)
        ).inspect()

        XCTAssertEqual(status, .managedHealthy(record))
    }

    func testRejectsRecordWithUnsupportedSchemaWithoutInspectingFiles() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let layout = InstallationLayout(root: root)
        let record = InstallationRecord(
            schemaVersion: 99, manifestSchemaVersion: 1, root: root,
            runtimeVersion: "runtime-1", modelSHA256: String(repeating: "a", count: 64),
            contextSize: 8_192, accessMode: .local, installedAt: Date()
        )
        try InstallationRecordStore().save(record, layout: layout)

        let status = await InstallationInspector(
            layout: layout,
            manifest: makeManifest(),
            launchAgentsDirectory: root.appending(path: "LaunchAgents")
        ).inspect()

        XCTAssertEqual(status, .managedIncompatible("The installation record schema is unsupported."))
    }

    func testManagedRecordTakesPrecedenceOverPartialAndLegacy() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let layout = InstallationLayout(root: root)
        try FileManager.default.createDirectory(at: layout.configDirectory, withIntermediateDirectories: true)
        try Data("invalid".utf8).write(to: layout.deploymentRecord)
        let manifest = makeManifest()
        try FileManager.default.createDirectory(at: layout.downloadsDirectory, withIntermediateDirectories: true)
        try Data().write(to: layout.partialFile(for: manifest.model))
        let agents = root.appending(path: "LaunchAgents")
        try writeLegacyPlist(at: agents.appending(path: "com.local.qwythos-9b.plist"))

        let status = await InstallationInspector(
            layout: layout, manifest: manifest, launchAgentsDirectory: agents,
            healthChecker: InspectorHealthChecker(healthy: true),
            serviceChecker: InspectorServiceChecker(loaded: true)
        ).inspect()

        XCTAssertEqual(status, .managedIncompatible("The installation record cannot be read."))
    }

    func testUnavailableRootTakesPrecedenceOverPartialAndLegacy() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let layout = InstallationLayout(root: root)
        let status = await InstallationInspector(
            layout: layout, manifest: makeManifest(),
            launchAgentsDirectory: root.appending(path: "LaunchAgents"),
            healthChecker: InspectorHealthChecker(healthy: true),
            serviceChecker: InspectorServiceChecker(loaded: true)
        ).inspect()
        XCTAssertEqual(status, .installationRootUnavailable(root.standardizedFileURL))
    }

    func testOnlyExactExecutablePositionIsRecognizedAsLegacy() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        try writePlist(
            ["Label": "com.local.qwythos-9b", "ProgramArguments": ["/bin/echo", "--note", "not-llama-server"]],
            to: url
        )
        XCTAssertNil(LegacyLaunchAgentDetector.recognizedPlist(at: url))
        try writePlist(
            ["Label": "com.local.qwythos-9b", "Program": "/opt/bin/llama-server"],
            to: url
        )
        XCTAssertNotNil(LegacyLaunchAgentDetector.recognizedPlist(at: url))
    }

    func testServiceAndHealthFailuresAreReportedWithFilesystemDamageSet() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let layout = InstallationLayout(root: root)
        let manifest = makeManifest(modelHash: hash(of: Data("model".utf8)))
        let record = InstallationRecord(
            manifestSchemaVersion: 1, root: root, runtimeVersion: "runtime-1",
            modelSHA256: manifest.model.sha256, contextSize: 8_192, accessMode: .local, installedAt: Date()
        )
        try writeManagedFiles(layout: layout, manifest: manifest)
        try InstallationRecordStore().save(record, layout: layout)
        let agents = root.appending(path: "LaunchAgents")
        try LaunchAgentInstaller(launchAgentsDirectory: agents).install(
            layout: layout, options: .init(root: root, contextSize: 8_192, accessMode: .local), manifest: manifest
        )
        try FileManager.default.removeItem(at: layout.runtimeCurrent)

        let status = await InstallationInspector(
            layout: layout, manifest: manifest, launchAgentsDirectory: agents,
            healthChecker: InspectorHealthChecker(healthy: false),
            serviceChecker: InspectorServiceChecker(loaded: false)
        ).inspect()

        XCTAssertEqual(status, .managedRepairable(record, [.runtime, .launchAgent]))
    }

    func testUnhealthyEndpointDoesNotAddConfigurationWhenModelDamageExplainsIt() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let layout = InstallationLayout(root: root)
        let manifest = makeManifest(modelHash: hash(of: Data("model".utf8)))
        let record = InstallationRecord(
            manifestSchemaVersion: 1, root: root, runtimeVersion: "runtime-1",
            modelSHA256: manifest.model.sha256, contextSize: 8_192,
            accessMode: .local, installedAt: Date()
        )
        try writeManagedFiles(layout: layout, manifest: manifest)
        try Data("damaged".utf8).write(to: layout.modelFile)
        try InstallationRecordStore().save(record, layout: layout)
        let agents = root.appending(path: "LaunchAgents")
        try LaunchAgentInstaller(launchAgentsDirectory: agents).install(
            layout: layout,
            options: .init(root: root, contextSize: 8_192, accessMode: .local),
            manifest: manifest
        )

        let status = await InstallationInspector(
            layout: layout, manifest: manifest, launchAgentsDirectory: agents,
            healthChecker: InspectorHealthChecker(healthy: false),
            serviceChecker: InspectorServiceChecker(loaded: true)
        ).inspect()

        XCTAssertEqual(status, .managedRepairable(record, [.model]))
    }

    func testManagedModelReplacementCannotRedirectDescriptorHashing() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let layout = InstallationLayout(root: root)
        let expectedModel = Data("model".utf8)
        let manifest = makeManifest(modelHash: hash(of: expectedModel))
        let record = InstallationRecord(
            manifestSchemaVersion: manifest.schemaVersion,
            root: root,
            runtimeVersion: manifest.runtime.version,
            modelSHA256: manifest.model.sha256,
            contextSize: 8_192,
            accessMode: .local,
            installedAt: Date()
        )
        try writeManagedFiles(layout: layout, manifest: manifest)
        try Data("damaged".utf8).write(to: layout.modelFile)

        let agents = root.appending(path: "LaunchAgents")
        try LaunchAgentInstaller(launchAgentsDirectory: agents).install(
            layout: layout,
            options: .init(root: root, contextSize: 8_192, accessMode: .local),
            manifest: manifest
        )
        let replacement = root.appending(path: "replacement-model.gguf")
        try expectedModel.write(to: replacement)

        let status = await InstallationInspector(
            layout: layout,
            manifest: manifest,
            records: InspectorRecordStore(record: record),
            hasher: ReplacingInspectorHasher(
                path: layout.modelFile,
                replacement: replacement
            ),
            launchAgentsDirectory: agents,
            healthChecker: InspectorHealthChecker(healthy: true),
            serviceChecker: InspectorServiceChecker(loaded: true)
        ).inspect()

        XCTAssertEqual(status, .managedRepairable(record, [.model]))
    }

    func testManagedModelReplacementDuringHashFailsClosed() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let layout = InstallationLayout(root: root)
        let expectedModel = Data("model".utf8)
        let manifest = makeManifest(modelHash: hash(of: expectedModel))
        let record = InstallationRecord(
            manifestSchemaVersion: manifest.schemaVersion,
            root: root,
            runtimeVersion: manifest.runtime.version,
            modelSHA256: manifest.model.sha256,
            contextSize: 8_192,
            accessMode: .local,
            installedAt: Date()
        )
        try writeManagedFiles(layout: layout, manifest: manifest)
        let agents = root.appending(path: "LaunchAgents")
        try LaunchAgentInstaller(launchAgentsDirectory: agents).install(
            layout: layout,
            options: .init(root: root, contextSize: 8_192, accessMode: .local),
            manifest: manifest
        )
        let replacement = root.appending(path: "damaged-model.gguf")
        try Data("damaged".utf8).write(to: replacement)

        let status = await InstallationInspector(
            layout: layout,
            manifest: manifest,
            records: InspectorRecordStore(record: record),
            hasher: ReplacingInspectorHasher(
                path: layout.modelFile,
                replacement: replacement
            ),
            launchAgentsDirectory: agents,
            healthChecker: InspectorHealthChecker(healthy: true),
            serviceChecker: InspectorServiceChecker(loaded: true)
        ).inspect()

        XCTAssertEqual(status, .managedRepairable(record, [.model]))
    }

    func testManagedPlistReplacementCannotRedirectDescriptorRead() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let layout = InstallationLayout(root: root)
        let manifest = makeManifest(modelHash: hash(of: Data("model".utf8)))
        let record = InstallationRecord(
            manifestSchemaVersion: manifest.schemaVersion,
            root: root,
            runtimeVersion: manifest.runtime.version,
            modelSHA256: manifest.model.sha256,
            contextSize: 8_192,
            accessMode: .local,
            installedAt: Date()
        )
        try writeManagedFiles(layout: layout, manifest: manifest)

        let agents = root.appending(path: "LaunchAgents")
        let managedPlist = agents.appending(path: "\(manifest.service.label).plist")
        try writePlist(
            ["Label": "not-qwythos", "ProgramArguments": ["/bin/false"]],
            to: managedPlist
        )
        let replacementDirectory = root.appending(path: "ReplacementLaunchAgents")
        try LaunchAgentInstaller(launchAgentsDirectory: replacementDirectory).install(
            layout: layout,
            options: .init(root: root, contextSize: 8_192, accessMode: .local),
            manifest: manifest
        )
        let replacement = replacementDirectory.appending(
            path: "\(manifest.service.label).plist"
        )

        let status = await InstallationInspector(
            layout: layout,
            manifest: manifest,
            records: InspectorRecordStore(record: record),
            launchAgentsDirectory: agents,
            healthChecker: InspectorHealthChecker(healthy: true),
            serviceChecker: InspectorServiceChecker(loaded: true),
            plistReader: ReplacingInspectorPlistReader(
                path: managedPlist,
                replacement: replacement
            )
        ).inspect()

        XCTAssertEqual(status, .managedRepairable(record, [.launchAgent]))
    }

    func testLegacyPlistReplacementCannotRedirectDescriptorRead() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let layout = InstallationLayout(root: root)
        let agents = root.appending(path: "LaunchAgents")
        let legacyPlist = agents.appending(
            path: "\(LaunchAgentInstaller.defaultLabel).plist"
        )
        try writePlist(
            ["Label": "not-qwythos", "ProgramArguments": ["/bin/false"]],
            to: legacyPlist
        )
        let replacement = root.appending(path: "replacement-legacy.plist")
        try writeLegacyPlist(at: replacement)

        let status = await InstallationInspector(
            layout: layout,
            manifest: makeManifest(),
            launchAgentsDirectory: agents,
            plistReader: ReplacingInspectorPlistReader(
                path: legacyPlist,
                replacement: replacement
            )
        ).inspect()

        XCTAssertEqual(status, .notInstalled)
    }

    func testManagedPlistReplacementDuringParsingFailsClosed() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let layout = InstallationLayout(root: root)
        let manifest = makeManifest(modelHash: hash(of: Data("model".utf8)))
        let record = InstallationRecord(
            manifestSchemaVersion: manifest.schemaVersion,
            root: root,
            runtimeVersion: manifest.runtime.version,
            modelSHA256: manifest.model.sha256,
            contextSize: 8_192,
            accessMode: .local,
            installedAt: Date()
        )
        try writeManagedFiles(layout: layout, manifest: manifest)
        let agents = root.appending(path: "LaunchAgents")
        try LaunchAgentInstaller(launchAgentsDirectory: agents).install(
            layout: layout,
            options: .init(
                root: root,
                contextSize: 8_192,
                accessMode: .local
            ),
            manifest: manifest
        )
        let managedPlist = agents.appending(
            path: "\(manifest.service.label).plist"
        )
        let replacement = root.appending(path: "invalid-managed.plist")
        try writePlist(
            ["Label": "not-qwythos", "ProgramArguments": ["/bin/false"]],
            to: replacement
        )

        let status = await InstallationInspector(
            layout: layout,
            manifest: manifest,
            records: InspectorRecordStore(record: record),
            launchAgentsDirectory: agents,
            healthChecker: InspectorHealthChecker(healthy: true),
            serviceChecker: InspectorServiceChecker(loaded: true),
            plistReader: ReplacingInspectorPlistReader(
                path: managedPlist,
                replacement: replacement
            )
        ).inspect()

        XCTAssertEqual(
            status,
            .managedRepairable(record, [.launchAgent])
        )
    }

    func testLegacyPlistReplacementDuringParsingFailsClosed() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let layout = InstallationLayout(root: root)
        let agents = root.appending(path: "LaunchAgents")
        let legacyPlist = agents.appending(
            path: "\(LaunchAgentInstaller.defaultLabel).plist"
        )
        try writeLegacyPlist(at: legacyPlist)
        let replacement = root.appending(path: "invalid-legacy.plist")
        try writePlist(
            ["Label": "not-qwythos", "ProgramArguments": ["/bin/false"]],
            to: replacement
        )

        let status = await InstallationInspector(
            layout: layout,
            manifest: makeManifest(),
            launchAgentsDirectory: agents,
            plistReader: ReplacingInspectorPlistReader(
                path: legacyPlist,
                replacement: replacement
            )
        ).inspect()

        XCTAssertEqual(status, .notInstalled)
    }

    private func makeRoot() throws -> URL {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let root = packageRoot
            .appending(path: ".build/inspector-tests")
            .appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func makeManifest(modelHash: String = String(repeating: "a", count: 64)) -> DeploymentManifest {
        DeploymentManifest(
            schemaVersion: 1,
            runtime: .init(version: "runtime-1", archive: .init(filename: "runtime.tar.gz", sourceURL: URL(string: "https://example.com/runtime")!, size: 1, sha256: String(repeating: "b", count: 64)), directoryName: "runtime-1", serverRelativePath: "llama-server"),
            model: .init(filename: InstallationLayout.modelFilename, sourceURL: URL(string: "https://example.com/model")!, size: 5, sha256: modelHash),
            service: .init(label: "com.local.qwythos-9b", port: 18_080)
        )
    }

    private func writeManagedFiles(layout: InstallationLayout, manifest: DeploymentManifest) throws {
        try FileManager.default.createDirectory(at: layout.modelsDirectory, withIntermediateDirectories: true)
        try Data("model".utf8).write(to: layout.modelFile)
        let runtime = layout.runtimeVersion(manifest.runtime.version)
        try FileManager.default.createDirectory(at: runtime, withIntermediateDirectories: true)
        let server = runtime.appending(path: "llama-server")
        try Data("server".utf8).write(to: server)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: server.path)
        try FileManager.default.createDirectory(at: layout.runtimeDirectory, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: layout.runtimeCurrent.path, withDestinationPath: runtime.path)
    }

    private func writeLegacyPlist(at url: URL) throws {
        try writePlist(["Label": "com.local.qwythos-9b", "ProgramArguments": ["/opt/homebrew/bin/llama-server", "--port", "18080"]], to: url)
    }

    private func writePlist(_ plist: [String: Any], to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: url)
    }

    private func hash(of data: Data) -> String {
        let file = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try! data.write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        return try! SHA256Hasher().sha256(file: file)
    }
}

private struct InspectorHealthChecker: InstallationHealthChecking {
    let healthy: Bool
    func isHealthy(_ url: URL) async -> Bool { healthy }
}

private struct InspectorServiceChecker: InstallationServiceChecking {
    let loaded: Bool
    func isLoaded(label: String) async -> Bool { loaded }
}

private final class InspectorCommandRunner: CommandRunning, @unchecked Sendable {
    struct Command: Equatable {
        let executable: String
        let arguments: [String]
    }

    private let launchctl: CommandResult
    private let lsof: CommandResult
    private let lock = NSLock()
    private var recordedCommands: [Command] = []

    init(launchctl: CommandResult, lsof: CommandResult) {
        self.launchctl = launchctl
        self.lsof = lsof
    }

    var commands: [Command] {
        lock.withLock { recordedCommands }
    }

    func run(_ command: LaunchCommand) async -> CommandResult {
        lock.withLock {
            recordedCommands.append(
                .init(executable: command.executable, arguments: command.arguments)
            )
        }
        return command.executable == "/bin/launchctl" ? launchctl : lsof
    }
}

private struct InspectorRecordStore: InstallationRecordStoring {
    let record: InstallationRecord?

    func load(layout: InstallationLayout) throws -> InstallationRecord? {
        record
    }

    func save(_ record: InstallationRecord, layout: InstallationLayout) throws {}
    func remove(layout: InstallationLayout) throws {}
}

private final class ReplacingInspectorRootRecordStore:
    InstallationRecordStoring,
    @unchecked Sendable
{
    private let record: InstallationRecord
    private let root: URL
    private let replacementRoot: URL
    private let detachedRoot: URL
    private let lock = NSLock()
    private var replaced = false

    init(
        record: InstallationRecord,
        root: URL,
        replacementRoot: URL,
        detachedRoot: URL
    ) {
        self.record = record
        self.root = root
        self.replacementRoot = replacementRoot
        self.detachedRoot = detachedRoot
    }

    func load(layout: InstallationLayout) throws -> InstallationRecord? {
        lock.lock()
        let shouldReplace = !replaced
        replaced = true
        lock.unlock()
        if shouldReplace {
            guard Darwin.rename(root.path, detachedRoot.path) == 0,
                  Darwin.rename(replacementRoot.path, root.path) == 0 else {
                throw CocoaError(.fileReadUnknown)
            }
        }
        return record
    }

    func save(
        _ record: InstallationRecord,
        layout: InstallationLayout
    ) throws {}

    func remove(layout: InstallationLayout) throws {}
}

private struct ReplacingInspectorHasher: FileHashing {
    let path: URL
    let replacement: URL

    func sha256(file: URL) throws -> String {
        try replacePath()
        return try SHA256Hasher().sha256(file: file)
    }

    func sha256(fileDescriptor: Int32) throws -> String {
        try replacePath()
        return try SHA256Hasher().sha256(fileDescriptor: fileDescriptor)
    }

    private func replacePath() throws {
        try FileManager.default.removeItem(at: path)
        try FileManager.default.createSymbolicLink(
            atPath: path.path,
            withDestinationPath: replacement.path
        )
    }
}

private struct ReplacingInspectorPlistReader: LaunchAgentPlistReading {
    let path: URL
    let replacement: URL

    func plist(at url: URL) -> LegacyLaunchAgent? {
        var metadata = stat()
        guard lstat(path.path, &metadata) == 0,
              metadata.st_mode & S_IFMT == S_IFREG,
              replacePath(),
              let data = try? Data(contentsOf: url)
        else { return nil }
        return LegacyLaunchAgentDetector.plist(data: data, at: url)
    }

    func plist(data: Data, at url: URL) -> LegacyLaunchAgent? {
        guard replacePath() else { return nil }
        return LegacyLaunchAgentDetector.plist(data: data, at: url)
    }

    private func replacePath() -> Bool {
        do {
            try FileManager.default.removeItem(at: path)
            try FileManager.default.createSymbolicLink(
                atPath: path.path,
                withDestinationPath: replacement.path
            )
            return true
        } catch {
            return false
        }
    }
}
