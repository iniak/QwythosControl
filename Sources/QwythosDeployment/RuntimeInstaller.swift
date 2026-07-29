import Darwin
import Foundation
import QwythosCore

public enum RuntimeInstallerError: Error, Equatable, Sendable {
    case archiveMissing
    case archiveDigestMismatch
    case invalidServerPath
    case unexpectedArchiveContents
    case escapedStagingDirectory
    case missingServer
    case unsafeRuntimeFile
    case invalidDynamicLibrary
    case invalidMachO
    case validationFailed(command: String, exitCode: Int32)
    case versionAlreadyInstalled(String)
    case previousRuntimeMissing(String)
    case replacementRecoveryFailed(String)
    case commandTimedOut
    case commandLaunchFailed(String)
}

public protocol RuntimeCurrentLinkReplacing: Sendable {
    func replaceCurrentLink(with destination: URL, layout: InstallationLayout) throws
}

public struct AtomicRuntimeCurrentLinkReplacer: RuntimeCurrentLinkReplacing {
    public init() {}

    public func replaceCurrentLink(with destination: URL, layout: InstallationLayout) throws {
        let version = destination.lastPathComponent
        guard InstallationRecord.isSafeRuntimeVersionComponent(version),
              destination.standardizedFileURL
                == layout.runtimeVersion(version).standardizedFileURL else {
            throw POSIXTransactionError.unsafePath
        }
        let root = try POSIXDirectoryDescriptor.openRoot(layout.root)
        let runtime = try root.openDirectory("runtime", createMode: 0o700)
        let versions = try runtime.openDirectory("versions", createMode: 0o700)
        guard let metadata = try versions.metadata(for: version),
              metadata.st_mode & S_IFMT == S_IFDIR else {
            throw RuntimeInstallerError.previousRuntimeMissing(version)
        }
        try runtime.replaceSymbolicLink(
            "current",
            withRelativeTarget: "versions/\(version)"
        )
    }
}

public struct RuntimeInstaller: RuntimeInstalling, Sendable {
    public static let commandTimeout: Duration = .seconds(60)

    private let commandRunner: any CommandRunning
    private let linkReplacer: any RuntimeCurrentLinkReplacing
    private let hasher: any FileHashing

    public init(
        commandRunner: any CommandRunning = SystemCommandRunner(timeout: commandTimeout),
        linkReplacer: any RuntimeCurrentLinkReplacing = AtomicRuntimeCurrentLinkReplacer(),
        hasher: any FileHashing = SHA256Hasher()
    ) {
        self.commandRunner = commandRunner
        self.linkReplacer = linkReplacer
        self.hasher = hasher
    }

