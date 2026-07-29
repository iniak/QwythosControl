import Darwin
import Foundation
import QwythosCore

public protocol LegacyModelLocating: Sendable {
    func locate(modelSHA256: String) throws -> URL?
}

public enum ModelReuseResult: Equatable, Sendable {
    case reused
    case downloadRequired
}

public protocol ModelReusing: Sendable {
    func reuse(_ source: URL, at destination: URL, expectedSHA256: String) throws -> ModelReuseResult
}

public protocol LegacyMigrating: Sendable {
    func migrate(options: DeploymentOptions) async throws
}

public enum LegacyMigrationError: Error, Equatable, Sendable {
    case legacyInstallationNotRecognized
    case modelDownloadRequired
    case serviceControlFailed
    case healthCheckFailed
    case managedRuntimeMissing
    case legacyBackupConflict
    case legacyBackupFailed
    case rollbackFailed(String)
}

public struct LegacyModelLocator: LegacyModelLocating, Sendable {
    private let cacheRoots: [URL]
    private let hasher: any FileHashing

    public init(
        cacheRoots: [URL] = LegacyModelLocator.defaultCacheRoots,
        hasher: any FileHashing = SHA256Hasher()
    ) {
        self.cacheRoots = cacheRoots.map(\.standardizedFileURL)
        self.hasher = hasher
    }

    public init(
        legacyPlist: LegacyLaunchAgent,
        homeDirectory: URL = URL(fileURLWithPath: NSHomeDirectory()),
        hasher: any FileHashing = SHA256Hasher()
    ) {
        let configured = legacyPlist.environment["LLAMA_CACHE"].map(URL.init(fileURLWithPath:))
        self.init(
            cacheRoots: ([configured].compactMap { $0 } + Self.cacheRoots(in: homeDirectory)),
            hasher: hasher
        )
    }

    public func locate(modelSHA256: String) throws -> URL? {
        let digest = modelSHA256.lowercased()
        for root in cacheRoots {
            for candidate in candidates(in: root, digest: digest) where isRegularFile(candidate) {
                if try hasher.sha256(file: candidate).caseInsensitiveCompare(digest) == .orderedSame {
                    return candidate
                }
            }
        }
        return nil
    }

    public static var defaultCacheRoots: [URL] {
        cacheRoots(in: URL(fileURLWithPath: NSHomeDirectory()))
    }

    private static func cacheRoots(in home: URL) -> [URL] {
        [
            home.appending(path: "Library/Caches/llama.cpp"),
            home.appending(path: ".cache/llama.cpp"),
        ]
    }

    private func candidates(in root: URL, digest: String) -> [URL] {
        var candidates = [
            root.appending(path: "blobs/\(digest)"),
            root.appending(path: digest),
            root.appending(path: "models/\(digest)"),
        ]
        if let directories = try? FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) {
            candidates += directories.compactMap { directory in
                (try? directory.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
                    ? directory.appending(path: "blobs/\(digest)")
                    : nil
            }
        }
        return candidates
    }

    private func isRegularFile(_ url: URL) -> Bool {
        var metadata = stat()
        return lstat(url.path, &metadata) == 0 && metadata.st_mode & S_IFMT == S_IFREG
    }
}

public enum ModelReuserError: Error, Equatable, Sendable {
    case sourceDigestMismatch
    case destinationExists
    case copyFailed
}

public struct ModelReuser: ModelReusing, Sendable {
    typealias AfterInstallHook = @Sendable (Int32, String) throws -> Void
    typealias AfterStageCreationHook = @Sendable (Int32, String) throws -> Void
    enum StagingStrategy: CaseIterable, Equatable, Sendable {
        case clone
        case hardLink
        case copy
    }

    enum CloneResult: Equatable, Sendable {
        // The operation must capture this identity from an owned descriptor.
        case created(POSIXFileIdentity)
        case failed(Int32)
    }

    struct FileOperations: Sendable {
        let clone: @Sendable (Int32, Int32, String) -> CloneResult
        let hardLink: @Sendable (Int32, String, Int32, String) -> Int32
        let renameNoReplace:
            @Sendable (Int32, String, Int32, String) -> Int32
        let syncDirectory: @Sendable (Int32) -> Int32

        static let live = FileOperations(
            clone: { sourceDescriptor, directoryDescriptor, name in
                guard fclonefileat(
                    sourceDescriptor,
                    directoryDescriptor,
                    name,
                    0
                ) == 0 else {
                    return .failed(errno)
                }

                let descriptor = openat(
                    directoryDescriptor,
                    name,
                    O_RDONLY | O_NOFOLLOW | O_CLOEXEC
                )
                guard descriptor >= 0 else {
                    return .failed(errno)
                }
                let file = POSIXFileDescriptor(descriptor)
                do {
                    return .created(
                        POSIXFileIdentity(try file.metadata())
                    )
                } catch POSIXTransactionError.operationFailed(let code) {
                    return .failed(code)
                } catch {
                    return .failed(EIO)
                }
            },
            hardLink: {
                sourceDirectory,
                sourceName,
                destinationDirectory,
                destinationName in
                linkat(
                    sourceDirectory,
                    sourceName,
                    destinationDirectory,
                    destinationName,
                    0
                )
            },
            renameNoReplace: {
                sourceDirectory,
                sourceName,
                destinationDirectory,
                destinationName in
                renameatx_np(
                    sourceDirectory,
                    sourceName,
                    destinationDirectory,
                    destinationName,
                    UInt32(RENAME_EXCL)
                )
            },
            syncDirectory: { fsync($0) }
        )
    }

    private let hasher: any FileHashing
    private let afterInstall: AfterInstallHook
    private let afterStageCreation: AfterStageCreationHook
    private let strategy: StagingStrategy?
    private let operations: FileOperations

    public init(hasher: any FileHashing = SHA256Hasher()) {
        self.hasher = hasher
        self.afterInstall = { _, _ in }
        self.afterStageCreation = { _, _ in }
        self.strategy = nil
        self.operations = .live
    }

    init(
        hasher: any FileHashing = SHA256Hasher(),
        afterInstall: @escaping AfterInstallHook
    ) {
        self.hasher = hasher
        self.afterInstall = afterInstall
        self.afterStageCreation = { _, _ in }
        self.strategy = nil
        self.operations = .live
    }

    init(
        hasher: any FileHashing = SHA256Hasher(),
        strategy: StagingStrategy
    ) {
        self.hasher = hasher
        self.afterInstall = { _, _ in }
        self.afterStageCreation = { _, _ in }
        self.strategy = strategy
        self.operations = .live
    }

    init(
        hasher: any FileHashing = SHA256Hasher(),
        strategy: StagingStrategy,
        afterStageCreation: @escaping AfterStageCreationHook
    ) {
        self.hasher = hasher
        self.afterInstall = { _, _ in }
        self.afterStageCreation = afterStageCreation
        self.strategy = strategy
        self.operations = .live
    }

