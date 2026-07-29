import Foundation

public struct CommandResult: Sendable {
    public let exitCode: Int32
    public let output: String

    public init(exitCode: Int32, output: String) {
        self.exitCode = exitCode
        self.output = output
    }
}

public protocol CommandRunning: Sendable {
    func run(_ command: LaunchCommand) async -> CommandResult
}

public protocol HealthChecking: Sendable {
    func isHealthy(_ url: URL) async -> Bool
}

public protocol FileExistenceChecking: Sendable {
    func fileExists(atPath path: String) -> Bool
}

public struct LocalFileExistenceChecker: FileExistenceChecking {
    public init() {}

    public func fileExists(atPath path: String) -> Bool {
        FileManager.default.fileExists(atPath: path)
    }
}

public enum ServiceControlError: LocalizedError, Sendable {
    case commandFailed(String)

    public var errorDescription: String? {
        switch self {
        case .commandFailed(let message):
            return message
        }
    }
}

private enum ProcessInterruption: Sendable {
    case cancelled
    case timedOut
}

private enum ProcessRunOutcome: Sendable {
    case terminated(Int32)
    case launchFailed(String)
    case interrupted(ProcessInterruption)
}

private final class ProcessRunContinuationGate: @unchecked Sendable {
    private let lock = NSLock()
    private var didResume = false

    func resume(
        _ continuation: CheckedContinuation<ProcessRunOutcome, Never>,
        returning outcome: ProcessRunOutcome
    ) {
        lock.lock()
        let shouldResume = !didResume
        didResume = true
        lock.unlock()

        if shouldResume {
            continuation.resume(returning: outcome)
        }
    }
}

private final class ProcessRunCoordinator: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var interruption: ProcessInterruption?
    private var completed = false

    func launch(_ process: Process) -> ProcessRunOutcome? {
        lock.lock()
        defer { lock.unlock() }

        if let interruption {
            completed = true
            return .interrupted(interruption)
        }

        self.process = process

        do {
            try process.run()
            return nil
        } catch {
            self.process = nil
            completed = true
            return .launchFailed(error.localizedDescription)
        }
    }

    func requestInterruption(_ reason: ProcessInterruption) {
        lock.lock()
        guard !completed, interruption == nil else {
            lock.unlock()
            return
        }

        interruption = reason
        let process = process
        lock.unlock()

        if let process, process.isRunning {
            process.terminate()
        }
    }

    func didTerminate(exitCode: Int32) -> ProcessRunOutcome {
        lock.lock()
        defer { lock.unlock() }

        completed = true
        process = nil

        if let interruption {
            return .interrupted(interruption)
        }
        return .terminated(exitCode)
    }
}

public struct SystemCommandRunner: CommandRunning {
    private let timeout: Duration

    public init(timeout: Duration = .seconds(2)) {
        self.timeout = timeout
    }

    public func run(_ command: LaunchCommand) async -> CommandResult {
        let coordinator = ProcessRunCoordinator()

        return await withTaskCancellationHandler {
            await run(command, coordinator: coordinator)
        } onCancel: {
            coordinator.requestInterruption(.cancelled)
        }
    }

    private func run(
        _ command: LaunchCommand,
        coordinator: ProcessRunCoordinator
    ) async -> CommandResult {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: command.executable)
        process.arguments = command.arguments
        process.standardOutput = pipe
        process.standardError = pipe

        let continuationGate = ProcessRunContinuationGate()
        let outputTask = Task.detached {
            pipe.fileHandleForReading.readDataToEndOfFile()
        }
        let timeoutTask = Task {
            do {
                try await Task.sleep(for: timeout)
                coordinator.requestInterruption(.timedOut)
            } catch {
                // The process completed before its deadline.
            }
        }
        defer { timeoutTask.cancel() }

        let outcome: ProcessRunOutcome = await withCheckedContinuation { continuation in
            process.terminationHandler = { terminatedProcess in
                continuationGate.resume(
                    continuation,
                    returning: coordinator.didTerminate(
                        exitCode: terminatedProcess.terminationStatus
                    )
                )
            }

            if let immediateOutcome = coordinator.launch(process) {
                process.terminationHandler = nil
                try? pipe.fileHandleForWriting.close()
                continuationGate.resume(
                    continuation,
                    returning: immediateOutcome
                )
            }
        }
        let data = await outputTask.value

        switch outcome {
        case .terminated(let exitCode):
            return CommandResult(
                exitCode: exitCode,
                output: String(decoding: data, as: UTF8.self)
            )
        case .launchFailed(let message):
            return CommandResult(exitCode: -1, output: message)
        case .interrupted(let interruption):
            let processOutput = String(decoding: data, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let message: String
            let exitCode: Int32

            switch interruption {
            case .cancelled:
                message = "Command cancelled."
                exitCode = -2
            case .timedOut:
                message = "Command timed out."
                exitCode = -3
            }

            let output = processOutput.isEmpty ? message : "\(processOutput)\n\(message)"
            return CommandResult(exitCode: exitCode, output: output)
        }
    }
}

public struct URLSessionHealthChecker: HealthChecking {
    private struct HealthResponse: Decodable {
        let status: String
    }

    private let session: URLSession
    private let timeout: Duration

