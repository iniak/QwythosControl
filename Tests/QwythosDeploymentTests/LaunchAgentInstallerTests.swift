import Darwin
import Foundation
import XCTest
@testable import QwythosDeployment

final class LaunchAgentInstallerTests: XCTestCase {
    func testSharedModeBindsAllInterfacesAndRequiresKeyFile() throws {
        let layout = InstallationLayout(root: temporaryDirectory())
        let installer = LaunchAgentInstaller(launchAgentsDirectory: temporaryDirectory())

        let data = try installer.makePlist(
            layout: layout,
            options: .init(root: layout.root, contextSize: 16_384, accessMode: .shared),
            manifest: manifest
        )
        let plist = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        )
        let arguments = try XCTUnwrap(plist["ProgramArguments"] as? [String])
        let hostIndex = try XCTUnwrap(arguments.firstIndex(of: "--host"))
        let keyIndex = try XCTUnwrap(arguments.firstIndex(of: "--api-key-file"))

        XCTAssertEqual(arguments[hostIndex + 1], "0.0.0.0")
        XCTAssertEqual(arguments[keyIndex + 1], layout.apiKeyFile.path)
        XCTAssertFalse(arguments.contains(where: { $0.hasPrefix("api-key-") && $0 != "--api-key-file" }))
        XCTAssertEqual(arguments[0], layout.runtimeCurrent.appending(path: "llama-server").path)
        XCTAssertEqual(argumentValue("--model", in: arguments), layout.modelFile.path)
        XCTAssertEqual(argumentValue("--port", in: arguments), "18080")
        XCTAssertEqual(argumentValue("--ctx-size", in: arguments), "16384")
        XCTAssertEqual(argumentValue("--alias", in: arguments), "qwythos-9b")
        XCTAssertEqual(argumentValue("--parallel", in: arguments), "1")
        XCTAssertEqual(argumentValue("--n-gpu-layers", in: arguments), "99")
        XCTAssertTrue(arguments.contains("--jinja"))
        XCTAssertEqual(argumentValue("--temp", in: arguments), "0.6")
        XCTAssertEqual(argumentValue("--top-p", in: arguments), "0.95")
        XCTAssertEqual(argumentValue("--top-k", in: arguments), "20")
        XCTAssertEqual(argumentValue("--repeat-penalty", in: arguments), "1.05")
        XCTAssertEqual(plist["StandardOutPath"] as? String, layout.logsDirectory.appending(path: "llama-server.stdout.log").path)
        XCTAssertEqual(plist["StandardErrorPath"] as? String, layout.logsDirectory.appending(path: "llama-server.stderr.log").path)
        XCTAssertEqual(plist["RunAtLoad"] as? Bool, true)
        XCTAssertEqual(plist["KeepAlive"] as? Bool, true)
        XCTAssertEqual(plist["ProcessType"] as? String, "Interactive")
    }

    func testLocalModeBindsLoopbackAndDoesNotRequireKeyFile() throws {
        let layout = InstallationLayout(root: temporaryDirectory())
        let installer = LaunchAgentInstaller(launchAgentsDirectory: temporaryDirectory())

        let data = try installer.makePlist(
            layout: layout,
            options: .init(root: layout.root, contextSize: 8_192, accessMode: .local),
            manifest: manifest
        )
        let plist = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        )
        let arguments = try XCTUnwrap(plist["ProgramArguments"] as? [String])
        let hostIndex = try XCTUnwrap(arguments.firstIndex(of: "--host"))

        XCTAssertEqual(arguments[hostIndex + 1], "127.0.0.1")
        XCTAssertFalse(arguments.contains("--api-key-file"))
    }

    func testSharedInstallCreatesAProtectedKeyAndAtomicPlistInInjectedDirectory() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let layout = InstallationLayout(root: root)
        try FileManager.default.createDirectory(at: layout.modelsDirectory, withIntermediateDirectories: true)
        try Data().write(to: layout.modelFile)
        let launchAgents = root.appending(path: "LaunchAgents")
        let installer = LaunchAgentInstaller(launchAgentsDirectory: launchAgents)

        try installer.install(
            layout: layout,
            options: .init(root: root, contextSize: 4_096, accessMode: .shared),
            manifest: manifest
        )

        let key = try XCTUnwrap(APIKeyStore(fileURL: layout.apiKeyFile).load())
        XCTAssertEqual(key.count, 43)
        XCTAssertFalse(key.contains("="))
        let permissions = try FileManager.default.attributesOfItem(atPath: layout.apiKeyFile.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual((permissions?.intValue ?? 0) & 0o777, 0o600)
        XCTAssertTrue(FileManager.default.fileExists(atPath: installer.plistURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: layout.logsDirectory.path))
    }

    func testPrepareInstallationReturnsManagedPlistAndCreatesDependencies() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let layout = InstallationLayout(root: root)
        try FileManager.default.createDirectory(at: layout.modelsDirectory, withIntermediateDirectories: true)
        try Data("model".utf8).write(to: layout.modelFile)
        let launchAgents = root.appending(path: "LaunchAgents")
        let preparer: any LaunchAgentPreparing = LaunchAgentInstaller(
            launchAgentsDirectory: launchAgents
        )

        let preparedPlist = try preparer.prepareInstallation(
            layout: layout,
            options: .init(root: root, contextSize: 8_192, accessMode: .shared),
            manifest: manifest
        )

        let plist = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: preparedPlist, format: nil) as? [String: Any]
        )
        let arguments = try XCTUnwrap(plist["ProgramArguments"] as? [String])
        XCTAssertEqual(plist["Label"] as? String, "com.local.qwythos-9b")
        XCTAssertEqual(argumentValue("--model", in: arguments), layout.modelFile.path)
        XCTAssertEqual(argumentValue("--api-key-file", in: arguments), layout.apiKeyFile.path)
        XCTAssertNotNil(try APIKeyStore(fileURL: layout.apiKeyFile).load())
        XCTAssertTrue(FileManager.default.fileExists(atPath: launchAgents.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: layout.logsDirectory.path))
    }

    func testPrepareInstallationDoesNotReplaceExistingPlist() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let layout = InstallationLayout(root: root)
        try FileManager.default.createDirectory(at: layout.modelsDirectory, withIntermediateDirectories: true)
        try Data("model".utf8).write(to: layout.modelFile)
        let launchAgents = root.appending(path: "LaunchAgents")
        try FileManager.default.createDirectory(at: launchAgents, withIntermediateDirectories: true)
        let plistURL = launchAgents.appending(path: "\(LaunchAgentInstaller.defaultLabel).plist")
        let existingPlist = Data("legacy-plist".utf8)
        try existingPlist.write(to: plistURL)
        let preparer: any LaunchAgentPreparing = LaunchAgentInstaller(
            launchAgentsDirectory: launchAgents
        )

        _ = try preparer.prepareInstallation(
            layout: layout,
            options: .init(root: root, contextSize: 8_192, accessMode: .local),
            manifest: manifest
        )

        XCTAssertEqual(try Data(contentsOf: plistURL), existingPlist)
    }

    func testRejectsUnsupportedContextSize() {
        let layout = InstallationLayout(root: temporaryDirectory())
        XCTAssertThrowsError(
            try LaunchAgentInstaller(launchAgentsDirectory: temporaryDirectory()).makePlist(
                layout: layout,
                options: .init(root: layout.root, contextSize: 32_768, accessMode: .local),
                manifest: manifest
            )
        ) { error in
            XCTAssertEqual(error as? DeploymentOptionsError, .unsupportedContextSize(32_768))
        }
    }

    func testAPIKeyStoreRejectsInsecureAndMalformedExistingKeys() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appending(path: "api-keys.txt")
        let store = APIKeyStore(fileURL: file)
        _ = try store.generate()
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)
        XCTAssertThrowsError(try store.load())

        try Data("not-a-key\n".utf8).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        XCTAssertThrowsError(try store.load())
    }

    func testAPIKeyStoreRejectsNonCanonicalBase64URL() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        let file = root.appending(path: "api-keys.txt")
        try Data("\(String(repeating: "A", count: 42))B\n".utf8)
            .write(to: file)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: file.path
        )

        XCTAssertThrowsError(try APIKeyStore(fileURL: file).load()) {
            XCTAssertEqual(
                $0 as? APIKeyStoreError,
                .invalidStoredKey
            )
        }
    }

    func testAPIKeyStoreRejectsHardLinkedKey() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appending(path: "api-keys.txt")
        let alias = root.appending(path: "key-alias.txt")
        let store = APIKeyStore(fileURL: file)
        _ = try store.generate()
        try FileManager.default.linkItem(at: file, to: alias)

        XCTAssertThrowsError(try store.load()) {
            XCTAssertEqual(
                $0 as? APIKeyStoreError,
                .invalidStoredKey
            )
        }
    }

    func testAPIKeyStoreRejectsSymlinkedConfigDirectory() throws {
        let base = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let root = base.appending(path: "root")
        let outside = base.appending(path: "outside")
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: outside,
            withIntermediateDirectories: true
        )
        try FileManager.default.createSymbolicLink(
            at: root.appending(path: "config"),
            withDestinationURL: outside
        )

        XCTAssertThrowsError(
            try APIKeyStore(
                fileURL: root.appending(path: "config/api-keys.txt")
            ).generate()
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: outside.appending(path: "api-keys.txt").path
            )
        )
    }

    func testAPIKeyStoreRejectsPathReplacementDuringDescriptorRead() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appending(path: "api-keys.txt")
        let replacementName = "replacement-key.txt"
        let store = APIKeyStore(fileURL: file)
        _ = try store.generate()
        let replacement = canonicalKey(byte: 0x42)
        try Data("\(replacement)\n".utf8).write(
            to: root.appending(path: replacementName)
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: root.appending(path: replacementName).path
        )

        let swappingStore = APIKeyStore(
            fileURL: file,
            beforeKeyRead: { parent, name in
                guard renameat(
                    parent,
                    replacementName,
                    parent,
                    name
                ) == 0 else {
                    throw POSIXTransactionError.operationFailed(errno)
                }
            }
        )

        XCTAssertThrowsError(try swappingStore.load()) {
            XCTAssertEqual(
                $0 as? APIKeyStoreError,
                .invalidStoredKey
            )
        }
        XCTAssertEqual(
            try String(contentsOf: file, encoding: .utf8),
            "\(replacement)\n"
        )
    }

    func testPrepareInstallationRejectsSymlinkedLogsDirectory() throws {
        let base = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let root = base.appending(path: "root")
        let outside = base.appending(path: "outside")
        let layout = InstallationLayout(root: root)
        try FileManager.default.createDirectory(
            at: layout.modelsDirectory,
            withIntermediateDirectories: true
        )
        try Data("model".utf8).write(to: layout.modelFile)
        try FileManager.default.createDirectory(
            at: outside,
            withIntermediateDirectories: true
        )
        try FileManager.default.createSymbolicLink(
            at: layout.logsDirectory,
            withDestinationURL: outside
        )

        XCTAssertThrowsError(
            try LaunchAgentInstaller(
                launchAgentsDirectory: base.appending(path: "LaunchAgents")
            ).prepareInstallation(
                layout: layout,
                options: .init(
                    root: root,
                    contextSize: 8_192,
                    accessMode: .local
                ),
                manifest: manifest
            )
        )
    }

    private let manifest = DeploymentManifest(
        schemaVersion: 1,
        runtime: RuntimeArtifact(
            version: "b10159",
            archive: DeploymentArtifact(
                filename: "runtime.tar.gz",
                sourceURL: URL(string: "https://example.com/runtime.tar.gz")!,
                size: 1,
                sha256: String(repeating: "a", count: 64)
            ),
            directoryName: "llama-b10159",
            serverRelativePath: "llama-server"
        ),
        model: DeploymentArtifact(
            filename: InstallationLayout.modelFilename,
            sourceURL: URL(string: "https://example.com/model.gguf")!,
            size: 1,
            sha256: String(repeating: "b", count: 64)
        ),
        service: ServiceDefaults(label: "com.local.qwythos-9b", port: 18_080)
    )

    private func temporaryDirectory() -> URL {
        let temporaryPath = FileManager.default.temporaryDirectory.path
        guard let resolvedPath = realpath(temporaryPath, nil) else {
            preconditionFailure(
                "Could not resolve temporary directory: \(temporaryPath)"
            )
        }
        defer { free(resolvedPath) }
        return URL(
            fileURLWithPath: String(cString: resolvedPath),
            isDirectory: true
        ).appending(
            path: UUID().uuidString,
            directoryHint: .isDirectory
        )
    }

    private func argumentValue(_ flag: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
        return arguments[index + 1]
    }

    private func canonicalKey(byte: UInt8) -> String {
        Data(repeating: byte, count: 32)
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
