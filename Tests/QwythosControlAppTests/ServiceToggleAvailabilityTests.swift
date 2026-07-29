import XCTest
@testable import QwythosControlApp
import QwythosCore

final class ServiceToggleAvailabilityTests: XCTestCase {
    func testDeploymentActivityDisablesTheTrayServiceToggle() {
        XCTAssertTrue(
            AppDelegate.isServiceToggleEnabled(
                availableAction: .start,
                operationInProgress: false,
                deploymentBusy: false
            )
        )
        XCTAssertFalse(
            AppDelegate.isServiceToggleEnabled(
                availableAction: .start,
                operationInProgress: false,
                deploymentBusy: true
            )
        )
        XCTAssertFalse(
            AppDelegate.isServiceToggleEnabled(
                availableAction: .stop,
                operationInProgress: true,
                deploymentBusy: false
            )
        )
        XCTAssertFalse(
            AppDelegate.isServiceToggleEnabled(
                availableAction: nil,
                operationInProgress: false,
                deploymentBusy: false
            )
        )
    }
}
