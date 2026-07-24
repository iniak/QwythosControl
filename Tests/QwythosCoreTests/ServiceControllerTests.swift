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

    func testRefreshReportsStartingAndStopActionForLoadedWaitingJob() async {
        let runner = FakeRunner(
            printExitCode: 0,
            printOutput: """
            gui/501/com.local.qwythos-9b = {
                state = waiting
                last exit code = 0
            }
            """
        )
        let controller = ServiceController(
            configuration: .test,
            runner: runner,
            healthChecker: FakeHealthChecker(result: false)
        )

        let snapshot = await controller.refreshSnapshot()

        XCTAssertEqual(
            snapshot,
            ServiceSnapshot(state: .starting, availableAction: .stop)
        )
    }

    func testRefreshReportsFailedLoadedJobWithActionableExitCodeAndStopAction() async {
        let runner = FakeRunner(
            printExitCode: 0,
            printOutput: """
            gui/501/com.local.qwythos-9b = {
                state = waiting
                last exit code = 78
            }
            """
        )
        let controller = ServiceController(
            configuration: .test,
            runner: runner,
            healthChecker: FakeHealthChecker(result: false)
        )

        let snapshot = await controller.refreshSnapshot()

        guard case .failed(let message) = snapshot.state else {
            return XCTFail("Expected a failed snapshot, got \(snapshot)")
        }
        XCTAssertTrue(message.contains("last exit code 78"))
        XCTAssertEqual(snapshot.availableAction, .stop)
    }

    func testRefreshTreatsOnlyCanonicalNotFoundResponseAsStopped() async {
        let runner = FakeRunner(
            printExitCode: 113,
            printOutput: """
            Bad request.
            Could not find service "com.local.qwythos-9b" in domain for user gui: 501
            """
        )
        let controller = ServiceController(
            configuration: .test,
            runner: runner,
            healthChecker: FakeHealthChecker(result: false),
            fileChecker: FakeFileChecker(exists: true)
        )

        let snapshot = await controller.refreshSnapshot()

        XCTAssertEqual(
            snapshot,
            ServiceSnapshot(state: .stopped, availableAction: .start)
        )
    }

    func testRefreshReportsLaunchctlQueryErrorsAsFailedWithoutGuessingToggleAction() async {
        let runner = FakeRunner(
            printExitCode: 1,
            printOutput: "Operation not permitted"
        )
        let controller = ServiceController(
            configuration: .test,
            runner: runner,
            healthChecker: FakeHealthChecker(result: false)
        )

        let snapshot = await controller.refreshSnapshot()

        guard case .failed(let message) = snapshot.state else {
            return XCTFail("Expected a failed snapshot, got \(snapshot)")
        }
        XCTAssertTrue(message.contains("Operation not permitted"))
        XCTAssertNil(snapshot.availableAction)
    }

    func testRefreshReportsMissingPlistBeforeOfferingStart() async {
        let runner = FakeRunner(printExitCode: 113)
        let controller = ServiceController(
            configuration: .test,
            runner: runner,
            healthChecker: FakeHealthChecker(result: false),
            fileChecker: FakeFileChecker(exists: false)
        )

        let snapshot = await controller.refreshSnapshot()

        guard case .failed(let message) = snapshot.state else {
            return XCTFail("Expected a failed snapshot, got \(snapshot)")
        }
        XCTAssertTrue(message.contains(ServiceConfiguration.test.plistPath))
        XCTAssertTrue(message.localizedCaseInsensitiveContains("missing"))
        XCTAssertNil(snapshot.availableAction)
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

    func testFailedStopDoesNotOverrideSubsequentRunningObservation() async {
        let runner = FakeRunner(
            printExitCode: 0,
            stopExitCode: 1,
            stopOutput: "bootout failed"
        )
        let controller = ServiceController(
            configuration: .test,
            runner: runner,
            healthChecker: FakeHealthChecker(result: true)
        )

        do {
            try await controller.stop()
            XCTFail("Expected stop to throw")
        } catch {
            XCTAssertEqual(error.localizedDescription, "bootout failed")
        }

        let snapshot = await controller.refreshSnapshot()

        XCTAssertEqual(
            snapshot,
            ServiceSnapshot(state: .running, availableAction: .stop)
        )
    }

    func testFailedStartDoesNotOverrideSubsequentStoppedObservation() async {
        let runner = FakeRunner(
            printExitCode: 113,
            startExitCode: 1,
            startOutput: "bootstrap failed"
        )
        let controller = ServiceController(
            configuration: .test,
            runner: runner,
            healthChecker: FakeHealthChecker(result: false),
            fileChecker: FakeFileChecker(exists: true)
        )

        do {
            try await controller.start()
            XCTFail("Expected start to throw")
        } catch {
            XCTAssertEqual(error.localizedDescription, "bootstrap failed")
        }

        let snapshot = await controller.refreshSnapshot()

        XCTAssertEqual(
            snapshot,
            ServiceSnapshot(state: .stopped, availableAction: .start)
        )
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

    func testCancelledQueuedOperationNeverEntersRunner() async throws {
        let runner = BlockingRunner()
        let controller = ServiceController(
            configuration: .test,
            runner: runner,
            healthChecker: FakeHealthChecker(result: true)
        )

        let startTask = Task {
            try await controller.start()
        }
        await runner.waitForCallCount(1)

        let stopTask = Task {
            try await controller.stop()
        }
        await controller.waitForOperationAttemptCount(2)
        stopTask.cancel()

        do {
            try await stopTask.value
            XCTFail("Expected the queued stop to be cancelled")
        } catch is CancellationError {
            // Expected.
        } catch {
            XCTFail("Unexpected cancellation error: \(error)")
        }

        let queuedOperationCount = await controller.queuedOperationCount()
        let commands = await runner.recordedCommands()
        XCTAssertEqual(queuedOperationCount, 0)
        XCTAssertEqual(commands, [ServiceConfiguration.test.startCommand])

        await runner.releaseNext()
        try await startTask.value
    }
}

final class SystemCommandRunnerTests: XCTestCase {
    func testFastExitingProcessesCompleteReliably() async {
        let runner = SystemCommandRunner()
        let command = LaunchCommand(executable: "/usr/bin/true", arguments: [])

        for _ in 0..<100 {
            let result = await runner.run(command)
            XCTAssertEqual(result.exitCode, 0)
            XCTAssertEqual(result.output, "")
        }
    }

    func testLargeOutputIsDrainedWithoutBlockingProcessExit() async {
        let result = await SystemCommandRunner().run(
            LaunchCommand(executable: "/usr/bin/seq", arguments: ["1", "20000"])
        )

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertTrue(result.output.hasPrefix("1\n2\n3\n"))
        XCTAssertTrue(result.output.hasSuffix("20000\n"))
    }

    func testLaunchFailureReturnsWithoutWaitingForPipeEOF() async {
        let result = await SystemCommandRunner().run(
            LaunchCommand(
                executable: "/path/that/does/not/exist/qwythos-command",
                arguments: []
            )
        )

        XCTAssertEqual(result.exitCode, -1)
        XCTAssertFalse(result.output.isEmpty)
    }

    func testTimeoutTerminatesLaunchedProcess() async {
        let clock = ContinuousClock()
        let start = clock.now

        let result = await SystemCommandRunner(timeout: .milliseconds(50)).run(
            LaunchCommand(executable: "/bin/sleep", arguments: ["5"])
        )

        XCTAssertEqual(result.exitCode, -3)
        XCTAssertTrue(result.output.localizedCaseInsensitiveContains("timed out"))
        XCTAssertLessThan(start.duration(to: clock.now), .seconds(1))
    }

    func testCancellationTerminatesLaunchedProcess() async {
        let runner = SystemCommandRunner(timeout: .seconds(5))
        let task = Task {
            await runner.run(LaunchCommand(executable: "/bin/sleep", arguments: ["5"]))
        }
        try? await Task.sleep(for: .milliseconds(50))

        task.cancel()
        let result = await task.value

        XCTAssertEqual(result.exitCode, -2)
        XCTAssertTrue(result.output.localizedCaseInsensitiveContains("cancelled"))
    }
}

private actor FakeRunner: CommandRunning {
    private let printExitCode: Int32
    private let printOutput: String
    private let startExitCode: Int32
    private let stopExitCode: Int32
    private let startOutput: String
    private let stopOutput: String
    private var commands: [LaunchCommand] = []

    init(
        printExitCode: Int32,
        printOutput: String? = nil,
        startExitCode: Int32 = 0,
        stopExitCode: Int32 = 0,
        startOutput: String = "",
        stopOutput: String = ""
    ) {
        self.printExitCode = printExitCode
        self.printOutput = printOutput ?? Self.defaultPrintOutput(for: printExitCode)
        self.startExitCode = startExitCode
        self.stopExitCode = stopExitCode
        self.startOutput = startOutput
        self.stopOutput = stopOutput
    }

    func run(_ command: LaunchCommand) async -> CommandResult {
        commands.append(command)

        if command == ServiceConfiguration.test.printCommand {
            return CommandResult(exitCode: printExitCode, output: printOutput)
        }
        if command == ServiceConfiguration.test.startCommand {
            return CommandResult(exitCode: startExitCode, output: startOutput)
        }
        return CommandResult(exitCode: stopExitCode, output: stopOutput)
    }

    func lastCommand() -> LaunchCommand? {
        commands.last
    }

    private static func defaultPrintOutput(for exitCode: Int32) -> String {
        if exitCode == 0 {
            return """
            gui/501/com.local.qwythos-9b = {
                state = running
            }
            """
        }

        return """
        Bad request.
        Could not find service "com.local.qwythos-9b" in domain for user gui: 501
        """
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

private struct FakeFileChecker: FileExistenceChecking {
    let exists: Bool

    func fileExists(atPath path: String) -> Bool {
        exists
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
