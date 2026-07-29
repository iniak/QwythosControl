import Darwin
import Foundation

enum POSIXTransactionError: Error, Equatable, Sendable {
    case unsafePath
    case notFound
    case ownershipChanged
    case deviceBoundary
    case operationFailed(Int32)
}

struct POSIXFileIdentity: Equatable, Sendable {
    let device: dev_t
    let inode: ino_t

    init(_ metadata: stat) {
        device = metadata.st_dev
        inode = metadata.st_ino
    }

    init(device: dev_t, inode: ino_t) {
        self.device = device
        self.inode = inode
    }
}

struct POSIXOwnedDirectory {
    let name: String
    let directory: POSIXDirectoryDescriptor
    let identity: POSIXFileIdentity
}

final class POSIXFileDescriptor {
    private var descriptor: Int32

    init(_ descriptor: Int32) {
        self.descriptor = descriptor
    }

    deinit {
        if descriptor >= 0 {
            _ = Darwin.close(descriptor)
        }
    }

    var rawValue: Int32 {
        descriptor
    }

    func metadata() throws -> stat {
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0 else {
            throw POSIXTransactionError.operationFailed(errno)
        }
        return metadata
    }

    func closeChecked() throws {
        guard descriptor >= 0 else { return }
        let closing = descriptor
        descriptor = -1
        guard Darwin.close(closing) == 0 else {
            throw POSIXTransactionError.operationFailed(errno)
        }
    }
}

final class POSIXDirectoryDescriptor {
    let rawValue: Int32

    private init(_ descriptor: Int32) {
        rawValue = descriptor
    }

    deinit {
        _ = Darwin.close(rawValue)
    }

    func metadata() throws -> stat {
        var metadata = stat()
        guard fstat(rawValue, &metadata) == 0 else {
            throw POSIXTransactionError.operationFailed(errno)
        }
        return metadata
    }

    static func validateRootURL(_ root: URL) throws {
        let path = root.path
        let components = (path as NSString).pathComponents
        let urlComponents = URLComponents(
            url: root,
            resolvingAgainstBaseURL: false
        )
        let hasLocalAuthority = urlComponents?.host?.isEmpty ?? true
        guard root.isFileURL,
              root.baseURL == nil,
              urlComponents?.scheme == "file",
              urlComponents?.user == nil,
              urlComponents?.password == nil,
              hasLocalAuthority,
              urlComponents?.port == nil,
              urlComponents?.query == nil,
              urlComponents?.fragment == nil,
              isCanonicalAbsolutePath(path),
              components.first == "/" else {
            throw POSIXTransactionError.unsafePath
        }
    }

