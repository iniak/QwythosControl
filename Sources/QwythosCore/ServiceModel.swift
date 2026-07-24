import Foundation

public enum ServiceState: Equatable, Sendable {
    case stopped
    case starting
    case running
    case failed(String)

    public static func resolve(
        jobLoaded: Bool,
        healthOK: Bool,
        lastError: String?
    ) -> ServiceState {
        if let lastError { return .failed(lastError) }
        if healthOK { return .running }
        return jobLoaded ? .starting : .stopped
    }
}

public struct LaunchCommand: Equatable, Sendable {
    public let executable: String
    public let arguments: [String]
}

public struct ServiceConfiguration: Sendable {
    public let uid: uid_t
    public let label: String
    public let plistPath: String
    public let healthURL: URL
    public let chatURL: URL
    public let logsPath: String

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
