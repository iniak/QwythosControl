import Foundation
import Security
import Darwin

public enum APIKeyStoreError: Error, Equatable, Sendable {
    case randomGenerationFailed(OSStatus)
    case invalidStoredKey
    case fileOperationFailed
}

public struct APIKeyStore: APIKeyStoring, Sendable {
    private static let keyByteCount = 32
    private static let encodedKeyByteCount = 43
    private static let payloadByteCount = encodedKeyByteCount + 1

    typealias BeforeKeyReadHook =
        @Sendable (_ parentDescriptor: Int32, _ name: String) throws -> Void

    public let fileURL: URL
    private let beforeKeyRead: BeforeKeyReadHook

    public init(fileURL: URL) {
        self.fileURL = fileURL
        beforeKeyRead = { _, _ in }
    }

    init(
        fileURL: URL,
        beforeKeyRead: @escaping BeforeKeyReadHook
    ) {
        self.fileURL = fileURL
        self.beforeKeyRead = beforeKeyRead
    }

    public func load() throws -> String? {
        let parent: POSIXDirectoryDescriptor
        do {
            parent = try POSIXDirectoryDescriptor.openRoot(
                fileURL.deletingLastPathComponent()
            )
        } catch POSIXTransactionError.notFound {
            return nil
        } catch {
            throw APIKeyStoreError.invalidStoredKey
        }

        let name = fileURL.lastPathComponent
        return try Self.loadValidatedKey(
            named: name,
            in: parent,
            beforeRead: beforeKeyRead
        )
    }

    static func loadValidatedKey(
        named name: String,
        in parent: POSIXDirectoryDescriptor,
        beforeRead: BeforeKeyReadHook = { _, _ in }
    ) throws -> String? {
        let file: POSIXFileDescriptor
        do {
            file = try parent.openFile(
                name,
                flags: O_RDONLY | O_NOFOLLOW
            )
        } catch POSIXTransactionError.notFound {
            return nil
        } catch {
            throw APIKeyStoreError.invalidStoredKey
        }

        do {
            let opened = try file.metadata()
            guard Self.validKeyMetadata(opened) else {
                throw APIKeyStoreError.invalidStoredKey
            }
            let identity = POSIXFileIdentity(opened)
            try beforeRead(parent.rawValue, name)
            let data = try Self.readPayload(from: file.rawValue)
            let afterRead = try file.metadata()
            guard Self.validKeyMetadata(afterRead),
                  POSIXFileIdentity(afterRead) == identity,
                  let current = try parent.metadata(for: name),
                  Self.validKeyMetadata(current),
                  POSIXFileIdentity(current) == identity else {
                throw APIKeyStoreError.invalidStoredKey
            }
            return try Self.decodeKeyPayload(data)
        } catch let error as APIKeyStoreError {
            throw error
        } catch {
            throw APIKeyStoreError.invalidStoredKey
        }
    }