    static func openRoot(_ root: URL) throws -> POSIXDirectoryDescriptor {
        try validateRootURL(root)
        let components = (root.path as NSString).pathComponents
        let descriptor = Darwin.open(
            "/",
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard descriptor >= 0 else {
            throw POSIXTransactionError.unsafePath
        }
        var directory = POSIXDirectoryDescriptor(descriptor)
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0,
              metadata.st_mode & S_IFMT == S_IFDIR else {
            throw POSIXTransactionError.unsafePath
        }

        for component in components.dropFirst() {
            guard !component.isEmpty,
                  component != ".",
                  component != "..",
                  !component.contains("/") else {
                throw POSIXTransactionError.unsafePath
            }
            let child = openat(
                directory.rawValue,
                component,
                O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
            )
            guard child >= 0 else {
                if errno == ENOENT {
                    throw POSIXTransactionError.notFound
                }
                throw POSIXTransactionError.unsafePath
            }
            let opened = POSIXDirectoryDescriptor(child)
            var childMetadata = stat()
            guard fstat(child, &childMetadata) == 0,
                  childMetadata.st_mode & S_IFMT == S_IFDIR else {
                throw POSIXTransactionError.unsafePath
            }
            directory = opened
        }
        return directory
    }

    static func openOrCreateRoot(
        _ root: URL,
        mode: mode_t = 0o700
    ) throws -> POSIXDirectoryDescriptor {
        try validateRootURL(root)
        let descriptor = Darwin.open(
            "/",
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard descriptor >= 0 else { throw POSIXTransactionError.unsafePath }
        var directory = POSIXDirectoryDescriptor(descriptor)
        for component in (root.path as NSString).pathComponents.dropFirst() {
            directory = try directory.openDirectory(component, createMode: mode)
        }
        return directory
    }

    private static func isCanonicalAbsolutePath(_ path: String) -> Bool {
        if path == "/" { return true }
        let components = path.split(
            separator: "/",
            omittingEmptySubsequences: false
        )
        guard components.count > 1, components.first?.isEmpty == true else {
            return false
        }
        return components.dropFirst().allSatisfy {
            !$0.isEmpty && $0 != "." && $0 != ".."
        }
    }

    static func openOwned(_ descriptor: Int32) -> POSIXDirectoryDescriptor {
        POSIXDirectoryDescriptor(descriptor)
    }

    func validateDirectoryIfPresent(_ name: String) throws {
        try validateComponent(name)
        var metadata = stat()
        if fstatat(rawValue, name, &metadata, AT_SYMLINK_NOFOLLOW) == 0 {
            guard metadata.st_mode & S_IFMT == S_IFDIR else {
                throw POSIXTransactionError.unsafePath
            }
            return
        }
        guard errno == ENOENT else {
            throw POSIXTransactionError.unsafePath
        }
    }

    func openDirectory(
        _ name: String,
        createMode: mode_t? = nil
    ) throws -> POSIXDirectoryDescriptor {
        try validateComponent(name)

        while true {
            var metadata = stat()
            if fstatat(rawValue, name, &metadata, AT_SYMLINK_NOFOLLOW) == 0 {
                guard metadata.st_mode & S_IFMT == S_IFDIR else {
                    throw POSIXTransactionError.unsafePath
                }
            } else if errno == ENOENT, let createMode {
                try Task.checkCancellation()
                if mkdirat(rawValue, name, createMode) != 0, errno != EEXIST {
                    throw POSIXTransactionError.operationFailed(errno)
                }
            } else if errno == ENOENT {
                throw POSIXTransactionError.notFound
            } else {
                throw POSIXTransactionError.unsafePath
            }

            let child = openat(
                rawValue,
                name,
                O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
            )
            if child >= 0 {
                return POSIXDirectoryDescriptor(child)
            }
            if errno == ENOENT, createMode != nil {
                continue
            }
            throw POSIXTransactionError.unsafePath
        }
    }

    func createOwnedDirectory(
        prefix: String,
        mode: mode_t
    ) throws -> POSIXOwnedDirectory {
        guard !prefix.isEmpty, !prefix.contains("/") else {
            throw POSIXTransactionError.unsafePath
        }
        for _ in 0..<16 {
            let name = "\(prefix)\(UUID().uuidString)"
            try validateComponent(name)
            try Task.checkCancellation()
            if mkdirat(rawValue, name, mode) != 0 {
                if errno == EEXIST { continue }
                throw POSIXTransactionError.operationFailed(errno)
            }

            let child = openat(
                rawValue,
                name,
                O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
            )
            guard child >= 0 else {
                throw POSIXTransactionError.operationFailed(errno)
            }
            let directory = POSIXDirectoryDescriptor(child)
            var openedMetadata = stat()
            guard fstat(child, &openedMetadata) == 0,
                  openedMetadata.st_mode & S_IFMT == S_IFDIR else {
                throw POSIXTransactionError.unsafePath
            }
            let identity = POSIXFileIdentity(openedMetadata)
            guard let publicMetadata = try metadata(for: name),
                  publicMetadata.st_mode & S_IFMT == S_IFDIR,
                  POSIXFileIdentity(publicMetadata) == identity else {
                throw POSIXTransactionError.ownershipChanged
            }
            return POSIXOwnedDirectory(
                name: name,
                directory: directory,
                identity: identity
            )
        }
        throw POSIXTransactionError.operationFailed(EEXIST)
    }

    func openFile(
        _ name: String,
        flags: Int32,
        mode: mode_t = 0
    ) throws -> POSIXFileDescriptor {
        try validateComponent(name)
        let descriptor = openat(rawValue, name, flags | O_CLOEXEC, mode)
        guard descriptor >= 0 else {
            let code = errno
            if code == ENOENT { throw POSIXTransactionError.notFound }
            throw POSIXTransactionError.operationFailed(code)
        }
        return POSIXFileDescriptor(descriptor)
    }

    func metadata(
        for name: String,
        nofollow: Bool = true
    ) throws -> stat? {
        try validateComponent(name)
        var metadata = stat()
        let flags = nofollow ? AT_SYMLINK_NOFOLLOW : 0
        if fstatat(rawValue, name, &metadata, flags) == 0 {
            return metadata
        }
        if errno == ENOENT { return nil }
        throw POSIXTransactionError.operationFailed(errno)
    }

    func link(
        sourceDirectory: POSIXDirectoryDescriptor,
        sourceName: String,
        destinationName: String
    ) throws {
        try validateComponent(sourceName)
        try validateComponent(destinationName)
        guard linkat(
            sourceDirectory.rawValue,
            sourceName,
            rawValue,
            destinationName,
            0
        ) == 0 else {
            throw POSIXTransactionError.operationFailed(errno)
        }
    }

    func unlink(_ name: String) throws {
        try validateComponent(name)
        guard unlinkat(rawValue, name, 0) == 0 else {
            if errno == ENOENT { return }
            throw POSIXTransactionError.operationFailed(errno)
        }
    }

    func unlinkIfOwned(
        _ name: String,
        identity: POSIXFileIdentity,
        beforeQuarantine: () throws -> Void = {}
    ) throws {
        try validateComponent(name)
        try beforeQuarantine()

        let guardEntry = try createGuardEntry()
        let guardName = guardEntry.name
        let guardIdentity = guardEntry.identity
        var pendingGuardCleanup: (String, POSIXFileIdentity)? = (
            guardName,
            guardIdentity
        )
        defer {
            if let pendingGuardCleanup {
                try? unlinkPrivateEntryIfOwned(
                    pendingGuardCleanup.0,
                    identity: pendingGuardCleanup.1
                )
            }
        }

        guard renameatx_np(
            rawValue,
            name,
            rawValue,
            guardName,
            UInt32(RENAME_SWAP)
        ) == 0 else {
            if errno == ENOENT { return }
            throw POSIXTransactionError.operationFailed(errno)
        }

        guard let quarantined = try metadata(for: guardName),
              quarantined.st_mode & S_IFMT == S_IFREG,
              POSIXFileIdentity(quarantined) == identity else {
            guard renameatx_np(
                rawValue,
                name,
                rawValue,
                guardName,
                UInt32(RENAME_SWAP)
            ) == 0 else {
                throw POSIXTransactionError.operationFailed(errno)
            }
            throw POSIXTransactionError.ownershipChanged
        }

        let quarantinedIdentity = POSIXFileIdentity(quarantined)
        guard let publicEntry = try metadata(for: name),
              publicEntry.st_mode & S_IFMT == S_IFREG,
              POSIXFileIdentity(publicEntry) == guardIdentity else {
            try unlinkPrivateEntryIfOwned(guardName, identity: quarantinedIdentity)
            throw POSIXTransactionError.ownershipChanged
        }

        try unlinkPrivateEntryIfOwned(guardName, identity: quarantinedIdentity)
        try unlinkPrivateEntryIfOwned(name, identity: guardIdentity)
        pendingGuardCleanup = nil
    }

    func removeDirectoryIfOwned(
        _ name: String,
        identity: POSIXFileIdentity
    ) throws {
        try validateComponent(name)

        for _ in 0..<16 {
            let quarantineName = ".directory-quarantine-\(UUID().uuidString)"
            guard renameatx_np(
                rawValue,
                name,
                rawValue,
                quarantineName,
                UInt32(RENAME_EXCL)
            ) == 0 else {
                if errno == ENOENT { return }
                if errno == EEXIST { continue }
                throw POSIXTransactionError.operationFailed(errno)
            }

            guard let quarantined = try metadata(for: quarantineName),
                  quarantined.st_mode & S_IFMT == S_IFDIR,
                  POSIXFileIdentity(quarantined) == identity else {
                guard renameatx_np(
                    rawValue,
                    quarantineName,
                    rawValue,
                    name,
                    UInt32(RENAME_EXCL)
                ) == 0 else {
                    throw POSIXTransactionError.operationFailed(errno)
                }
                throw POSIXTransactionError.ownershipChanged
            }

            guard unlinkat(rawValue, quarantineName, AT_REMOVEDIR) == 0 else {
                if errno == ENOENT { return }
                throw POSIXTransactionError.operationFailed(errno)
            }
            return
        }
        throw POSIXTransactionError.operationFailed(EEXIST)
    }

    func quarantineDirectoryIfOwned(
        _ name: String,
        quarantinePrefix: String,
        beforeQuarantine: () throws -> Void = {}
    ) throws -> POSIXOwnedDirectory? {
        try validateComponent(name)
        guard !quarantinePrefix.isEmpty,
              !quarantinePrefix.contains("/") else {
            throw POSIXTransactionError.unsafePath
        }
        guard let captured = try metadata(for: name) else { return nil }
        guard captured.st_mode & S_IFMT == S_IFDIR else {
            throw POSIXTransactionError.unsafePath
        }

        let identity = POSIXFileIdentity(captured)

        for _ in 0..<16 {
            let quarantineName = "\(quarantinePrefix)\(UUID().uuidString)"
            do {
                return try quarantineDirectoryIfOwned(
                    name,
                    identity: identity,
                    quarantineName: quarantineName,
                    beforeQuarantine: beforeQuarantine
                )
            } catch POSIXTransactionError.operationFailed(EEXIST) {
                continue
            }
        }
        throw POSIXTransactionError.operationFailed(EEXIST)
    }

    func quarantineDirectoryIfOwned(
        _ name: String,
        identity: POSIXFileIdentity,
        quarantineName: String,
        beforeQuarantine: () throws -> Void = {}
    ) throws -> POSIXOwnedDirectory? {
        try validateComponent(name)
        try validateComponent(quarantineName)
        guard name != quarantineName else {
            throw POSIXTransactionError.unsafePath
        }
        guard let captured = try metadata(for: name) else { return nil }
        guard captured.st_mode & S_IFMT == S_IFDIR,
              POSIXFileIdentity(captured) == identity else {
            throw POSIXTransactionError.ownershipChanged
        }

        let directory = try openDirectory(name)
        guard POSIXFileIdentity(try directory.metadata()) == identity else {
            throw POSIXTransactionError.ownershipChanged
        }
        try beforeQuarantine()
        guard let current = try metadata(for: name),
              current.st_mode & S_IFMT == S_IFDIR,
              POSIXFileIdentity(current) == identity else {
            throw POSIXTransactionError.ownershipChanged
        }

        guard renameatx_np(
            rawValue,
            name,
            rawValue,
            quarantineName,
            UInt32(RENAME_EXCL)
        ) == 0 else {
            if errno == ENOENT {
                throw POSIXTransactionError.ownershipChanged
            }
            throw POSIXTransactionError.operationFailed(errno)
        }

        guard let quarantined = try metadata(for: quarantineName),
              quarantined.st_mode & S_IFMT == S_IFDIR,
              POSIXFileIdentity(quarantined) == identity else {
            guard renameatx_np(
                rawValue,
                quarantineName,
                rawValue,
                name,
                UInt32(RENAME_EXCL)
            ) == 0 else {
                throw POSIXTransactionError.ownershipChanged
            }
            throw POSIXTransactionError.ownershipChanged
        }
        try sync()
        return POSIXOwnedDirectory(
            name: quarantineName,
            directory: directory,
            identity: identity
        )
    }

    func removeOwnedDirectoryTree(_ owned: POSIXOwnedDirectory) throws {
        try removeOwnedDirectoryTree(
            owned,
            deviceBoundaryCheck: { rootDevice, entryDevice, _ in
                rootDevice == entryDevice
            }
        )
    }

    func removeOwnedDirectoryTree(
        _ owned: POSIXOwnedDirectory,
        deviceBoundaryCheck: (
            _ rootDevice: dev_t,
            _ entryDevice: dev_t,
            _ name: String
        ) -> Bool
    ) throws {
        try validateComponent(owned.name)
        guard let current = try metadata(for: owned.name),
              current.st_mode & S_IFMT == S_IFDIR,
              POSIXFileIdentity(current) == owned.identity,
              POSIXFileIdentity(try owned.directory.metadata())
                == owned.identity else {
            throw POSIXTransactionError.ownershipChanged
        }

        let rootDevice = current.st_dev
        try owned.directory.validateRecursiveDeviceBoundaries(
            rootDevice: rootDevice,
            deviceBoundaryCheck: deviceBoundaryCheck
        )
        try owned.directory.removeContentsRecursively(
            rootDevice: rootDevice,
            deviceBoundaryCheck: deviceBoundaryCheck
        )
        guard let current = try metadata(for: owned.name),
              current.st_mode & S_IFMT == S_IFDIR,
              POSIXFileIdentity(current) == owned.identity else {
            throw POSIXTransactionError.ownershipChanged
        }
        guard deviceBoundaryCheck(
            rootDevice,
            current.st_dev,
            owned.name
        ) else {
            throw POSIXTransactionError.deviceBoundary
        }
        guard unlinkat(rawValue, owned.name, AT_REMOVEDIR) == 0 else {
            throw POSIXTransactionError.operationFailed(errno)
        }
        try sync()
    }

    func openOwnedDirectory(
        _ name: String,
        identity: POSIXFileIdentity
    ) throws -> POSIXOwnedDirectory? {
        try validateComponent(name)
        guard let captured = try metadata(for: name) else {
            try sync()
            return nil
        }
        guard captured.st_mode & S_IFMT == S_IFDIR,
              POSIXFileIdentity(captured) == identity else {
            throw POSIXTransactionError.ownershipChanged
        }
        let directory = try openDirectory(name)
        guard POSIXFileIdentity(try directory.metadata()) == identity else {
            throw POSIXTransactionError.ownershipChanged
        }
        return POSIXOwnedDirectory(
            name: name,
            directory: directory,
            identity: identity
        )
    }

    func openOwnedDirectoryIfPresent(
        _ name: String
    ) throws -> POSIXOwnedDirectory? {
        guard let metadata = try metadata(for: name) else { return nil }
        guard metadata.st_mode & S_IFMT == S_IFDIR else {
            throw POSIXTransactionError.unsafePath
        }
        return try openOwnedDirectory(name, identity: POSIXFileIdentity(metadata))
    }

    func moveOwnedDirectory(
        _ owned: POSIXOwnedDirectory,
        to destination: POSIXDirectoryDescriptor,
        name: String
    ) throws -> POSIXOwnedDirectory {
        try validateComponent(owned.name)
        try destination.validateComponent(name)
        guard let sourceMetadata = try metadata(for: owned.name),
              sourceMetadata.st_mode & S_IFMT == S_IFDIR,
              POSIXFileIdentity(sourceMetadata) == owned.identity,
              POSIXFileIdentity(try owned.directory.metadata()) == owned.identity,
              try destination.metadata(for: name) == nil else {
            throw POSIXTransactionError.ownershipChanged
        }
        guard renameatx_np(
            rawValue,
            owned.name,
            destination.rawValue,
            name,
            UInt32(RENAME_EXCL)
        ) == 0 else {
            throw POSIXTransactionError.operationFailed(errno)
        }
        guard let moved = try destination.metadata(for: name),
              moved.st_mode & S_IFMT == S_IFDIR,
              POSIXFileIdentity(moved) == owned.identity,
              POSIXFileIdentity(try owned.directory.metadata()) == owned.identity else {
            throw POSIXTransactionError.ownershipChanged
        }
        try sync()
        if destination.rawValue != rawValue {
            try destination.sync()
        }
        return POSIXOwnedDirectory(
            name: name,
            directory: owned.directory,
            identity: owned.identity
        )
    }

    func resolvedPath() throws -> URL {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard fcntl(rawValue, F_GETPATH, &buffer) == 0 else {
            throw POSIXTransactionError.operationFailed(errno)
        }
        let path = String(
            decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) },
            as: UTF8.self
        )
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    func replaceSymbolicLink(
        _ name: String,
        withRelativeTarget target: String
    ) throws {
        try validateComponent(name)
        let components = target.split(separator: "/", omittingEmptySubsequences: false)
        guard !target.hasPrefix("/"),
              !components.isEmpty,
              components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw POSIXTransactionError.unsafePath
        }
        for _ in 0..<16 {
            let temporary = ".link-\(UUID().uuidString)"
            guard symlinkat(target, rawValue, temporary) == 0 else {
                if errno == EEXIST { continue }
                throw POSIXTransactionError.operationFailed(errno)
            }
            guard renameat(rawValue, temporary, rawValue, name) == 0 else {
                let code = errno
                _ = unlinkat(rawValue, temporary, 0)
                throw POSIXTransactionError.operationFailed(code)
            }
            try sync()
            return
        }
        throw POSIXTransactionError.operationFailed(EEXIST)
    }

