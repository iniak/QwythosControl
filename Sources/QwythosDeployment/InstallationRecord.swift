import Foundation
import Darwin

public struct InstallationRecord: Codable, Equatable, Sendable {
    public static let schemaVersion = 1

    public let schemaVersion: Int
    public let manifestSchemaVersion: Int
    public let root: URL
    public let runtimeVersion: String
    public let modelSHA256: String
    public let contextSize: Int
    public let accessMode: NetworkAccessMode
    public let installedAt: Date

    public init(
        schemaVersion: Int = InstallationRecord.schemaVersion,
        manifestSchemaVersion: Int,
        root: URL,
        runtimeVersion: String,
        modelSHA256: String,
        contextSize: Int,
        accessMode: NetworkAccessMode,
        installedAt: Date
    ) {
        self.schemaVersion = schemaVersion
        self.manifestSchemaVersion = manifestSchemaVersion
        self.root = root.standardizedFileURL
        self.runtimeVersion = runtimeVersion
        self.modelSHA256 = modelSHA256.lowercased()
        self.contextSize = contextSize
        self.accessMode = accessMode
        self.installedAt = installedAt
    }

    public static func isSafeRuntimeVersionComponent(
        _ value: String
    ) -> Bool {
        guard !value.isEmpty, value.utf8.count <= 255 else { return false }
        return value.utf8.allSatisfy { byte in
            (48...57).contains(byte)
                || (65...90).contains(byte)
                || (97...122).contains(byte)
                || byte == 45
                || byte == 95
        }
    }

    func validateManagedShape(for layout: InstallationLayout) throws {
        guard schemaVersion == Self.schemaVersion,
              root.path == layout.root.path,
              Self.isSafeRuntimeVersionComponent(runtimeVersion),
              Self.isValidSHA256(modelSHA256),
              DeploymentOptions.supportedContextSizes.contains(contextSize)
        else {
            throw InstallationRecordValidationError.invalidRecord
        }
    }

    private static func isValidSHA256(_ value: String) -> Bool {
        let bytes = value.utf8
        return bytes.count == 64 && bytes.allSatisfy {
            (48...57).contains($0)
                || (65...70).contains($0)
                || (97...102).contains($0)
        }
    }
}

enum InstallationRecordValidationError: Error {
    case invalidRecord
}

public protocol InstallationRecordStoring: Sendable {
    func load(layout: InstallationLayout) throws -> InstallationRecord?
    func save(_ record: InstallationRecord, layout: InstallationLayout) throws
    func remove(layout: InstallationLayout) throws
    func remove(
        ifMatching expectedRecord: InstallationRecord,
        layout: InstallationLayout
    ) throws -> Bool
}

public extension InstallationRecordStoring {
    func remove(
        ifMatching expectedRecord: InstallationRecord,
        layout: InstallationLayout
    ) throws -> Bool {
        false
    }
}

public struct InstallationRecordStore: InstallationRecordStoring, Sendable {
    private static let maximumRecordByteCount = 1_048_576

    typealias BeforeRecordPublishHook = @Sendable (Int32, String) throws -> Void
    typealias BeforeRecordReadHook = @Sendable (Int32, String) throws -> Void
    typealias DirectorySync = @Sendable (Int32) -> Int32

    private let beforeRecordPublish: BeforeRecordPublishHook
    private let beforeRecordRead: BeforeRecordReadHook
    private let directorySync: DirectorySync

    public init() {
        beforeRecordPublish = { _, _ in }
        beforeRecordRead = { _, _ in }
        directorySync = { fsync($0) }
    }

    init(beforeRecordPublish: @escaping BeforeRecordPublishHook) {
        self.beforeRecordPublish = beforeRecordPublish
        beforeRecordRead = { _, _ in }
        directorySync = { fsync($0) }
    }

    init(beforeRecordRead: @escaping BeforeRecordReadHook) {
        beforeRecordPublish = { _, _ in }
        self.beforeRecordRead = beforeRecordRead
        directorySync = { fsync($0) }
    }

    init(syncDirectory: @escaping DirectorySync) {
        beforeRecordPublish = { _, _ in }
        beforeRecordRead = { _, _ in }
        directorySync = syncDirectory
    }

