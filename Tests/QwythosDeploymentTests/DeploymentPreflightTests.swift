import Foundation
import XCTest
@testable import QwythosDeployment

final class DeploymentPreflightTests: XCTestCase {
    func testSystemProfileCreatesMissingRootThroughNoFollowAncestors() throws {
        let parent = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let root = parent.appending(path: "Application Support/Qwythos Control")
        defer { try? FileManager.default.removeItem(at: parent) }
        try FileManager.default.createDirectory(
            at: parent,
            withIntermediateDirectories: true
        )

        try SystemProfile().prepareRootForPreflight(root)

        var isDirectory: ObjCBool = false
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: root.path,
                isDirectory: &isDirectory
            )
        )
        XCTAssertTrue(isDirectory.boolValue)
    }

    func testSystemProfileRejectsSymlinkAncestorWithoutCreatingThroughIt() throws {
        let parent = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let outside = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer {
            try? FileManager.default.removeItem(at: parent)
            try? FileManager.default.removeItem(at: outside)
        }
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let symlink = parent.appending(path: "linked")
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: outside)
        let root = symlink.appending(path: "Qwythos Control")

        XCTAssertThrowsError(try SystemProfile().prepareRootForPreflight(root))
        XCTAssertThrowsError(try SystemProfile().availableCapacity(at: symlink))
        XCTAssertFalse(SystemProfile().isWritable(symlink))
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: outside.appending(path: "Qwythos Control").path
            )
        )
    }

    func testAutomaticContextUsesMemoryThresholds() throws {
        XCTAssertThrowsError(
            try PerformanceProfile.automatic(physicalMemory: 8 * 1_073_741_824)
        )
        XCTAssertEqual(
            try PerformanceProfile.automatic(physicalMemory: 16 * 1_073_741_824)
                .contextSize,
            8_192
        )
        XCTAssertEqual(
            try PerformanceProfile.automatic(physicalMemory: 24 * 1_073_741_824)
                .contextSize,
            16_384
        )
    }

    func testPreflightRejectsIntelAndInsufficientStorage() async {
        let preflight = DeploymentPreflight(
            profile: FakeSystemProfile(
                architecture: "x86_64",
                operatingSystem: .init(majorVersion: 14, minorVersion: 0, patchVersion: 0),
                physicalMemory: 16 * 1_073_741_824,
                availableCapacity: 7_999_999_999,
                writable: true
            ),
            portChecker: FakePortChecker(isAvailable: true)
        )

        let report = await preflight.run(
            root: URL(fileURLWithPath: "/tmp/root"),
            servicePort: 18_080
        )

        XCTAssertFalse(report.canDeploy)
        XCTAssertTrue(report.issues.contains(.unsupportedArchitecture("x86_64")))
        XCTAssertTrue(report.issues.contains(.insufficientStorage))
    }

    func testPreflightReportsEachFailedCheck() async {
        let preflight = DeploymentPreflight(
            profile: FakeSystemProfile(
                architecture: "x86_64",
                operatingSystem: .init(majorVersion: 12, minorVersion: 6, patchVersion: 0),
                physicalMemory: 15 * 1_073_741_824,
                availableCapacity: 7_999_999_999,
                writable: false
            ),
            portChecker: FakePortChecker(isAvailable: false)
        )

        let report = await preflight.run(
            root: URL(fileURLWithPath: "/tmp/root"),
            servicePort: 18_080
        )

        XCTAssertFalse(report.architectureSupported)
        XCTAssertFalse(report.operatingSystemSupported)
        XCTAssertFalse(report.memorySufficient)
        XCTAssertFalse(report.storageSufficient)
        XCTAssertFalse(report.rootWritable)
        XCTAssertFalse(report.portAvailable)
        XCTAssertEqual(
            Set(report.issues),
            [
                .unsupportedArchitecture("x86_64"),
                .unsupportedOperatingSystem(12),
                .insufficientMemory,
                .insufficientStorage,
                .unwritableRoot,
                .portUnavailable(18_080),
            ]
        )
    }

    func testPreflightAcceptsMinimumSupportedDevice() async {
        let preflight = DeploymentPreflight(
            profile: FakeSystemProfile(
                architecture: "arm64",
                operatingSystem: .init(majorVersion: 13, minorVersion: 0, patchVersion: 0),
                physicalMemory: 16 * 1_073_741_824,
                availableCapacity: 8_000_000_000,
                writable: true
            ),
            portChecker: FakePortChecker(isAvailable: true)
        )

        let report = await preflight.run(
            root: URL(fileURLWithPath: "/tmp/root"),
            servicePort: 18_080
        )

        XCTAssertTrue(report.canDeploy)
        XCTAssertTrue(report.issues.isEmpty)
    }
}
