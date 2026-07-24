import XCTest
@testable import QwythosCore

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

    func testOperationsDoNotEnterRunnerConcurrently() async throws {
        let runner = BlockingRunner()
        let controller = ServiceController(
            configuration: .test,
            runner: runner,
            healthChecker: FakeHealthChecker(result: true)
        )

        async let start: Void = controller.start()
        await runner.waitForCallCount(1)

        async let stop: Void = controller.stop()
        await controller.waitForOperationAttemptCount(2)

        let queuedOperationCount = await controller.queuedOperationCount()
        let commandsBeforeStartCompletes = await runner.recordedCommands()
        XCTAssertEqual(queuedOperationCount, 1)
        XCTAssertEqual(commandsBeforeStartCompletes, [ServiceConfiguration.test.startCommand])

        await runner.releaseNext()
        try await start
        await runner.waitForCallCount(2)
        await runner.releaseNext()
        try await stop
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

private actor BlockingRunner: CommandRunning {
    private struct CallWaiter {
        let count: Int
        let continuation: CheckedContinuation<Void, Never>
    }

    private var commands: [LaunchCommand] = []
    private var blockedCalls: [CheckedContinuation<Void, Never>] = []
    private var callWaiters: [CallWaiter] = []

    func run(_ command: LaunchCommand) async -> CommandResult {
        commands.append(command)
        resumeSatisfiedCallWaiters()

        await withCheckedContinuation { continuation in
            blockedCalls.append(continuation)
        }

        return CommandResult(exitCode: 0, output: "")
    }

    func waitForCallCount(_ count: Int) async {
        guard commands.count < count else {
            return
        }

        await withCheckedContinuation { continuation in
            callWaiters.append(CallWaiter(count: count, continuation: continuation))
        }
    }

    func recordedCommands() -> [LaunchCommand] {
        commands
    }

    func releaseNext() {
        blockedCalls.removeFirst().resume()
    }

    private func resumeSatisfiedCallWaiters() {
        let satisfied = callWaiters.filter { $0.count <= commands.count }
        callWaiters.removeAll { $0.count <= commands.count }
        for waiter in satisfied {
            waiter.continuation.resume()
        }
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