    public func load(layout: InstallationLayout) throws -> InstallationRecord? {
        let root: POSIXDirectoryDescriptor
        do {
            root = try POSIXDirectoryDescriptor.openRoot(layout.root)
        } catch POSIXTransactionError.notFound {
            return nil
        } catch {
            throw InstallationRecordStoreError.unsafeRecordPath
        }

        let config: POSIXDirectoryDescriptor
        do {
            config = try root.openDirectory("config")
        } catch POSIXTransactionError.notFound {
            return nil
        } catch {
            throw InstallationRecordStoreError.unsafeRecordPath
        }

        let name = layout.deploymentRecord.lastPathComponent
        let file: POSIXFileDescriptor
        do {
            file = try config.openFile(
                name,
                flags: O_RDONLY | O_NOFOLLOW
            )
        } catch POSIXTransactionError.notFound {
            return nil
        } catch {
            throw InstallationRecordStoreError.unsafeRecordPath
        }

        let data: Data
        do {
            let metadata = try file.metadata()
            guard metadata.st_mode & S_IFMT == S_IFREG,
                  metadata.st_size >= 0,
                  metadata.st_size <= Self.maximumRecordByteCount else {
                throw InstallationRecordStoreError.unsafeRecordPath
            }
            try beforeRecordRead(config.rawValue, name)
            data = try readRecordData(
                from: file.rawValue,
                maximumByteCount: Self.maximumRecordByteCount
            )
        } catch let error as InstallationRecordStoreError {
            throw error
        } catch {
            throw InstallationRecordStoreError.unsafeRecordPath
        }

        let record = try JSONDecoder().decode(
            InstallationRecord.self,
            from: data
        )
        return InstallationRecord(
            schemaVersion: record.schemaVersion,
            manifestSchemaVersion: record.manifestSchemaVersion,
            root: record.root,
            runtimeVersion: record.runtimeVersion,
            modelSHA256: record.modelSHA256,
            contextSize: record.contextSize,
            accessMode: record.accessMode,
            installedAt: record.installedAt
        )
    }

    private func readRecordData(
        from descriptor: Int32,
        maximumByteCount: Int
    ) throws -> Data {
        var data = Data()
        var offset: off_t = 0
        var buffer = [UInt8](repeating: 0, count: 64 * 1_024)

        while true {
            let remainingWithOverflowByte = maximumByteCount - data.count + 1
            let requestedByteCount = min(buffer.count, remainingWithOverflowByte)
            let count = buffer.withUnsafeMutableBytes {
                pread(
                    descriptor,
                    $0.baseAddress,
                    requestedByteCount,
                    offset
                )
            }
            if count < 0 {
                if errno == EINTR { continue }
                throw POSIXTransactionError.operationFailed(errno)
            }
            if count == 0 { return data }
            guard data.count + count <= maximumByteCount else {
                throw InstallationRecordStoreError.unsafeRecordPath
            }
            data.append(contentsOf: buffer.prefix(count))
            offset += off_t(count)
        }
    }