    init(
        hasher: any FileHashing = SHA256Hasher(),
        operations: FileOperations
    ) {
        self.hasher = hasher
        self.afterInstall = { _, _ in }
        self.afterStageCreation = { _, _ in }
        self.strategy = nil
        self.operations = operations
    }

    public func reuse(_ source: URL, at destination: URL, expectedSHA256: String) throws -> ModelReuseResult {
        _ = try reuseWithIdentity(
            source,
            at: destination,
            expectedSHA256: expectedSHA256
        )
        return .reused
    }

    func reuseWithIdentity(
        _ source: URL,
        at destination: URL,
        expectedSHA256: String
    ) throws -> POSIXFileIdentity {
        do {
            try POSIXDirectoryDescriptor.validateRootURL(destination)
        } catch {
            throw ModelReuserError.copyFailed
        }
        let modelsURL = destination.deletingLastPathComponent().standardizedFileURL
        let rootURL = modelsURL.deletingLastPathComponent().standardizedFileURL
        guard modelsURL.lastPathComponent == "models",
              destination.standardizedFileURL == modelsURL.appending(path: destination.lastPathComponent),
              destination.lastPathComponent == InstallationLayout.modelFilename else {
            throw ModelReuserError.copyFailed
        }

        let sourceDescriptor = Darwin.open(
            source.path,
            O_RDONLY | O_NOFOLLOW | O_CLOEXEC
        )
        guard sourceDescriptor >= 0 else {
            throw ModelReuserError.sourceDigestMismatch
        }
        let sourceFile = POSIXFileDescriptor(sourceDescriptor)
        let sourceMetadata = try sourceFile.metadata()
        guard sourceMetadata.st_mode & S_IFMT == S_IFREG,
              try hasher.sha256(fileDescriptor: sourceDescriptor)
                .caseInsensitiveCompare(expectedSHA256) == .orderedSame else {
            throw ModelReuserError.sourceDigestMismatch
        }

        let root: POSIXDirectoryDescriptor
        do {
            root = try POSIXDirectoryDescriptor.openRoot(rootURL)
        } catch {
            throw ModelReuserError.copyFailed
        }
        let models: POSIXDirectoryDescriptor
        let stagingRoot: POSIXDirectoryDescriptor
        let transaction: POSIXOwnedDirectory
        do {
            models = try root.openDirectory("models", createMode: 0o700)
            stagingRoot = try root.openDirectory("staging", createMode: 0o700)
            transaction = try stagingRoot.createOwnedDirectory(
                prefix: ".model-transaction-",
                mode: 0o700
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw ModelReuserError.copyFailed
        }
        let staging = transaction.directory
        defer {
            try? stagingRoot.removeDirectoryIfOwned(
                transaction.name,
                identity: transaction.identity
            )
        }

        let staged: StagedFile
        do {
            staged = try createStagedFile(
                source: source,
                sourceFile: sourceFile,
                sourceIdentity: POSIXFileIdentity(sourceMetadata),
                staging: staging
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw ModelReuserError.copyFailed
        }
        defer {
            try? staging.unlinkIfOwned(staged.name, identity: staged.identity)
        }

        guard staged.metadata.st_mode & S_IFMT == S_IFREG,
              try hasher.sha256(fileDescriptor: staged.file.rawValue)
                .caseInsensitiveCompare(expectedSHA256) == .orderedSame else {
            throw ModelReuserError.copyFailed
        }
        guard let currentStagedMetadata = try? staging.metadata(
            for: staged.name
        ),
              currentStagedMetadata.st_mode & S_IFMT == S_IFREG,
              POSIXFileIdentity(currentStagedMetadata) == staged.identity else {
            throw ModelReuserError.copyFailed
        }

        try Task.checkCancellation()
        let publicationResult = operations.renameNoReplace(
            staging.rawValue,
            staged.name,
            models.rawValue,
            destination.lastPathComponent
        )
        if publicationResult != 0 {
            let publicationError = errno
            if publicationError == EEXIST {
                throw ModelReuserError.destinationExists
            }
            throw ModelReuserError.copyFailed
        }

        var validated = false
        defer {
            if !validated {
                do {
                    try models.unlinkIfOwned(
                        destination.lastPathComponent,
                        identity: staged.identity
                    )
                    _ = syncDirectory(models.rawValue)
                } catch {
                    // Preserve a mismatched replacement and surface the main error.
                }
            }
        }
        guard let installedMetadata = try? models.metadata(for: destination.lastPathComponent),
              installedMetadata.st_mode & S_IFMT == S_IFREG else {
            throw ModelReuserError.copyFailed
        }
        let installedIdentity = POSIXFileIdentity(installedMetadata)
        guard installedIdentity == staged.identity else {
            throw ModelReuserError.copyFailed
        }
        do {
            try afterInstall(models.rawValue, destination.lastPathComponent)
        } catch {
            throw ModelReuserError.copyFailed
        }

        let installed: POSIXFileDescriptor
        do {
            installed = try models.openFile(
                destination.lastPathComponent,
                flags: O_RDONLY | O_NOFOLLOW
            )
        } catch {
            throw ModelReuserError.copyFailed
        }
        let finalMetadata = try installed.metadata()
        guard finalMetadata.st_mode & S_IFMT == S_IFREG,
              POSIXFileIdentity(finalMetadata) == installedIdentity,
              try hasher.sha256(fileDescriptor: installed.rawValue)
                .caseInsensitiveCompare(expectedSHA256) == .orderedSame else {
            throw ModelReuserError.copyFailed
        }
        guard let currentMetadata = try? models.metadata(
            for: destination.lastPathComponent
        ),
              currentMetadata.st_mode & S_IFMT == S_IFREG,
              POSIXFileIdentity(currentMetadata) == installedIdentity else {
            throw ModelReuserError.copyFailed
        }
        guard syncDirectory(models.rawValue) else {
            throw ModelReuserError.copyFailed
        }
        validated = true
        return installedIdentity
    }

    private struct StagedFile {
        let name: String
        let file: POSIXFileDescriptor
        let metadata: stat
        let identity: POSIXFileIdentity
    }

    private func createStagedFile(
        source: URL,
        sourceFile: POSIXFileDescriptor,
        sourceIdentity: POSIXFileIdentity,
        staging: POSIXDirectoryDescriptor
    ) throws -> StagedFile {
        switch strategy {
        case .clone:
            if let clone = try cloneToFreshName(
                sourceFile: sourceFile,
                staging: staging
            ) {
                return clone
            }
            return try copyToFreshName(
                sourceFile: sourceFile,
                staging: staging
            )
        case .hardLink:
            guard let hardLink = try hardLinkToFreshName(
                source: source,
                sourceIdentity: sourceIdentity,
                staging: staging
            ) else {
                throw ModelReuserError.copyFailed
            }
            return hardLink
        case .copy:
            return try copyToFreshName(
                sourceFile: sourceFile,
                staging: staging
            )
        case nil:
            break
        }

        if let clone = try cloneToFreshName(sourceFile: sourceFile, staging: staging) {
            return clone
        }
        if let hardLink = try hardLinkToFreshName(
            source: source,
            sourceIdentity: sourceIdentity,
            staging: staging
        ) {
            return hardLink
        }
        return try copyToFreshName(sourceFile: sourceFile, staging: staging)
    }

    private func cloneToFreshName(
        sourceFile: POSIXFileDescriptor,
        staging: POSIXDirectoryDescriptor
    ) throws -> StagedFile? {
        for _ in 0..<16 {
            let name = freshStagingName()
            try Task.checkCancellation()
            let cloneResult = operations.clone(
                sourceFile.rawValue,
                staging.rawValue,
                name
            )
            let identity: POSIXFileIdentity
            switch cloneResult {
            case .created(let createdIdentity):
                identity = createdIdentity
            case .failed(let cloneError):
                if cloneError == EEXIST { continue }
                if cloneError == ENOTSUP
                    || cloneError == EOPNOTSUPP
                    || cloneError == EXDEV {
                    return nil
                }
                throw ModelReuserError.copyFailed
            }

            do {
                try Task.checkCancellation()
                try afterStageCreation(staging.rawValue, name)
                let staged = try openStagedFile(
                    name,
                    expectedIdentity: identity,
                    in: staging
                )
                guard fsync(staged.file.rawValue) == 0 else {
                    throw ModelReuserError.copyFailed
                }
                guard let publicMetadata = try staging.metadata(for: name),
                      publicMetadata.st_mode & S_IFMT == S_IFREG,
                      POSIXFileIdentity(publicMetadata) == identity else {
                    throw ModelReuserError.copyFailed
                }
                return staged
            } catch {
                try? staging.unlinkIfOwned(name, identity: identity)
                throw error
            }
        }
        throw ModelReuserError.copyFailed
    }

    private func hardLinkToFreshName(
        source: URL,
        sourceIdentity: POSIXFileIdentity,
        staging: POSIXDirectoryDescriptor
    ) throws -> StagedFile? {
        let parentDescriptor = Darwin.open(
            source.deletingLastPathComponent().path,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard parentDescriptor >= 0 else { return nil }
        let sourceParent = POSIXDirectoryDescriptor.openOwned(parentDescriptor)

        for _ in 0..<16 {
            let name = freshStagingName()
            try Task.checkCancellation()
            let hardLinkResult = operations.hardLink(
                sourceParent.rawValue,
                source.lastPathComponent,
                staging.rawValue,
                name
            )
            if hardLinkResult == 0 {
                return try finishCreatedStagedFile(
                    name,
                    expectedIdentity: sourceIdentity,
                    in: staging
                )
            }
            let hardLinkError = errno
            if hardLinkError == EEXIST { continue }
            if [
                EXDEV,
                ENOTSUP,
                EOPNOTSUPP,
                EPERM,
                EACCES,
                EMLINK,
                ENOENT,
            ].contains(hardLinkError) {
                return nil
            }
            throw ModelReuserError.copyFailed
        }
        throw ModelReuserError.copyFailed
    }

    private func copyToFreshName(
        sourceFile: POSIXFileDescriptor,
        staging: POSIXDirectoryDescriptor
    ) throws -> StagedFile {
        for _ in 0..<16 {
            let name = freshStagingName()
            try Task.checkCancellation()
            let descriptor = openat(
                staging.rawValue,
                name,
                O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
                0o600
            )
            if descriptor < 0 {
                if errno == EEXIST { continue }
                throw ModelReuserError.copyFailed
            }
            let file = POSIXFileDescriptor(descriptor)
            let identity = POSIXFileIdentity(try file.metadata())
            do {
                try copyContents(source: sourceFile.rawValue, destination: descriptor)
                try Task.checkCancellation()
                guard fsync(descriptor) == 0 else {
                    throw ModelReuserError.copyFailed
                }
                try afterStageCreation(staging.rawValue, name)
                let metadata = try file.metadata()
                guard metadata.st_mode & S_IFMT == S_IFREG,
                      POSIXFileIdentity(metadata) == identity,
                      let publicMetadata = try staging.metadata(for: name),
                      publicMetadata.st_mode & S_IFMT == S_IFREG,
                      POSIXFileIdentity(publicMetadata) == identity else {
                    throw ModelReuserError.copyFailed
                }
                return StagedFile(
                    name: name,
                    file: file,
                    metadata: metadata,
                    identity: identity
                )
            } catch {
                try? staging.unlinkIfOwned(name, identity: identity)
                throw error
            }
        }
        throw ModelReuserError.copyFailed
    }

    private func copyContents(source: Int32, destination: Int32) throws {
        var buffer = [UInt8](repeating: 0, count: 1_048_576)
        var sourceOffset: off_t = 0
        while true {
            let count = buffer.withUnsafeMutableBytes {
                pread(source, $0.baseAddress, $0.count, sourceOffset)
            }
            if count < 0 {
                if errno == EINTR { continue }
                throw ModelReuserError.copyFailed
            }
            if count == 0 { return }

            var written = 0
            while written < count {
                try Task.checkCancellation()
                let result = buffer.withUnsafeBytes {
                    Darwin.write(
                        destination,
                        $0.baseAddress!.advanced(by: written),
                        count - written
                    )
                }
                if result < 0 {
                    if errno == EINTR { continue }
                    throw ModelReuserError.copyFailed
                }
                guard result > 0 else { throw ModelReuserError.copyFailed }
                written += result
            }
            sourceOffset += off_t(count)
        }
    }

    private func openStagedFile(
        _ name: String,
        expectedIdentity: POSIXFileIdentity,
        in staging: POSIXDirectoryDescriptor
    ) throws -> StagedFile {
        let file = try staging.openFile(name, flags: O_RDONLY | O_NOFOLLOW)
        let metadata = try file.metadata()
        guard metadata.st_mode & S_IFMT == S_IFREG,
              POSIXFileIdentity(metadata) == expectedIdentity else {
            throw ModelReuserError.copyFailed
        }
        return StagedFile(
            name: name,
            file: file,
            metadata: metadata,
            identity: expectedIdentity
        )
    }

    private func finishCreatedStagedFile(
        _ name: String,
        expectedIdentity: POSIXFileIdentity,
        in staging: POSIXDirectoryDescriptor
    ) throws -> StagedFile {
        do {
            try afterStageCreation(staging.rawValue, name)
            return try openStagedFile(
                name,
                expectedIdentity: expectedIdentity,
                in: staging
            )
        } catch {
            try? staging.unlinkIfOwned(name, identity: expectedIdentity)
            throw error
        }
    }

    private func freshStagingName() -> String {
        ".model-\(UUID().uuidString).tmp"
    }

    private func syncDirectory(_ descriptor: Int32) -> Bool {
        while true {
            if operations.syncDirectory(descriptor) == 0 { return true }
            let code = errno
            if code == EINTR { continue }
            return false
        }
    }
}

public struct LegacyInstallationMigrator: LegacyMigrating, Sendable {
    typealias BackupInstallHook = @Sendable (Int32, String) throws -> Void
    typealias BeforeLegacyRestoreHook = @Sendable () throws -> Void

    struct FileOperations: Sendable {
        let renameNoReplace:
            @Sendable (Int32, String, Int32, String) -> Int32
        let syncDirectory: @Sendable (Int32) -> Int32

        static let live = FileOperations(
            renameNoReplace: {
                sourceDirectory,
                sourceName,
                destinationDirectory,
                destinationName in
                renameatx_np(
                    sourceDirectory,
                    sourceName,
                    destinationDirectory,
                    destinationName,
                    UInt32(RENAME_EXCL)
                )
            },
            syncDirectory: { fsync($0) }
        )
    }

    private let layout: InstallationLayout
    private let manifest: DeploymentManifest
    private let launchAgentsDirectory: URL
    private let records: any InstallationRecordStoring
    private let modelLocator: (any LegacyModelLocating)?
    private let modelReuser: any ModelReusing
    private let launchAgentInstaller: any LaunchAgentInstalling
    private let commandRunner: any CommandRunning
    private let healthChecker: any HealthChecking
    private let uid: uid_t
    private let beforeBackupInstall: BackupInstallHook
    private let beforeLegacyRestore: BeforeLegacyRestoreHook
    private let fileOperations: FileOperations
    private let sleeper: any DeploymentSleeping
    private let healthPollAttempts: Int

    public init(
        layout: InstallationLayout,
        manifest: DeploymentManifest,
        launchAgentsDirectory: URL = URL(fileURLWithPath: NSHomeDirectory()).appending(path: "Library/LaunchAgents"),
        records: any InstallationRecordStoring = InstallationRecordStore(),
        modelLocator: (any LegacyModelLocating)? = nil,
        modelReuser: any ModelReusing = ModelReuser(),
        launchAgentInstaller: (any LaunchAgentInstalling)? = nil,
        commandRunner: any CommandRunning = SystemCommandRunner(),
        healthChecker: any HealthChecking = URLSessionHealthChecker(),
        uid: uid_t = getuid()
    ) {
        self.init(
            layout: layout,
            manifest: manifest,
            launchAgentsDirectory: launchAgentsDirectory,
            records: records,
            modelLocator: modelLocator,
            modelReuser: modelReuser,
            launchAgentInstaller: launchAgentInstaller,
            commandRunner: commandRunner,
            healthChecker: healthChecker,
            uid: uid,
            beforeBackupInstall: { _, _ in },
            beforeLegacyRestore: {},
            fileOperations: .live,
            sleeper: ContinuousDeploymentSleeper(),
            healthPollAttempts: 90
        )
    }

    init(
        layout: InstallationLayout,
        manifest: DeploymentManifest,
        launchAgentsDirectory: URL,
        records: any InstallationRecordStoring = InstallationRecordStore(),
        modelLocator: (any LegacyModelLocating)? = nil,
        modelReuser: any ModelReusing = ModelReuser(),
        launchAgentInstaller: (any LaunchAgentInstalling)? = nil,
        commandRunner: any CommandRunning = SystemCommandRunner(),
        healthChecker: any HealthChecking = URLSessionHealthChecker(),
        uid: uid_t = getuid(),
        beforeBackupInstall: @escaping BackupInstallHook,
        beforeLegacyRestore: @escaping BeforeLegacyRestoreHook = {},
        fileOperations: FileOperations = .live,
        sleeper: any DeploymentSleeping = ContinuousDeploymentSleeper(),
        healthPollAttempts: Int = 1
    ) {
        self.layout = layout
        self.manifest = manifest
        self.launchAgentsDirectory = launchAgentsDirectory
        self.records = records
        self.modelLocator = modelLocator
        self.modelReuser = modelReuser
        self.launchAgentInstaller = launchAgentInstaller
            ?? LaunchAgentInstaller(launchAgentsDirectory: launchAgentsDirectory)
        self.commandRunner = commandRunner
        self.healthChecker = healthChecker
        self.uid = uid
        self.beforeBackupInstall = beforeBackupInstall
        self.beforeLegacyRestore = beforeLegacyRestore
        self.fileOperations = fileOperations
        self.sleeper = sleeper
        self.healthPollAttempts = max(1, healthPollAttempts)
    }

    public func migrate(options: DeploymentOptions) async throws {
        try options.validate(for: layout)
        let legacyURL = launchAgentsDirectory.appending(
            path: "\(LaunchAgentInstaller.defaultLabel).plist"
        )
        let snapshot = try legacySnapshot(at: legacyURL)
        guard let legacy = LegacyLaunchAgentDetector.plist(
            data: snapshot.data,
            at: legacyURL
        ), LegacyLaunchAgentDetector.isRecognized(legacy) else {
            throw LegacyMigrationError.legacyInstallationNotRecognized
        }
        guard verifiedManagedRuntime() else {
            throw LegacyMigrationError.managedRuntimeMissing
        }
        try validateManagedRootAndExistingDirectories()
        guard let launchAgentPreparer = launchAgentInstaller
            as? any LaunchAgentPreparing else {
            throw LegacyMigrationError.legacyBackupFailed
        }

        let source: URL?
        do {
            _ = try managedModelIdentity()
            source = nil
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            let locator = modelLocator
                ?? LegacyModelLocator(legacyPlist: legacy)
            guard let located = try locator.locate(
                modelSHA256: manifest.model.sha256
            ) else {
                throw LegacyMigrationError.modelDownloadRequired
            }
            source = located
        }

        try Task.checkCancellation()
        let initialServiceState = try await queryServiceState()
        var state = RollbackState(
            legacyURL: legacyURL,
            legacySnapshot: snapshot,
            initiallyLoaded: initialServiceState == .loaded
        )

        do {
            try Task.checkCancellation()
            if let source {
                state.modelIdentity = try reuseModel(source)
            }

            try Task.checkCancellation()
            try backupLegacy(data: snapshot.data, mode: snapshot.mode)

            if initialServiceState == .loaded {
                try Task.checkCancellation()
                state.legacyBootoutAttempted = true
                try await runService(command: .stop, plistPath: legacyURL.path)
            }

            try Task.checkCancellation()
            state.managedInstallAttempted = true
            let managedPlist = try launchAgentPreparer.prepareInstallation(
                layout: layout,
                options: options,
                manifest: manifest
            )
            do {
                state.managedPlistSnapshot = try publishManagedPlist(
                    managedPlist,
                    replacing: snapshot,
                    at: legacyURL
                )
            } catch ManagedPlistPublishError.recoveryDurabilityUncertain {
                state.plistRecoveryDurabilityUncertain = true
                throw LegacyMigrationError.legacyBackupFailed
            }

            try Task.checkCancellation()
            state.managedBootstrapAttempted = true
            try await runService(command: .start, plistPath: legacyURL.path)
            guard try await waitForHealth() else {
                throw LegacyMigrationError.healthCheckFailed
            }

            let record = InstallationRecord(
                manifestSchemaVersion: manifest.schemaVersion,
                root: layout.root,
                runtimeVersion: manifest.runtime.version,
                modelSHA256: manifest.model.sha256,
                contextSize: options.contextSize,
                accessMode: options.accessMode,
                installedAt: Date()
            )
            try Task.checkCancellation()
            state.record = record
            try records.save(record, layout: layout)
        } catch {
            let rollbackState = state
            let cleanup = Task.detached { [self, rollbackState] in
                await rollback(rollbackState)
            }
            let rollbackFailures = await cleanup.value
            if !rollbackFailures.isEmpty {
                throw LegacyMigrationError.rollbackFailed(
                    rollbackFailures.joined(separator: "; ")
                )
            }
            throw error
        }
    }

    private var healthURL: URL {
        URL(string: "http://127.0.0.1:\(manifest.service.port)/health")!
    }

    private func waitForHealth() async throws -> Bool {
        for attempt in 0..<healthPollAttempts {
            try Task.checkCancellation()
            if await healthChecker.isHealthy(healthURL) {
                try Task.checkCancellation()
                return true
            }
            try Task.checkCancellation()
            if attempt + 1 < healthPollAttempts {
                try await sleeper.sleep(for: .seconds(1))
            }
        }
        return false
    }

    private enum ServiceCommand {
        case start
        case stop
    }

    private enum ServiceState: Sendable {
        case loaded
        case absent
    }

    private struct LegacySnapshot: Equatable, Sendable {
        let data: Data
        let mode: mode_t
        let identity: POSIXFileIdentity
    }

    private enum ManagedPlistPublishError: Error {
        case recoveryDurabilityUncertain
    }

    private struct RollbackState: Sendable {
        let legacyURL: URL
        let legacySnapshot: LegacySnapshot
        let initiallyLoaded: Bool
        var legacyBootoutAttempted = false
        var managedInstallAttempted = false
        var managedBootstrapAttempted = false
        var plistRecoveryDurabilityUncertain = false
        var managedPlistSnapshot: LegacySnapshot?
        var modelIdentity: POSIXFileIdentity?
        var record: InstallationRecord?

        var serviceMayHaveChanged: Bool {
            legacyBootoutAttempted
                || managedInstallAttempted
                || managedBootstrapAttempted
        }
    }

    private func validateManagedRootAndExistingDirectories() throws {
        do {
            let root = try POSIXDirectoryDescriptor.openRoot(layout.root)
            try root.validateDirectoryIfPresent("models")
            try root.validateDirectoryIfPresent("staging")
            try root.validateDirectoryIfPresent("config")
            try root.validateDirectoryIfPresent("logs")
        } catch {
            throw LegacyMigrationError.managedRuntimeMissing
        }
    }

    private func reuseModel(_ source: URL) throws -> POSIXFileIdentity? {
        if let reuser = modelReuser as? ModelReuser {
            return try reuser.reuseWithIdentity(
                source,
                at: layout.modelFile,
                expectedSHA256: manifest.model.sha256
            )
        }
        let result = try modelReuser.reuse(
            source,
            at: layout.modelFile,
            expectedSHA256: manifest.model.sha256
        )
        guard result == .reused else {
            throw LegacyMigrationError.modelDownloadRequired
        }
        _ = try managedModelIdentity()
        return nil
    }

    private func managedModelIdentity() throws -> POSIXFileIdentity {
        do {
            let root = try POSIXDirectoryDescriptor.openRoot(layout.root)
            let models = try root.openDirectory("models")
            let file = try models.openFile(
                InstallationLayout.modelFilename,
                flags: O_RDONLY | O_NOFOLLOW
            )
            let metadata = try file.metadata()
            guard metadata.st_mode & S_IFMT == S_IFREG,
                  try SHA256Hasher().sha256(fileDescriptor: file.rawValue)
                    .caseInsensitiveCompare(manifest.model.sha256) == .orderedSame else {
                throw ModelReuserError.copyFailed
            }
            return POSIXFileIdentity(metadata)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw ModelReuserError.copyFailed
        }
    }

    private func backupLegacy(data: Data, mode: mode_t) throws {
        let root: POSIXDirectoryDescriptor
        let config: POSIXDirectoryDescriptor
        do {
            root = try POSIXDirectoryDescriptor.openRoot(layout.root)
            config = try root.openDirectory("config", createMode: 0o700)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw LegacyMigrationError.legacyBackupFailed
        }

        let backupName = layout.legacyPlistBackup.lastPathComponent
        if try existingBackupMatches(
            in: config,
            name: backupName,
            data: data,
            mode: mode
        ) {
            return
        }

        var temporaryName: String?
        var temporaryIdentity: POSIXFileIdentity?
        defer {
            if let temporaryName, let temporaryIdentity {
                try? config.unlinkIfOwned(
                    temporaryName,
                    identity: temporaryIdentity
                )
            }
        }

        let temporary: POSIXFileDescriptor
        do {
            let created = try createBackupTemporary(
                in: config,
                mode: mode
            )
            temporaryName = created.name
            temporaryIdentity = created.identity
            temporary = created.file
            try writeData(data, to: temporary.rawValue, checkCancellation: true)
            try Task.checkCancellation()
            guard fsync(temporary.rawValue) == 0 else {
                throw LegacyMigrationError.legacyBackupFailed
            }
            try temporary.closeChecked()
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as LegacyMigrationError {
            throw error
        } catch {
            throw LegacyMigrationError.legacyBackupFailed
        }

        guard let temporaryName, let temporaryIdentity else {
            throw LegacyMigrationError.legacyBackupFailed
        }
        try Task.checkCancellation()
        do {
            try beforeBackupInstall(config.rawValue, backupName)
        } catch {
            throw LegacyMigrationError.legacyBackupFailed
        }
        try Task.checkCancellation()

        let publicationResult = fileOperations.renameNoReplace(
            config.rawValue,
            temporaryName,
            config.rawValue,
            backupName
        )
        if publicationResult != 0 {
            let publicationError = errno
            if publicationError == EEXIST {
                if try existingBackupMatches(
                    in: config,
                    name: backupName,
                    data: data,
                    mode: mode
                ) {
                    return
                }
                throw LegacyMigrationError.legacyBackupConflict
            }
            throw LegacyMigrationError.legacyBackupFailed
        }

        var validated = false
        defer {
            if !validated {
                do {
                    try config.unlinkIfOwned(
                        backupName,
                        identity: temporaryIdentity
                    )
                    _ = syncDirectory(config.rawValue)
                } catch {
                    // Preserve a mismatched replacement and surface the main error.
                }
            }
        }
        guard let installed = try? config.metadata(for: backupName),
              installed.st_mode & S_IFMT == S_IFREG else {
            throw LegacyMigrationError.legacyBackupFailed
        }
        let installedIdentity = POSIXFileIdentity(installed)
        guard installedIdentity == temporaryIdentity,
              try existingBackupMatches(
                in: config,
                name: backupName,
                data: data,
                mode: mode
              ) else {
            throw LegacyMigrationError.legacyBackupFailed
        }
        guard syncDirectory(config.rawValue) else {
            throw LegacyMigrationError.legacyBackupFailed
        }
        validated = true
    }

    private func createBackupTemporary(
        in config: POSIXDirectoryDescriptor,
        mode: mode_t
    ) throws -> (
        name: String,
        file: POSIXFileDescriptor,
        identity: POSIXFileIdentity
    ) {
        for _ in 0..<16 {
            let name = ".legacy-backup-\(UUID().uuidString).tmp"
            try Task.checkCancellation()
            let descriptor = openat(
                config.rawValue,
                name,
                O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
                mode
            )
            if descriptor < 0 {
                if errno == EEXIST { continue }
                throw LegacyMigrationError.legacyBackupFailed
            }
            let file = POSIXFileDescriptor(descriptor)
            let identity = POSIXFileIdentity(try file.metadata())
            var keep = false
            defer {
                if !keep {
                    try? config.unlinkIfOwned(name, identity: identity)
                }
            }
            try Task.checkCancellation()
            guard fchmod(descriptor, mode) == 0 else {
                throw LegacyMigrationError.legacyBackupFailed
            }
            keep = true
            return (name, file, identity)
        }
        throw LegacyMigrationError.legacyBackupFailed
    }

    private func existingBackupMatches(
        in config: POSIXDirectoryDescriptor,
        name: String,
        data: Data,
        mode: mode_t
    ) throws -> Bool {
        let metadata: stat?
        do {
            metadata = try config.metadata(for: name)
        } catch {
            throw LegacyMigrationError.legacyBackupFailed
        }
        guard let metadata else { return false }
        guard metadata.st_mode & S_IFMT == S_IFREG else {
            throw LegacyMigrationError.legacyBackupConflict
        }
        do {
            let file = try config.openFile(name, flags: O_RDONLY | O_NOFOLLOW)
            let openedMetadata = try file.metadata()
            guard POSIXFileIdentity(openedMetadata) == POSIXFileIdentity(metadata),
                  openedMetadata.st_mode & S_IFMT == S_IFREG,
                  openedMetadata.st_mode & 0o777 == mode,
                  try descriptorContentsEqual(
                    file.rawValue,
                    data: data,
                    size: openedMetadata.st_size
                  ) else {
                throw LegacyMigrationError.legacyBackupConflict
            }
            guard let current = try config.metadata(for: name),
                  current.st_mode & S_IFMT == S_IFREG,
                  POSIXFileIdentity(current)
                    == POSIXFileIdentity(openedMetadata) else {
                throw LegacyMigrationError.legacyBackupConflict
            }
            return true
        } catch let error as LegacyMigrationError {
            throw error
        } catch {
            throw LegacyMigrationError.legacyBackupConflict
        }
    }

    private func syncDirectory(_ descriptor: Int32) -> Bool {
        while true {
            if fileOperations.syncDirectory(descriptor) == 0 { return true }
            let code = errno
            if code == EINTR { continue }
            return false
        }
    }

    private func rollback(_ state: RollbackState) async -> [String] {
        var failures: [String] = []
        var serviceState: ServiceState?
        var managedServiceConfirmedAbsent = !state.serviceMayHaveChanged
        var plistRestored = !state.managedInstallAttempted
        var serviceReconciled = !state.serviceMayHaveChanged

        func recordFailure(_ message: String) {
            if !failures.contains(message) {
                failures.append(message)
            }
        }

        if state.serviceMayHaveChanged {
            do {
                serviceState = try await queryServiceState()
            } catch {
                recordFailure("service state query failed")
            }

            if serviceState == .loaded {
                do {
                    try await runService(
                        command: .stop,
                        plistPath: state.legacyURL.path
                    )
                } catch {
                    // The command may have timed out after launchd applied it.
                }
                do {
                    serviceState = try await queryServiceState()
                } catch {
                    serviceState = nil
                    recordFailure("service state query failed")
                }
            }
            managedServiceConfirmedAbsent = serviceState == .absent
            if !managedServiceConfirmedAbsent {
                recordFailure("managed bootout failed")
            }
        }

        if state.managedInstallAttempted {
            if state.plistRecoveryDurabilityUncertain {
                recordFailure("legacy plist restore failed")
            } else if let managedPlistSnapshot = state.managedPlistSnapshot {
                do {
                    try beforeLegacyRestore()
                    try restoreLegacy(
                        state.legacySnapshot,
                        replacing: managedPlistSnapshot,
                        at: state.legacyURL
                    )
                    plistRestored = true
                } catch {
                    recordFailure("legacy plist restore failed")
                }
            } else if (try? plistSnapshot(at: state.legacyURL))
                == state.legacySnapshot {
                plistRestored = true
            } else {
                recordFailure("legacy plist restore failed")
            }
        }

        if state.serviceMayHaveChanged {
            if state.initiallyLoaded,
               managedServiceConfirmedAbsent,
               plistRestored {
                do {
                    try await runService(
                        command: .start,
                        plistPath: state.legacyURL.path
                    )
                } catch {
                    // A timed-out bootstrap can still have taken effect.
                }
                do {
                    serviceState = try await queryServiceState()
                } catch {
                    serviceState = nil
                    recordFailure("service state query failed")
                }
                if serviceState != .loaded {
                    recordFailure("legacy bootstrap failed")
                }
            } else if !state.initiallyLoaded,
                      managedServiceConfirmedAbsent,
                      plistRestored {
                do {
                    serviceState = try await queryServiceState()
                } catch {
                    serviceState = nil
                    recordFailure("service state query failed")
                }
                if serviceState != .absent {
                    recordFailure("service rollback incomplete")
                }
            }

            serviceReconciled = managedServiceConfirmedAbsent
                && plistRestored
                && serviceState == (state.initiallyLoaded ? .loaded : .absent)
        }

        guard serviceReconciled else {
            recordFailure("service rollback incomplete")
            return failures
        }

        if let record = state.record {
            do {
                if try !records.remove(
                    ifMatching: record,
                    layout: layout
                ) {
                    recordFailure("record cleanup failed")
                }
            } catch {
                recordFailure("record cleanup failed")
            }
        }
        if let identity = state.modelIdentity {
            do {
                try removeManagedModelIfOwned(identity)
            } catch {
                failures.append("model cleanup failed")
            }
        }
        return failures
    }

    private func removeManagedModelIfOwned(
        _ identity: POSIXFileIdentity
    ) throws {
        let root = try POSIXDirectoryDescriptor.openRoot(layout.root)
        let models = try root.openDirectory("models")
        try models.unlinkIfOwned(
            InstallationLayout.modelFilename,
            identity: identity
        )
        guard syncDirectory(models.rawValue) else {
            throw LegacyMigrationError.legacyBackupFailed
        }
    }

    private func publishManagedPlist(
        _ data: Data,
        replacing original: LegacySnapshot,
        at url: URL
    ) throws -> LegacySnapshot {
        let directory: POSIXDirectoryDescriptor
        do {
            directory = try POSIXDirectoryDescriptor.openRoot(
                url.deletingLastPathComponent()
            )
        } catch {
            throw LegacyMigrationError.legacyBackupFailed
        }

        let created = try createManagedPlistTemporary(
            data: data,
            in: directory
        )
        var cleanupIdentity: POSIXFileIdentity? = created.identity
        defer {
            if let cleanupIdentity {
                try? directory.unlinkIfOwned(
                    created.name,
                    identity: cleanupIdentity
                )
            }
        }

        let staged = try plistSnapshot(
            in: directory,
            name: created.name
        )
        guard staged.identity == created.identity,
              staged.data == data else {
            throw LegacyMigrationError.legacyBackupFailed
        }

        try Task.checkCancellation()
        try directory.exchange(url.lastPathComponent, with: created.name)
        cleanupIdentity = nil

        func restoreOriginalAfterFailedPublish() -> Bool {
            do {
                try directory.exchange(
                    url.lastPathComponent,
                    with: created.name
                )
                cleanupIdentity = created.identity
                return syncDirectory(directory.rawValue)
            } catch {
                cleanupIdentity = nil
                return false
            }
        }

        let displaced: LegacySnapshot
        do {
            displaced = try plistSnapshot(
                in: directory,
                name: created.name
            )
            guard displaced == original else {
                throw LegacyMigrationError.legacyBackupFailed
            }
        } catch {
            guard restoreOriginalAfterFailedPublish() else {
                throw ManagedPlistPublishError.recoveryDurabilityUncertain
            }
            throw LegacyMigrationError.legacyBackupFailed
        }

        cleanupIdentity = displaced.identity
        let installed: LegacySnapshot
        do {
            installed = try plistSnapshot(
                in: directory,
                name: url.lastPathComponent
            )
            guard installed.identity == staged.identity,
                  installed.data == staged.data,
                  installed.mode == staged.mode,
                  syncDirectory(directory.rawValue) else {
                throw LegacyMigrationError.legacyBackupFailed
            }
        } catch {
            guard restoreOriginalAfterFailedPublish() else {
                throw ManagedPlistPublishError.recoveryDurabilityUncertain
            }
            throw LegacyMigrationError.legacyBackupFailed
        }

        do {
            try directory.unlinkIfOwned(
                created.name,
                identity: displaced.identity
            )
            cleanupIdentity = nil
        } catch {
            // The config backup remains authoritative if the private old entry
            // cannot be removed without proving ownership.
        }
        return installed
    }

    private func createManagedPlistTemporary(
        data: Data,
        in directory: POSIXDirectoryDescriptor
    ) throws -> (
        name: String,
        identity: POSIXFileIdentity
    ) {
        for _ in 0..<16 {
            let name = ".managed-plist-\(UUID().uuidString).tmp"
            try Task.checkCancellation()
            let descriptor = openat(
                directory.rawValue,
                name,
                O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
                0o600
            )
            if descriptor < 0 {
                if errno == EEXIST { continue }
                throw LegacyMigrationError.legacyBackupFailed
            }
            let file = POSIXFileDescriptor(descriptor)
            let identity = POSIXFileIdentity(try file.metadata())
            var keep = false
            defer {
                if !keep {
                    try? directory.unlinkIfOwned(name, identity: identity)
                }
            }
            guard fchmod(descriptor, 0o600) == 0 else {
                throw LegacyMigrationError.legacyBackupFailed
            }
            try writeData(data, to: descriptor, checkCancellation: true)
            guard fsync(descriptor) == 0 else {
                throw LegacyMigrationError.legacyBackupFailed
            }
            try file.closeChecked()
            keep = true
            return (name, identity)
        }
        throw LegacyMigrationError.legacyBackupFailed
    }

    private func restoreLegacy(
        _ original: LegacySnapshot,
        replacing managed: LegacySnapshot,
        at url: URL
    ) throws {
        let directory: POSIXDirectoryDescriptor
        do {
            directory = try POSIXDirectoryDescriptor.openRoot(
                url.deletingLastPathComponent()
            )
        } catch {
            throw LegacyMigrationError.legacyBackupFailed
        }
        let temporaryName = ".legacy-restore-\(UUID().uuidString).tmp"
        let descriptor = openat(
            directory.rawValue,
            temporaryName,
            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
            original.mode
        )
        guard descriptor >= 0 else {
            throw LegacyMigrationError.legacyBackupFailed
        }
        let temporary = POSIXFileDescriptor(descriptor)
        let restorationIdentity = POSIXFileIdentity(try temporary.metadata())
        var cleanupIdentity: POSIXFileIdentity? = restorationIdentity
        defer {
            if let cleanupIdentity {
                try? directory.unlinkIfOwned(
                    temporaryName,
                    identity: cleanupIdentity
                )
            }
        }
        guard fchmod(descriptor, original.mode) == 0 else {
            throw LegacyMigrationError.legacyBackupFailed
        }
        try writeData(original.data, to: descriptor, checkCancellation: false)
        guard fsync(descriptor) == 0 else {
            throw LegacyMigrationError.legacyBackupFailed
        }
        try temporary.closeChecked()

        do {
            try directory.exchange(url.lastPathComponent, with: temporaryName)
        } catch {
            throw LegacyMigrationError.legacyBackupFailed
        }

        let displaced: LegacySnapshot
        do {
            displaced = try plistSnapshot(
                in: directory,
                name: temporaryName
            )
            guard displaced.identity == managed.identity,
                  displaced.data == managed.data,
                  displaced.mode == managed.mode else {
                throw LegacyMigrationError.legacyBackupFailed
            }
        } catch {
            try? directory.exchange(url.lastPathComponent, with: temporaryName)
            throw LegacyMigrationError.legacyBackupFailed
        }

        cleanupIdentity = displaced.identity
        let restored = try plistSnapshot(
            in: directory,
            name: url.lastPathComponent
        )
        guard restored.identity == restorationIdentity,
              restored.data == original.data,
              restored.mode == original.mode,
              syncDirectory(directory.rawValue) else {
            throw LegacyMigrationError.legacyBackupFailed
        }
        try directory.unlinkIfOwned(
            temporaryName,
            identity: displaced.identity
        )
        cleanupIdentity = nil
    }

    private func legacySnapshot(at url: URL) throws -> LegacySnapshot {
        do {
            return try plistSnapshot(at: url)
        } catch {
            throw LegacyMigrationError.legacyInstallationNotRecognized
        }
    }

    private func plistSnapshot(at url: URL) throws -> LegacySnapshot {
        let directory: POSIXDirectoryDescriptor
        do {
            directory = try POSIXDirectoryDescriptor.openRoot(
                url.deletingLastPathComponent()
            )
        } catch {
            throw LegacyMigrationError.legacyBackupFailed
        }
        return try plistSnapshot(
            in: directory,
            name: url.lastPathComponent
        )
    }

    private func plistSnapshot(
        in directory: POSIXDirectoryDescriptor,
        name: String
    ) throws -> LegacySnapshot {
        let file = try directory.openFile(
            name,
            flags: O_RDONLY | O_NOFOLLOW
        )
        let snapshot = try plistSnapshot(file)
        guard let current = try directory.metadata(for: name),
              current.st_mode & S_IFMT == S_IFREG,
              POSIXFileIdentity(current) == snapshot.identity else {
            throw LegacyMigrationError.legacyBackupFailed
        }
        return snapshot
    }

    private func plistSnapshot(
        _ file: POSIXFileDescriptor
    ) throws -> LegacySnapshot {
        let metadata = try file.metadata()
        guard metadata.st_mode & S_IFMT == S_IFREG,
              metadata.st_size >= 0,
              metadata.st_size <= 1_048_576 else {
            throw LegacyMigrationError.legacyBackupFailed
        }
        let data = try readData(
            from: file.rawValue,
            count: Int(metadata.st_size)
        )
        return LegacySnapshot(
            data: data,
            mode: metadata.st_mode & 0o777,
            identity: POSIXFileIdentity(metadata)
        )
    }

    private func verifiedManagedRuntime() -> Bool {
        do {
            let root = try POSIXDirectoryDescriptor.openRoot(layout.root)
            let runtime = try root.openDirectory("runtime")
            let versions = try runtime.openDirectory("versions")
            let version = try versions.openDirectory(manifest.runtime.version)
            let server = try version.openFile(
                manifest.runtime.serverRelativePath,
                flags: O_RDONLY | O_NOFOLLOW
            )
            let serverMetadata = try server.metadata()
            guard serverMetadata.st_mode & S_IFMT == S_IFREG,
                  serverMetadata.st_mode & 0o111 != 0,
                  let currentEntry = try runtime.metadata(for: "current"),
                  currentEntry.st_mode & S_IFMT == S_IFLNK else {
                return false
            }

            let currentDescriptor = openat(
                runtime.rawValue,
                "current",
                O_RDONLY | O_DIRECTORY | O_CLOEXEC
            )
            guard currentDescriptor >= 0 else { return false }
            let current = POSIXDirectoryDescriptor.openOwned(currentDescriptor)
            let versionIdentity = POSIXFileIdentity(try versionMetadata(version))
            let currentIdentity = POSIXFileIdentity(try versionMetadata(current))
            guard currentIdentity == versionIdentity else { return false }
            let currentServer = try current.openFile(
                manifest.runtime.serverRelativePath,
                flags: O_RDONLY | O_NOFOLLOW
            )
            return POSIXFileIdentity(try currentServer.metadata())
                == POSIXFileIdentity(serverMetadata)
        } catch {
            return false
        }
    }

    private func versionMetadata(
        _ directory: POSIXDirectoryDescriptor
    ) throws -> stat {
        var metadata = stat()
        guard fstat(directory.rawValue, &metadata) == 0 else {
            throw POSIXTransactionError.operationFailed(errno)
        }
        return metadata
    }

    private func queryServiceState() async throws -> ServiceState {
        let result = await commandRunner.run(.init(
            executable: "/bin/launchctl",
            arguments: ["print", "gui/\(uid)/\(manifest.service.label)"]
        ))
        try Task.checkCancellation()
        if result.exitCode == 0 { return .loaded }
        if isCanonicalMissingService(result.output) { return .absent }
        throw LegacyMigrationError.serviceControlFailed
    }

    private func runService(
        command: ServiceCommand,
        plistPath: String
    ) async throws {
        let domain = "gui/\(uid)"
        let arguments: [String]
        switch command {
        case .start:
            arguments = ["bootstrap", domain, plistPath]
        case .stop:
            arguments = ["bootout", "\(domain)/\(manifest.service.label)"]
        }
        let result = await commandRunner.run(.init(
            executable: "/bin/launchctl",
            arguments: arguments
        ))
        try Task.checkCancellation()
        if result.exitCode == 0 { return }
        if command == .stop, isCanonicalMissingService(result.output) {
            return
        }
        throw LegacyMigrationError.serviceControlFailed
    }

    private func isCanonicalMissingService(_ output: String) -> Bool {
        output.localizedCaseInsensitiveContains("could not find service")
            && output.localizedCaseInsensitiveContains("in domain for user gui:")
    }

    private func descriptorContentsEqual(
        _ descriptor: Int32,
        data: Data,
        size: off_t
    ) throws -> Bool {
        guard size == off_t(data.count) else { return false }
        let existing = try readData(from: descriptor, count: data.count)
        return existing == data
    }

    private func readData(from descriptor: Int32, count: Int) throws -> Data {
        var data = Data(count: count)
        var offset = 0
        while offset < count {
            let result = data.withUnsafeMutableBytes {
                pread(
                    descriptor,
                    $0.baseAddress!.advanced(by: offset),
                    count - offset,
                    off_t(offset)
                )
            }
            if result < 0 {
                if errno == EINTR { continue }
                throw LegacyMigrationError.legacyBackupFailed
            }
            guard result > 0 else {
                throw LegacyMigrationError.legacyBackupFailed
            }
            offset += result
        }
        return data
    }

    private func writeData(
        _ data: Data,
        to descriptor: Int32,
        checkCancellation: Bool
    ) throws {
        var offset = 0
        while offset < data.count {
            if checkCancellation {
                try Task.checkCancellation()
            }
            let result = data.withUnsafeBytes {
                Darwin.write(
                    descriptor,
                    $0.baseAddress!.advanced(by: offset),
                    data.count - offset
                )
            }
            if result < 0 {
                if errno == EINTR { continue }
                throw LegacyMigrationError.legacyBackupFailed
            }
            guard result > 0 else {
                throw LegacyMigrationError.legacyBackupFailed
            }
            offset += result
        }
    }
}
