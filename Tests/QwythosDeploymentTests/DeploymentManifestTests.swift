import Foundation
import XCTest
@testable import QwythosDeployment

final class DeploymentManifestTests: XCTestCase {
    func testLoadsManifestFromPackagedAppResourcesWithoutBundleModule() throws {
        let appResources = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
            .appending(path: "Qwythos Control.app/Contents/Resources", directoryHint: .isDirectory)
        let resourceBundle = appResources.appending(
            path: DeploymentManifest.resourceBundleName,
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(
            at: resourceBundle,
            withIntermediateDirectories: true
        )
        defer {
            try? FileManager.default.removeItem(
                at: appResources
                    .deletingLastPathComponent()
                    .deletingLastPathComponent()
                    .deletingLastPathComponent()
            )
        }
        let expected = Data(#"{"schemaVersion":1}"#.utf8)
        try expected.write(
            to: resourceBundle.appending(path: "deployment-manifest.json")
        )

        XCTAssertEqual(
            try DeploymentManifest.productionData(searching: [appResources]),
            expected
        )
    }

    func testMissingPackagedManifestThrowsInsteadOfTerminating() {
        let emptyResources = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)

        XCTAssertThrowsError(
            try DeploymentManifest.productionData(searching: [emptyResources])
        ) { error in
            XCTAssertEqual(error as? ManifestError, .missingResource)
        }
    }

    func testLoadsPinnedProductionManifest() throws {
        let manifest = try DeploymentManifest.load(
            data: DeploymentManifest.productionData()
        )

        XCTAssertEqual(manifest.schemaVersion, 1)
        XCTAssertEqual(manifest.runtime.version, "b10159")
        XCTAssertEqual(manifest.runtime.archive.filename, "llama-b10159-bin-macos-arm64.tar.gz")
        XCTAssertEqual(
            manifest.runtime.archive.sourceURL,
            URL(string: "https://github.com/ggml-org/llama.cpp/releases/download/b10159/llama-b10159-bin-macos-arm64.tar.gz")
        )
        XCTAssertEqual(manifest.runtime.size, 10_896_813)
        XCTAssertEqual(
            manifest.runtime.archive.sha256,
            "fa8710855b9432ed0df1917f3beba2ec68d6b57bbd45f4234bf33e6afa0c311c"
        )
        XCTAssertEqual(manifest.runtime.directoryName, "llama-b10159")
        XCTAssertEqual(manifest.runtime.serverRelativePath, "llama-server")
        XCTAssertEqual(
            manifest.model.filename,
            "Qwythos-9B-Claude-Mythos-5-1M-uncensored-heretic-Q4_K_M.gguf"
        )
        XCTAssertEqual(
            manifest.model.sourceURL,
            URL(string: "https://huggingface.co/llmfan46/Qwythos-9B-Claude-Mythos-5-1M-uncensored-heretic-GGUF/resolve/5a91ab33c680ecfbd6731810bba2c068cb8427df/Qwythos-9B-Claude-Mythos-5-1M-uncensored-heretic-Q4_K_M.gguf")
        )
        XCTAssertEqual(manifest.model.size, 6_216_967_936)
        XCTAssertEqual(
            manifest.model.sha256,
            "1ee1cd89574b1b2e57447d6dab8328a6c39b20d18557a322d928215a8a8a96de"
        )
        XCTAssertEqual(manifest.service.label, "com.local.qwythos-9b")
        XCTAssertEqual(manifest.service.port, 18_080)
    }

    func testRejectsUnknownSchemaVersion() {
        let data = Data(#"{"schemaVersion":2}"#.utf8)

        XCTAssertThrowsError(try DeploymentManifest.load(data: data))
    }

    func testRejectsManifestWithInvalidArtifactHash() {
        let data = Data("""
        {
          "schemaVersion": 1,
          "runtime": {
            "version": "b10159",
            "archive": {
              "filename": "runtime.tar.gz",
              "sourceURL": "https://example.com/runtime.tar.gz",
              "size": 1,
              "sha256": "not-a-sha256"
            },
            "directoryName": "runtime",
            "serverRelativePath": "bin/llama-server"
          },
          "model": {
            "filename": "model.gguf",
            "sourceURL": "https://example.com/model.gguf",
            "size": 1,
            "sha256": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
          },
          "service": {
            "label": "com.local.qwythos-9b",
            "port": 18080
          }
        }
        """.utf8)

        XCTAssertThrowsError(try DeploymentManifest.load(data: data)) { error in
            XCTAssertEqual(error as? ManifestError, .invalidSHA256("not-a-sha256"))
        }
    }

    func testRejectsUnicodeHexCharactersInArtifactHash() {
        let invalidHash = String(repeating: "ａ", count: 64)
        let data = Data("""
        {
          "schemaVersion": 1,
          "runtime": {
            "version": "b10159",
            "archive": {
              "filename": "runtime.tar.gz",
              "sourceURL": "https://example.com/runtime.tar.gz",
              "size": 1,
              "sha256": "\(invalidHash)"
            },
            "directoryName": "runtime",
            "serverRelativePath": "bin/llama-server"
          },
          "model": {
            "filename": "model.gguf",
            "sourceURL": "https://example.com/model.gguf",
            "size": 1,
            "sha256": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
          },
          "service": {
            "label": "com.local.qwythos-9b",
            "port": 18080
          }
        }
        """.utf8)

        XCTAssertThrowsError(try DeploymentManifest.load(data: data)) { error in
            XCTAssertEqual(error as? ManifestError, .invalidSHA256(invalidHash))
        }
    }
}
