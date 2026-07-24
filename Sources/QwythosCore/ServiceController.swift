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

public enum ServiceControlError: LocalizedError, Sendable {
    case commandFailed(String)

    public var errorDescription: String? {
        switch self {
        case .commandFailed(let message):
            return message
        }
    }
}

public struct SystemCommandRunner: CommandRunning {
    public init() {}

    public func run(_ command: LaunchCommand) async -> CommandResult {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: command.executable)
        process.arguments = command.arguments
        process.standardOutput = pipe
        process.standardError = pipe

        do {
            try process.run()
        } catch {
            return CommandResult(exitCode: -1, output: error.localizedDescription)
        }

        let waitTask = Task.detached { () -> Int32 in
            process.waitUntilExit()
            return process.terminationStatus
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()

        return CommandResult(
            exitCode: await waitTask.value,
            output: String(decoding: data, as: UTF8.self)
        )
    }
}

public struct URLSessionHealthChecker: HealthChecking {
    public init() {}

    public func isHealthy(_ url: URL) async -> Bool {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 2
        let session = URLSession(configuration: configuration)

        do {
            let (data, response) = try await session.data(from: url)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                return false
            }
            return String(decoding: data, as: UTF8.self).contains("\"status\":\"ok\"")
        } catch {
            return false
        }
    }
}

public actor ServiceController {
    public let configuration: ServiceConfiguration
    private let runner: any CommandRunning
    private let healthChecker: any HealthChecking
    private var lastError: String?
    private var operationInProgress = false
    private var operationWaiters: [CheckedContinuation<Void, Never>] = []

    public init(
        configuration: ServiceConfiguration,
        runner: any CommandRunning,
        healthChecker: any HealthChecking
    ) {
        self.configuration = configuration
        self.runner = runner
        self.healthChecker = healthChecker
    }

    public func refresh() async -> ServiceState {
        await beginOperation()
        defer { endOperation() }

        let result = await runner.run(configuration.printCommand)
        let loaded = result.exitCode == 0
        let healthy: Bool

        if loaded {
            healthy = await healthChecker.isHealthy(configuration.healthURL)
        } else {
            healthy = false
        }

        return .resolve(jobLoaded: loaded, healthOK: healthy, lastError: lastError)
    }

    public func start() async throws {
        await beginOperation()
        defer { endOperation() }

        lastError = nil
        let result = await runner.run(configuration.startCommand)
        guard result.exitCode == 0 else {
            lastError = result.output
            throw ServiceControlError.commandFailed(result.output)
        }
    }

    public func stop() async throws {
        await beginOperation()
        defer { endOperation() }

        lastError = nil
        let result = await runner.run(configuration.stopCommand)
        guard result.exitCode == 0 else {
            lastError = result.output
            throw ServiceControlError.commandFailed(result.output)
        }
    }

    private func beginOperation() async {
        guard operationInProgress else {
            operationInProgress = true
            return
        }

        await withCheckedContinuation { continuation in
            operationWaiters.append(continuation)
        }
    }

    private func endOperation() {
        guard !operationWaiters.isEmpty else {
            operationInProgress = false
            return
        }

        operationWaiters.removeFirst().resume()
    }
}
