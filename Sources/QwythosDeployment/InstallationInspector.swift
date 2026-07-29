import Darwin
import Foundation
import QwythosCore

public enum RepairComponent: Hashable, Sendable {
    case runtime
    case model
    case configuration
    case launchAgent
}

public enum InstallationStatus: Equatable, Sendable {
    case notInstalled
    case partiallyDownloaded
    case legacyDetected
    case installationRootUnavailable(URL)
    case managedHealthy(InstallationRecord)
    case managedRepairable(InstallationRecord, Set<RepairComponent>)
    case managedIncompatible(String)
}

public protocol InstallationInspecting: Sendable {
    func inspect() async -> InstallationStatus
    func inspectUnlocatedDefaultRoot() async -> InstallationStatus
    func ownsServicePort(_ port: UInt16) async -> Bool
}

public extension InstallationInspecting {
    func inspectUnlocatedDefaultRoot() async -> InstallationStatus {
        await inspect()
    }

    func ownsServicePort(_ port: UInt16) async -> Bool {
        false
    }
}

public protocol InstallationHealthChecking: Sendable {
    func isHealthy(_ url: URL) async -> Bool
}

public protocol InstallationServiceChecking: Sendable {
    func isLoaded(label: String) async -> Bool
}

public protocol LaunchAgentPlistReading: Sendable {
    func plist(at url: URL) -> LegacyLaunchAgent?
    func plist(data: Data, at url: URL) -> LegacyLaunchAgent?
}

public extension LaunchAgentPlistReading {
    func plist(data: Data, at url: URL) -> LegacyLaunchAgent? {
        nil
    }
}

public struct LaunchAgentPlistReader: LaunchAgentPlistReading, Sendable {
    public init() {}

    public func plist(at url: URL) -> LegacyLaunchAgent? {
        LegacyLaunchAgentDetector.plist(at: url)
    }

    public func plist(data: Data, at url: URL) -> LegacyLaunchAgent? {
        LegacyLaunchAgentDetector.plist(data: data, at: url)
    }
}

public struct SystemInstallationServiceChecker: InstallationServiceChecking, Sendable {
    private let runner: any CommandRunning
    private let uid: uid_t

    public init(runner: any CommandRunning = SystemCommandRunner(), uid: uid_t = getuid()) {
        self.runner = runner
        self.uid = uid
    }

    public func isLoaded(label: String) async -> Bool {
        let result = await runner.run(.init(
            executable: "/bin/launchctl",
            arguments: ["print", "gui/\(uid)/\(label)"]
        ))
        return result.exitCode == 0
    }
}

public protocol InstallationServicePortChecking: Sendable {
    func ownsServicePort(_ port: UInt16, label: String) async -> Bool
}

public struct SystemInstallationServicePortChecker: InstallationServicePortChecking, Sendable {
    private let runner: any CommandRunning
    private let uid: uid_t

    public init(runner: any CommandRunning = SystemCommandRunner(), uid: uid_t = getuid()) {
        self.runner = runner
        self.uid = uid
    }

    public func ownsServicePort(_ port: UInt16, label: String) async -> Bool {
        let job = await runner.run(.init(
            executable: "/bin/launchctl",
            arguments: ["print", "gui/\(uid)/\(label)"]
        ))
        guard job.exitCode == 0,
              let pid = runningPID(in: job.output) else {
            return false
        }
        let listener = await runner.run(.init(
            executable: "/usr/sbin/lsof",
            arguments: [
                "-nP", "-a", "-p", String(pid),
                "-iTCP:\(port)", "-sTCP:LISTEN",
            ]
        ))
        return listener.exitCode == 0
    }

    private func runningPID(in launchctlOutput: String) -> Int32? {
        for line in launchctlOutput.split(separator: "\n") {
            let fields = line.split(
                whereSeparator: { $0 == " " || $0 == "=" }
            )
            guard fields.count == 2,
                  fields[0] == "pid",
                  let pid = Int32(fields[1]),
                  pid > 0 else {
                continue
            }
            return pid
        }
        return nil
    }
}

public struct SystemInstallationHealthChecker: InstallationHealthChecking, Sendable {
    private let checker: any HealthChecking

    public init(checker: any HealthChecking = URLSessionHealthChecker()) {
        self.checker = checker
    }

    public func isHealthy(_ url: URL) async -> Bool {
        await checker.isHealthy(url)
    }
}

public struct InstallationInspector: InstallationInspecting, Sendable {
    private let layout: InstallationLayout
    private let manifest: DeploymentManifest
    private let records: any InstallationRecordStoring
    private let hasher: any FileHashing
    private let launchAgentsDirectory: URL
    private let healthChecker: any InstallationHealthChecking
    private let serviceChecker: any InstallationServiceChecking
    private let servicePortChecker: any InstallationServicePortChecking
    private let plistReader: any LaunchAgentPlistReading