    public func install(
        archive: URL,
        manifest: RuntimeArtifact,
        layout: InstallationLayout
    ) async throws {
        let fileManager = FileManager.default
        let serverComponents = manifest.serverRelativePath.split(separator: "/").map(String.init)
        guard !serverComponents.isEmpty,
              !serverComponents.contains(where: { $0 == "." || $0 == ".." || $0.isEmpty }) else {
            throw RuntimeInstallerError.invalidServerPath
        }

        let pinnedArchive = try pinVerifiedArchive(
            archive,
            manifest: manifest,
            layout: layout
        )
        defer {
            try? pinnedArchive.parent.removeOwnedDirectoryTree(
                pinnedArchive.directory
            )
        }

        try TarArchiveInspector.inspect(
            archiveName: pinnedArchive.archiveName,
            directory: pinnedArchive.directory.directory,
            expectedRoot: manifest.directoryName
        )
        try extractArchive(
            named: pinnedArchive.archiveName,
            in: pinnedArchive.directory.directory
        )

        let extractedRoot = try pinnedArchive.directory.directory
            .openOwnedDirectoryIfPresent(manifest.directoryName)
        guard let extractedRoot else {
            throw RuntimeInstallerError.unexpectedArchiveContents
        }
        let extractedRootURL = try extractedRoot.directory.resolvedPath()
        try validateExtractedContents(
            staging: pinnedArchive.directory.directory,
            expectedRootName: manifest.directoryName,
            ignoredEntry: pinnedArchive.archiveName
        )

        let server = serverComponents.reduce(extractedRootURL) {
            $0.appending(path: $1)
        }
        guard isRegularNonSymlinkFile(server), fileManager.isExecutableFile(atPath: server.path) else {
            throw RuntimeInstallerError.missingServer
        }

        let serverMachO = try MachOInspector.inspect(server)
        guard serverMachO.isArm64, serverMachO.rpaths == ["@loader_path"] else {
            throw RuntimeInstallerError.invalidMachO
        }

        try await validateDynamicLibraries(server: server, root: extractedRootURL)

        let version = try await run(
            executable: server,
            arguments: ["--version"]
        )
        guard version.exitCode == 0 else {
            throw RuntimeInstallerError.validationFailed(command: "llama-server --version", exitCode: version.exitCode)
        }

        let root = try POSIXDirectoryDescriptor.openRoot(layout.root)
        let runtime = try root.openDirectory("runtime", createMode: 0o700)
        let versions = try runtime.openDirectory("versions", createMode: 0o700)
        try recoverReplacementBackup(
            runtime: runtime,
            versions: versions,
            version: manifest.version
        )

        let displacedExistingVersion: POSIXOwnedDirectory?
        if let existing = try versions.openOwnedDirectoryIfPresent(manifest.version) {
            displacedExistingVersion = try versions.moveOwnedDirectory(
                existing,
                to: runtime,
                name: ".replacement-backup"
            )
        } else {
            displacedExistingVersion = nil
        }
        var promotedVersion: POSIXOwnedDirectory?
        do {
            promotedVersion = try pinnedArchive.directory.directory.moveOwnedDirectory(
                extractedRoot,
                to: versions,
                name: manifest.version
            )
            try linkReplacer.replaceCurrentLink(
                with: layout.runtimeVersion(manifest.version),
                layout: layout
            )
        } catch let installationError {
            do {
                if let promotedVersion {
                    try versions.removeOwnedDirectoryTree(promotedVersion)
                }
                if let displacedExistingVersion {
                    _ = try runtime.moveOwnedDirectory(
                        displacedExistingVersion,
                        to: versions,
                        name: manifest.version
                    )
                }
            } catch {
                throw RuntimeInstallerError.replacementRecoveryFailed(
                    String(describing: error)
                )
            }
            throw installationError
        }
    }

    public func rollBackCurrentRuntime(to previousVersion: String, layout: InstallationLayout) throws {
        guard InstallationRecord.isSafeRuntimeVersionComponent(previousVersion) else {
            throw RuntimeInstallerError.previousRuntimeMissing(previousVersion)
        }
        let root = try POSIXDirectoryDescriptor.openRoot(layout.root)
        let runtime = try root.openDirectory("runtime")
        let versions = try runtime.openDirectory("versions")
        if let backup = try runtime.openOwnedDirectoryIfPresent(".replacement-backup") {
            guard try runtime.symbolicLinkTarget("current")
                == "versions/\(previousVersion)" else {
                throw RuntimeInstallerError.previousRuntimeMissing(previousVersion)
            }
            if let replaced = try versions.openOwnedDirectoryIfPresent(previousVersion) {
                try versions.removeOwnedDirectoryTree(replaced)
            }
            _ = try runtime.moveOwnedDirectory(
                backup,
                to: versions,
                name: previousVersion
            )
        }
        guard try versions.openOwnedDirectoryIfPresent(previousVersion) != nil else {
            throw RuntimeInstallerError.previousRuntimeMissing(previousVersion)
        }
        try linkReplacer.replaceCurrentLink(
            with: layout.runtimeVersion(previousVersion),
            layout: layout
        )
    }

    public func commitCurrentRuntime(layout: InstallationLayout) throws {
        let root = try POSIXDirectoryDescriptor.openRoot(layout.root)
        let runtime = try root.openDirectory("runtime")
        if let backup = try runtime.openOwnedDirectoryIfPresent(".replacement-backup") {
            try runtime.removeOwnedDirectoryTree(backup)
        }
    }

