import Darwin
import Foundation
import QwythosCore

public protocol ManagedServiceControlling: Sendable {
    func start() async throws
    func stop() async throws
    func isRunning() async -> Bool
}

public extension ManagedServiceControlling {
    func isRunning() async -> Bool { true }
}

extension ServiceController: ManagedServiceControlling {
    public func isRunning() async -> Bool {
        switch await refresh() {
        case .running, .starting: true
        default: false
        }
    }
}

public protocol DeploymentCoordinating: Sendable {
    func snapshots() async -> AsyncStream<DeploymentSnapshot>
    func inspect() async -> InstallationStatus
    func deploy(options: DeploymentOptions) async throws
    func migrate(options: DeploymentOptions) async throws
    func pause() async
    func pauseAndWait() async
    func cancel() async
    func repair() async throws
    func reinstallRuntime() async throws
    func setAccessMode(_ mode: NetworkAccessMode) async throws
    func regenerateAPIKey() async throws -> String
    func uninstall(deleteModel: Bool) async throws
}

public extension DeploymentCoordinating {
    func cancel() async {
        await pauseAndWait()
    }
}

public enum DeploymentCoordinatorError: Error, Equatable, Sendable {
    case operationInProgress
    case installationNotFound
    case installationNotRepairable
    case preflightFailed([PreflightIssue])
    case artifactDigestMismatch(
        component: RepairComponent,
        expected: String,
        actual: String
    )
    case unsafeDownloadedArtifact
    case healthTimedOut
    case sharedAccessRequired
    case runtimeRollbackFailed(String)
}

protocol DeploymentFileManaging: Sendable {
    func promoteModel(
        from source: URL,
        layout: InstallationLayout,
        expectedSHA256: String
    ) throws

    func removeManagedItem(
        _ url: URL,
        layout: InstallationLayout,
        kind: ManagedRemovalKind
    ) throws

    func removeManagedRuntimeVersion(
        record: InstallationRecord,
        layout: InstallationLayout
    ) throws

    func finalizeManagedRuntimeCleanup(
        layout: InstallationLayout
    ) throws

    func managedModelMatches(
        layout: InstallationLayout,
        expectedSHA256: String
    ) throws -> Bool

    func removeManagedModel(
        layout: InstallationLayout,
        expectedSHA256: String
    ) throws
}

enum ManagedRemovalKind: Equatable, Sendable {
    case fileOrLink
    case emptyDirectory
}

struct LiveDeploymentFileManager: DeploymentFileManaging {
    private let modelReuser: any ModelReusing
    private let hasher: any FileHashing
    private let beforeDirectoryQuarantine:
        @Sendable (URL) throws -> Void
    private let afterDirectoryQuarantine:
        @Sendable (URL) throws -> Void
    private let tombstones = RuntimeCleanupTombstoneStore()

    init(
        hasher: any FileHashing,
        beforeDirectoryQuarantine:
            @escaping @Sendable (URL) throws -> Void = { _ in },
        afterDirectoryQuarantine:
            @escaping @Sendable (URL) throws -> Void = { _ in }
    ) {
        self.hasher = hasher
        modelReuser = ModelReuser(hasher: hasher)
        self.beforeDirectoryQuarantine = beforeDirectoryQuarantine
        self.afterDirectoryQuarantine = afterDirectoryQuarantine
    }

    func promoteModel(
        from source: URL,
        layout: InstallationLayout,
        expectedSHA256: String
    ) throws {
        _ = try layout.requireManaged(source)
        _ = try layout.requireManaged(layout.modelFile)
        let root = try POSIXDirectoryDescriptor.openRoot(layout.root)
        let models = try root.openDirectory("models", createMode: 0o700)
        if try models.metadata(
            for: InstallationLayout.modelFilename
        ) != nil {
            try models.unlink(InstallationLayout.modelFilename)
        }
        _ = try modelReuser.reuse(
            source,
            at: layout.modelFile,
            expectedSHA256: expectedSHA256
        )
    }

    func removeManagedItem(
        _ url: URL,
        layout: InstallationLayout,
        kind: ManagedRemovalKind
    ) throws {
        let managed = try layout.requireManaged(url)
        let (parent, name) = try managedParent(
            of: managed,
            layout: layout
        )
        guard let metadata = try parent.metadata(for: name) else { return }

        switch kind {
        case .fileOrLink:
            guard metadata.st_mode & S_IFMT != S_IFDIR else {
                throw POSIXTransactionError.unsafePath
            }
            try parent.unlink(name)
        case .emptyDirectory:
            guard metadata.st_mode & S_IFMT == S_IFDIR else {
                throw POSIXTransactionError.unsafePath
            }
            guard unlinkat(parent.rawValue, name, AT_REMOVEDIR) == 0 else {
                if errno == ENOENT || errno == ENOTEMPTY || errno == EEXIST {
                    return
                }
                throw POSIXTransactionError.operationFailed(errno)
            }
        }
    }

    func removeManagedRuntimeVersion(
        record: InstallationRecord,
        layout: InstallationLayout
    ) throws {
        if try finishPendingRuntimeRemoval(
            record: record,
            layout: layout
        ) {
            return
        }

        let root = try POSIXDirectoryDescriptor.openRoot(layout.root)
        let runtime = try root.openDirectory("runtime")
        let versions = try runtime.openDirectory("versions")
        let managed = try layout.requireManaged(
            layout.runtimeVersion(record.runtimeVersion)
        )
        guard let metadata = try versions.metadata(
            for: record.runtimeVersion
        ) else {
            return
        }
        guard metadata.st_mode & S_IFMT == S_IFDIR else {
            throw POSIXTransactionError.unsafePath
        }
        let identity = POSIXFileIdentity(metadata)
        let quarantineName =
            "\(RuntimeCleanupTombstone.quarantinePrefix)\(UUID().uuidString)"
        let tombstone = RuntimeCleanupTombstone(
            record: record,
            quarantineName: quarantineName,
            identity: identity
        )
        try tombstones.save(tombstone, layout: layout)

        let owned: POSIXOwnedDirectory
        do {
            guard let quarantined = try versions.quarantineDirectoryIfOwned(
                record.runtimeVersion,
                identity: identity,
                quarantineName: quarantineName,
                beforeQuarantine: {
                    try beforeDirectoryQuarantine(managed)
                }
            ) else {
                return
            }
            owned = quarantined
        } catch {
            let quarantineMissing = try versions.metadata(
                for: quarantineName
            ) == nil
            let publicIdentity = try versions.metadata(
                for: record.runtimeVersion
            ).map(POSIXFileIdentity.init)
            if quarantineMissing, publicIdentity == identity {
                _ = try? tombstones.remove(
                    ifMatching: tombstone,
                    layout: layout
                )
            }
            throw error
        }

        do {
            try afterDirectoryQuarantine(managed)
            try versions.removeOwnedDirectoryTree(owned)
        } catch {
            if try versions.restoreOwnedDirectory(
                owned,
                to: record.runtimeVersion
            ) {
                guard try tombstones.remove(
                    ifMatching: tombstone,
                    layout: layout
                ) else {
                    throw POSIXTransactionError.ownershipChanged
                }
            }
            throw error
        }

    }

