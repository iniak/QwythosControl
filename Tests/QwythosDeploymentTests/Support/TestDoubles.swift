import Foundation
import QwythosCore
@testable import QwythosDeployment

struct FakeSystemProfile: SystemProfileProviding {
    let architecture: String
    let operatingSystem: OperatingSystemVersion
    let physicalMemory: UInt64
    let availableCapacity: Int64
    let writable: Bool

    func availableCapacity(at url: URL) throws -> Int64 {
        availableCapacity
    }

    func isWritable(_ url: URL) -> Bool {
        writable
    }
}

struct FakePortChecker: PortChecking {
    let isAvailable: Bool

    func isAvailable(port: UInt16) async -> Bool {
        isAvailable
    }
}

enum CoordinatorEvent: Equatable {
    case healthSucceeded
    case recordSaved
}

final class LockedCoordinatorEvents: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [CoordinatorEvent] = []

    var values: [CoordinatorEvent] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func append(_ event: CoordinatorEvent) {
        lock.lock()
        storage.append(event)
        lock.unlock()
    }
}

final class LockedCallLog: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []

    var values: [String] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func append(_ value: String) {
        lock.lock()
        storage.append(value)
        lock.unlock()
    }
}

final class FakeInstallationLocator: InstallationLocating, @unchecked Sendable {
    enum Failure: Error {
        case remove
    }

    private let lock = NSLock()
    private var location: InstallationLocation?
    private var remainingRemoveFailures: Int
    private(set) var removeCount = 0
    private(set) var removeAttempts = 0

    init(root: URL? = nil, removeFailures: Int = 0) {
        location = root.map(InstallationLocation.init(root:))
        remainingRemoveFailures = removeFailures
    }

    func load() throws -> InstallationLocation? {
        lock.lock()
        defer { lock.unlock() }
        return location
    }

    func save(_ location: InstallationLocation) throws {
        lock.lock()
        self.location = location
        lock.unlock()
    }

    func remove() throws {
        lock.lock()
        removeAttempts += 1
        if remainingRemoveFailures > 0 {
            remainingRemoveFailures -= 1
            lock.unlock()
            throw Failure.remove
        }
        location = nil
        removeCount += 1
        lock.unlock()
    }
}

final class FakeInstallationRecordStore:
    InstallationRecordStoring,
    @unchecked Sendable
{
    enum Failure: Error {
        case save
    }

    private let lock = NSLock()
    private let events: LockedCoordinatorEvents
    private var record: InstallationRecord?
    private(set) var saveCount = 0
    private(set) var removeCount = 0
    private let failSaves: Bool
    private let writeThenFailSaves: Bool

    init(
        record: InstallationRecord? = nil,
        events: LockedCoordinatorEvents = LockedCoordinatorEvents(),
        failSaves: Bool = false,
        writeThenFailSaves: Bool = false
    ) {
        self.record = record
        self.events = events
        self.failSaves = failSaves
        self.writeThenFailSaves = writeThenFailSaves
    }

    func load(layout: InstallationLayout) throws -> InstallationRecord? {
        lock.lock()
        defer { lock.unlock() }
        return record
    }

    func save(_ record: InstallationRecord, layout: InstallationLayout) throws {
        if failSaves {
            throw Failure.save
        }
        lock.lock()
        self.record = record
        saveCount += 1
        lock.unlock()
        if writeThenFailSaves {
            throw Failure.save
        }
        events.append(.recordSaved)
    }

    func remove(layout: InstallationLayout) throws {
        lock.lock()
        record = nil
        removeCount += 1
        lock.unlock()
    }

    func remove(
        ifMatching expectedRecord: InstallationRecord,
        layout: InstallationLayout
    ) throws -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard record == expectedRecord else { return false }
        record = nil
        removeCount += 1
        return true
    }

    func currentRecord() -> InstallationRecord? {
        lock.lock()
        defer { lock.unlock() }
        return record
    }

    func replaceCurrentRecordAccessMode(_ accessMode: NetworkAccessMode) {
        lock.lock()
        defer { lock.unlock() }
        guard let record else { return }
        self.record = InstallationRecord(
            manifestSchemaVersion: record.manifestSchemaVersion,
            root: record.root,
            runtimeVersion: record.runtimeVersion,
            modelSHA256: record.modelSHA256,
            contextSize: record.contextSize,
            accessMode: accessMode,
            installedAt: record.installedAt
        )
    }
}

