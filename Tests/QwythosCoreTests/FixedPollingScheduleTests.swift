import XCTest
@testable import QwythosCore

final class FixedPollingScheduleTests: XCTestCase {
    func testRefreshDurationDoesNotShiftTheNextThreeSecondDeadline() {
        let clock = ContinuousClock()
        let start = clock.now
        var schedule = FixedPollingSchedule(
            startingAt: start,
            interval: .seconds(3)
        )

        let deadline = schedule.nextDeadline(
            after: start.advanced(by: .seconds(2))
        )

        XCTAssertEqual(start.duration(to: deadline), .seconds(3))
    }

    func testMissedDeadlinesAreSkippedWithoutCreatingCatchUpRefreshes() {
        let clock = ContinuousClock()
        let start = clock.now
        var schedule = FixedPollingSchedule(
            startingAt: start,
            interval: .seconds(3)
        )

        let deadline = schedule.nextDeadline(
            after: start.advanced(by: .seconds(7))
        )

        XCTAssertEqual(start.duration(to: deadline), .seconds(9))
    }
}