    func managedModelMatches(
        layout: InstallationLayout,
        expectedSHA256: String
    ) throws -> Bool {
        _ = try layout.requireManaged(layout.modelFile)

        let root: POSIXDirectoryDescriptor
        do {
            root = try POSIXDirectoryDescriptor.openRoot(layout.root)
        } catch POSIXTransactionError.notFound {
            return false
        }

        let models: POSIXDirectoryDescriptor
        do {
            models = try root.openDirectory("models")
        } catch POSIXTransactionError.notFound {
            return false
        }

        let name = InstallationLayout.modelFilename
        let file: POSIXFileDescriptor
        do {
            file = try models.openFile(name, flags: O_RDONLY | O_NOFOLLOW)
        } catch POSIXTransactionError.notFound {
            return false
        }

        let opened = try file.metadata()
        guard opened.st_mode & S_IFMT == S_IFREG else {
            throw POSIXTransactionError.unsafePath
        }
        let identity = POSIXFileIdentity(opened)
        let digest = try hasher.sha256(fileDescriptor: file.rawValue)
        let afterHash = try file.metadata()
        guard afterHash.st_mode & S_IFMT == S_IFREG,
              POSIXFileIdentity(afterHash) == identity,
              let current = try models.metadata(for: name),
              current.st_mode & S_IFMT == S_IFREG,
              POSIXFileIdentity(current) == identity else {
            throw POSIXTransactionError.ownershipChanged
        }
        return digest.caseInsensitiveCompare(expectedSHA256) == .orderedSame
    }

    func removeManagedModel(
        layout: InstallationLayout,
        expectedSHA256: String
    ) throws {
        guard try managedModelMatches(
            layout: layout,
            expectedSHA256: expectedSHA256
        ) else {
            let root: POSIXDirectoryDescriptor
            do {
                root = try POSIXDirectoryDescriptor.openRoot(layout.root)
            } catch POSIXTransactionError.notFound {
                return
            }
            let models: POSIXDirectoryDescriptor
            do {
                models = try root.openDirectory("models")
            } catch POSIXTransactionError.notFound {
                return
            }
            guard try models.metadata(for: InstallationLayout.modelFilename) != nil
            else {
                return
            }
            throw POSIXTransactionError.ownershipChanged
        }

        let root = try POSIXDirectoryDescriptor.openRoot(layout.root)
        let models = try root.openDirectory("models")
        let name = InstallationLayout.modelFilename
        let file = try models.openFile(name, flags: O_RDONLY | O_NOFOLLOW)
        let identity = POSIXFileIdentity(try file.metadata())
        guard let current = try models.metadata(for: name),
              current.st_mode & S_IFMT == S_IFREG,
              POSIXFileIdentity(current) == identity else {
            throw POSIXTransactionError.ownershipChanged
        }
        try models.unlinkIfOwned(name, identity: identity)
        try models.sync()
    }

    func finalizeManagedRuntimeCleanup(
        layout: InstallationLayout
    ) throws {
        guard let tombstone = try tombstones.load(layout: layout) else {
            return
        }
        _ = try tombstone.validatedIdentity(layout: layout)
        let root = try POSIXDirectoryDescriptor.openRoot(layout.root)
        do {
            let runtime = try root.openDirectory("runtime")
            let versions = try runtime.openDirectory("versions")
            guard try versions.metadata(
                for: tombstone.quarantineName
            ) == nil else {
                throw POSIXTransactionError.ownershipChanged
            }
            guard try tombstones.remove(
                ifMatching: tombstone,
                layout: layout
            ) else {
                throw POSIXTransactionError.ownershipChanged
            }
            try pruneConfigIfEmpty(root: root)
            return
        } catch POSIXTransactionError.notFound {
            guard try tombstones.remove(
                ifMatching: tombstone,
                layout: layout
            ) else {
                throw POSIXTransactionError.ownershipChanged
            }
            try pruneConfigIfEmpty(root: root)
        }
    }

    private func finishPendingRuntimeRemoval(
        record: InstallationRecord,
        layout: InstallationLayout
    ) throws -> Bool {
        guard let tombstone = try tombstones.load(layout: layout) else {
            try rejectOrphanedRuntimeQuarantines(layout: layout)
            return false
        }
        let identity = try tombstone.validatedIdentity(
            record: record,
            layout: layout
        )

        let root = try POSIXDirectoryDescriptor.openRoot(layout.root)
        let runtime: POSIXDirectoryDescriptor
        let versions: POSIXDirectoryDescriptor
        do {
            runtime = try root.openDirectory("runtime")
            versions = try runtime.openDirectory("versions")
        } catch POSIXTransactionError.notFound {
            return true
        }

        guard let owned = try versions.openOwnedDirectory(
            tombstone.quarantineName,
            identity: identity
        ) else {
            if let publicEntry = try versions.metadata(
                for: record.runtimeVersion
            ),
               POSIXFileIdentity(publicEntry) == identity {
                guard let prepared = try versions
                    .quarantineDirectoryIfOwned(
                        record.runtimeVersion,
                        identity: identity,
                        quarantineName: tombstone.quarantineName
                    ) else {
                    return true
                }
                return try removePendingRuntimeDirectory(
                    prepared,
                    record: record,
                    tombstone: tombstone,
                    versions: versions,
                    layout: layout
                )
            }
            return true
        }

        return try removePendingRuntimeDirectory(
            owned,
            record: record,
            tombstone: tombstone,
            versions: versions,
            layout: layout
        )
    }

