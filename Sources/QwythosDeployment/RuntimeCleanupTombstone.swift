import Darwin
import Foundation

struct RuntimeCleanupTombstone: Codable, Equatable, Sendable {
    static let schemaVersion = 1
    static let quarantinePrefix = ".qwythos-runtime-cleanup-"

    let schemaVersion: Int
    let record: InstallationRecord
    let quarantineName: String
    let device: Int64
    let inode: UInt64

    init(
        record: InstallationRecord,
        quarantineName: String,
        identity: POSIXFileIdentity
    ) {
        schemaVersion = Self.schemaVersion
        self.record = record
        self.quarantineName = quarantineName
        device = Int64(identity.device)
        inode = UInt64(identity.inode)
    }

    func validatedIdentity(
        record expectedRecord: InstallationRecord? = nil,
        layout: InstallationLayout
    ) throws -> POSIXFileIdentity {
        let quarantineSuffix = String(
            quarantineName.dropFirst(Self.quarantinePrefix.count)
        )
        guard schemaVersion == Self.schemaVersion,
              expectedRecord.map({ record == $0 }) ?? true,
              record.schemaVersion == InstallationRecord.schemaVersion,
              record.root.standardizedFileURL
                == layout.root.standardizedFileURL,
              InstallationRecord.isSafeRuntimeVersionComponent(
                record.runtimeVersion
              ),
              quarantineName.hasPrefix(Self.quarantinePrefix),
              UUID(uuidString: quarantineSuffix) != nil,
              !quarantineName.contains("/"),
              let device = dev_t(exactly: device),
              let inode = ino_t(exactly: inode) else {
            throw POSIXTransactionError.ownershipChanged
        }
        return POSIXFileIdentity(device: device, inode: inode)
    }
}

struct RuntimeCleanupTombstoneStore {
    private static let maximumByteCount = 1_048_576

    func load(
        layout: InstallationLayout
    ) throws -> RuntimeCleanupTombstone? {
        try loadWithIdentity(layout: layout)?.tombstone
    }

    func save(
        _ tombstone: RuntimeCleanupTombstone,
        layout: InstallationLayout
    ) throws {
        let root = try POSIXDirectoryDescriptor.openRoot(layout.root)
        let config = try root.openDirectory("config")
        let name = layout.runtimeCleanupTombstone.lastPathComponent
        guard try config.metadata(for: name) == nil else {
            throw POSIXTransactionError.ownershipChanged
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(tombstone)
        guard data.count <= Self.maximumByteCount else {
            throw POSIXTransactionError.unsafePath
        }

        for _ in 0..<16 {
            let temporaryName =
                ".runtime-cleanup-\(UUID().uuidString).tmp"
            let temporary: POSIXFileDescriptor
            do {
                temporary = try config.openFile(
                    temporaryName,
                    flags: O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW,
                    mode: 0o600
                )
            } catch POSIXTransactionError.operationFailed(EEXIST) {
                continue
            }
            let identity = POSIXFileIdentity(try temporary.metadata())
            var published = false
            defer {
                if !published {
                    try? config.unlinkIfOwned(
                        temporaryName,
                        identity: identity
                    )
                }
            }

            try write(data, to: temporary.rawValue)
            guard fsync(temporary.rawValue) == 0 else {
                throw POSIXTransactionError.operationFailed(errno)
            }
            try temporary.closeChecked()
            guard renameatx_np(
                config.rawValue,
                temporaryName,
                config.rawValue,
                name,
                UInt32(RENAME_EXCL)
            ) == 0 else {
                if errno == EEXIST {
                    throw POSIXTransactionError.ownershipChanged
                }
                throw POSIXTransactionError.operationFailed(errno)
            }
            published = true
            guard let metadata = try config.metadata(for: name),
                  metadata.st_mode & S_IFMT == S_IFREG,
                  POSIXFileIdentity(metadata) == identity else {
                throw POSIXTransactionError.ownershipChanged
            }
            try config.sync()
            return
        }
        throw POSIXTransactionError.operationFailed(EEXIST)
    }

    func remove(
        ifMatching expected: RuntimeCleanupTombstone,
        layout: InstallationLayout
    ) throws -> Bool {
        guard let current = try loadWithIdentity(layout: layout) else {
            return false
        }
        guard current.tombstone == expected else {
            throw POSIXTransactionError.ownershipChanged
        }
        let root = try POSIXDirectoryDescriptor.openRoot(layout.root)
        let config = try root.openDirectory("config")
        try config.unlinkIfOwned(
            layout.runtimeCleanupTombstone.lastPathComponent,
            identity: current.identity
        )
        try config.sync()
        return true
    }

    private func loadWithIdentity(
        layout: InstallationLayout
    ) throws -> (
        tombstone: RuntimeCleanupTombstone,
        identity: POSIXFileIdentity
    )? {
        let root: POSIXDirectoryDescriptor
        do {
            root = try POSIXDirectoryDescriptor.openRoot(layout.root)
        } catch POSIXTransactionError.notFound {
            return nil
        }
        let config: POSIXDirectoryDescriptor
        do {
            config = try root.openDirectory("config")
        } catch POSIXTransactionError.notFound {
            return nil
        }
        let file: POSIXFileDescriptor
        do {
            file = try config.openFile(
                layout.runtimeCleanupTombstone.lastPathComponent,
                flags: O_RDONLY | O_NOFOLLOW
            )
        } catch POSIXTransactionError.notFound {
            return nil
        }

        do {
            let metadata = try file.metadata()
            guard metadata.st_mode & S_IFMT == S_IFREG,
                  metadata.st_size >= 0,
                  metadata.st_size <= Self.maximumByteCount else {
                throw POSIXTransactionError.ownershipChanged
            }
            let data = try read(
                from: file.rawValue,
                maximumByteCount: Self.maximumByteCount
            )
            let tombstone = try JSONDecoder().decode(
                RuntimeCleanupTombstone.self,
                from: data
            )
            return (tombstone, POSIXFileIdentity(metadata))
        } catch {
            throw POSIXTransactionError.ownershipChanged
        }
    }

    private func read(
        from descriptor: Int32,
        maximumByteCount: Int
    ) throws -> Data {
        var data = Data()
        var offset: off_t = 0
        var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
        while true {
            let requested = min(
                buffer.count,
                maximumByteCount - data.count + 1
            )
            let count = buffer.withUnsafeMutableBytes {
                pread(descriptor, $0.baseAddress, requested, offset)
            }
            if count < 0 {
                if errno == EINTR { continue }
                throw POSIXTransactionError.operationFailed(errno)
            }
            if count == 0 { return data }
            data.append(contentsOf: buffer.prefix(count))
            guard data.count <= maximumByteCount else {
                throw POSIXTransactionError.ownershipChanged
            }
            offset += off_t(count)
        }
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
                    throw POSIXTransactionError.operationFailed(errno)
                }
                guard count > 0 else {
                    throw POSIXTransactionError.operationFailed(EIO)
                }
                offset += count
            }
        }
    }
}