    func symbolicLinkTarget(_ name: String) throws -> String? {
        try validateComponent(name)
        var buffer = [CChar](repeating: 0, count: 256)
        while true {
            let count = readlinkat(rawValue, name, &buffer, buffer.count)
            if count < 0 {
                if errno == ENOENT { return nil }
                throw POSIXTransactionError.operationFailed(errno)
            }
            if count < buffer.count {
                return String(bytes: buffer.prefix(Int(count)).map(UInt8.init), encoding: .utf8)
            }
            buffer = [CChar](repeating: 0, count: buffer.count * 2)
        }
    }

    func restoreOwnedDirectory(
        _ owned: POSIXOwnedDirectory,
        to publicName: String
    ) throws -> Bool {
        try validateComponent(owned.name)
        try validateComponent(publicName)
        guard let quarantined = try metadata(for: owned.name) else {
            return false
        }
        guard quarantined.st_mode & S_IFMT == S_IFDIR,
              POSIXFileIdentity(quarantined) == owned.identity,
              POSIXFileIdentity(try owned.directory.metadata())
                == owned.identity else {
            throw POSIXTransactionError.ownershipChanged
        }
        guard try metadata(for: publicName) == nil else { return false }
        guard renameatx_np(
            rawValue,
            owned.name,
            rawValue,
            publicName,
            UInt32(RENAME_EXCL)
        ) == 0 else {
            if errno == EEXIST { return false }
            throw POSIXTransactionError.operationFailed(errno)
        }
        guard let restored = try metadata(for: publicName),
              restored.st_mode & S_IFMT == S_IFDIR,
              POSIXFileIdentity(restored) == owned.identity else {
            throw POSIXTransactionError.ownershipChanged
        }
        try sync()
        return true
    }