final class FakeArtifactDownloader: ArtifactDownloading, @unchecked Sendable {
    let calls = LockedCallLog()
    private let suspendUntilCancelled: Bool

    init(suspendUntilCancelled: Bool = false) {
        self.suspendUntilCancelled = suspendUntilCancelled
    }

    func download(
        artifact: DeploymentArtifact,
        partialURL: URL,
        progress: @escaping @Sendable (DownloadProgress) -> Void
    ) async throws -> URL {
        calls.append(artifact.filename)
        if suspendUntilCancelled {
            try await Task.sleep(for: .seconds(3_600))
        }
        try Task.checkCancellation()
        return partialURL
    }
}

struct FakeFileHasher: FileHashing {
    let manifest: DeploymentManifest

    func sha256(file: URL) throws -> String {
        file.lastPathComponent.contains(manifest.runtime.archive.filename)
            ? manifest.runtime.archive.sha256
            : manifest.model.sha256
    }
}

final class FakeRuntimeInstaller: RuntimeInstalling, @unchecked Sendable {
    let calls = LockedCallLog()
    private let cancelAfterInstall: Bool
    private let suspendAfterInstall: Bool

    init(
        cancelAfterInstall: Bool = false,
        suspendAfterInstall: Bool = false
    ) {
        self.cancelAfterInstall = cancelAfterInstall
        self.suspendAfterInstall = suspendAfterInstall
    }

    func install(
        archive: URL,
        manifest: RuntimeArtifact,
        layout: InstallationLayout
    ) async throws {
        calls.append("install:\(manifest.version)")
        if cancelAfterInstall {
            throw CancellationError()
        }
        if suspendAfterInstall {
            try await Task.sleep(for: .seconds(3_600))
        }
    }

    func rollBackCurrentRuntime(
        to previousVersion: String,
        layout: InstallationLayout
    ) throws {
        calls.append("rollback:\(previousVersion)")
    }
}

final class FakeLaunchAgentInstaller:
    LaunchAgentInstalling,
    @unchecked Sendable
{
    let calls = LockedCallLog()
    private(set) var key = "fixture-original-key"

    func install(
        layout: InstallationLayout,
        options: DeploymentOptions,
        manifest: DeploymentManifest
    ) throws {
        calls.append("install:\(options.accessMode.rawValue)")
    }

    func restoreLegacyPlist(layout: InstallationLayout) throws {
        calls.append("restore")
    }

    func uninstall() throws {
        calls.append("uninstall")
    }

    func regenerateAPIKey(layout: InstallationLayout) throws -> String {
        calls.append("regenerate-key")
        key = "fixture-api-key"
        return key
    }

    func captureInstallationState(layout: InstallationLayout) throws -> LaunchAgentInstallationState {
        calls.append("capture-state")
        return LaunchAgentInstallationState(plist: Data("plist".utf8), apiKey: Data(key.utf8))
    }

    func restoreInstallationState(_ state: LaunchAgentInstallationState, layout: InstallationLayout) throws {
        calls.append("restore-state")
        key = String(decoding: state.apiKey ?? Data(), as: UTF8.self)
    }

    func restoreAPIKeyState(_ state: LaunchAgentInstallationState, layout: InstallationLayout) throws {
        calls.append("restore-key")
        key = String(decoding: state.apiKey ?? Data(), as: UTF8.self)
    }

    func restorePlistState(_ state: LaunchAgentInstallationState, layout: InstallationLayout) throws {
        calls.append("restore-plist")
    }
}

struct FakeInstallationInspector: InstallationInspecting {
    let status: InstallationStatus

    init(
        damaged: Set<RepairComponent> = [],
        record: InstallationRecord? = nil
    ) {
        if let record {
            status = damaged.isEmpty
                ? .managedHealthy(record)
                : .managedRepairable(record, damaged)
        } else {
            status = .notInstalled
        }
    }

    func inspect() async -> InstallationStatus {
        status
    }
}

final class FakeLegacyMigrator: LegacyMigrating, @unchecked Sendable {
    let calls = LockedCallLog()

    func migrate(options: DeploymentOptions) async throws {
        calls.append("migrate")
    }
}

final class FakeManagedService:
    ManagedServiceControlling,
    @unchecked Sendable
{
    let calls = LockedCallLog()
    private let honorCancellation: Bool

    init(honorCancellation: Bool = false) {
        self.honorCancellation = honorCancellation
    }

    func start() async throws {
        if honorCancellation {
            try Task.checkCancellation()
        }
        calls.append("start")
    }

    func stop() async throws {
        if honorCancellation {
            try Task.checkCancellation()
        }
        calls.append("stop")
    }

    func isRunning() async -> Bool { true }
}

