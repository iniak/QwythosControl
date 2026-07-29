import Foundation
import XCTest
import QwythosCore
@testable import QwythosDeployment

final class RuntimeInstallerTests: XCTestCase {
    func testRejectsRuntimeArchiveWhoseDigestDoesNotMatchManifest() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let archive = try makeArchive(in: root)
        let manifest = RuntimeArtifact(
            version: "b10159",
            archive: DeploymentArtifact(
                filename: "runtime.tar.gz",
                sourceURL: URL(string: "https://example.com/runtime.tar.gz")!,
                size: 1,
                sha256: String(repeating: "0", count: 64)
            ),
            directoryName: "llama-b10159",
            serverRelativePath: "llama-server"
        )

        await XCTAssertThrowsErrorAsync {
            try await RuntimeInstaller(
                commandRunner: RuntimeCommandRunnerFake(
                    fileOutput: "Mach-O 64-bit executable arm64"
                )
            ).install(
                archive: archive,
                manifest: manifest,
                layout: InstallationLayout(root: root)
            )
        }
    }

    func testInstallPromotesValidatedRuntimeAndUpdatesCurrentLink() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let layout = InstallationLayout(root: root)
        let archive = try makeArchive(in: root)
        let runner = RuntimeCommandRunnerFake(fileOutput: "Mach-O 64-bit executable arm64")
        let installer = RuntimeInstaller(commandRunner: runner)

        try await installer.install(
            archive: archive,
            manifest: runtimeArtifact(version: "b10159", archive: archive),
            layout: layout
        )

        XCTAssertTrue(FileManager.default.fileExists(atPath: layout.runtimeServer(version: "b10159").path))
        XCTAssertEqual(
            try FileManager.default.destinationOfSymbolicLink(atPath: layout.runtimeCurrent.path),
            "versions/b10159"
        )
        XCTAssertTrue(runner.commands.contains { $0.executable.hasSuffix("/llama-b10159/llama-server") && $0.arguments == ["--version"] })
    }

    func testInstallRejectsSymlinkedRuntimeDirectoryWithoutMutatingItsTarget() async throws {
        let root = temporaryDirectory()
        let outside = temporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: outside)
        }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: root.appending(path: "runtime"),
            withDestinationURL: outside
        )
        let archive = try makeArchive(in: root)

        await XCTAssertThrowsErrorAsync {
            try await RuntimeInstaller(
                commandRunner: RuntimeCommandRunnerFake(
                    fileOutput: "Mach-O 64-bit executable arm64"
                )
            ).install(
                archive: archive,
                manifest: self.runtimeArtifact(version: "b10159", archive: archive),
                layout: InstallationLayout(root: root)
            )
        }

        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: outside.appending(path: "versions/b10159").path
            )
        )
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: outside.appending(path: "current").path)
        )
    }

    func testCommitAndRollbackRejectSymlinkedRuntimeDirectoryWithoutMutatingTarget() throws {
        let root = temporaryDirectory()
        let outside = temporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: outside)
        }
        let layout = InstallationLayout(root: root)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: outside.appending(path: ".replacement-backup"),
            withIntermediateDirectories: true
        )
        try FileManager.default.createSymbolicLink(
            atPath: layout.runtimeDirectory.path,
            withDestinationPath: outside.path
        )

        XCTAssertThrowsError(
            try RuntimeInstaller().commitCurrentRuntime(layout: layout)
        )
        XCTAssertThrowsError(
            try RuntimeInstaller().rollBackCurrentRuntime(
                to: "b10158",
                layout: layout
            )
        )
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: outside.appending(path: ".replacement-backup").path
            )
        )
    }

    func testValidationFailureLeavesExistingCurrentLinkUnchanged() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let layout = InstallationLayout(root: root)
        let oldRuntime = layout.runtimeVersion("b10158")
        try FileManager.default.createDirectory(at: oldRuntime, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: layout.runtimeDirectory, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: layout.runtimeCurrent,
            withDestinationURL: oldRuntime
        )

        let installer = RuntimeInstaller(
            commandRunner: RuntimeCommandRunnerFake(fileOutput: "Mach-O 64-bit executable x86_64")
        )

        let archive = try makeArchive(in: root, arm64: false)
        do {
            try await installer.install(
                archive: archive,
                manifest: runtimeArtifact(version: "b10159", archive: archive),
                layout: layout
            )
            XCTFail("Expected incompatible runtime validation to fail")
        } catch RuntimeInstallerError.invalidMachO {
            // Expected: the new runtime must not be promoted.
        }

        XCTAssertEqual(
            try FileManager.default.destinationOfSymbolicLink(atPath: layout.runtimeCurrent.path),
            oldRuntime.path
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: layout.runtimeVersion("b10159").path))
    }

    func testRejectsArchiveEntriesOutsideExpectedRootBeforeExtraction() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let layout = InstallationLayout(root: root)
        let archive = root.appending(path: "runtime.tar.gz")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data().write(to: archive)
        let installer = RuntimeInstaller(
            commandRunner: RuntimeCommandRunnerFake(
                fileOutput: "Mach-O 64-bit executable arm64",
                archiveListOutput: "-rwxr-xr-x 0 root wheel 0 Jan 1 00:00 ../outside/llama-server\n"
            )
        )

        do {
            try await installer.install(
                archive: archive,
                manifest: runtimeArtifact(version: "b10159", archive: archive),
                layout: layout
            )
            XCTFail("Expected unsafe archive listing to be rejected")
        } catch RuntimeInstallerError.unexpectedArchiveContents {
            // Expected: never hand a traversal archive to tar extraction.
        }

        XCTAssertFalse(FileManager.default.fileExists(atPath: layout.runtimeVersionsDirectory.path))
    }

    func testRejectsSymlinkTraversalBeforeExtraction() async throws {
        let root = try preparedRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let runner = RuntimeCommandRunnerFake(
            fileOutput: "Mach-O 64-bit executable arm64"
        )

        let source = root.appending(path: "unsafe-source")
        let runtime = source.appending(path: "llama-b10159")
        try FileManager.default.createDirectory(at: runtime, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: runtime.appending(path: "lib bad dylib"),
            withDestinationURL: URL(fileURLWithPath: "../../outside")
        )
        try createArchive(root: runtime, source: source, destination: root.appending(path: "runtime.tar.gz"))

        await assertUnsafeArchiveIsNotExtracted(root: root, runner: runner)
    }

    func testRejectsHardlinkTraversalBeforeExtraction() async throws {
        let root = try preparedRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try writeHardlinkTraversalArchive(to: root.appending(path: "runtime.tar.gz"))
        let runner = RuntimeCommandRunnerFake(
            fileOutput: "Mach-O 64-bit executable arm64",
            archiveListOutput: "hrwxr-xr-x 0 root wheel 0 Jan 1 00:00 llama-b10159/libbad.dylib link to ../../outside\n"
        )

        await assertUnsafeArchiveIsNotExtracted(root: root, runner: runner)
    }

    func testRejectsRuntimeWithoutDynamicLibraries() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let layout = InstallationLayout(root: root)
        let installer = RuntimeInstaller(
            commandRunner: RuntimeCommandRunnerFake(fileOutput: "Mach-O 64-bit executable arm64")
        )

        let archive = try makeArchive(in: root, includesDynamicLibrary: false)
        do {
            try await installer.install(
                archive: archive,
                manifest: runtimeArtifact(version: "b10159", archive: archive),
                layout: layout
            )
            XCTFail("Expected a runtime without dynamic libraries to be rejected")
        } catch RuntimeInstallerError.invalidDynamicLibrary {
            // Expected: the archive must contain its runtime dependencies.
        }
    }

    func testRollbackAtomicallyPointsCurrentAtPreviousVersion() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let layout = InstallationLayout(root: root)
        let oldRuntime = layout.runtimeVersion("b10158")
        let newRuntime = layout.runtimeVersion("b10159")
        try FileManager.default.createDirectory(at: oldRuntime, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: newRuntime, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: layout.runtimeCurrent, withDestinationURL: newRuntime)

        try RuntimeInstaller().rollBackCurrentRuntime(to: "b10158", layout: layout)

        XCTAssertEqual(
            try FileManager.default.destinationOfSymbolicLink(atPath: layout.runtimeCurrent.path),
            "versions/b10158"
        )
    }

    func testSameVersionReinstallCanRestorePreviousRuntime() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let layout = InstallationLayout(root: root)
        let archive = try makeArchive(in: root)
        let runner = RuntimeCommandRunnerFake(
            fileOutput: "Mach-O 64-bit executable arm64"
        )
        let installer = RuntimeInstaller(commandRunner: runner)

        try await installer.install(
            archive: archive,
            manifest: runtimeArtifact(version: "b10159", archive: archive),
            layout: layout
        )
        let marker = layout.runtimeVersion("b10159")
            .appending(path: "previous-marker")
        try Data("old".utf8).write(to: marker)

        try await installer.install(
            archive: archive,
            manifest: runtimeArtifact(version: "b10159", archive: archive),
            layout: layout
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))

        XCTAssertEqual(
            try FileManager.default.destinationOfSymbolicLink(
                atPath: layout.runtimeCurrent.path
            ),
            "versions/b10159"
        )

        try installer.rollBackCurrentRuntime(
            to: "b10159",
            layout: layout
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path))

        try await installer.install(
            archive: archive,
            manifest: runtimeArtifact(version: "b10159", archive: archive),
            layout: layout
        )
        try installer.commitCurrentRuntime(layout: layout)
        try installer.rollBackCurrentRuntime(
            to: "b10159",
            layout: layout
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
    }

    func testSameVersionInstallRepairsStaleReplacementBackupBeforeReplacing() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let layout = InstallationLayout(root: root)
        let stale = layout.runtimeDirectory.appending(path: ".replacement-backup")
        try FileManager.default.createDirectory(at: stale, withIntermediateDirectories: true)
        try Data("old".utf8).write(to: stale.appending(path: "marker"))

        let installer = RuntimeInstaller(commandRunner: RuntimeCommandRunnerFake(fileOutput: "Mach-O 64-bit executable arm64"))
        let archive = try makeArchive(in: root)
        try await installer.install(
            archive: archive,
            manifest: runtimeArtifact(version: "b10159", archive: archive),
            layout: layout
        )

        XCTAssertTrue(FileManager.default.fileExists(atPath: stale.appending(path: "marker").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: layout.runtimeVersion("b10159").appending(path: "marker").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: layout.runtimeVersion("b10159").path))
    }

    func testFailedCurrentReplacementRemovesOnlyNewVersionAndAllowsRetry() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let layout = InstallationLayout(root: root)
        let oldRuntime = layout.runtimeVersion("b10158")
        try FileManager.default.createDirectory(at: oldRuntime, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: layout.runtimeDirectory, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: layout.runtimeCurrent, withDestinationURL: oldRuntime)
        let archive = try makeArchive(in: root)
        let runner = RuntimeCommandRunnerFake(fileOutput: "Mach-O 64-bit executable arm64")

        do {
            try await RuntimeInstaller(commandRunner: runner, linkReplacer: FailingLinkReplacer()).install(
                archive: archive,
                manifest: runtimeArtifact(version: "b10159", archive: archive),
                layout: layout
            )
            XCTFail("Expected current-link replacement to fail")
        } catch LinkFailure.expected {
            XCTAssertFalse(FileManager.default.fileExists(atPath: layout.runtimeVersion("b10159").path))
            XCTAssertTrue(FileManager.default.fileExists(atPath: oldRuntime.path))
            XCTAssertEqual(
                try FileManager.default.destinationOfSymbolicLink(atPath: layout.runtimeCurrent.path),
                oldRuntime.path
            )
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        try await RuntimeInstaller(commandRunner: runner).install(
            archive: archive,
            manifest: runtimeArtifact(version: "b10159", archive: archive),
            layout: layout
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: layout.runtimeVersion("b10159").path))
    }

    private func runtimeArtifact(
        version: String,
        archive: URL
    ) -> RuntimeArtifact {
        RuntimeArtifact(
            version: version,
            archive: DeploymentArtifact(
                filename: "runtime.tar.gz",
                sourceURL: URL(string: "https://example.com/runtime.tar.gz")!,
                size: 1,
                sha256: try! SHA256Hasher().sha256(file: archive)
            ),
            directoryName: "llama-\(version)",
            serverRelativePath: "llama-server"
        )
    }

    private func makeArchive(
        in root: URL,
        includesDynamicLibrary: Bool = true,
        arm64: Bool = true
    ) throws -> URL {
        let source = root.appending(path: "archive-source")
        let runtimeRoot = source.appending(path: "llama-b10159")
        try FileManager.default.createDirectory(at: runtimeRoot, withIntermediateDirectories: true)
        let server = runtimeRoot.appending(path: "llama-server")
        try machO(withRPath: true, arm64: arm64).write(to: server)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: server.path)
        if includesDynamicLibrary {
            try machO(withRPath: false, arm64: arm64).write(to: runtimeRoot.appending(path: "libllama.dylib"))
        }

        let archive = root.appending(path: "runtime.tar.gz")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        process.arguments = ["--format", "ustar", "-czf", archive.path, "-C", source.path, runtimeRoot.lastPathComponent]
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        return archive
    }

    private func temporaryDirectory() -> URL {
        URL(fileURLWithPath: "/private/tmp", isDirectory: true)
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    }

    private func machO(withRPath: Bool, arm64: Bool) -> Data {
        var data = Data()
        func append(_ value: UInt32) {
            var little = value.littleEndian
            withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
        }
        append(0xFEED_FACF)
        append(arm64 ? 0x0100_000C : 0x0100_0007)
        append(0)
        append(2)
        append(withRPath ? 1 : 0)
        append(withRPath ? 28 : 0)
        append(0)
        append(0)
        if withRPath {
            append(0x8000_001C)
            append(28)
            append(12)
            data.append(contentsOf: "@loader_path\0".utf8)
            data.append(contentsOf: repeatElement(0, count: 4))
        }
        return data
    }

    private func preparedRoot() throws -> URL {
        let root = temporaryDirectory()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func createArchive(root: URL, source: URL, destination: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        process.arguments = ["--format", "ustar", "-czf", destination.path, "-C", source.path, root.lastPathComponent]
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
    }

    private func writeHardlinkTraversalArchive(to destination: URL) throws {
        var header = [UInt8](repeating: 0, count: 512)
        write("llama-b10159/lib bad dylib", into: &header, at: 0, count: 100)
        write("0000644\0", into: &header, at: 100, count: 8)
        write("0000000\0", into: &header, at: 108, count: 8)
        write("0000000\0", into: &header, at: 116, count: 8)
        write("00000000000\0", into: &header, at: 124, count: 12)
        write("00000000000\0", into: &header, at: 136, count: 12)
        for index in 148..<156 { header[index] = 32 }
        header[156] = 49
        write("../../outside", into: &header, at: 157, count: 100)
        write("ustar\0", into: &header, at: 257, count: 6)
        write("00", into: &header, at: 263, count: 2)
        let checksum = header.reduce(0, { $0 + Int($1) })
        write(String(format: "%06o\0 ", checksum), into: &header, at: 148, count: 8)

        let raw = destination.deletingLastPathComponent().appending(path: "unsafe.tar")
        var archive = Data(header)
        archive.append(Data(repeating: 0, count: 1024))
        try archive.write(to: raw)
        defer { try? FileManager.default.removeItem(at: raw) }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/gzip")
        process.arguments = ["-c", raw.path]
        let output = Pipe()
        process.standardOutput = output
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        try output.fileHandleForReading.readDataToEndOfFile().write(to: destination)
    }

    private func write(_ value: String, into bytes: inout [UInt8], at offset: Int, count: Int) {
        for (index, byte) in value.utf8.prefix(count).enumerated() {
            bytes[offset + index] = byte
        }
    }

    private func assertUnsafeArchiveIsNotExtracted(
        root: URL,
        runner: RuntimeCommandRunnerFake
    ) async {
        let archive = root.appending(path: "runtime.tar.gz")
        do {
            try await RuntimeInstaller(commandRunner: runner).install(
                archive: archive,
                manifest: runtimeArtifact(version: "b10159", archive: archive),
                layout: InstallationLayout(root: root)
            )
            XCTFail("Expected unsafe archive to be rejected")
        } catch RuntimeInstallerError.unexpectedArchiveContents {
            XCTAssertFalse(runner.commands.contains { $0.arguments.contains("-xzf") })
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }
}

private func XCTAssertThrowsErrorAsync(
    _ expression: @escaping () async throws -> Void,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        try await expression()
        XCTFail("Expected an error", file: file, line: line)
    } catch {
    }
}