    func entryNames(withPrefix prefix: String) throws -> [String] {
        guard !prefix.isEmpty, !prefix.contains("/") else {
            throw POSIXTransactionError.unsafePath
        }
        return try entryNames().filter { $0.hasPrefix(prefix) }
    }

    func sync() throws {
        guard fsync(rawValue) == 0 else {
            throw POSIXTransactionError.operationFailed(errno)
        }
    }

    func exchange(_ firstName: String, with secondName: String) throws {
        try validateComponent(firstName)
        try validateComponent(secondName)
        guard renameatx_np(
            rawValue,
            firstName,
            rawValue,
            secondName,
            UInt32(RENAME_SWAP)
        ) == 0 else {
            throw POSIXTransactionError.operationFailed(errno)
        }
    }

    private func createGuardEntry() throws -> (
        name: String,
        identity: POSIXFileIdentity
    ) {
        for _ in 0..<16 {
            let name = ".cleanup-guard-\(UUID().uuidString).tmp"
            let descriptor = openat(
                rawValue,
                name,
                O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
                0o600
            )
            if descriptor < 0 {
                if errno == EEXIST { continue }
                throw POSIXTransactionError.operationFailed(errno)
            }
            let file = POSIXFileDescriptor(descriptor)
            return (name, POSIXFileIdentity(try file.metadata()))
        }
        throw POSIXTransactionError.operationFailed(EEXIST)
    }

