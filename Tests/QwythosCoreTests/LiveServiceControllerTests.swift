import Foundation
import XCTest
@testable import QwythosCore

final class LiveServiceControllerTests: XCTestCase {
    func testProductionControllerStopsAndRestartsModelService() async throws {
        guard ProcessInfo.processInfo.environment["QWYTHOS_LIVE_INTEGRATION"] == "1" else {
            throw XCTSkip("Set QWYTHOS_LIVE_INTEGRATION=1 to exercise the installed model service.")
        }

        let configuration = Self.productionConfiguration
        let controller = ServiceController(
            configuration: configuration,
            runner: SystemCommandRunner(),
            healthChecker: URLSessionHealthChecker()
        )
        let initialState = await controller.refresh()
        guard initialState == .running else {
            throw XCTSkip(
                "The live cycle requires an initially running service and will not change \(initialState)."
            )
        }

        addTeardownBlock {
            let restoredState = await Self.restoreServiceIfNeeded(configuration: configuration)
            XCTAssertEqual(
                restoredState,
                .running,
                "The model service must be running and healthy after live integration cleanup."
            )
        }

        try await controller.stop()

        let stoppedState = await Self.wait(
            for: .stopped,
            using: controller,
            timeout: .seconds(10)
        )
        XCTAssertEqual(stoppedState, .stopped)

        let controlJobResult = await SystemCommandRunner().run(
            LaunchCommand(
                executable: "/bin/launchctl",
                arguments: [
                    "print",
                    "\(configuration.domain)/com.local.qwythos-control",
                ]
            )
        )
        XCTAssertEqual(
            controlJobResult.exitCode,
            0,
            "The control job must remain loaded while the model service is stopped.\n\(controlJobResult.output)"
        )
        XCTAssertTrue(controlJobResult.output.contains("state = running"))

        try await controller.start()

        let runningState = await Self.wait(
            for: .running,
            using: controller,
            timeout: .seconds(90)
        )
        XCTAssertEqual(
            runningState,
            .running,
            "The restarted model service did not become loaded and healthy within 90 seconds."
        )
    }

    private static let productionConfiguration = ServiceConfiguration(
        uid: getuid(),
        label: "com.local.qwythos-9b",
        plistPath: "\(NSHomeDirectory())/Library/LaunchAgents/com.local.qwythos-9b.plist",
        healthURL: URL(string: "http://127.0.0.1:18080/health")!,
        chatURL: URL(string: "http://127.0.0.1:18080")!,
        logsPath: "\(NSHomeDirectory())/Codex/logs"
    )

    private static func restoreServiceIfNeeded(
        configuration: ServiceConfiguration
    ) async -> ServiceState {
        let controller = ServiceController(
            configuration: configuration,
            runner: SystemCommandRunner(),
            healthChecker: URLSessionHealthChecker()
        )

        var state = await controller.refresh()
        if state == .running {
            return state
        }

        if state == .stopped {
            try? await controller.start()
        }

        state = await wait(for: .running, using: controller, timeout: .seconds(90))
        if state == .running {
            return state
        }

        try? await controller.stop()
        _ = await wait(for: .stopped, using: controller, timeout: .seconds(10))
        try? await controller.start()

        return await wait(for: .running, using: controller, timeout: .seconds(90))
    }

    private static func wait(
        for expectedState: ServiceState,
        using controller: ServiceController,
        timeout: Duration
    ) async -> ServiceState {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        var state = await controller.refresh()

        while state != expectedState && clock.now < deadline {
            try? await Task.sleep(for: .seconds(1))
            state = await controller.refresh()
        }

        return state
    }
}