    private func removePendingRuntimeDirectory(
        _ owned: POSIXOwnedDirectory,
        record: InstallationRecord,
        tombstone: RuntimeCleanupTombstone,
        versions: POSIXDirectoryDescriptor,
        layout: InstallationLayout
    ) throws -> Bool {
        do {
            try versions.removeOwnedDirectoryTree(owned)
        } catch {
            if try versions.restoreOwnedDirectory(
                owned,
                to: record.runtimeVersion
            ) {
                guard try tombstones.remove(
                    ifMatching: tombstone,
                    layout: layout
                ) else {
                    throw POSIXTransactionError.ownershipChanged
                }
            }
            throw error
        }
        return true
    }

    private func pruneConfigIfEmpty(
        root: POSIXDirectoryDescriptor
    ) throws {
        guard unlinkat(root.rawValue, "config", AT_REMOVEDIR) == 0 else {
            if errno == ENOENT || errno == ENOTEMPTY || errno == EEXIST {
                return
            }
            throw POSIXTransactionError.operationFailed(errno)
        }
        try root.sync()
    }

    private func rejectOrphanedRuntimeQuarantines(
        layout: InstallationLayout
    ) throws {
        let root: POSIXDirectoryDescriptor
        do {
            root = try POSIXDirectoryDescriptor.openRoot(layout.root)
        } catch POSIXTransactionError.notFound {
            return
        }
        do {
            let runtime = try root.openDirectory("runtime")
            let versions = try runtime.openDirectory("versions")
            guard try versions.entryNames(
                withPrefix: RuntimeCleanupTombstone.quarantinePrefix
            ).isEmpty else {
                throw POSIXTransactionError.ownershipChanged
            }
        } catch POSIXTransactionError.notFound {
            return
        }
    }

    private func managedParent(
        of managed: URL,
        layout: InstallationLayout
    ) throws -> (POSIXDirectoryDescriptor, String) {
        let rootComponents = layout.root.path.split(separator: "/")
        let managedComponents = managed.path.split(separator: "/")
        guard managedComponents.starts(with: rootComponents),
              managedComponents.count > rootComponents.count,
              let name = managedComponents.last else {
            throw POSIXTransactionError.unsafePath
        }

        var parent = try POSIXDirectoryDescriptor.openRoot(layout.root)
        for component in managedComponents
            .dropFirst(rootComponents.count)
            .dropLast() {
            parent = try parent.openDirectory(String(component))
        }
        return (parent, String(name))
    }
}

protocol DeploymentSleeping: Sendable {
    func sleep(for duration: Duration) async throws
}

struct ContinuousDeploymentSleeper: DeploymentSleeping {
    func sleep(for duration: Duration) async throws {
        try await Task.sleep(for: duration)
    }
}