    private struct PinnedArchive {
        let archiveName: String
        let parent: POSIXDirectoryDescriptor
        let directory: POSIXOwnedDirectory
    }

    private func pinVerifiedArchive(
        _ archive: URL,
        manifest: RuntimeArtifact,
        layout: InstallationLayout
    ) throws -> PinnedArchive {
        _ = try layout.requireManaged(archive)
        let archiveParent = try POSIXDirectoryDescriptor.openRoot(
            archive.deletingLastPathComponent()
        )
        let archiveName = archive.lastPathComponent
        let source: POSIXFileDescriptor
        do {
            source = try archiveParent.openFile(
                archiveName,
                flags: O_RDONLY | O_NOFOLLOW
            )
        } catch POSIXTransactionError.notFound {
            throw RuntimeInstallerError.archiveMissing
        }

        let sourceMetadata = try source.metadata()
        guard sourceMetadata.st_mode & S_IFMT == S_IFREG else {
            throw RuntimeInstallerError.archiveMissing
        }
        let sourceIdentity = POSIXFileIdentity(sourceMetadata)
        let digest = try hasher.sha256(fileDescriptor: source.rawValue)
        let afterHash = try source.metadata()
        guard afterHash.st_mode & S_IFMT == S_IFREG,
              POSIXFileIdentity(afterHash) == sourceIdentity,
              let current = try archiveParent.metadata(for: archiveName),
              current.st_mode & S_IFMT == S_IFREG,
              POSIXFileIdentity(current) == sourceIdentity else {
            throw RuntimeInstallerError.archiveMissing
        }
        guard digest.caseInsensitiveCompare(manifest.archive.sha256) == .orderedSame else {
            throw RuntimeInstallerError.archiveDigestMismatch
        }

        let root = try POSIXDirectoryDescriptor.openRoot(layout.root)
        let staging = try root.openDirectory("staging", createMode: 0o700)
        let directory = try staging.createOwnedDirectory(
            prefix: ".runtime-install-",
            mode: 0o700
        )
        let name = "archive.tar.gz"
        do {
            let destination = try directory.directory.openFile(
                name,
                flags: O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW,
                mode: 0o600
            )
            let destinationIdentity = POSIXFileIdentity(
                try destination.metadata()
            )
            try copyArchive(
                from: source.rawValue,
                to: destination.rawValue
            )
            guard fsync(destination.rawValue) == 0 else {
                throw RuntimeInstallerError.archiveMissing
            }
            try destination.closeChecked()
            guard let copied = try directory.directory.metadata(for: name),
                  copied.st_mode & S_IFMT == S_IFREG,
                  POSIXFileIdentity(copied) == destinationIdentity else {
                throw RuntimeInstallerError.archiveMissing
            }
            return PinnedArchive(
                archiveName: name,
                parent: staging,
                directory: directory
            )
        } catch {
            try? staging.removeOwnedDirectoryTree(directory)
            throw error
        }
    }

    private func copyArchive(from source: Int32, to destination: Int32) throws {
        var buffer = [UInt8](repeating: 0, count: 1_048_576)
        var offset: off_t = 0
        while true {
            let count = buffer.withUnsafeMutableBytes {
                pread(source, $0.baseAddress, $0.count, offset)
            }
            if count < 0 {
                if errno == EINTR { continue }
                throw RuntimeInstallerError.archiveMissing
            }
            if count == 0 { return }
            var written = 0
            while written < count {
                let result = buffer.withUnsafeBytes {
                    Darwin.write(
                        destination,
                        $0.baseAddress!.advanced(by: written),
                        count - written
                    )
                }
                if result < 0 {
                    if errno == EINTR { continue }
                    throw RuntimeInstallerError.archiveMissing
                }
                guard result > 0 else {
                    throw RuntimeInstallerError.archiveMissing
                }
                written += result
            }
            offset += off_t(count)
        }
    }

