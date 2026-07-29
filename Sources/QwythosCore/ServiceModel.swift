import Foundation

public enum ServiceState: Equatable, Sendable {
    case stopped
    case starting
    case stopping
    case running
    case failed(String)

    public static func resolve(
        jobLoaded: Bool,
        healthOK: Bool,
        lastError _: String?
    ) -> ServiceState {
        resolve(jobLoaded: jobLoaded, healthOK: healthOK)
    }

    public static func resolve(
        jobLoaded: Bool,
        healthOK: Bool
    ) -> ServiceState {
        if healthOK { return .running }
        return jobLoaded ? .starting : .stopped
    }
}

public enum ServiceAction: Equatable, Sendable {
    case start
    case stop

    public var inProgressState: ServiceState {
        switch self {
        case .start:
            return .starting
        case .stop:
            return .stopping
        }
    }
}

public struct ServiceSnapshot: Equatable, Sendable {
    public let state: ServiceState
    public let availableAction: ServiceAction?

    public init(state: ServiceState, availableAction: ServiceAction?) {
        self.state = state
        self.availableAction = availableAction
    }

    public func overlayingOperationFailure(_ message: String) -> ServiceSnapshot {
        ServiceSnapshot(
            state: .failed(message),
            availableAction: availableAction
        )
    }
}

public struct LaunchCommand: Equatable, Sendable {
    public let executable: String
    public let arguments: [String]

    public init(executable: String, arguments: [String]) {
        self.executable = executable
        self.arguments = arguments
    }
}

public struct ServiceConfiguration: Sendable {
    public let uid: uid_t
    public let label: String
    public let plistPath: String
    public let healthURL: URL
    public let chatURL: URL
    public let logsPath: String

    public init(
        uid: uid_t,
        label: String,
        plistPath: String,
        healthURL: URL,
        chatURL: URL,
        logsPath: String
    ) {
        self.uid = uid
        self.label = label
        self.plistPath = plistPath
        self.healthURL = healthURL
        self.chatURL = chatURL
        self.logsPath = logsPath
    }

    public var domain: String { "gui/\(uid)" }
    public var serviceTarget: String { "\(domain)/\(label)" }
    public var startCommand: LaunchCommand {
        LaunchCommand(
            executable: "/bin/launchctl",
            arguments: ["bootstrap", domain, plistPath]
        )
    }
    public var stopCommand: LaunchCommand {
        LaunchCommand(
            executable: "/bin/launchctl",
            arguments: ["bootout", serviceTarget]
        )
    }
    public var printCommand: LaunchCommand {
        LaunchCommand(
            executable: "/bin/launchctl",
            arguments: ["print", serviceTarget]
        )
    }
}