    public init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 2
        configuration.timeoutIntervalForResource = 2
        self.session = URLSession(configuration: configuration)
        self.timeout = .seconds(2)
    }

    init(session: URLSession, timeout: Duration) {
        self.session = session
        self.timeout = timeout
    }

    public func isHealthy(_ url: URL) async -> Bool {
        let requestTask = Task {
            try await session.data(from: url)
        }
        let timeoutTask = Task {
            do {
                try await Task.sleep(for: timeout)
                requestTask.cancel()
            } catch {
                // The request completed before its deadline.
            }
        }

        return await withTaskCancellationHandler {
            defer { timeoutTask.cancel() }

            do {
                let (data, response) = try await requestTask.value
                guard let statusCode = (response as? HTTPURLResponse)?.statusCode else {
                    return false
                }
                return Self.isHealthyResponse(statusCode: statusCode, data: data)
            } catch {
                return false
            }
        } onCancel: {
            requestTask.cancel()
        }
    }

    static func isHealthyResponse(statusCode: Int, data: Data) -> Bool {
        guard statusCode == 200,
              let response = try? JSONDecoder().decode(HealthResponse.self, from: data)
        else {
            return false
        }

        return response.status == "ok"
    }
}

public actor ServiceController {
    private struct AttemptWaiter {
        let count: Int
        let continuation: CheckedContinuation<Void, Never>
    }

    private struct OperationWaiter {
        let id: UUID
        let continuation: CheckedContinuation<Bool, Never>
    }

    public let configuration: ServiceConfiguration
    private let runner: any CommandRunning
    private let healthChecker: any HealthChecking
    private let fileChecker: any FileExistenceChecking
    private var operationInProgress = false
    private var operationWaiters: [OperationWaiter] = []
    private var operationAttemptCount = 0
    private var attemptWaiters: [AttemptWaiter] = []

    public init(
        configuration: ServiceConfiguration,
        runner: any CommandRunning,
        healthChecker: any HealthChecking,
        fileChecker: any FileExistenceChecking = LocalFileExistenceChecker()
    ) {
        self.configuration = configuration
        self.runner = runner
        self.healthChecker = healthChecker
        self.fileChecker = fileChecker
    }

    public func refresh() async -> ServiceState {
        await refreshSnapshot().state
    }

    public func refreshSnapshot() async -> ServiceSnapshot {
        guard await beginOperation() else {
            return ServiceSnapshot(
                state: .failed("Status refresh was cancelled."),
                availableAction: nil
            )
        }
        defer { endOperation() }

        let result = await runner.run(configuration.printCommand)
        let queryOutcome = LaunchctlPrintParser.parse(result)

        switch queryOutcome {
        case .absent:
            guard fileChecker.fileExists(atPath: configuration.plistPath) else {
                return ServiceSnapshot(
                    state: .failed(
                        "Model LaunchAgent plist is missing at \(configuration.plistPath). Restore it before starting the service."
                    ),
                    availableAction: nil
                )
            }
            return ServiceSnapshot(state: .stopped, availableAction: .start)
        case .loaded:
            return ServiceSnapshot(state: .starting, availableAction: .stop)
        case .running:
            let healthy = await healthChecker.isHealthy(configuration.healthURL)
            return ServiceSnapshot(
                state: healthy ? .running : .starting,
                availableAction: .stop
            )
        case .failedLoaded(let message):
            return ServiceSnapshot(state: .failed(message), availableAction: .stop)
        case .queryFailed(let message):
            return ServiceSnapshot(state: .failed(message), availableAction: nil)
        }
    }

    public func start() async throws {
        guard await beginOperation() else {
            throw CancellationError()
        }
        defer { endOperation() }

        try Task.checkCancellation()
        let result = await runner.run(configuration.startCommand)
        try Task.checkCancellation()
        guard result.exitCode == 0 else {
            throw ServiceControlError.commandFailed(result.output)
        }
    }

    public func stop() async throws {
        guard await beginOperation() else {
            throw CancellationError()
        }
        defer { endOperation() }

        try Task.checkCancellation()
        let result = await runner.run(configuration.stopCommand)
        try Task.checkCancellation()
        if isAlreadyAbsentBootout(result) {
            return
        }
        guard result.exitCode == 0 else {
            throw ServiceControlError.commandFailed(result.output)
        }
    }

    private func isAlreadyAbsentBootout(_ result: CommandResult) -> Bool {
        result.exitCode == 3
            && result.output.hasPrefix("Could not find service ")
            && result.output.contains(" in domain for user gui: ")
    }

    func waitForOperationAttemptCount(_ count: Int) async {
        guard operationAttemptCount < count else {
            return
        }

        await withCheckedContinuation { continuation in
            attemptWaiters.append(AttemptWaiter(count: count, continuation: continuation))
        }
    }

    func queuedOperationCount() -> Int {
        operationWaiters.count
    }

    private func beginOperation() async -> Bool {
        operationAttemptCount += 1
        resumeSatisfiedAttemptWaiters()

        guard !Task.isCancelled else {
            return false
        }

        guard operationInProgress else {
            operationInProgress = true
            return true
        }

        let waiterID = UUID()
        let admitted = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                operationWaiters.append(
                    OperationWaiter(id: waiterID, continuation: continuation)
                )
            }
        } onCancel: {
            Task {
                await self.cancelQueuedOperation(id: waiterID)
            }
        }

        if admitted, Task.isCancelled {
            endOperation()
            return false
        }
        return admitted
    }

    private func endOperation() {
        guard !operationWaiters.isEmpty else {
            operationInProgress = false
            return
        }

        operationWaiters.removeFirst().continuation.resume(returning: true)
    }

    private func cancelQueuedOperation(id: UUID) {
        guard let index = operationWaiters.firstIndex(where: { $0.id == id }) else {
            return
        }

        let waiter = operationWaiters.remove(at: index)
        waiter.continuation.resume(returning: false)
    }

    private func resumeSatisfiedAttemptWaiters() {
        let satisfied = attemptWaiters.filter { $0.count <= operationAttemptCount }
        attemptWaiters.removeAll { $0.count <= operationAttemptCount }
        for waiter in satisfied {
            waiter.continuation.resume()
        }
    }
}