    private func recoverReplacementBackup(
        runtime: POSIXDirectoryDescriptor,
        versions: POSIXDirectoryDescriptor,
        version: String
    ) throws {
        guard let backup = try runtime.openOwnedDirectoryIfPresent(
            ".replacement-backup"
        ) else { return }
        do {
            if try versions.openOwnedDirectoryIfPresent(version) != nil {
                try runtime.removeOwnedDirectoryTree(backup)
            } else {
                _ = try runtime.moveOwnedDirectory(
                    backup,
                    to: versions,
                    name: version
                )
            }
        } catch {
            throw RuntimeInstallerError.replacementRecoveryFailed(String(describing: error))
        }
    }

    private func isSafeLinkTarget(_ target: String) -> Bool {
        let components = target.split(separator: "/", omittingEmptySubsequences: false)
        return !target.hasPrefix("/")
            && !components.contains("")
            && !components.contains(".")
            && !components.contains("..")
    }

    private func run(executable: URL, arguments: [String]) async throws -> CommandResult {
        let result = await commandRunner.run(
            LaunchCommand(executable: executable.path, arguments: arguments)
        )
        if result.exitCode == -3 {
            throw RuntimeInstallerError.commandTimedOut
        }
        if result.exitCode == -2 {
            throw CancellationError()
        }
        if result.exitCode == -1 {
            throw RuntimeInstallerError.commandLaunchFailed(result.output)
        }
        return result
    }

    private func extractArchive(
        named archiveName: String,
        in directory: POSIXDirectoryDescriptor
    ) throws {
        try Task.checkCancellation()
        let process = try DescriptorWorkingDirectory.withDirectory(directory) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
            process.arguments = ["-xzf", archiveName, "-C", "."]
            process.standardError = Pipe()
            try process.run()
            return process
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw RuntimeInstallerError.validationFailed(
                command: "tar",
                exitCode: process.terminationStatus
            )
        }
        try Task.checkCancellation()
    }

    private func validateExtractedContents(
        staging: POSIXDirectoryDescriptor,
        expectedRootName: String,
        ignoredEntry: String
    ) throws {
        let contents = try staging.entryNames().filter { $0 != ignoredEntry }
        guard contents == [expectedRootName] else {
            throw RuntimeInstallerError.unexpectedArchiveContents
        }
    }

    private func validateDynamicLibraries(server: URL, root: URL) async throws {
        let result = try await run(
            executable: URL(fileURLWithPath: "/usr/bin/otool"),
            arguments: ["-L", server.path]
        )
        guard result.exitCode == 0 else {
            throw RuntimeInstallerError.validationFailed(command: "otool -L", exitCode: result.exitCode)
        }

        let dependencies = result.output.split(separator: "\n").dropFirst()
        guard !dependencies.isEmpty else { throw RuntimeInstallerError.invalidDynamicLibrary }
        for line in dependencies {
            let dependency = line.trimmingCharacters(in: .whitespaces)
                .split(separator: " ", maxSplits: 1).first.map(String.init) ?? ""
            if dependency.hasPrefix("/System/Library/") || dependency.hasPrefix("/usr/lib/") {
                continue
            }
            guard dependency.hasPrefix("@rpath/") else {
                throw RuntimeInstallerError.invalidDynamicLibrary
            }
            let relativePath = String(dependency.dropFirst("@rpath/".count))
            guard isSafeLinkTarget(relativePath) else {
                throw RuntimeInstallerError.invalidDynamicLibrary
            }
            let library = root.appending(path: relativePath)
            let resolvedLibrary = library.resolvingSymlinksInPath().standardizedFileURL
            guard isContained(resolvedLibrary, within: root), isRegularNonSymlinkFile(resolvedLibrary) else {
                throw RuntimeInstallerError.invalidDynamicLibrary
            }
            guard (try MachOInspector.inspect(resolvedLibrary)).isArm64 else {
                throw RuntimeInstallerError.invalidMachO
            }
        }
    }

    private func isRegularNonSymlinkFile(_ url: URL) -> Bool {
        var metadata = stat()
        guard lstat(url.path, &metadata) == 0 else { return false }
        return metadata.st_mode & S_IFMT == S_IFREG
    }

    private func validateContainedPath(_ candidate: URL, within root: URL) throws {
        guard isContained(candidate.resolvingSymlinksInPath().standardizedFileURL, within: root) else {
            throw RuntimeInstallerError.escapedStagingDirectory
        }
    }

    private func isContained(_ candidate: URL, within root: URL) -> Bool {
        let resolvedRoot = root.resolvingSymlinksInPath().standardizedFileURL.path
        let resolvedCandidate = candidate.resolvingSymlinksInPath().standardizedFileURL.path
        return resolvedCandidate == resolvedRoot || resolvedCandidate.hasPrefix(resolvedRoot + "/")
    }

}