    public init(
        layout: InstallationLayout,
        manifest: DeploymentManifest,
        records: any InstallationRecordStoring = InstallationRecordStore(),
        hasher: any FileHashing = SHA256Hasher(),
        launchAgentsDirectory: URL = URL(fileURLWithPath: NSHomeDirectory()).appending(path: "Library/LaunchAgents"),
        healthChecker: any InstallationHealthChecking = SystemInstallationHealthChecker(),
        serviceChecker: any InstallationServiceChecking = SystemInstallationServiceChecker(),
        servicePortChecker: any InstallationServicePortChecking = SystemInstallationServicePortChecker(),
        plistReader: any LaunchAgentPlistReading = LaunchAgentPlistReader()
    ) {
        self.layout = layout
        self.manifest = manifest
        self.records = records
        self.hasher = hasher
        self.launchAgentsDirectory = launchAgentsDirectory
        self.healthChecker = healthChecker
        self.serviceChecker = serviceChecker
        self.servicePortChecker = servicePortChecker
        self.plistReader = plistReader
    }

    public func inspect() async -> InstallationStatus {
        let root: POSIXDirectoryDescriptor
        let rootIdentity: POSIXFileIdentity
        do {
            root = try POSIXDirectoryDescriptor.openRoot(layout.root)
            let rootMetadata = try root.metadata()
            guard rootMetadata.st_mode & S_IFMT == S_IFDIR else {
                return .installationRootUnavailable(layout.root)
            }
            rootIdentity = POSIXFileIdentity(rootMetadata)
        } catch {
            return .installationRootUnavailable(layout.root)
        }

        let record: InstallationRecord?
        do {
            record = try records.load(layout: layout)
        } catch {
            return .managedIncompatible("The installation record cannot be read.")
        }

        if let record {
            if let incompatibility = incompatibleReason(for: record) {
                return rootIsCurrent(rootIdentity)
                    ? .managedIncompatible(incompatibility)
                    : .installationRootUnavailable(layout.root)
            }
            return await inspectManaged(
                record,
                root: root,
                rootIdentity: rootIdentity
            )
        }

        let status: InstallationStatus
        if hasPartialDownload {
            status = .partiallyDownloaded
        } else if let legacy = readPlist(at: legacyPlistURL),
           LegacyLaunchAgentDetector.isRecognized(legacy) {
            status = .legacyDetected
        } else {
            status = .notInstalled
        }
        return rootIsCurrent(rootIdentity)
            ? status
            : .installationRootUnavailable(layout.root)
    }

    public func inspectUnlocatedDefaultRoot() async -> InstallationStatus {
        let status = await inspect()
        guard case .installationRootUnavailable = status else {
            return status
        }
        var metadata = stat()
        guard lstat(layout.root.path, &metadata) != 0, errno == ENOENT else {
            return status
        }
        if let legacy = readPlist(at: legacyPlistURL),
           LegacyLaunchAgentDetector.isRecognized(legacy) {
            return .legacyDetected
        }
        return .notInstalled
    }

    public func ownsServicePort(_ port: UInt16) async -> Bool {
        guard port == manifest.service.port,
              let plist = readPlist(at: legacyPlistURL),
              LegacyLaunchAgentDetector.isRecognized(plist),
              plist.label == manifest.service.label else {
            return false
        }
        return await servicePortChecker.ownsServicePort(
            port,
            label: manifest.service.label
        )
    }

    private func inspectManaged(
        _ record: InstallationRecord,
        root: POSIXDirectoryDescriptor,
        rootIdentity: POSIXFileIdentity
    ) async -> InstallationStatus {
        var damaged: Set<RepairComponent> = []
        if !runtimeIsValid(for: record) { damaged.insert(.runtime) }
        if !modelIsValid(for: record, root: root) { damaged.insert(.model) }
        if !configurationIsValid(for: record, root: root) { damaged.insert(.configuration) }
        if !launchAgentIsValid(for: record) { damaged.insert(.launchAgent) }

        if !(await serviceChecker.isLoaded(label: manifest.service.label)) {
            damaged.insert(.launchAgent)
        }
        if !(await healthChecker.isHealthy(healthURL)) {
            if damaged.isDisjoint(with: [.runtime, .model, .launchAgent]) {
                damaged.insert(.configuration)
            }
        }
        guard rootIsCurrent(rootIdentity) else {
            return .installationRootUnavailable(layout.root)
        }
        return damaged.isEmpty ? .managedHealthy(record) : .managedRepairable(record, damaged)
    }