private final class RuntimeCommandRunnerFake: CommandRunning, @unchecked Sendable {
    struct Command: Equatable {
        let executable: String
        let arguments: [String]
    }

    private let fileOutput: String
    private let archiveListOutput: String?
    private let lock = NSLock()
    private var recordedCommands: [Command] = []

    init(fileOutput: String, archiveListOutput: String? = nil) {
        self.fileOutput = fileOutput
        self.archiveListOutput = archiveListOutput
    }

    var commands: [Command] {
        lock.withLock { recordedCommands }
    }

    func run(_ command: LaunchCommand) async -> CommandResult {
        let executable = URL(fileURLWithPath: command.executable)
        let arguments = command.arguments
        lock.withLock {
            recordedCommands.append(Command(executable: executable.path, arguments: arguments))
        }

        if executable.path == "/usr/bin/file" {
            return CommandResult(exitCode: 0, output: fileOutput)
        }
        if arguments.first == "-tvzf", let archiveListOutput {
            return CommandResult(exitCode: 0, output: archiveListOutput)
        }
        if executable.path == "/usr/bin/otool" {
            let serverPath = arguments.last ?? "llama-server"
            return CommandResult(
                exitCode: 0,
                output: "\(serverPath):\n\t@rpath/libllama.dylib (compatibility version 0.0.0, current version 0.0.0)\n"
            )
        }
        if arguments.last == "--version" {
            return CommandResult(exitCode: 0, output: "b10159")
        }

        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        do {
            try process.run()
        } catch {
            return CommandResult(exitCode: -1, output: error.localizedDescription)
        }
        process.waitUntilExit()
        let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        return CommandResult(exitCode: process.terminationStatus, output: text)
    }
}

private enum LinkFailure: Error {
    case expected
}

private struct FailingLinkReplacer: RuntimeCurrentLinkReplacing {
    func replaceCurrentLink(with destination: URL, layout: InstallationLayout) throws {
        throw LinkFailure.expected
    }
}