    public func save(_ record: InstallationRecord, layout: InstallationLayout) throws {
        guard record.root.path == layout.root.path else {
            throw InstallationRecordStoreError.rootMismatch
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(record)

        let root: POSIXDirectoryDescriptor
        let config: POSIXDirectoryDescriptor
        do {
            root = try POSIXDirectoryDescriptor.openRoot(layout.root)
            config = try root.openDirectory("config", createMode: 0o700)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw InstallationRecordStoreError.unsafeRecordPath
        }
        try atomicReplace(
            data,
            named: layout.deploymentRecord.lastPathComponent,
            in: config
        )
    }

    public func remove(layout: InstallationLayout) throws {
        let root: POSIXDirectoryDescriptor
        do {
            root = try POSIXDirectoryDescriptor.openRoot(layout.root)
        } catch POSIXTransactionError.notFound {
            return
        } catch {
            throw InstallationRecordStoreError.unsafeRecordPath
        }

        let config: POSIXDirectoryDescriptor
        do {
            config = try root.openDirectory("config")
        } catch POSIXTransactionError.notFound {
            return
        } catch {
            throw InstallationRecordStoreError.unsafeRecordPath
        }

        let name = layout.deploymentRecord.lastPathComponent
        let captured: stat?
        do {
            captured = try config.metadata(for: name)
        } catch {
            throw InstallationRecordStoreError.unsafeRecordPath
        }
        guard let captured else { return }
        guard captured.st_mode & S_IFMT == S_IFREG else {
            throw InstallationRecordStoreError.unsafeRecordPath
        }

        do {
            let file = try config.openFile(name, flags: O_RDONLY | O_NOFOLLOW)
            let opened = try file.metadata()
            guard opened.st_mode & S_IFMT == S_IFREG,
                  POSIXFileIdentity(opened) == POSIXFileIdentity(captured),
                  let current = try config.metadata(for: name),
                  POSIXFileIdentity(current) == POSIXFileIdentity(opened)
            else {
                throw InstallationRecordStoreError.unsafeRecordPath
            }
            try config.unlinkIfOwned(
                name,
                identity: POSIXFileIdentity(opened)
            )
            try syncDirectory(config.rawValue)
        } catch let error as InstallationRecordStoreError {
            throw error
        } catch {
            throw InstallationRecordStoreError.unsafeRecordPath
        }
    }

    public func remove(
        ifMatching expectedRecord: InstallationRecord,
        layout: InstallationLayout
    ) throws -> Bool {
        let root: POSIXDirectoryDescriptor
        do {
            root = try POSIXDirectoryDescriptor.openRoot(layout.root)
        } catch POSIXTransactionError.notFound {
            return true
        } catch {
            throw InstallationRecordStoreError.unsafeRecordPath
        }

        let config: POSIXDirectoryDescriptor
        do {
            config = try root.openDirectory("config")
        } catch POSIXTransactionError.notFound {
            return true
        } catch {
            throw InstallationRecordStoreError.unsafeRecordPath
        }

        let name = layout.deploymentRecord.lastPathComponent
        let file: POSIXFileDescriptor
        do {
            file = try config.openFile(
                name,
                flags: O_RDONLY | O_NOFOLLOW
            )
        } catch POSIXTransactionError.notFound {
            return true
        } catch {
            throw InstallationRecordStoreError.unsafeRecordPath
        }

        do {
            let opened = try file.metadata()
            guard opened.st_mode & S_IFMT == S_IFREG,
                  opened.st_size >= 0,
                  opened.st_size <= Self.maximumRecordByteCount else {
                throw InstallationRecordStoreError.unsafeRecordPath
            }
            let openedIdentity = POSIXFileIdentity(opened)
            try beforeRecordRead(config.rawValue, name)
            let data = try readRecordData(
                from: file.rawValue,
                maximumByteCount: Self.maximumRecordByteCount
            )
            let currentRecord = try JSONDecoder().decode(
                InstallationRecord.self,
                from: data
            )
            guard currentRecord == expectedRecord else { return false }
            guard let current = try config.metadata(for: name),
                  current.st_mode & S_IFMT == S_IFREG,
                  POSIXFileIdentity(current) == openedIdentity else {
                return false
            }
            try config.unlinkIfOwned(name, identity: openedIdentity)
            try syncDirectory(config.rawValue)
            return true
        } catch let error as InstallationRecordStoreError {
            throw error
        } catch {
            throw InstallationRecordStoreError.unsafeRecordPath
        }
    }

    private func atomicReplace(
        _ data: Data,
        named name: String,
        in directory: POSIXDirectoryDescriptor
    ) throws {
        do {
            if let existing = try directory.metadata(for: name),
               existing.st_mode & S_IFMT != S_IFREG {
                throw InstallationRecordStoreError.unsafeRecordPath
            }
        } catch let error as InstallationRecordStoreError {
            throw error
        } catch {
            throw InstallationRecordStoreError.unsafeRecordPath
        }

        let created = try createTemporaryFile(in: directory)
        let temporaryName = created.name
        let temporary = created.file
        var temporaryContainsCreatedFile = true
        defer {
            if temporaryContainsCreatedFile {
                try? directory.unlinkIfOwned(
                    temporaryName,
                    identity: created.identity
                )
            }
        }

        guard fchmod(temporary.rawValue, 0o600) == 0 else {
            throw posixError(errno)
        }
        try write(data, to: temporary.rawValue)
        guard fsync(temporary.rawValue) == 0 else {
            throw posixError(errno)
        }
        try temporary.closeChecked()

        let expectedExistingIdentity: POSIXFileIdentity?
        if let existing = try directory.metadata(for: name) {
            guard existing.st_mode & S_IFMT == S_IFREG else {
                throw InstallationRecordStoreError.unsafeRecordPath
            }
            expectedExistingIdentity = POSIXFileIdentity(existing)
        } else {
            expectedExistingIdentity = nil
        }
        try beforeRecordPublish(directory.rawValue, name)
        let displacedIdentity = try publishTemporary(
            temporaryName,
            identity: created.identity,
            as: name,
            replacing: expectedExistingIdentity,
            in: directory
        )
        temporaryContainsCreatedFile = false

        do {
            try syncDirectory(directory.rawValue)
        } catch {
            if displacedIdentity != nil {
                do {
                    try directory.exchange(temporaryName, with: name)
                    temporaryContainsCreatedFile = true
                    try syncDirectory(directory.rawValue)
                } catch {
                    // Preserve both entries if the exact rollback cannot be proven.
                }
            } else {
                try? directory.unlinkIfOwned(
                    name,
                    identity: created.identity
                )
                try? syncDirectory(directory.rawValue)
            }
            throw error
        }

        if let displacedIdentity {
            try directory.unlinkIfOwned(
                temporaryName,
                identity: displacedIdentity
            )
        }
    }

    private func publishTemporary(
        _ temporaryName: String,
        identity temporaryIdentity: POSIXFileIdentity,
        as name: String,
        replacing expectedExistingIdentity: POSIXFileIdentity?,
        in directory: POSIXDirectoryDescriptor
    ) throws -> POSIXFileIdentity? {
        guard let expectedExistingIdentity else {
            if renameatx_np(
                directory.rawValue,
                temporaryName,
                directory.rawValue,
                name,
                UInt32(RENAME_EXCL)
            ) == 0 {
                return nil
            }
            let publishError = errno
            if publishError == EEXIST {
                throw InstallationRecordStoreError.unsafeRecordPath
            }
            if publishError == EISDIR || publishError == ENOTDIR {
                throw InstallationRecordStoreError.unsafeRecordPath
            }
            throw posixError(publishError)
        }

        try directory.exchange(temporaryName, with: name)
        guard let installed = try directory.metadata(for: name),
              installed.st_mode & S_IFMT == S_IFREG,
              POSIXFileIdentity(installed) == temporaryIdentity else {
            try? directory.exchange(temporaryName, with: name)
            throw InstallationRecordStoreError.unsafeRecordPath
        }
        guard let displaced = try directory.metadata(for: temporaryName),
              displaced.st_mode & S_IFMT == S_IFREG,
              POSIXFileIdentity(displaced) == expectedExistingIdentity else {
            try directory.exchange(temporaryName, with: name)
            throw InstallationRecordStoreError.unsafeRecordPath
        }
        return POSIXFileIdentity(displaced)
    }

    private func createTemporaryFile(
        in directory: POSIXDirectoryDescriptor
    ) throws -> (
        name: String,
        file: POSIXFileDescriptor,
        identity: POSIXFileIdentity
    ) {
        for _ in 0..<16 {
            let candidate = ".deployment-\(UUID().uuidString).tmp"
            let descriptor = openat(
                directory.rawValue,
                candidate,
                O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
                0o600
            )
            if descriptor >= 0 {
                let file = POSIXFileDescriptor(descriptor)
                return (
                    candidate,
                    file,
                    POSIXFileIdentity(try file.metadata())
                )
            }
            if errno != EEXIST {
                throw posixError(errno)
            }
        }
        throw posixError(EEXIST)
    }

    private func write(_ data: Data, to descriptor: Int32) throws {
        var offset = 0
        while offset < data.count {
            let count = data.withUnsafeBytes {
                Darwin.write(
                    descriptor,
                    $0.baseAddress!.advanced(by: offset),
                    data.count - offset
                )
            }
            if count < 0 {
                if errno == EINTR { continue }
                throw posixError(errno)
            }
            guard count > 0 else { throw posixError(EIO) }
            offset += count
        }
    }

    private func syncDirectory(_ descriptor: Int32) throws {
        while true {
            if directorySync(descriptor) == 0 { return }
            let code = errno
            if code == EINTR { continue }
            throw posixError(code)
        }
    }

    private func posixError(_ code: Int32) -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
    }

}

public enum InstallationRecordStoreError: Error, Equatable, Sendable {
    case rootMismatch
    case unsafeRecordPath
}