private enum DescriptorWorkingDirectory {
    private static let lock = NSLock()

    static func withDirectory<T>(
        _ directory: POSIXDirectoryDescriptor,
        operation: () throws -> T
    ) throws -> T {
        lock.lock()
        defer { lock.unlock() }

        let original = Darwin.open(".", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard original >= 0 else {
            throw POSIXTransactionError.operationFailed(errno)
        }
        defer { _ = Darwin.close(original) }
        guard fchdir(directory.rawValue) == 0 else {
            throw POSIXTransactionError.operationFailed(errno)
        }
        defer { _ = fchdir(original) }
        return try operation()
    }
}

private enum TarArchiveInspector {
    static func inspect(
        archiveName: String,
        directory: POSIXDirectoryDescriptor,
        expectedRoot: String
    ) throws {
        let pipe = Pipe()
        let errorPipe = Pipe()
        let process = try DescriptorWorkingDirectory.withDirectory(directory) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/gzip")
            process.arguments = ["-dc", archiveName]
            process.standardOutput = pipe
            process.standardError = errorPipe
            try process.run()
            return process
        }
        let handle = pipe.fileHandleForReading
        var completed = false
        defer {
            try? handle.close()
            if !completed && process.isRunning { process.terminate() }
            process.waitUntilExit()
        }

        while true {
            let header = try readExactly(512, from: handle)
            if header.allSatisfy({ $0 == 0 }) { break }
            guard validChecksum(header),
                  let name = string(header, offset: 0, count: 100),
                  let prefix = string(header, offset: 345, count: 155),
                  let size = octal(header, offset: 124, count: 12) else {
                throw RuntimeInstallerError.unexpectedArchiveContents
            }
            let path = prefix.isEmpty ? name : "\(prefix)/\(name)"
            let type = header[156]
            guard safePath(path, root: expectedRoot), [0, 48, 49, 50, 53].contains(type) else {
                throw RuntimeInstallerError.unexpectedArchiveContents
            }
            if type == 49 || type == 50 {
                guard let target = string(header, offset: 157, count: 100), safeLinkTarget(target) else {
                    throw RuntimeInstallerError.unexpectedArchiveContents
                }
            }
            try discard(size + ((512 - size % 512) % 512), from: handle)
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let error = String(
                decoding: errorPipe.fileHandleForReading.readDataToEndOfFile(),
                as: UTF8.self
            )
            throw RuntimeInstallerError.commandLaunchFailed(error)
        }
        completed = true
    }

    private static func safePath(_ path: String, root: String) -> Bool {
        let normalized = path.hasSuffix("/") ? String(path.dropLast()) : path
        let components = normalized.split(separator: "/", omittingEmptySubsequences: false)
        return !normalized.hasPrefix("/") && components.first == Substring(root)
            && !components.contains("") && !components.contains(".") && !components.contains("..")
    }

    private static func safeLinkTarget(_ target: String) -> Bool {
        let components = target.split(separator: "/", omittingEmptySubsequences: false)
        return !target.hasPrefix("/") && !components.contains("")
            && !components.contains(".") && !components.contains("..")
    }