    private func rootIsCurrent(_ expectedIdentity: POSIXFileIdentity) -> Bool {
        do {
            let current = try POSIXDirectoryDescriptor.openRoot(layout.root)
            let metadata = try current.metadata()
            return metadata.st_mode & S_IFMT == S_IFDIR
                && POSIXFileIdentity(metadata) == expectedIdentity
        } catch {
            return false
        }
    }

    private var legacyPlistURL: URL {
        launchAgentsDirectory.appending(path: "\(LaunchAgentInstaller.defaultLabel).plist")
    }

    private var healthURL: URL {
        URL(string: "http://127.0.0.1:\(manifest.service.port)/health")!
    }

    private var hasPartialDownload: Bool {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: layout.downloadsDirectory,
            includingPropertiesForKeys: nil
        ) else { return false }
        return files.contains { $0.lastPathComponent.hasSuffix(".partial") }
    }

    private func incompatibleReason(for record: InstallationRecord) -> String? {
        if record.schemaVersion != InstallationRecord.schemaVersion { return "The installation record schema is unsupported." }
        if record.manifestSchemaVersion != manifest.schemaVersion { return "The installation record was created for another manifest schema." }
        if record.root.path != layout.root.path { return "The installation record belongs to another root." }
        if !InstallationRecord.isSafeRuntimeVersionComponent(record.runtimeVersion) { return "The installed runtime version is invalid." }
        if record.modelSHA256.caseInsensitiveCompare(manifest.model.sha256) != .orderedSame { return "The installed model digest is not pinned by this manifest." }
        if !DeploymentOptions.supportedContextSizes.contains(record.contextSize) { return "The recorded context size is unsupported." }
        return nil
    }

    private func runtimeIsValid(for record: InstallationRecord) -> Bool {
        let expected = layout.runtimeServer(version: record.runtimeVersion).standardizedFileURL
        let current = layout.runtimeCurrent.appending(path: "llama-server").resolvingSymlinksInPath().standardizedFileURL
        return current == expected
            && isRegularFile(expected, under: layout.root)
            && FileManager.default.isExecutableFile(atPath: expected.path)
    }

    private func modelIsValid(
        for record: InstallationRecord,
        root: POSIXDirectoryDescriptor
    ) -> Bool {
        do {
            let models = try root.openDirectory("models")
            let model = try models.openFile(
                InstallationLayout.modelFilename,
                flags: O_RDONLY | O_NOFOLLOW
            )
            let metadata = try model.metadata()
            guard metadata.st_mode & S_IFMT == S_IFREG else { return false }
            let identity = POSIXFileIdentity(metadata)
            let digest = try hasher.sha256(fileDescriptor: model.rawValue)
            guard let currentMetadata = try models.metadata(
                for: InstallationLayout.modelFilename
            ),
                currentMetadata.st_mode & S_IFMT == S_IFREG,
                POSIXFileIdentity(currentMetadata) == identity
            else {
                return false
            }
            return digest.caseInsensitiveCompare(record.modelSHA256) == .orderedSame
        } catch {
            return false
        }
    }

    private func configurationIsValid(
        for record: InstallationRecord,
        root: POSIXDirectoryDescriptor
    ) -> Bool {
        guard record.accessMode == .shared else { return true }
        do {
            let config = try root.openDirectory("config")
            return try APIKeyStore.loadValidatedKey(
                named: layout.apiKeyFile.lastPathComponent,
                in: config
            )
            != nil
        } catch {
            return false
        }
    }

    private func isRegularFile(_ url: URL, under root: URL) -> Bool {
        guard isContained(url, in: root) else { return false }
        var metadata = stat()
        guard lstat(url.path, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFREG else { return false }
        var parent = url.deletingLastPathComponent()
        while parent.path != root.path {
            var parentMetadata = stat()
            guard lstat(parent.path, &parentMetadata) == 0, parentMetadata.st_mode & S_IFMT == S_IFDIR else { return false }
            parent = parent.deletingLastPathComponent()
        }
        return true
    }

    private func isContained(_ url: URL, in root: URL) -> Bool {
        let candidate = url.standardizedFileURL.path
        let rootPath = root.standardizedFileURL.path
        return candidate.hasPrefix(rootPath + "/")
    }

    private func launchAgentIsValid(for record: InstallationRecord) -> Bool {
        guard let plist = readPlist(at: legacyPlistURL),
              plist.label == manifest.service.label,
              plist.arguments.first == layout.runtimeCurrent.appending(path: "llama-server").path,
              plist.argumentValue("--model") == layout.modelFile.path,
              plist.argumentValue("--port") == String(manifest.service.port),
              plist.argumentValue("--ctx-size") == String(record.contextSize),
              plist.argumentValue("--host") == (record.accessMode == .shared ? "0.0.0.0" : "127.0.0.1")
        else { return false }
        return record.accessMode == .shared
            ? plist.argumentValue("--api-key-file") == layout.apiKeyFile.path
            : plist.argumentValue("--api-key-file") == nil
    }

    private func readPlist(at url: URL) -> LegacyLaunchAgent? {
        do {
            let directory = try POSIXDirectoryDescriptor.openRoot(
                url.deletingLastPathComponent()
            )
            let file = try directory.openFile(
                url.lastPathComponent,
                flags: O_RDONLY | O_NOFOLLOW
            )
            let openedMetadata = try file.metadata()
            guard openedMetadata.st_mode & S_IFMT == S_IFREG else {
                return nil
            }
            let data = try readRegularFileData(from: file)
            let plist = plistReader.plist(data: data, at: url)
            guard let currentMetadata = try directory.metadata(
                for: url.lastPathComponent
            ),
                currentMetadata.st_mode & S_IFMT == S_IFREG,
                POSIXFileIdentity(currentMetadata)
                    == POSIXFileIdentity(openedMetadata)
            else {
                return nil
            }
            return plist
        } catch {
            return nil
        }
    }

    private func readRegularFileData(from file: POSIXFileDescriptor) throws -> Data {
        let metadata = try file.metadata()
        let maximumPlistSize: off_t = 4 * 1_024 * 1_024
        guard metadata.st_mode & S_IFMT == S_IFREG,
              metadata.st_size >= 0,
              metadata.st_size <= maximumPlistSize else {
            throw POSIXTransactionError.unsafePath
        }

        let expectedCount = Int(metadata.st_size)
        var bytes = [UInt8](repeating: 0, count: expectedCount)
        var offset = 0
        while offset < expectedCount {
            let count = bytes.withUnsafeMutableBytes { buffer in
                pread(
                    file.rawValue,
                    buffer.baseAddress!.advanced(by: offset),
                    expectedCount - offset,
                    off_t(offset)
                )
            }
            if count < 0 {
                if errno == EINTR { continue }
                throw POSIXTransactionError.operationFailed(errno)
            }
            guard count > 0 else {
                throw POSIXTransactionError.ownershipChanged
            }
            offset += count
        }

        var trailingByte: UInt8 = 0
        while true {
            let count = pread(
                file.rawValue,
                &trailingByte,
                1,
                off_t(expectedCount)
            )
            if count < 0, errno == EINTR { continue }
            guard count == 0 else {
                if count < 0 {
                    throw POSIXTransactionError.operationFailed(errno)
                }
                throw POSIXTransactionError.ownershipChanged
            }
            break
        }
        return Data(bytes)
    }
}

