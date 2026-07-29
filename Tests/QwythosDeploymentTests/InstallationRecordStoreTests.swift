import Darwin
import Foundation
import XCTest
@testable import QwythosDeployment

final class InstallationRecordStoreTests: XCTestCase {
    func testLoadRejectsMissingRootReachedThroughAncestorSymlink() throws {
        let container = try makeRoot()
        defer { try? FileManager.default.removeItem(at: container) }
        let link = container.appending(path: "linked-ancestor")
        try FileManager.default.createSymbolicLink(
            atPath: link.path,
            withDestinationPath: container
                .appending(path: "missing-target")
                .path
        )
        let layout = InstallationLayout(
            root: link.appending(path: "managed")
        )

        XCTAssertThrowsError(
            try InstallationRecordStore().load(layout: layout)
        ) { error in
            XCTAssertEqual(
                error as? InstallationRecordStoreError,
                .unsafeRecordPath
            )
        }
    }

    func testSaveRejectsSymlinkRootWithoutCreatingConfigInTarget() throws {
        let container = try makeRoot()
        defer { try? FileManager.default.removeItem(at: container) }
        let target = container.appending(path: "target")
        let linkedRoot = container.appending(path: "managed")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            atPath: linkedRoot.path,
            withDestinationPath: target.path
        )
        let layout = InstallationLayout(root: linkedRoot)

