import Darwin
import Foundation
import XCTest
@testable import QwythosDeployment

final class POSIXFileTransactionTests: XCTestCase {
    func testQuarantinesCapturedDirectoryAtPreselectedName() throws {
        let rootURL = canonicalTemporaryDirectory()
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let root = try POSIXDirectoryDescriptor.openOrCreateRoot(rootURL)
        let versions = try root.openDirectory("versions", createMode: 0o700)
        let source = try versions.openDirectory("b10159", createMode: 0o700)
        let identity = POSIXFileIdentity(try source.metadata())
        let quarantineName = ".qwythos-runtime-cleanup-\(UUID().uuidString)"

        let owned = try XCTUnwrap(
            versions.quarantineDirectoryIfOwned(
                "b10159",
                identity: identity,
                quarantineName: quarantineName
            )
        )

        XCTAssertEqual(owned.name, quarantineName)
        XCTAssertNil(try versions.metadata(for: "b10159"))
        XCTAssertEqual(
            try versions.metadata(for: quarantineName)
                .map(POSIXFileIdentity.init),
            identity
        )
    }

    func testRecursiveRemovalRefusesInjectedDeviceBoundary() throws {
        let rootURL = canonicalTemporaryDirectory()
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let root = try POSIXDirectoryDescriptor.openOrCreateRoot(rootURL)
        let versions = try root.openDirectory("versions", createMode: 0o700)
        let source = try versions.openDirectory("b10159", createMode: 0o700)
        _ = try source.openDirectory("mounted-boundary", createMode: 0o700)
        let identity = POSIXFileIdentity(try source.metadata())
        let owned = try XCTUnwrap(
            versions.quarantineDirectoryIfOwned(
                "b10159",
                identity: identity,
                quarantineName: ".quarantine-\(UUID().uuidString)"
            )
        )

        XCTAssertThrowsError(
            try versions.removeOwnedDirectoryTree(
                owned,
                deviceBoundaryCheck: { rootDevice, entryDevice, name in
                    name != "mounted-boundary" && rootDevice == entryDevice
                }
            )
        ) { error in
            XCTAssertEqual(
                error as? POSIXTransactionError,
                .deviceBoundary
            )
        }
        XCTAssertNotNil(try versions.metadata(for: owned.name))
    }

    func testRecursiveRemovalDeletesValidatedNonemptyTree() throws {
        let rootURL = canonicalTemporaryDirectory()
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let root = try POSIXDirectoryDescriptor.openOrCreateRoot(rootURL)
        let versions = try root.openDirectory("versions", createMode: 0o700)
        let source = try versions.openDirectory("b10159", createMode: 0o700)
        let nested = try source.openDirectory("nested", createMode: 0o700)
        let file = try nested.openFile(
            "payload",
            flags: O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW,
            mode: 0o600
        )
        try file.closeChecked()
        let identity = POSIXFileIdentity(try source.metadata())
        let owned = try XCTUnwrap(
            versions.quarantineDirectoryIfOwned(
                "b10159",
                identity: identity,
                quarantineName: ".quarantine-\(UUID().uuidString)"
            )
        )

        try versions.removeOwnedDirectoryTree(owned)

        XCTAssertNil(try versions.metadata(for: owned.name))
    }

    private func canonicalTemporaryDirectory() -> URL {
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
        )
    }
}