    public func generate() throws -> String {
        var bytes = [UInt8](
            repeating: 0,
            count: Self.keyByteCount
        )
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard status == errSecSuccess else {
            throw APIKeyStoreError.randomGenerationFailed(status)
        }

        let key = Self.encodeKey(Data(bytes))
        do {
            let parent = try POSIXDirectoryDescriptor.openOrCreateRoot(
                fileURL.deletingLastPathComponent(),
                mode: 0o700
            )
            try atomicReplace(
                Data("\(key)\n".utf8),
                named: fileURL.lastPathComponent,
                in: parent
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw APIKeyStoreError.fileOperationFailed
        }
        return key
    }

    public func remove() throws {
        let parent: POSIXDirectoryDescriptor
        do {
            parent = try POSIXDirectoryDescriptor.openRoot(
                fileURL.deletingLastPathComponent()
            )
        } catch POSIXTransactionError.notFound {
            return
        } catch {
            throw APIKeyStoreError.fileOperationFailed
        }

        let name = fileURL.lastPathComponent
        let file: POSIXFileDescriptor
        do {
            file = try parent.openFile(
                name,
                flags: O_RDONLY | O_NOFOLLOW
            )
        } catch POSIXTransactionError.notFound {
            return
        } catch {
            throw APIKeyStoreError.fileOperationFailed
        }

        do {
            let metadata = try file.metadata()
            guard Self.validKeyMetadata(metadata) else {
                throw APIKeyStoreError.fileOperationFailed
            }
            let identity = POSIXFileIdentity(metadata)
            guard let current = try parent.metadata(for: name),
                  POSIXFileIdentity(current) == identity else {
                throw APIKeyStoreError.fileOperationFailed
            }
            try parent.unlinkIfOwned(name, identity: identity)
            try parent.sync()
        } catch {
            throw APIKeyStoreError.fileOperationFailed
        }
    }

    func restore(payload: Data?) throws {
        guard let payload else {
            try remove()
            return
        }
        _ = try Self.decodeKeyPayload(payload)
        do {
            let parent = try POSIXDirectoryDescriptor.openOrCreateRoot(
                fileURL.deletingLastPathComponent(),
                mode: 0o700
            )
            try atomicReplace(
                payload,
                named: fileURL.lastPathComponent,
                in: parent
            )
        } catch let error as APIKeyStoreError {
            throw error
        } catch {
            throw APIKeyStoreError.fileOperationFailed
        }
    }

    private func atomicReplace(
        _ data: Data,
        named name: String,
        in directory: POSIXDirectoryDescriptor
    ) throws {
        let expectedExistingIdentity: POSIXFileIdentity?
        if let existing = try directory.metadata(for: name) {
            guard Self.validKeyMetadata(existing) else {
                throw APIKeyStoreError.fileOperationFailed
            }
            expectedExistingIdentity = POSIXFileIdentity(existing)
        } else {
            expectedExistingIdentity = nil
        }

        for _ in 0..<16 {
            let temporaryName =
                ".api-key-\(UUID().uuidString).tmp"
            let temporary: POSIXFileDescriptor
            do {
                temporary = try directory.openFile(
                    temporaryName,
                    flags:
                        O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW,
                    mode: 0o600
                )
            } catch POSIXTransactionError.operationFailed(EEXIST) {
                continue
            }
            let temporaryMetadata = try temporary.metadata()
            let temporaryIdentity = POSIXFileIdentity(
                temporaryMetadata
            )
            var temporaryNeedsCleanup = true
            defer {
                if temporaryNeedsCleanup {
                    try? directory.unlinkIfOwned(
                        temporaryName,
                        identity: temporaryIdentity
                    )
                }
            }

            guard temporaryMetadata.st_mode & S_IFMT == S_IFREG,
                  temporaryMetadata.st_nlink == 1,
                  fchmod(temporary.rawValue, 0o600) == 0 else {
                throw APIKeyStoreError.fileOperationFailed
            }
            try write(data, to: temporary.rawValue)
            guard fsync(temporary.rawValue) == 0 else {
                throw APIKeyStoreError.fileOperationFailed
            }
            try temporary.closeChecked()

            if let expectedExistingIdentity {
                guard let current = try directory.metadata(for: name),
                      Self.validKeyMetadata(current),
                      POSIXFileIdentity(current)
                        == expectedExistingIdentity else {
                    throw APIKeyStoreError.fileOperationFailed
                }
                try directory.exchange(temporaryName, with: name)
                guard let installed = try directory.metadata(
                    for: name
                ),
                    Self.validKeyMetadata(installed),
                    POSIXFileIdentity(installed)
                        == temporaryIdentity,
                    let displaced = try directory.metadata(
                        for: temporaryName
                    ),
                    POSIXFileIdentity(displaced)
                        == expectedExistingIdentity else {
                    try? directory.exchange(
                        temporaryName,
                        with: name
                    )
                    throw APIKeyStoreError.fileOperationFailed
                }
                do {
                    try directory.sync()
                } catch {
                    try? directory.exchange(
                        temporaryName,
                        with: name
                    )
                    throw APIKeyStoreError.fileOperationFailed
                }
                try directory.unlinkIfOwned(
                    temporaryName,
                    identity: expectedExistingIdentity
                )
                temporaryNeedsCleanup = false
            } else {
                guard renameatx_np(
                    directory.rawValue,
                    temporaryName,
                    directory.rawValue,
                    name,
                    UInt32(RENAME_EXCL)
                ) == 0 else {
                    throw APIKeyStoreError.fileOperationFailed
                }
                temporaryNeedsCleanup = false
                guard let installed = try directory.metadata(
                    for: name
                ),
                    Self.validKeyMetadata(installed),
                    POSIXFileIdentity(installed)
                        == temporaryIdentity else {
                    throw APIKeyStoreError.fileOperationFailed
                }
                do {
                    try directory.sync()
                } catch {
                    try? directory.unlinkIfOwned(
                        name,
                        identity: temporaryIdentity
                    )
                    throw APIKeyStoreError.fileOperationFailed
                }
            }
            return
        }
        throw APIKeyStoreError.fileOperationFailed
    }

    private static func validKeyMetadata(_ metadata: stat) -> Bool {
        metadata.st_mode & S_IFMT == S_IFREG
            && metadata.st_mode & 0o7777 == 0o600
            && metadata.st_nlink == 1
            && metadata.st_uid == geteuid()
            && metadata.st_size == Self.payloadByteCount
    }

    private static func readPayload(from descriptor: Int32) throws -> Data {
        var data = Data()
        var offset: off_t = 0
        var buffer = [UInt8](
            repeating: 0,
            count: Self.payloadByteCount + 1
        )
        while true {
            let count = buffer.withUnsafeMutableBytes {
                pread(
                    descriptor,
                    $0.baseAddress,
                    $0.count,
                    offset
                )
            }
            if count < 0 {
                if errno == EINTR { continue }
                throw APIKeyStoreError.invalidStoredKey
            }
            if count == 0 { break }
            data.append(contentsOf: buffer.prefix(count))
            guard data.count <= Self.payloadByteCount else {
                throw APIKeyStoreError.invalidStoredKey
            }
            offset += off_t(count)
        }
        guard data.count == Self.payloadByteCount else {
            throw APIKeyStoreError.invalidStoredKey
        }
        return data
    }

    private func write(_ data: Data, to descriptor: Int32) throws {
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(
                    descriptor,
                    bytes.baseAddress?.advanced(by: offset),
                    bytes.count - offset
                )
                if count < 0 {
                    if errno == EINTR { continue }
                    throw APIKeyStoreError.fileOperationFailed
                }
                guard count > 0 else {
                    throw APIKeyStoreError.fileOperationFailed
                }
                offset += count
            }
        }
    }

    private static func decodeKeyPayload(_ data: Data) throws -> String {
        guard data.count == payloadByteCount,
              data.last == UInt8(ascii: "\n"),
              let contents = String(data: data, encoding: .utf8)
        else {
            throw APIKeyStoreError.invalidStoredKey
        }
        let key = String(contents.dropLast())
        guard key.utf8.count == encodedKeyByteCount,
              key.allSatisfy({
                  $0.isASCII
                      && ($0.isLetter
                          || $0.isNumber
                          || $0 == "-"
                          || $0 == "_")
              }),
              let decoded = Data(
                  base64Encoded:
                    key
                        .replacingOccurrences(of: "-", with: "+")
                        .replacingOccurrences(of: "_", with: "/")
                        + "="
              ),
              decoded.count == keyByteCount,
              encodeKey(decoded) == key else {
            throw APIKeyStoreError.invalidStoredKey
        }
        return key
    }

    private static func encodeKey(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

public enum LaunchAgentInstallerError: Error, Equatable, Sendable {
    case modelMissing
}

public struct LaunchAgentInstaller: LaunchAgentInstalling, LaunchAgentPreparing, Sendable {
    public static let defaultLabel = "com.local.qwythos-9b"

    public let launchAgentsDirectory: URL
    private let keyStore: (any APIKeyStoring)?

    public init(
        launchAgentsDirectory: URL = URL(fileURLWithPath: NSHomeDirectory()).appending(path: "Library/LaunchAgents"),
        keyStore: (any APIKeyStoring)? = nil
    ) {
        self.launchAgentsDirectory = launchAgentsDirectory.standardizedFileURL
        self.keyStore = keyStore
    }

    public var plistURL: URL {
        launchAgentsDirectory.appending(path: "\(Self.defaultLabel).plist")
    }

    public func install(
        layout: InstallationLayout,
        options: DeploymentOptions,
        manifest: DeploymentManifest
    ) throws {
        let data = try prepareInstallation(layout: layout, options: options, manifest: manifest)
        try data.write(to: plistURL, options: .atomic)
    }

    public func prepareInstallation(
        layout: InstallationLayout,
        options: DeploymentOptions,
        manifest: DeploymentManifest
    ) throws -> Data {
        let fileManager = FileManager.default
        try options.validate(for: layout)
        guard fileManager.fileExists(atPath: layout.modelFile.path) else {
            throw LaunchAgentInstallerError.modelMissing
        }

        if options.accessMode == .shared {
            let store = resolvedKeyStore(for: layout)
            if try store.load() == nil {
                _ = try store.generate()
            }
        }

        let data = try makePlist(layout: layout, options: options, manifest: manifest)
        try fileManager.createDirectory(at: launchAgentsDirectory, withIntermediateDirectories: true)
        let root = try POSIXDirectoryDescriptor.openRoot(layout.root)
        _ = try root.openDirectory("logs", createMode: 0o700)
        return data
    }

    public func restoreLegacyPlist(layout: InstallationLayout) throws {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: layout.legacyPlistBackup.path) else { return }
        try fileManager.createDirectory(at: launchAgentsDirectory, withIntermediateDirectories: true)
        try Data(contentsOf: layout.legacyPlistBackup).write(to: plistURL, options: .atomic)
    }

    public func uninstall() throws {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: plistURL.path) else { return }
        try fileManager.removeItem(at: plistURL)
    }

    public func regenerateAPIKey(layout: InstallationLayout) throws -> String {
        try resolvedKeyStore(for: layout).generate()
    }

    public func captureInstallationState(layout: InstallationLayout) throws -> LaunchAgentInstallationState {
        let keyData = try resolvedKeyStore(for: layout).load().map {
            Data("\($0)\n".utf8)
        }
        return LaunchAgentInstallationState(
            plist: try dataIfPresent(at: plistURL),
            apiKey: keyData
        )
    }

    public func restoreInstallationState(
        _ state: LaunchAgentInstallationState,
        layout: InstallationLayout
    ) throws {
        try replace(plistURL, with: state.plist, mode: nil)
        try APIKeyStore(fileURL: layout.apiKeyFile)
            .restore(payload: state.apiKey)
    }

    public func restoreAPIKeyState(_ state: LaunchAgentInstallationState, layout: InstallationLayout) throws {
        try APIKeyStore(fileURL: layout.apiKeyFile)
            .restore(payload: state.apiKey)
    }

    public func restorePlistState(_ state: LaunchAgentInstallationState, layout: InstallationLayout) throws {
        try replace(plistURL, with: state.plist, mode: nil)
    }

    public func makePlist(
        layout: InstallationLayout,
        options: DeploymentOptions,
        manifest: DeploymentManifest
    ) throws -> Data {
        try options.validate(for: layout)
        let server = layout.runtimeCurrent.appending(path: "llama-server")
        var arguments = [
            server.path,
            "--alias", "qwythos-9b",
            "--model", layout.modelFile.path,
            "--host", options.accessMode == .shared ? "0.0.0.0" : "127.0.0.1",
            "--port", String(manifest.service.port),
            "--ctx-size", String(options.contextSize),
            "--parallel", "1",
            "--n-gpu-layers", "99",
            "--jinja",
            "--temp", "0.6",
            "--top-p", "0.95",
            "--top-k", "20",
            "--repeat-penalty", "1.05",
        ]
        if options.accessMode == .shared {
            arguments += ["--api-key-file", layout.apiKeyFile.path]
        }

        let plist = LaunchAgentPlist(
            label: manifest.service.label,
            programArguments: arguments,
            standardOutPath: layout.logsDirectory.appending(path: "llama-server.stdout.log").path,
            standardErrorPath: layout.logsDirectory.appending(path: "llama-server.stderr.log").path
        )
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .xml
        return try encoder.encode(plist)
    }

    private func resolvedKeyStore(for layout: InstallationLayout) -> any APIKeyStoring {
        keyStore ?? APIKeyStore(fileURL: layout.apiKeyFile)
    }

    private func dataIfPresent(at url: URL) throws -> Data? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try Data(contentsOf: url)
    }

    private func replace(_ url: URL, with data: Data?, mode: mode_t?) throws {
        let manager = FileManager.default
        guard let data else {
            if manager.fileExists(atPath: url.path) { try manager.removeItem(at: url) }
            return
        }
        try manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
        if let mode { guard chmod(url.path, mode) == 0 else { throw APIKeyStoreError.fileOperationFailed } }
    }
}

private struct LaunchAgentPlist: Codable {
    let label: String
    let programArguments: [String]
    let standardOutPath: String
    let standardErrorPath: String
    let runAtLoad = true
    let keepAlive = true
    let processType = "Interactive"

    enum CodingKeys: String, CodingKey {
        case label = "Label"
        case programArguments = "ProgramArguments"
        case standardOutPath = "StandardOutPath"
        case standardErrorPath = "StandardErrorPath"
        case runAtLoad = "RunAtLoad"
        case keepAlive = "KeepAlive"
        case processType = "ProcessType"
    }
}
