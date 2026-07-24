import XCTest
import QwythosCore

final class ServiceControllerTests: XCTestCase {
    func testRefreshReportsRunningWhenJobAndHealthExist() async {
        let runner = FakeRunner(printExitCode: 0)
        let health = FakeHealthChecker(result: true)
        let controller = ServiceController(
            configuration: .test,
            runner: runner,
            healthChecker: health
        )

        let state = await controller.refresh()

        XCTAssertEqual(state, .running)
    }

    func testStartRunsBootstrapCommand() async throws {
        let runner = FakeRunner(printExitCode: 1)
        let controller = ServiceController(
            configuration: .test,
            runner: runner,
            healthChecker: FakeHealthChecker(result: false)
        )

        try await controller.start()

        let command = await runner.lastCommand()

        XCTAssertEqual(command, ServiceConfiguration.test.startCommand)
    }

    func testStopRunsBootoutCommand() async throws {
        let runner = FakeRunner(printExitCode: 0)
        let controller = ServiceController(
            configuration: .test,
            runner: runner,
            healthChecker: FakeHealthChecker(result: true)
        )

        try await controller.stop()

        let command = await runner.lastCommand()

        XCTAssertEqual(command, ServiceConfiguration.test.stopCommand)
    }

    func testStartThrowsWhenCommandFails() async {
        let runner = FakeRunner(printExitCode: 0, startExitCode: 1, startOutput: "bootstrap failed")
        let controller = ServiceController(
            configuration: .test,
            runner: runner,
            healthChecker: FakeHealthChecker(result: false)
        )

        do {
            try await controller.start()
            XCTFail("Expected start to throw")
        } catch let error as ServiceControlError {
            guard case .commandFailed("bootstrap failed") = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testStopThrowsWhenCommandFails() async {
        let runner = FakeRunner(printExitCode: 0, stopExitCode: 1, stopOutput: "bootout failed")
        let controller = ServiceController(
            configuration: .test,
            runner: runner,
            healthChecker: FakeHealthChecker(result: true)
        )

        do {
            try await controller.stop()
            XCTFail("Expected stop to throw")
        } catch let error as ServiceControlError {
            guard case .commandFailed("bootout failed") = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }
}

private actor FakeRunner: CommandRunning {
    private let printExitCode: Int32
    private let startExitCode: Int32
    private let stopExitCode: Int32
    private let startOutput: String
    private let stopOutput: String
    private var commands: [LaunchCommand] = []

    init(
        printExitCode: Int32,
        startExitCode: Int32 = 0,
        stopExitCode: Int32 = 0,
        startOutput: String = "",
        stopOutput: String = ""
    ) {
        self.printExitCode = printExitCode
        self.startExitCode = startExitCode
        self.stopExitCode = stopExitCode
        self.startOutput = startOutput
        self.stopOutput = stopOutput
    }

    func run(_ command: LaunchCommand) async -> CommandResult {
        commands.append(command)

        if command == ServiceConfiguration.test.printCommand {
            return CommandResult(exitCode: printExitCode, output: "")
        }
        if command == ServiceConfiguration.test.startCommand {
            return CommandResult(exitCode: startExitCode, output: startOutput)
        }
        return CommandResult(exitCode: stopExitCode, output: stopOutput)
    }

    func lastCommand() -> LaunchCommand? {
        commands.last
    }
}

private actor FakeHealthChecker: HealthChecking {
    private let result: Bool

    init(result: Bool) {
        self.result = result
    }

    func isHealthy(_ url: URL) async -> Bool {
        result
    }
}

private extension ServiceConfiguration {
    static let test = ServiceConfiguration(
        uid: 501,
        label: "com.local.qwythos-9b",
        plistPath: "/tmp/com.local.qwythos-9b.plist",
        healthURL: URL(string: "http://127.0.0.1:18080/health")!,
        chatURL: URL(string: "http://127.0.0.1:18080")!,
        logsPath: "/tmp"
    )
}