final class SequenceHealthChecker: HealthChecking, @unchecked Sendable {
    private let lock = NSLock()
    private var results: [Bool]
    private let events: LockedCoordinatorEvents
    private let suspendOnCheck: Bool

    init(
        results: [Bool],
        events: LockedCoordinatorEvents,
        suspendOnCheck: Bool = false
    ) {
        self.results = results
        self.events = events
        self.suspendOnCheck = suspendOnCheck
    }

    func isHealthy(_ url: URL) async -> Bool {
        if suspendOnCheck {
            try? await Task.sleep(for: .seconds(3_600))
        }
        let result = lock.withLock {
            results.isEmpty ? false : results.removeFirst()
        }
        if result {
            events.append(.healthSucceeded)
        }
        return result
    }
}

final class FakeDeploymentFileManager:
    DeploymentFileManaging,
    @unchecked Sendable
{
    enum Failure: Error {
        case removal
    }

    let removals = LockedCallLog()
    let directoryPrunes = LockedCallLog()
    let promotions = LockedCallLog()
    private let failingRemovalName: String?

    init(failingRemovalName: String? = nil) {
        self.failingRemovalName = failingRemovalName
    }

    func promoteModel(
        from source: URL,
        layout: InstallationLayout,
        expectedSHA256: String
    ) throws {
        promotions.append(source.lastPathComponent)
    }

    func removeManagedItem(
        _ url: URL,
        layout: InstallationLayout,
        kind: ManagedRemovalKind
    ) throws {
        switch kind {
        case .fileOrLink:
            removals.append(url.standardizedFileURL.path)
        case .emptyDirectory:
            directoryPrunes.append(url.standardizedFileURL.path)
        }
        if url.lastPathComponent == failingRemovalName {
            throw Failure.removal
        }
    }

    func removeManagedRuntimeVersion(
        record: InstallationRecord,
        layout: InstallationLayout
    ) throws {
        let url = layout.runtimeVersion(record.runtimeVersion)
        removals.append(url.standardizedFileURL.path)
        if url.lastPathComponent == failingRemovalName {
            throw Failure.removal
        }
    }

    func finalizeManagedRuntimeCleanup(
        layout: InstallationLayout
    ) throws {}

    func managedModelMatches(
        layout: InstallationLayout,
        expectedSHA256: String
    ) throws -> Bool {
        false
    }

    func removeManagedModel(
        layout: InstallationLayout,
        expectedSHA256: String
    ) throws {
        removals.append(layout.modelFile.standardizedFileURL.path)
        if layout.modelFile.lastPathComponent == failingRemovalName {
            throw Failure.removal
        }
    }
}

struct ImmediateDeploymentSleeper: DeploymentSleeping {
    func sleep(for duration: Duration) async throws {}
}

struct CoordinatorFixture {
    let events: LockedCoordinatorEvents
    let options: DeploymentOptions
    let coordinator: DeploymentCoordinator
    let locator: FakeInstallationLocator
    let downloader: FakeArtifactDownloader
    let runtimeInstaller: FakeRuntimeInstaller
    let launchAgentInstaller: FakeLaunchAgentInstaller
    let recordStore: FakeInstallationRecordStore
    let service: FakeManagedService
    let files: FakeDeploymentFileManager

