import XCTest
import QwythosCore

final class ServiceModelTests: XCTestCase {
    func testStateResolution() {
        XCTAssertEqual(ServiceState.resolve(jobLoaded: false, healthOK: false, lastError: nil), .stopped)
        XCTAssertEqual(ServiceState.resolve(jobLoaded: true, healthOK: false, lastError: nil), .starting)
        XCTAssertEqual(ServiceState.resolve(jobLoaded: true, healthOK: true, lastError: nil), .running)
        XCTAssertEqual(ServiceState.resolve(jobLoaded: false, healthOK: false, lastError: "boom"), .stopped)
        XCTAssertEqual(ServiceState.resolve(jobLoaded: true, healthOK: true, lastError: "old error"), .running)
    }

    func testServiceActionsExposeOperationSpecificProgressState() {
        XCTAssertEqual(ServiceAction.start.inProgressState, .starting)
        XCTAssertEqual(ServiceAction.stop.inProgressState, .stopping)
    }

    func testLaunchCommandsUseCurrentUserDomain() {
        let config = ServiceConfiguration(
            uid: 501,
            label: "com.local.qwythos-9b",
            plistPath: "/Users/iniak/Library/LaunchAgents/com.local.qwythos-9b.plist",
            healthURL: URL(string: "http://127.0.0.1:18080/health")!,
            chatURL: URL(string: "http://127.0.0.1:18080")!,
            logsPath: "/Users/iniak/Codex/logs"
        )
        XCTAssertEqual(config.startCommand.arguments, [
            "bootstrap", "gui/501",
            "/Users/iniak/Library/LaunchAgents/com.local.qwythos-9b.plist"
        ])
        XCTAssertEqual(config.stopCommand.arguments, [
            "bootout", "gui/501/com.local.qwythos-9b"
        ])
    }
}
