import Darwin
import Foundation
import XCTest
@testable import QwythosDeployment

final class SHA256HasherTests: XCTestCase {
    func testHashesFileWithoutLoadingWholeFile() throws {
        let url = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString)
        try Data("abc".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        XCTAssertEqual(
            try SHA256Hasher().sha256(file: url),
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        )
    }

    func testURLHashingStopsWhenTaskIsAlreadyCancelled() async throws {
        let url = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString)
        try Data(repeating: 0x61, count: 1_048_577).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let result = await Task {
            withUnsafeCurrentTask { task in
                task?.cancel()
            }
            return try SHA256Hasher().sha256(file: url)
        }.result

        guard case .failure(let error) = result else {
            return XCTFail("Expected hashing to stop for a cancelled task")
        }
        XCTAssertTrue(error is CancellationError)
    }

    func testDescriptorHashingStopsWhenTaskIsAlreadyCancelled() async throws {
        let url = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString)
        try Data(repeating: 0x61, count: 1_048_577).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let descriptor = open(url.path, O_RDONLY | O_CLOEXEC)
        guard descriptor >= 0 else {
            return XCTFail("Unable to open hashing fixture")
        }
        defer { _ = close(descriptor) }

        let result = await Task {
            withUnsafeCurrentTask { task in
                task?.cancel()
            }
            return try SHA256Hasher().sha256(fileDescriptor: descriptor)
        }.result

        guard case .failure(let error) = result else {
            return XCTFail("Expected hashing to stop for a cancelled task")
        }
        XCTAssertTrue(error is CancellationError)
    }
}