    init(
        healthResults: [Bool] = [true],
        damaged: Set<RepairComponent> = [],
        existingRuntimeVersion: String? = nil,
        suspendDownloads: Bool = false,
        cancelAfterRuntimeInstall: Bool = false,
        suspendAfterRuntimeInstall: Bool = false,
        serviceHonorsCancellation: Bool = false,
        suspendHealthCheck: Bool = false,
        failingRemovalName: String? = nil,
        failRecordSaves: Bool = false,
        writeThenFailRecordSaves: Bool = false,
        recordRootOverride: URL? = nil,
        locatorRemoveFailures: Int = 0
    ) {
        let events = LockedCoordinatorEvents()
        let root = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString)
        let options = DeploymentOptions(
            root: root,
            contextSize: 8_192,
            accessMode: .local
        )
        let existingRecord = existingRuntimeVersion.map {
            InstallationRecord(
                manifestSchemaVersion: DeploymentManifest.fixture.schemaVersion,
                root: recordRootOverride ?? root,
                runtimeVersion: $0,
                modelSHA256: DeploymentManifest.fixture.model.sha256,
                contextSize: options.contextSize,
                accessMode: options.accessMode,
                installedAt: Date(timeIntervalSince1970: 1)
            )
        }
        let locator = FakeInstallationLocator(
            root: existingRecord == nil ? nil : root,
            removeFailures: locatorRemoveFailures
        )
        let recordStore = FakeInstallationRecordStore(
            record: existingRecord,
            events: events,
            failSaves: failRecordSaves,
            writeThenFailSaves: writeThenFailRecordSaves
        )
        let healthChecker = SequenceHealthChecker(
            results: healthResults,
            events: events,
            suspendOnCheck: suspendHealthCheck
        )
        let downloader = FakeArtifactDownloader(
            suspendUntilCancelled: suspendDownloads
        )
        let runtimeInstaller = FakeRuntimeInstaller(
            cancelAfterInstall: cancelAfterRuntimeInstall,
            suspendAfterInstall: suspendAfterRuntimeInstall
        )
        let launchAgentInstaller = FakeLaunchAgentInstaller()
        let service = FakeManagedService(
            honorCancellation: serviceHonorsCancellation
        )
        let files = FakeDeploymentFileManager(
            failingRemovalName: failingRemovalName
        )

        self.events = events
        self.options = options
        self.locator = locator
        self.downloader = downloader
        self.runtimeInstaller = runtimeInstaller
        self.launchAgentInstaller = launchAgentInstaller
        self.recordStore = recordStore
        self.service = service
        self.files = files
        self.coordinator = DeploymentCoordinator(
            manifest: .fixture,
            locator: locator,
            preflight: .passingFixture,
            downloader: downloader,
            hasher: FakeFileHasher(manifest: .fixture),
            runtimeInstaller: runtimeInstaller,
            launchAgentInstaller: launchAgentInstaller,
            inspector: FakeInstallationInspector(
                damaged: damaged,
                record: existingRecord
            ),
            migrator: FakeLegacyMigrator(),
            recordStore: recordStore,
            service: service,
            healthChecker: healthChecker,
            files: files,
            sleeper: ImmediateDeploymentSleeper(),
            healthPollAttempts: max(1, healthResults.count)
        )
    }

    func captureSnapshots(
        operation: @escaping @Sendable () async throws -> Void
    ) async rethrows -> [DeploymentSnapshot] {
        let stream = await coordinator.snapshots()
        let collector = Task { () -> [DeploymentSnapshot] in
            var snapshots: [DeploymentSnapshot] = []
            for await snapshot in stream {
                guard snapshot.phase != .idle else { continue }
                snapshots.append(snapshot)
                if [.installed, .paused, .failed].contains(snapshot.phase) {
                    break
                }
            }
            return snapshots
        }
        try await operation()
        return await collector.value
    }

    func firstSnapshot() async -> DeploymentSnapshot {
        let stream = await coordinator.snapshots()
        var iterator = stream.makeAsyncIterator()
        return await iterator.next()!
    }
}

extension DeploymentManifest {
    static let fixture = DeploymentManifest(
        schemaVersion: 1,
        runtime: RuntimeArtifact(
            version: "fixture-runtime",
            archive: DeploymentArtifact(
                filename: "runtime.tar.gz",
                sourceURL: URL(string: "https://fixture.invalid/runtime")!,
                size: 10,
                sha256: String(repeating: "a", count: 64)
            ),
            directoryName: "runtime",
            serverRelativePath: "llama-server"
        ),
        model: DeploymentArtifact(
            filename: InstallationLayout.modelFilename,
            sourceURL: URL(string: "https://fixture.invalid/model")!,
            size: 90,
            sha256: String(repeating: "b", count: 64)
        ),
        service: ServiceDefaults(label: "fixture.service", port: 18_080)
    )
}

extension DeploymentPreflight {
    static let passingFixture = DeploymentPreflight(
        profile: FakeSystemProfile(
            architecture: "arm64",
            operatingSystem: .init(
                majorVersion: 14,
                minorVersion: 0,
                patchVersion: 0
            ),
            physicalMemory: 24 * 1_073_741_824,
            availableCapacity: 20_000_000_000,
            writable: true
        ),
        portChecker: FakePortChecker(isAvailable: true)
    )
}