public struct LegacyLaunchAgent: Equatable, Sendable {
    public let plistURL: URL
    public let label: String
    public let program: String?
    public let arguments: [String]
    public let environment: [String: String]

    public func argumentValue(_ flag: String) -> String? {
        guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
        return arguments[index + 1]
    }
}

public enum LegacyLaunchAgentDetector {
    public static func recognizedPlist(at url: URL) -> LegacyLaunchAgent? {
        guard let plist = plist(at: url), isRecognized(plist) else { return nil }
        return plist
    }

    public static func isRecognized(_ plist: LegacyLaunchAgent) -> Bool {
        guard plist.label == LaunchAgentInstaller.defaultLabel else { return false }
        let executable = plist.program ?? plist.arguments.first
        return executable.map { URL(fileURLWithPath: $0).lastPathComponent == "llama-server" } ?? false
    }

    static func plist(at url: URL) -> LegacyLaunchAgent? {
        var metadata = stat()
        guard lstat(url.path, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFREG,
              let data = try? Data(contentsOf: url)
        else { return nil }
        return plist(data: data, at: url)
    }

    static func plist(data: Data, at url: URL) -> LegacyLaunchAgent? {
        guard let values = try? PropertyListSerialization.propertyList(
            from: data,
            format: nil
        ) as? [String: Any],
              let label = values["Label"] as? String
        else { return nil }
        let program = values["Program"] as? String
        let arguments = values["ProgramArguments"] as? [String] ?? []
        return LegacyLaunchAgent(
            plistURL: url.standardizedFileURL,
            label: label,
            program: program,
            arguments: arguments,
            environment: values["EnvironmentVariables"] as? [String: String] ?? [:]
        )
    }
}
