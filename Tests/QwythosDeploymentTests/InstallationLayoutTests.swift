import Foundation
import XCTest
@testable import QwythosDeployment

final class InstallationLayoutTests: XCTestCase {
    func testBuildsAllManagedPathsUnderSelectedRoot() throws {
        let root = URL(fileURLWithPath: "/tmp/Qwythos Root")
        let layout = InstallationLayout(root: root)

        XCTAssertEqual(layout.configDirectory, root.appending(path: "config"))
        XCTAssertEqual(layout.downloadsDirectory, root.appending(path: "downloads"))
        XCTAssertEqual(layout.logsDirectory, root.appending(path: "logs"))
        XCTAssertEqual(layout.modelsDirectory, root.appending(path: "models"))
        XCTAssertEqual(layout.runtimeDirectory, root.appending(path: "runtime"))
        XCTAssertEqual(layout.runtimeVersionsDirectory, root.appending(path: "runtime/versions"))
        XCTAssertEqual(layout.runtimeCurrent, root.appending(path: "runtime/current"))
        XCTAssertEqual(layout.stagingDirectory, root.appending(path: "staging"))
        XCTAssertEqual(layout.deploymentRecord, root.appending(path: "config/deployment.json"))
        XCTAssertEqual(
            layout.runtimeCleanupTombstone,
            root.appending(path: "config/runtime-cleanup.json")
        )
        XCTAssertEqual(layout.apiKeyFile, root.appending(path: "config/api-keys.txt"))
        XCTAssertEqual(layout.legacyPlistBackup, root.appending(path: "config/legacy-launch-agent.plist"))
        XCTAssertEqual(
            layout.modelFile,
            root.appending(path: "models/Qwythos-9B-Claude-Mythos-5-1M-uncensored-heretic-Q4_K_M.gguf")
        )
        XCTAssertEqual(layout.runtimeVersion("b10159"), root.appending(path: "runtime/versions/b10159"))
        XCTAssertEqual(
            layout.runtimeServer(version: "b10159"),
            root.appending(path: "runtime/versions/b10159/llama-server")
        )
        let runtimeArchive = DeploymentArtifact(
            filename: "llama-b10159-bin-macos-arm64.tar.gz",
            sourceURL: URL(string: "https://example.com/runtime.tar.gz")!,
            size: 1,
            sha256: String(repeating: "a", count: 64)
        )
        XCTAssertEqual(
            layout.partialFile(for: runtimeArchive),
            root.appending(path: "downloads/llama-b10159-bin-macos-arm64.tar.gz.partial")
        )
        XCTAssertNoThrow(try layout.requireManaged(layout.modelFile))
        XCTAssertThrowsError(
            try layout.requireManaged(URL(fileURLWithPath: "/tmp/outside"))
        )
    }

    func testRejectsRootForDestructiveOperations() {
        let root = URL(fileURLWithPath: "/tmp/Qwythos Root")
        let layout = InstallationLayout(root: root)

        XCTAssertThrowsError(try layout.requireManaged(root))
    }

    func testLocatorRejectsNoncanonicalCustomVolumeRoot() throws {
        let supportDirectory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: supportDirectory) }
        let root = URL(fileURLWithPath: "/Volumes/Qwythos Disk/../Qwythos Disk")

        let locator = InstallationLocator(supportDirectory: supportDirectory)
        XCTAssertThrowsError(
            try locator.save(InstallationLocation(root: root))
        )
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: locator.fileURL.path)
        )
    }

    func testLocatorReturnsUnavailableVolumeWithoutRewritingIt() throws {
        let supportDirectory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: supportDirectory) }
        let root = URL(fileURLWithPath: "/Volumes/Qwythos Missing")
        let locator = InstallationLocator(supportDirectory: supportDirectory)
        try locator.save(InstallationLocation(root: root))

        let reloaded = try locator.load()

        XCTAssertEqual(reloaded?.root, root.standardizedFileURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: locator.fileURL.path))
    }

    func testDeploymentOptionsAcceptSameRootSpelledDifferently() throws {
        let layout = InstallationLayout(root: URL(fileURLWithPath: "/tmp/Qwythos Root"))
        let options = DeploymentOptions(
            root: URL(fileURLWithPath: "/tmp/Qwythos Root/", isDirectory: true),
            contextSize: 8_192,
            accessMode: .local
        )

        XCTAssertNoThrow(try options.validate(for: layout))
        XCTAssertThrowsError(
            try DeploymentOptions(
                root: URL(fileURLWithPath: "/tmp/Other Root"),
                contextSize: 8_192,
                accessMode: .local
            ).validate(for: layout)
        ) { error in
            XCTAssertEqual(error as? DeploymentOptionsError, .rootDoesNotMatchLayout)
        }
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    }
}