    private static func validChecksum(_ header: Data) -> Bool {
        guard let expected = octal(header, offset: 148, count: 8) else { return false }
        let actual = header.enumerated().reduce(0) { partial, item in
            partial + ((148..<156).contains(item.offset) ? 32 : Int(item.element))
        }
        return expected == actual
    }

    private static func string(_ data: Data, offset: Int, count: Int) -> String? {
        let bytes = data[offset..<(offset + count)].prefix { $0 != 0 }
        return String(bytes: bytes, encoding: .utf8)
    }

    private static func octal(_ data: Data, offset: Int, count: Int) -> Int? {
        let leading = data[offset..<(offset + count)].drop(while: { $0 == 0 || $0 == 32 })
        let bytes = Array(leading.reversed().drop(while: { $0 == 0 || $0 == 32 }).reversed())
        guard bytes.isEmpty || bytes.allSatisfy({ (48...55).contains($0) }) else { return nil }
        if bytes.isEmpty { return 0 }
        return bytes.reduce(0) { partial, byte in partial * 8 + Int(byte - 48) }
    }

    private static func readExactly(_ count: Int, from handle: FileHandle) throws -> Data {
        var data = Data()
        while data.count < count {
            guard let chunk = try handle.read(upToCount: count - data.count), !chunk.isEmpty else {
                throw RuntimeInstallerError.unexpectedArchiveContents
            }
            data.append(chunk)
        }
        return data
    }

    private static func discard(_ count: Int, from handle: FileHandle) throws {
        var remaining = count
        while remaining > 0 {
            let chunk = try readExactly(min(remaining, 32 * 1024), from: handle)
            remaining -= chunk.count
        }
    }
}

private struct MachOInfo {
    let isArm64: Bool
    let rpaths: [String]
}

private enum MachOInspector {
    static func inspect(_ url: URL) throws -> MachOInfo {
        guard let data = try? Data(contentsOf: url), data.count >= 32 else {
            throw RuntimeInstallerError.invalidMachO
        }
        return try inspectSlice(data, offset: 0)
    }

    private static func inspectSlice(_ data: Data, offset: Int) throws -> MachOInfo {
        guard value32(data, offset, littleEndian: true) == 0xFEED_FACF,
              let cpu = value32(data, offset + 4, littleEndian: true),
              let commandCount = value32(data, offset + 16, littleEndian: true),
              let commandBytes = value32(data, offset + 20, littleEndian: true) else {
            throw RuntimeInstallerError.invalidMachO
        }
        var cursor = offset + 32
        let commandEnd = cursor + Int(commandBytes)
        guard commandEnd <= data.count else { throw RuntimeInstallerError.invalidMachO }
        var rpaths: [String] = []
        for _ in 0..<commandCount {
            guard let command = value32(data, cursor, littleEndian: true),
                  let size = value32(data, cursor + 4, littleEndian: true), size >= 8,
                  cursor + Int(size) <= commandEnd else { throw RuntimeInstallerError.invalidMachO }
            if command == 0x8000_001C,
               let pathOffset = value32(data, cursor + 8, littleEndian: true),
               pathOffset < size,
               let path = cString(data, offset: cursor + Int(pathOffset), end: cursor + Int(size)) {
                rpaths.append(path)
            }
            cursor += Int(size)
        }
        return MachOInfo(isArm64: cpu == 0x0100_000C, rpaths: rpaths)
    }

    private static func value32(_ data: Data, _ offset: Int, littleEndian: Bool) -> UInt32? {
        guard offset >= 0, offset + 4 <= data.count else { return nil }
        let bytes = data[offset..<(offset + 4)]
        let value = bytes.enumerated().reduce(UInt32(0)) { $0 | UInt32($1.element) << UInt32($1.offset * 8) }
        return littleEndian ? value : value.byteSwapped
    }

    private static func cString(_ data: Data, offset: Int, end: Int) -> String? {
        guard offset < end else { return nil }
        let bytes = data[offset..<end].prefix { $0 != 0 }
        return String(bytes: bytes, encoding: .utf8)
    }
}
