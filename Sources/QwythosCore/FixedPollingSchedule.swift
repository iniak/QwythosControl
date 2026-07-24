import Foundation

public struct FixedPollingSchedule: Sendable {
    private let interval: Duration
    private var deadline: ContinuousClock.Instant

    public init(
        startingAt start: ContinuousClock.Instant,
        interval: Duration
    ) {
        precondition(interval > .zero)
        self.interval = interval
        self.deadline = start
    }

    public mutating func nextDeadline(
        after observationCompletedAt: ContinuousClock.Instant
    ) -> ContinuousClock.Instant {
        deadline = deadline.advanced(by: interval)

        while deadline <= observationCompletedAt {
            deadline = deadline.advanced(by: interval)
        }

        return deadline
    }
}