        XCTAssertThrowsError(
            try InstallationRecordStore().save(
                makeRecord(root: layout.root, installedAt: Date(timeIntervalSince1970: 1)),
                layout: layout
            )
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: target.appending(path: "config").path
            )
        )
    }

    func testSaveRejectsRelativeRootWithoutCreatingConfigInResolvedTarget() throws {
        let container = try makeRoot()
        defer { try? FileManager.default.removeItem(at: container) }
        let base = URL(
            fileURLWithPath: container.path,
            isDirectory: true
        )
        let relativeRoot = URL(
            fileURLWithPath: "relative-managed",
            relativeTo: base
        )
        let resolvedRoot = relativeRoot.standardizedFileURL
        try FileManager.default.createDirectory(
            at: resolvedRoot,
            withIntermediateDirectories: true
        )
        let layout = InstallationLayout(root: relativeRoot)

        XCTAssertThrowsError(
            try InstallationRecordStore().save(
                makeRecord(
                    root: resolvedRoot,
                    installedAt: Date(timeIntervalSince1970: 1)
                ),
                layout: layout
            )
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: resolvedRoot.appending(path: "config").path
            )
        )
    }

    func testSaveAtomicallyReplacesExistingRecord() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let layout = InstallationLayout(root: root)
        let store = InstallationRecordStore()
        let first = makeRecord(
            root: root,
            contextSize: 4_096,
            installedAt: Date(timeIntervalSince1970: 1)
        )
        let second = makeRecord(
            root: root,
            contextSize: 16_384,
            installedAt: Date(timeIntervalSince1970: 2)
        )

        try store.save(first, layout: layout)
        let originalHandle = try FileHandle(forReadingFrom: layout.deploymentRecord)
        defer { try? originalHandle.close() }
        let originalIdentity = try fileIdentity(layout.deploymentRecord)

        try store.save(second, layout: layout)

        let originalData = try XCTUnwrap(try originalHandle.readToEnd())
        XCTAssertEqual(
            try JSONDecoder().decode(InstallationRecord.self, from: originalData),
            first
        )
        XCTAssertEqual(try store.load(layout: layout), second)
        XCTAssertNotEqual(try fileIdentity(layout.deploymentRecord), originalIdentity)
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(
                atPath: layout.configDirectory.path
            ),
            [layout.deploymentRecord.lastPathComponent]
        )
    }

    func testSaveDirectorySyncFailureRestoresDisplacedRecord() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let layout = InstallationLayout(root: root)
        let first = makeRecord(
            root: root,
            contextSize: 4_096,
            installedAt: Date(timeIntervalSince1970: 1)
        )
        let second = makeRecord(
            root: root,
            contextSize: 16_384,
            installedAt: Date(timeIntervalSince1970: 2)
        )
        try InstallationRecordStore().save(first, layout: layout)
        let store = InstallationRecordStore(
            syncDirectory: {
                _ in
                errno = EIO
                return -1
            }
        )

        XCTAssertThrowsError(try store.save(second, layout: layout))

        XCTAssertEqual(
            try InstallationRecordStore().load(layout: layout),
            first
        )
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(
                atPath: layout.configDirectory.path
            ),
            [layout.deploymentRecord.lastPathComponent]
        )
    }

    func testSavePreservesNonRegularEntryInsertedBeforePublish() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let layout = InstallationLayout(root: root)
        let outside = root.appending(path: "outside")
        let outsideData = Data("outside".utf8)
        try outsideData.write(to: outside)
        let store = InstallationRecordStore(
            beforeRecordPublish: { directoryDescriptor, name in
                guard symlinkat(
                    outside.path,
                    directoryDescriptor,
                    name
                ) == 0 else {
                    throw POSIXError(
                        POSIXErrorCode(rawValue: errno) ?? .EIO
                    )
                }
            }
        )

        XCTAssertThrowsError(
            try store.save(
                makeRecord(root: root, installedAt: Date(timeIntervalSince1970: 1)),
                layout: layout
            )
        )

        var metadata = stat()
        XCTAssertEqual(lstat(layout.deploymentRecord.path, &metadata), 0)
        XCTAssertEqual(metadata.st_mode & S_IFMT, S_IFLNK)
        XCTAssertEqual(
            try FileManager.default.destinationOfSymbolicLink(
                atPath: layout.deploymentRecord.path
            ),
            outside.path
        )
        XCTAssertEqual(try Data(contentsOf: outside), outsideData)
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(
                atPath: layout.configDirectory.path
            ),
            [layout.deploymentRecord.lastPathComponent]
        )
    }

    func testSavePreservesRegularEntryInsertedBeforePublish() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let layout = InstallationLayout(root: root)
        let replacement = Data("unrelated record replacement".utf8)
        let store = InstallationRecordStore(
            beforeRecordPublish: { directoryDescriptor, name in
                let descriptor = openat(
                    directoryDescriptor,
                    name,
                    O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
                    0o600
                )
                guard descriptor >= 0 else {
                    throw POSIXError(
                        POSIXErrorCode(rawValue: errno) ?? .EIO
                    )
                }
                defer { _ = close(descriptor) }
                let count = replacement.withUnsafeBytes {
                    write(descriptor, $0.baseAddress, $0.count)
                }
                guard count == replacement.count else {
                    throw POSIXError(.EIO)
                }
            }
        )

        XCTAssertThrowsError(
            try store.save(
                makeRecord(root: root, installedAt: Date(timeIntervalSince1970: 1)),
                layout: layout
            )
        )

        XCTAssertEqual(
            try Data(contentsOf: layout.deploymentRecord),
            replacement
        )
    }

    func testLoadReadsOpenedRecordWhenPathIsReplacedBeforeRead() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let layout = InstallationLayout(root: root)
        let original = makeRecord(
            root: root,
            contextSize: 4_096,
            installedAt: Date(timeIntervalSince1970: 1)
        )
        let replacement = makeRecord(
            root: root,
            contextSize: 32_768,
            installedAt: Date(timeIntervalSince1970: 2)
        )
        try InstallationRecordStore().save(original, layout: layout)
        let replacementName = ".replacement.json"
        try JSONEncoder().encode(replacement).write(
            to: layout.configDirectory.appending(path: replacementName)
        )
        let store = InstallationRecordStore(
            beforeRecordRead: { directoryDescriptor, name in
                guard renameat(
                    directoryDescriptor,
                    replacementName,
                    directoryDescriptor,
                    name
                ) == 0 else {
                    throw POSIXError(
                        POSIXErrorCode(rawValue: errno) ?? .EIO
                    )
                }
            }
        )

        XCTAssertEqual(try store.load(layout: layout), original)
        XCTAssertEqual(
            try InstallationRecordStore().load(layout: layout),
            replacement
        )
    }

    func testLoadReadsOpenedRecordWhenPathBecomesSymlinkBeforeRead() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let layout = InstallationLayout(root: root)
        let original = makeRecord(
            root: root,
            contextSize: 4_096,
            installedAt: Date(timeIntervalSince1970: 1)
        )
        let outside = root.appending(path: "outside.json")
        let replacement = makeRecord(
            root: root,
            contextSize: 32_768,
            installedAt: Date(timeIntervalSince1970: 2)
        )
        try InstallationRecordStore().save(original, layout: layout)
        let outsideData = try JSONEncoder().encode(replacement)
        try outsideData.write(to: outside)
        let store = InstallationRecordStore(
            beforeRecordRead: { directoryDescriptor, name in
                guard unlinkat(directoryDescriptor, name, 0) == 0,
                      symlinkat(
                        outside.path,
                        directoryDescriptor,
                        name
                      ) == 0 else {
                    throw POSIXError(
                        POSIXErrorCode(rawValue: errno) ?? .EIO
                    )
                }
            }
        )

        XCTAssertEqual(try store.load(layout: layout), original)

        var metadata = stat()
        XCTAssertEqual(lstat(layout.deploymentRecord.path, &metadata), 0)
        XCTAssertEqual(metadata.st_mode & S_IFMT, S_IFLNK)
        XCTAssertEqual(try Data(contentsOf: outside), outsideData)
    }

    func testRemoveRejectsDirectoryAtRecordPathWithoutDeletingIt() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let layout = InstallationLayout(root: root)
        let sentinel = layout.deploymentRecord.appending(path: "keep")
        try FileManager.default.createDirectory(
            at: layout.deploymentRecord,
            withIntermediateDirectories: true
        )
        try Data("keep".utf8).write(to: sentinel)

        XCTAssertThrowsError(
            try InstallationRecordStore().remove(layout: layout)
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: sentinel.path))
    }

    func testRemoveDirectorySyncFailureIsSurfaced() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let layout = InstallationLayout(root: root)
        try InstallationRecordStore().save(
            makeRecord(root: root, installedAt: Date(timeIntervalSince1970: 1)),
            layout: layout
        )
        let store = InstallationRecordStore(
            syncDirectory: {
                _ in
                errno = EIO
                return -1
            }
        )

        XCTAssertThrowsError(try store.remove(layout: layout))
        XCTAssertNil(try InstallationRecordStore().load(layout: layout))
    }

    private func makeRoot() throws -> URL {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let root = packageRoot
            .appending(path: ".build/InstallationRecordStoreTests")
            .appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        return root
    }

    private func makeRecord(
        root: URL,
        contextSize: Int = 8_192,
        installedAt: Date
    ) -> InstallationRecord {
        InstallationRecord(
            manifestSchemaVersion: 1,
            root: root,
            runtimeVersion: "runtime-1",
            modelSHA256: String(repeating: "a", count: 64),
            contextSize: contextSize,
            accessMode: .local,
            installedAt: installedAt
        )
    }

    private func fileIdentity(_ url: URL) throws -> POSIXFileIdentity {
        var metadata = stat()
        guard lstat(url.path, &metadata) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        return POSIXFileIdentity(metadata)
    }
}