public actor DeploymentCoordinator: DeploymentCoordinating {
    private let manifest: DeploymentManifest
    private let locator: any InstallationLocating
    private let preflight: DeploymentPreflight
    private let downloader: any ArtifactDownloading
    private let hasher: any FileHashing
    private let runtimeInstaller: any RuntimeInstalling
    private let launchAgentInstaller: any LaunchAgentInstalling
    private let inspectorFactory:
        @Sendable (InstallationLayout) -> any InstallationInspecting
    private let migratorFactory:
        @Sendable (InstallationLayout) -> any LegacyMigrating
    private let recordStore: any InstallationRecordStoring
    private let service: any ManagedServiceControlling
    private let healthChecker: any HealthChecking
    private let files: any DeploymentFileManaging
    private let sleeper: any DeploymentSleeping
    private let healthPollAttempts: Int

    private var currentSnapshot = DeploymentSnapshot(
        phase: .idle,
        statusText: "Not installed."
    )
    private var subscribers:
        [UUID: AsyncStream<DeploymentSnapshot>.Continuation] = [:]
    private var activeOperation: UUID?
    private var cancelActiveSubtask: (@Sendable () -> Void)?
    private var pauseRequested = false
    private var pauseWaiters: [CheckedContinuation<Void, Never>] = []

    public init(
        manifest: DeploymentManifest,
        locator: any InstallationLocating,
        preflight: DeploymentPreflight,
        downloader: any ArtifactDownloading,
        hasher: any FileHashing,
        runtimeInstaller: any RuntimeInstalling,
        launchAgentInstaller: any LaunchAgentInstalling,
        inspector: any InstallationInspecting,
        migrator: any LegacyMigrating,
        recordStore: any InstallationRecordStoring,
        service: any ManagedServiceControlling,
        healthChecker: any HealthChecking
    ) {
        self.init(
            manifest: manifest,
            locator: locator,
            preflight: preflight,
            downloader: downloader,
            hasher: hasher,
            runtimeInstaller: runtimeInstaller,
            launchAgentInstaller: launchAgentInstaller,
            inspectorFactory: { _ in inspector },
            migratorFactory: { _ in migrator },
            recordStore: recordStore,
            service: service,
            healthChecker: healthChecker,
            files: LiveDeploymentFileManager(hasher: hasher),
            sleeper: ContinuousDeploymentSleeper(),
            healthPollAttempts: 90
        )
    }

    public init(
        manifest: DeploymentManifest,
        locator: any InstallationLocating,
        preflight: DeploymentPreflight,
        downloader: any ArtifactDownloading,
        hasher: any FileHashing,
        runtimeInstaller: any RuntimeInstalling,
        launchAgentInstaller: any LaunchAgentInstalling,
        inspectorFactory: @escaping @Sendable (InstallationLayout) -> any InstallationInspecting,
        migratorFactory: @escaping @Sendable (InstallationLayout) -> any LegacyMigrating,
        recordStore: any InstallationRecordStoring,
        service: any ManagedServiceControlling,
        healthChecker: any HealthChecking
    ) {
        self.init(
            manifest: manifest,
            locator: locator,
            preflight: preflight,
            downloader: downloader,
            hasher: hasher,
            runtimeInstaller: runtimeInstaller,
            launchAgentInstaller: launchAgentInstaller,
            inspectorFactory: inspectorFactory,
            migratorFactory: migratorFactory,
            recordStore: recordStore,
            service: service,
            healthChecker: healthChecker,
            files: LiveDeploymentFileManager(hasher: hasher),
            sleeper: ContinuousDeploymentSleeper(),
            healthPollAttempts: 90
        )
    }

    init(
        manifest: DeploymentManifest,
        locator: any InstallationLocating,
        preflight: DeploymentPreflight,
        downloader: any ArtifactDownloading,
        hasher: any FileHashing,
        runtimeInstaller: any RuntimeInstalling,
        launchAgentInstaller: any LaunchAgentInstalling,
        inspectorFactory: @escaping @Sendable (InstallationLayout) -> any InstallationInspecting,
        migratorFactory: @escaping @Sendable (InstallationLayout) -> any LegacyMigrating,
        recordStore: any InstallationRecordStoring,
        service: any ManagedServiceControlling,
        healthChecker: any HealthChecking,
        files: any DeploymentFileManaging,
        sleeper: any DeploymentSleeping,
        healthPollAttempts: Int
    ) {
        self.manifest = manifest
        self.locator = locator
        self.preflight = preflight
        self.downloader = downloader
        self.hasher = hasher
        self.runtimeInstaller = runtimeInstaller
        self.launchAgentInstaller = launchAgentInstaller
        self.inspectorFactory = inspectorFactory
        self.migratorFactory = migratorFactory
        self.recordStore = recordStore
        self.service = service
        self.healthChecker = healthChecker
        self.files = files
        self.sleeper = sleeper
        self.healthPollAttempts = max(1, healthPollAttempts)
    }

    init(
        manifest: DeploymentManifest,
        locator: any InstallationLocating,
        preflight: DeploymentPreflight,
        downloader: any ArtifactDownloading,
        hasher: any FileHashing,
        runtimeInstaller: any RuntimeInstalling,
        launchAgentInstaller: any LaunchAgentInstalling,
        inspector: any InstallationInspecting,
        migrator: any LegacyMigrating,
        recordStore: any InstallationRecordStoring,
        service: any ManagedServiceControlling,
        healthChecker: any HealthChecking,
        files: any DeploymentFileManaging,
        sleeper: any DeploymentSleeping,
        healthPollAttempts: Int
    ) {
        self.init(
            manifest: manifest,
            locator: locator,
            preflight: preflight,
            downloader: downloader,
            hasher: hasher,
            runtimeInstaller: runtimeInstaller,
            launchAgentInstaller: launchAgentInstaller,
            inspectorFactory: { _ in inspector },
            migratorFactory: { _ in migrator },
            recordStore: recordStore,
            service: service,
            healthChecker: healthChecker,
            files: files,
            sleeper: sleeper,
            healthPollAttempts: healthPollAttempts
        )
    }

    public func snapshots() async -> AsyncStream<DeploymentSnapshot> {
        let id = UUID()
        let pair = AsyncStream<DeploymentSnapshot>.makeStream()
        subscribers[id] = pair.continuation
        pair.continuation.yield(currentSnapshot)
        pair.continuation.onTermination = { @Sendable [weak self] _ in
            Task {
                await self?.removeSubscriber(id)
            }
        }
        return pair.stream
    }

    public func inspect() async -> InstallationStatus {
        do {
            if let location = try locator.load() {
                let layout = InstallationLayout(root: location.root)
                return await inspectorFactory(layout).inspect()
            }
            let layout = InstallationLayout(
                root: InstallationLocator.defaultInstallationRoot
            )
            return await inspectorFactory(layout)
                .inspectUnlocatedDefaultRoot()
        } catch {
            return .managedIncompatible(
                "The installation location cannot be read."
            )
        }
    }

    public func deploy(options: DeploymentOptions) async throws {
        let token = try beginOperation()
        defer { finishOperation(token) }

        do {
            try await deployOperation(options: options, token: token)
        } catch is CancellationError {
            publishPaused()
            throw CancellationError()
        } catch {
            publishFailure(for: error)
            throw error
        }
    }

    public func migrate(options: DeploymentOptions) async throws {
        let token = try beginOperation()
        defer { finishOperation(token) }

        do {
            let layout = InstallationLayout(root: options.root)
            let inspector = inspectorFactory(layout)
            let status = await inspector.inspect()
            let ownsOccupiedPort = await inspector.ownsServicePort(
                manifest.service.port
            )
            try await runPreflight(
                options: options,
                allowOccupiedQwythosPort:
                    status.recognizesQwythosService
                    && ownsOccupiedPort
            )
            try locator.save(InstallationLocation(root: options.root))
            try checkCancellation()
            var runtimeSwitched = false
            try await installRuntime(
                layout: layout,
                token: token,
                switchAttempted: &runtimeSwitched
            )
            try checkCancellation()
            publish(
                phase: .repairing,
                statusText: "Migrating existing installation..."
            )
            let migrator = migratorFactory(layout)
            do {
                try await runCancellable {
                    try await migrator.migrate(options: options)
                }
            } catch LegacyMigrationError.modelDownloadRequired {
                try checkCancellation()
                try await installModel(layout: layout, token: token)
                try checkCancellation()
                publish(
                    phase: .repairing,
                    statusText: "Migrating existing installation..."
                )
                try await runCancellable {
                    try await migrator.migrate(options: options)
                }
            }
            try checkCancellation()
            if runtimeSwitched {
                try? runtimeInstaller.commitCurrentRuntime(layout: layout)
            }
            publish(
                phase: .installed,
                overallProgress: 1,
                statusText: "Qwythos is installed."
            )
        } catch is CancellationError {
            publishPaused()
            throw CancellationError()
        } catch {
            publishFailure(for: error)
            throw error
        }
    }

    public func pause() async {
        guard activeOperation != nil else { return }
        pauseRequested = true
        cancelActiveSubtask?()
    }

    public func pauseAndWait() async {
        guard activeOperation != nil else { return }
        pauseRequested = true
        cancelActiveSubtask?()
        await withCheckedContinuation { continuation in
            if activeOperation == nil {
                continuation.resume()
            } else {
                pauseWaiters.append(continuation)
            }
        }
    }

    public func cancel() async {
        await pauseAndWait()
    }

    public func repair() async throws {
        let token = try beginOperation()
        defer { finishOperation(token) }

        do {
            let context = try loadManagedContext()
            let status = await inspectorFactory(context.layout).inspect()
            let damaged: Set<RepairComponent>
            switch status {
            case .managedHealthy(let inspectedRecord)
                where inspectedRecord == context.record:
                publish(
                    phase: .installed,
                    overallProgress: 1,
                    statusText: "Qwythos is installed."
                )
                return
            case .managedRepairable(let inspectedRecord, let components)
                where inspectedRecord == context.record:
                damaged = components
            case .managedIncompatible
                where canUpgradeRuntime(
                    record: context.record,
                    layout: context.layout
                ):
                damaged = [.runtime]
            default:
                throw DeploymentCoordinatorError.installationNotRepairable
            }

            publish(
                phase: .repairing,
                statusText: "Repairing installation..."
            )
            try await repair(
                components: damaged,
                context: context,
                token: token
            )
        } catch is CancellationError {
            publishPaused()
            throw CancellationError()
        } catch {
            publishFailure(for: error)
            throw error
        }
    }

    public func reinstallRuntime() async throws {
        let token = try beginOperation()
        defer { finishOperation(token) }

        do {
            let context = try loadManagedContext()
            publish(
                phase: .repairing,
                component: .runtime,
                statusText: "Reinstalling runtime..."
            )
            try await repair(
                components: [.runtime],
                context: context,
                token: token
            )
        } catch is CancellationError {
            publishPaused()
            throw CancellationError()
        } catch {
            publishFailure(for: error)
            throw error
        }
    }

    public func setAccessMode(_ mode: NetworkAccessMode) async throws {
        let token = try beginOperation()
        defer { finishOperation(token) }

        do {
            let context = try loadManagedContext()
            guard context.record.accessMode != mode else {
                publish(
                    phase: .installed,
                    overallProgress: 1,
                    statusText: "Qwythos is installed."
                )
                return
            }
            let options = DeploymentOptions(
                root: context.layout.root,
                contextSize: context.record.contextSize,
                accessMode: mode
            )
            try await rewriteConfiguration(
                options: options,
                previousRecord: context.record,
                layout: context.layout
            )
            do {
                try saveCompletionRecord(
                    makeRecord(options: options),
                    replacing: context.record,
                    layout: context.layout
                )
            } catch {
                await restoreConfiguration(
                    previousRecord: context.record,
                    layout: context.layout
                )
                throw error
            }
            publish(
                phase: .installed,
                overallProgress: 1,
                statusText: "Qwythos is installed."
            )
        } catch is CancellationError {
            publishPaused()
            throw CancellationError()
        } catch {
            publishFailure(for: error)
            throw error
        }
    }

    public func regenerateAPIKey() async throws -> String {
        let token = try beginOperation()
        defer { finishOperation(token) }

        do {
            let context = try loadManagedContext()
            guard context.record.accessMode == .shared else {
                throw DeploymentCoordinatorError.sharedAccessRequired
            }
            let options = options(for: context.record)
            let previousState = try launchAgentInstaller.captureInstallationState(
                layout: context.layout
            )
            let wasRunning = await service.isRunning()
            publish(
                phase: .writingConfiguration,
                component: .configuration,
                statusText: "Updating API key..."
            )
            do {
                try await service.stop()
                try checkCancellation()
                let key = try launchAgentInstaller.regenerateAPIKey(
                    layout: context.layout
                )
                try launchAgentInstaller.install(
                    layout: context.layout,
                    options: options,
                    manifest: manifest
                )
                try await startAndCheckHealth()
                publish(
                    phase: .installed,
                    overallProgress: 1,
                    statusText: "Qwythos is installed."
                )
                return key
            } catch {
                try await restoreKeyRotation(
                    state: previousState,
                    layout: context.layout,
                    shouldRestart: wasRunning
                )
                throw error
            }
        } catch is CancellationError {
            publishPaused()
            throw CancellationError()
        } catch {
            publishFailure(for: error)
            throw error
        }
    }

    private func restoreKeyRotation(
        state: LaunchAgentInstallationState,
        layout: InstallationLayout,
        shouldRestart: Bool
    ) async throws {
        try await Task.detached { [launchAgentInstaller, service] in
            var failures: [KeyRotationRecoveryStep] = []
            do { try await service.stop() } catch { failures.append(.stopService) }
            do { try launchAgentInstaller.restoreAPIKeyState(state, layout: layout) }
            catch { failures.append(.restoreAPIKey) }
            do { try launchAgentInstaller.restorePlistState(state, layout: layout) }
            catch { failures.append(.restorePlist) }
            if shouldRestart {
                do { try await service.start() } catch { failures.append(.restartService) }
            }
            if !failures.isEmpty { throw KeyRotationRecoveryError(failedSteps: failures) }
        }.value
    }

    public func uninstall(deleteModel: Bool) async throws {
        let token = try beginOperation()
        defer { finishOperation(token) }

        do {
            guard let context = try validatedUninstallContext() else {
                publish(
                    phase: .uninstalling,
                    statusText: "Finishing uninstall..."
                )
                let location = try requireLocation()
                try files.finalizeManagedRuntimeCleanup(
                    layout: InstallationLayout(root: location.root)
                )
                try locator.remove()
                publish(phase: .idle, statusText: "Not installed.")
                return
            }
            let layout = context.layout
            publish(
                phase: .uninstalling,
                statusText: "Uninstalling Qwythos..."
            )
            try await service.stop()
            try checkCancellation()
            try launchAgentInstaller.uninstall()

            let exactFilesOrLinks = [
                layout.runtimeCurrent,
                layout.apiKeyFile,
                layout.legacyPlistBackup,
                layout.partialFile(for: manifest.runtime.archive),
                layout.partialFile(for: manifest.model),
                layout.logsDirectory.appending(
                    path: "llama-server.stdout.log"
                ),
                layout.logsDirectory.appending(
                    path: "llama-server.stderr.log"
                ),
            ]
            for item in exactFilesOrLinks {
                try checkCancellation()
                try files.removeManagedItem(
                    item,
                    layout: layout,
                    kind: .fileOrLink
                )
            }

            try files.removeManagedRuntimeVersion(
                record: context.record,
                layout: layout
            )
            if deleteModel {
                try checkCancellation()
                try files.removeManagedModel(
                    layout: layout,
                    expectedSHA256: context.record.modelSHA256
                )
            }

            var emptyDirectories = [
                layout.runtimeVersionsDirectory,
                layout.runtimeDirectory,
                layout.downloadsDirectory,
                layout.logsDirectory,
                layout.stagingDirectory,
            ]
            if deleteModel {
                emptyDirectories.append(layout.modelsDirectory)
            }
            for directory in emptyDirectories {
                try checkCancellation()
                try files.removeManagedItem(
                    directory,
                    layout: layout,
                    kind: .emptyDirectory
                )
            }

            guard try recordStore.remove(
                ifMatching: context.record,
                layout: layout
            ) else {
                throw DeploymentCoordinatorError.installationNotRepairable
            }
            try files.finalizeManagedRuntimeCleanup(layout: layout)
            try files.removeManagedItem(
                layout.configDirectory,
                layout: layout,
                kind: .emptyDirectory
            )

            try locator.remove()
            publish(phase: .idle, statusText: "Not installed.")
        } catch is CancellationError {
            publishPaused()
            throw CancellationError()
        } catch {
            publishFailure(for: error)
            throw error
        }
    }

    private func deployOperation(
        options: DeploymentOptions,
        token: UUID
    ) async throws {
        let layout = InstallationLayout(root: options.root)
        let inspector = inspectorFactory(layout)
        let status = await inspector.inspect()
        let ownsOccupiedPort = await inspector.ownsServicePort(
            manifest.service.port
        )
        let locatedRoot = try locator.load()?.root.standardizedFileURL
        try await runPreflight(
            options: options,
            allowOccupiedQwythosPort:
                status.recognizesQwythosService
                && ownsOccupiedPort
                && locatedRoot == options.root.standardizedFileURL
        )
        try options.validate(for: layout)
        try locator.save(InstallationLocation(root: options.root))
        try checkCancellation()

        let previousRecord = try recordStore.load(layout: layout)
        if let previousRecord {
            try validateManagedContextRecord(
                previousRecord,
                layout: layout
            )
        }
        let runtimeNeeded = previousRecord?.runtimeVersion
            != manifest.runtime.version
        let modelNeeded = try !files.managedModelMatches(
            layout: layout,
            expectedSHA256: manifest.model.sha256
        )
        var runtimeSwitched = false
        var serviceStarted = false
        var configurationAttempted = false

        do {
            if runtimeNeeded {
                try await installRuntime(
                    layout: layout,
                    token: token,
                    switchAttempted: &runtimeSwitched
                )
            }
            if modelNeeded {
                try await installModel(layout: layout, token: token)
            }

            publish(
                phase: .writingConfiguration,
                component: .configuration,
                statusText: "Writing service configuration..."
            )
            configurationAttempted = true
            if previousRecord != nil {
                try await service.stop()
            }
            try checkCancellation()
            try launchAgentInstaller.install(
                layout: layout,
                options: options,
                manifest: manifest
            )
            publish(
                phase: .startingService,
                component: .launchAgent,
                statusText: "Starting Qwythos..."
            )
            try await service.start()
            serviceStarted = true
            try await waitForHealth()
            try checkCancellation()
            try saveCompletionRecord(
                makeRecord(options: options),
                replacing: previousRecord,
                layout: layout
            )
            if runtimeSwitched {
                // A retained backup is safer than invalidating a healthy record.
                try? runtimeInstaller.commitCurrentRuntime(layout: layout)
            }
            publish(
                phase: .installed,
                overallProgress: 1,
                statusText: "Qwythos is installed."
            )
        } catch {
            if runtimeSwitched, let previousRecord {
                try await rollBackRuntime(
                    previousRecord: previousRecord,
                    layout: layout
                )
            } else if configurationAttempted, let previousRecord {
                await restoreConfiguration(
                    previousRecord: previousRecord,
                    layout: layout
                )
            } else if previousRecord == nil,
                      configurationAttempted || serviceStarted {
                await cleanUpFailedNewService()
            }
            throw error
        }
    }

    private func cleanUpFailedNewService() async {
        let service = self.service
        let launchAgentInstaller = self.launchAgentInstaller
        await Task.detached {
            try? await service.stop()
            try? launchAgentInstaller.uninstall()
        }.value
    }

    private func repair(
        components: Set<RepairComponent>,
        context: ManagedContext,
        token: UUID
    ) async throws {
        var runtimeSwitched = false
        do {
            if components.contains(.runtime) {
                try await installRuntime(
                    layout: context.layout,
                    token: token,
                    switchAttempted: &runtimeSwitched
                )
            }
            if components.contains(.model) {
                try await installModel(
                    layout: context.layout,
                    token: token
                )
            }

            try await rewriteConfiguration(
                options: options(for: context.record),
                previousRecord: context.record,
                layout: context.layout,
                restoreConfigurationOnFailure: !runtimeSwitched
            )
            try saveCompletionRecord(
                InstallationRecord(
                    manifestSchemaVersion: manifest.schemaVersion,
                    root: context.layout.root,
                    runtimeVersion: manifest.runtime.version,
                    modelSHA256: manifest.model.sha256,
                    contextSize: context.record.contextSize,
                    accessMode: context.record.accessMode,
                    installedAt: Date()
                ),
                replacing: context.record,
                layout: context.layout
            )
            if runtimeSwitched {
                // A retained backup is safer than invalidating a healthy record.
                try? runtimeInstaller.commitCurrentRuntime(
                    layout: context.layout
                )
            }
            publish(
                phase: .installed,
                overallProgress: 1,
                statusText: "Qwythos is installed."
            )
        } catch {
            if runtimeSwitched {
                try await rollBackRuntime(
                    previousRecord: context.record,
                    layout: context.layout
                )
            }
            throw error
        }
    }

    private func installRuntime(
        layout: InstallationLayout,
        token: UUID,
        switchAttempted: inout Bool
    ) async throws {
        let artifact = manifest.runtime.archive
        publish(
            phase: .downloadingRuntime,
            component: .runtime,
            completedBytes: 0,
            totalBytes: artifact.size,
            overallProgress: 0,
            statusText: "Downloading runtime..."
        )
        let archive = try await download(
            artifact: artifact,
            partialURL: layout.partialFile(for: artifact),
            phase: .downloadingRuntime,
            component: .runtime,
            token: token
        )
        publish(
            phase: .verifyingRuntime,
            component: .runtime,
            statusText: "Verifying runtime..."
        )
        try verify(
            archive,
            artifact: artifact,
            component: .runtime,
            layout: layout
        )
        try checkCancellation()
        publish(
            phase: .installingRuntime,
            component: .runtime,
            statusText: "Installing runtime..."
        )
        let runtimeInstaller = self.runtimeInstaller
        let runtimeManifest = manifest.runtime
        switchAttempted = true
        try await runCancellable {
            try await runtimeInstaller.install(
                archive: archive,
                manifest: runtimeManifest,
                layout: layout
            )
        }
        try checkCancellation()
    }

    private func installModel(
        layout: InstallationLayout,
        token: UUID
    ) async throws {
        let artifact = manifest.model
        publish(
            phase: .downloadingModel,
            component: .model,
            completedBytes: 0,
            totalBytes: artifact.size,
            overallProgress: runtimeProgressOffset,
            statusText: "Downloading model..."
        )
        let model = try await download(
            artifact: artifact,
            partialURL: layout.partialFile(for: artifact),
            phase: .downloadingModel,
            component: .model,
            token: token
        )
        publish(
            phase: .verifyingModel,
            component: .model,
            statusText: "Verifying model..."
        )
        try verify(
            model,
            artifact: artifact,
            component: .model,
            layout: layout
        )
        try checkCancellation()
        try files.promoteModel(
            from: model,
            layout: layout,
            expectedSHA256: artifact.sha256
        )
    }

    private func rewriteConfiguration(
        options: DeploymentOptions,
        previousRecord: InstallationRecord,
        layout: InstallationLayout,
        restoreConfigurationOnFailure: Bool = true
    ) async throws {
        publish(
            phase: .writingConfiguration,
            component: .configuration,
            statusText: "Writing service configuration..."
        )
        try await service.stop()
        do {
            try checkCancellation()
            try launchAgentInstaller.install(
                layout: layout,
                options: options,
                manifest: manifest
            )
            try await startAndCheckHealth()
        } catch {
            if restoreConfigurationOnFailure {
                await restoreConfiguration(
                    previousRecord: previousRecord,
                    layout: layout
                )
            }
            throw error
        }
    }

    private func restoreConfiguration(
        previousRecord: InstallationRecord,
        layout: InstallationLayout
    ) async {
        let service = self.service
        let launchAgentInstaller = self.launchAgentInstaller
        let manifest = self.manifest
        let oldOptions = options(for: previousRecord)
        await Task.detached {
            try? await service.stop()
            try? launchAgentInstaller.install(
                layout: layout,
                options: oldOptions,
                manifest: manifest
            )
            try? await service.start()
        }.value
    }

    private func startAndCheckHealth() async throws {
        publish(
            phase: .startingService,
            component: .launchAgent,
            statusText: "Starting Qwythos..."
        )
        try await service.start()
        try await waitForHealth()
        try checkCancellation()
    }

    private func waitForHealth() async throws {
        publish(
            phase: .checkingHealth,
            component: .launchAgent,
            statusText: "Checking service health..."
        )
        let url = URL(
            string: "http://127.0.0.1:\(manifest.service.port)/health"
        )!
        for attempt in 0..<healthPollAttempts {
            try checkCancellation()
            if await healthChecker.isHealthy(url) {
                return
            }
            try checkCancellation()
            if attempt + 1 < healthPollAttempts {
                let sleeper = self.sleeper
                try await runCancellable {
                    try await sleeper.sleep(for: .seconds(1))
                }
            }
        }
        throw DeploymentCoordinatorError.healthTimedOut
    }

    private func rollBackRuntime(
        previousRecord: InstallationRecord,
        layout: InstallationLayout
    ) async throws {
        let service = self.service
        let runtimeInstaller = self.runtimeInstaller
        let launchAgentInstaller = self.launchAgentInstaller
        let manifest = self.manifest
        let previousOptions = options(for: previousRecord)
        do {
            try await Task.detached {
                try? await service.stop()
                try runtimeInstaller.rollBackCurrentRuntime(
                    to: previousRecord.runtimeVersion,
                    layout: layout
                )
                try launchAgentInstaller.install(
                    layout: layout,
                    options: previousOptions,
                    manifest: manifest
                )
                try await service.start()
            }.value
        } catch {
            throw DeploymentCoordinatorError.runtimeRollbackFailed(
                String(describing: error)
            )
        }
    }

    private func download(
        artifact: DeploymentArtifact,
        partialURL: URL,
        phase: DeploymentPhase,
        component: RepairComponent,
        token: UUID
    ) async throws -> URL {
        _ = try InstallationLayout(
            root: partialURL.deletingLastPathComponent()
                .deletingLastPathComponent()
        ).requireManaged(partialURL)
        let totalDownloadBytes = manifest.runtime.size + manifest.model.size
        let runtimeOffset: Int64 = component == .model
            ? manifest.runtime.size
            : 0
        let downloader = self.downloader
        let result = try await runCancellable {
            try await downloader.download(
                artifact: artifact,
                partialURL: partialURL
            ) { progress in
                Task {
                    await self.publishDownloadProgress(
                        progress,
                        phase: phase,
                        component: component,
                        token: token,
                        overallCompleted: runtimeOffset
                            + progress.completedBytes,
                        overallTotal: totalDownloadBytes
                    )
                }
            }
        }
        guard result.standardizedFileURL == partialURL.standardizedFileURL
        else {
            throw DeploymentCoordinatorError.unsafeDownloadedArtifact
        }
        return result
    }

    private func verify(
        _ file: URL,
        artifact: DeploymentArtifact,
        component: RepairComponent,
        layout: InstallationLayout
    ) throws {
        _ = try layout.requireManaged(file)
        let actual = try hasher.sha256(file: file)
        guard actual.caseInsensitiveCompare(artifact.sha256) == .orderedSame
        else {
            throw DeploymentCoordinatorError.artifactDigestMismatch(
                component: component,
                expected: artifact.sha256,
                actual: actual
            )
        }
    }

    private func runPreflight(
        options: DeploymentOptions,
        allowOccupiedQwythosPort: Bool
    ) async throws {
        publish(
            phase: .preflighting,
            statusText: "Checking this Mac..."
        )
        let report = await preflight.run(
            root: options.root,
            servicePort: manifest.service.port
        )
        var blockingIssues = report.issues
        if allowOccupiedQwythosPort {
            blockingIssues.removeAll {
                $0 == .portUnavailable(manifest.service.port)
            }
        }
        guard blockingIssues.isEmpty else {
            throw DeploymentCoordinatorError.preflightFailed(blockingIssues)
        }
        try checkCancellation()
    }

    private func loadManagedContext() throws -> ManagedContext {
        let location = try requireLocation()
        let layout = InstallationLayout(root: location.root)
        guard let record = try recordStore.load(layout: layout) else {
            throw DeploymentCoordinatorError.installationNotFound
        }
        try validateManagedContextRecord(record, layout: layout)
        return ManagedContext(layout: layout, record: record)
    }

    private func validatedUninstallContext() throws -> ManagedContext? {
        let location = try requireLocation()
        let layout = InstallationLayout(root: location.root)
        guard let record = try recordStore.load(layout: layout) else {
            return nil
        }
        do {
            try record.validateManagedShape(for: layout)
        } catch {
            throw DeploymentCoordinatorError.installationNotRepairable
        }
        return ManagedContext(layout: layout, record: record)
    }

    private func validateManagedContextRecord(
        _ record: InstallationRecord,
        layout: InstallationLayout
    ) throws {
        do {
            try record.validateManagedShape(for: layout)
            guard record.manifestSchemaVersion == manifest.schemaVersion,
                  record.modelSHA256.caseInsensitiveCompare(
                    manifest.model.sha256
                  ) == .orderedSame else {
                throw InstallationRecordValidationError.invalidRecord
            }
        } catch {
            throw DeploymentCoordinatorError.installationNotRepairable
        }
    }

    private func requireLocation() throws -> InstallationLocation {
        guard let location = try locator.load() else {
            throw DeploymentCoordinatorError.installationNotFound
        }
        return location
    }

    private func canUpgradeRuntime(
        record: InstallationRecord,
        layout: InstallationLayout
    ) -> Bool {
        (try? record.validateManagedShape(for: layout)) != nil
            && record.manifestSchemaVersion == manifest.schemaVersion
            && record.modelSHA256.caseInsensitiveCompare(
                manifest.model.sha256
            ) == .orderedSame
            && record.runtimeVersion != manifest.runtime.version
            && DeploymentOptions.supportedContextSizes.contains(
                record.contextSize
            )
    }

    private func options(
        for record: InstallationRecord
    ) -> DeploymentOptions {
        DeploymentOptions(
            root: record.root,
            contextSize: record.contextSize,
            accessMode: record.accessMode
        )
    }

    private func makeRecord(
        options: DeploymentOptions
    ) -> InstallationRecord {
        InstallationRecord(
            manifestSchemaVersion: manifest.schemaVersion,
            root: options.root,
            runtimeVersion: manifest.runtime.version,
            modelSHA256: manifest.model.sha256,
            contextSize: options.contextSize,
            accessMode: options.accessMode,
            installedAt: Date()
        )
    }

    private func saveCompletionRecord(
        _ record: InstallationRecord,
        replacing previousRecord: InstallationRecord?,
        layout: InstallationLayout
    ) throws {
        do {
            try recordStore.save(record, layout: layout)
        } catch {
            let removed = (
                try? recordStore.remove(
                    ifMatching: record,
                    layout: layout
                )
            ) == true
            if removed, let previousRecord {
                try? recordStore.save(previousRecord, layout: layout)
            }
            throw error
        }
    }

    private var runtimeProgressOffset: Double {
        let total = manifest.runtime.size + manifest.model.size
        guard total > 0 else { return 0 }
        return Double(manifest.runtime.size) / Double(total)
    }

    private func runCancellable<T: Sendable>(
        _ operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        let task = Task {
            try await operation()
        }
        cancelActiveSubtask = {
            task.cancel()
        }
        defer {
            cancelActiveSubtask = nil
        }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    private func beginOperation() throws -> UUID {
        guard activeOperation == nil else {
            throw DeploymentCoordinatorError.operationInProgress
        }
        let token = UUID()
        activeOperation = token
        pauseRequested = false
        return token
    }

    private func finishOperation(_ token: UUID) {
        guard activeOperation == token else { return }
        cancelActiveSubtask = nil
        pauseRequested = false
        activeOperation = nil
        let waiters = pauseWaiters
        pauseWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    private func checkCancellation() throws {
        if pauseRequested {
            throw CancellationError()
        }
        try Task.checkCancellation()
    }

    private func publishDownloadProgress(
        _ progress: DownloadProgress,
        phase: DeploymentPhase,
        component: RepairComponent,
        token: UUID,
        overallCompleted: Int64,
        overallTotal: Int64
    ) {
        guard activeOperation == token, currentSnapshot.phase == phase else {
            return
        }
        let overallProgress = overallTotal > 0
            ? min(1, Double(overallCompleted) / Double(overallTotal))
            : nil
        publish(
            phase: phase,
            component: component,
            completedBytes: progress.completedBytes,
            totalBytes: progress.totalBytes,
            overallProgress: overallProgress,
            statusText: currentSnapshot.statusText
        )
    }

    private func publish(
        phase: DeploymentPhase,
        operationID: UUID? = nil,
        component: RepairComponent? = nil,
        completedBytes: Int64? = nil,
        totalBytes: Int64? = nil,
        overallProgress: Double? = nil,
        statusText: String,
        failure: DeploymentFailure? = nil
    ) {
        let snapshot = DeploymentSnapshot(
            phase: phase,
            operationID: operationID ?? activeOperation,
            component: component,
            completedBytes: completedBytes,
            totalBytes: totalBytes,
            overallProgress: overallProgress,
            statusText: statusText,
            failure: failure
        )
        currentSnapshot = snapshot
        for continuation in subscribers.values {
            continuation.yield(snapshot)
        }
    }

    private func publishPaused() {
        publish(
            phase: .paused,
            component: currentSnapshot.component,
            completedBytes: currentSnapshot.completedBytes,
            totalBytes: currentSnapshot.totalBytes,
            overallProgress: currentSnapshot.overallProgress,
            statusText: "Deployment paused."
        )
    }

    private func publishFailure(for error: Error) {
        let reason: String
        switch error {
        case DeploymentCoordinatorError.healthTimedOut:
            reason = "Qwythos did not become healthy in time."
        case DeploymentCoordinatorError.preflightFailed:
            reason = "This Mac is not ready for deployment."
        case DeploymentCoordinatorError.artifactDigestMismatch:
            reason = "A downloaded file failed verification."
        case DeploymentCoordinatorError.installationNotFound:
            reason = "The managed installation could not be found."
        case DeploymentCoordinatorError.installationNotRepairable:
            reason = "This installation cannot be repaired automatically."
        case DeploymentCoordinatorError.sharedAccessRequired:
            reason = "API keys are only used for local-network access."
        default:
            reason = "The deployment operation failed."
        }
        let failure = DeploymentFailure(
            phase: currentSnapshot.phase,
            component: currentSnapshot.component,
            reason: reason,
            diagnostic: String(describing: error),
            recoveryActions: [.retry, .viewLogs]
        )
        publish(
            phase: .failed,
            component: currentSnapshot.component,
            completedBytes: currentSnapshot.completedBytes,
            totalBytes: currentSnapshot.totalBytes,
            overallProgress: currentSnapshot.overallProgress,
            statusText: reason,
            failure: failure
        )
    }

    private func removeSubscriber(_ id: UUID) {
        subscribers[id] = nil
    }
}

private struct ManagedContext {
    let layout: InstallationLayout
    let record: InstallationRecord
}

private extension InstallationStatus {
    var recognizesQwythosService: Bool {
        switch self {
        case .legacyDetected, .managedHealthy, .managedRepairable:
            return true
        default:
            return false
        }
    }
}