    private func unlinkPrivateEntryIfOwned(
        _ name: String,
        identity: POSIXFileIdentity
    ) throws {
        guard let metadata = try metadata(for: name) else { return }
        guard metadata.st_mode & S_IFMT == S_IFREG,
              POSIXFileIdentity(metadata) == identity else {
            throw POSIXTransactionError.ownershipChanged
        }
        guard unlinkat(rawValue, name, 0) == 0 else {
            if errno == ENOENT { return }
            throw POSIXTransactionError.operationFailed(errno)
        }
    }

    private func validateRecursiveDeviceBoundaries(
        rootDevice: dev_t,
        deviceBoundaryCheck: (
            _ rootDevice: dev_t,
            _ entryDevice: dev_t,
            _ name: String
        ) -> Bool
    ) throws {
        for name in try entryNames() {
            guard let captured = try metadata(for: name) else { continue }
            guard deviceBoundaryCheck(
                rootDevice,
                captured.st_dev,
                name
            ) else {
                throw POSIXTransactionError.deviceBoundary
            }
            if captured.st_mode & S_IFMT == S_IFDIR {
                let identity = POSIXFileIdentity(captured)
                let child = try openDirectory(name)
                let opened = try child.metadata()
                guard POSIXFileIdentity(opened) == identity else {
                    throw POSIXTransactionError.ownershipChanged
                }
                guard deviceBoundaryCheck(
                    rootDevice,
                    opened.st_dev,
                    name
                ) else {
                    throw POSIXTransactionError.deviceBoundary
                }
                try child.validateRecursiveDeviceBoundaries(
                    rootDevice: rootDevice,
                    deviceBoundaryCheck: deviceBoundaryCheck
                )
            }
        }
    }

    private func removeContentsRecursively(
        rootDevice: dev_t,
        deviceBoundaryCheck: (
            _ rootDevice: dev_t,
            _ entryDevice: dev_t,
            _ name: String
        ) -> Bool
    ) throws {
        for name in try entryNames() {
            guard let captured = try metadata(for: name) else { continue }
            guard deviceBoundaryCheck(
                rootDevice,
                captured.st_dev,
                name
            ) else {
                throw POSIXTransactionError.deviceBoundary
            }
            if captured.st_mode & S_IFMT == S_IFDIR {
                let identity = POSIXFileIdentity(captured)
                let child = try openDirectory(name)
                let opened = try child.metadata()
                guard POSIXFileIdentity(opened) == identity else {
                    throw POSIXTransactionError.ownershipChanged
                }
                guard deviceBoundaryCheck(
                    rootDevice,
                    opened.st_dev,
                    name
                ) else {
                    throw POSIXTransactionError.deviceBoundary
                }
                try child.removeContentsRecursively(
                    rootDevice: rootDevice,
                    deviceBoundaryCheck: deviceBoundaryCheck
                )
                guard let current = try metadata(for: name),
                      current.st_mode & S_IFMT == S_IFDIR,
                      POSIXFileIdentity(current) == identity else {
                    throw POSIXTransactionError.ownershipChanged
                }
                guard deviceBoundaryCheck(
                    rootDevice,
                    current.st_dev,
                    name
                ) else {
                    throw POSIXTransactionError.deviceBoundary
                }
                guard unlinkat(rawValue, name, AT_REMOVEDIR) == 0 else {
                    if errno == ENOENT { continue }
                    throw POSIXTransactionError.operationFailed(errno)
                }
            } else {
                guard let current = try metadata(for: name),
                      POSIXFileIdentity(current)
                        == POSIXFileIdentity(captured) else {
                    throw POSIXTransactionError.ownershipChanged
                }
                guard deviceBoundaryCheck(
                    rootDevice,
                    current.st_dev,
                    name
                ) else {
                    throw POSIXTransactionError.deviceBoundary
                }
                guard unlinkat(rawValue, name, 0) == 0 else {
                    if errno == ENOENT { continue }
                    throw POSIXTransactionError.operationFailed(errno)
                }
            }
        }
    }

    func entryNames() throws -> [String] {
        let duplicated = openat(
            rawValue,
            ".",
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard duplicated >= 0 else {
            throw POSIXTransactionError.operationFailed(errno)
        }
        guard let stream = fdopendir(duplicated) else {
            let code = errno
            _ = Darwin.close(duplicated)
            throw POSIXTransactionError.operationFailed(code)
        }
        defer { closedir(stream) }

        var names: [String] = []
        errno = 0
        while let entry = readdir(stream) {
            let length = Int(entry.pointee.d_namlen)
            let name = withUnsafePointer(
                to: entry.pointee.d_name
            ) { pointer in
                pointer.withMemoryRebound(
                    to: CChar.self,
                    capacity: length + 1
                ) {
                    String(cString: $0)
                }
            }
            if name != "." && name != ".." {
                names.append(name)
            }
            errno = 0
        }
        guard errno == 0 else {
            throw POSIXTransactionError.operationFailed(errno)
        }
        return names
    }

    private func validateComponent(_ component: String) throws {
        guard !component.isEmpty,
              component != ".",
              component != "..",
              !component.contains("/") else {
            throw POSIXTransactionError.unsafePath
        }
    }
}
