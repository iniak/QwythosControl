import Foundation

public enum NetworkAccessMode: String, Codable, Equatable, Sendable {
    case local
    case shared
}

public enum DeploymentPhase: String, Codable, Sendable {
    case idle
    case preflighting
    case ready
    case downloadingRuntime
    case verifyingRuntime
    case installingRuntime
    case downloadingModel
    case verifyingModel
    case writingConfiguration
    case startingService
    case checkingHealth
    case installed
    case paused
    case repairing
    case uninstalling
    case failed
}

public enum DeploymentRecoveryAction: String, Codable, Equatable, Sendable {
    case retry
    case viewLogs
}

public struct DeploymentFailure: Error, Equatable, Sendable {
    public let phase: DeploymentPhase
    public let component: RepairComponent?
    public let reason: String
    public let diagnostic: String
    public let timestamp: Date
    public let recoveryActions: [DeploymentRecoveryAction]

    public init(
        phase: DeploymentPhase,
        component: RepairComponent?,
        reason: String,
        diagnostic: String,
        timestamp: Date = Date(),
        recoveryActions: [DeploymentRecoveryAction]
    ) {
        self.phase = phase
        self.component = component
        self.reason = reason
        self.diagnostic = diagnostic
        self.timestamp = timestamp
        self.recoveryActions = recoveryActions
    }
}

public struct DeploymentSnapshot: Equatable, Sendable {
    public let operationID: UUID?
    public let phase: DeploymentPhase
    public let component: RepairComponent?
    public let completedBytes: Int64?
    public let totalBytes: Int64?
    public let overallProgress: Double?
    public let statusText: String
    public let failure: DeploymentFailure?

    public init(
        phase: DeploymentPhase,
        operationID: UUID? = nil,
        component: RepairComponent? = nil,
        completedBytes: Int64? = nil,
        totalBytes: Int64? = nil,
        overallProgress: Double? = nil,
        statusText: String,
        failure: DeploymentFailure? = nil
    ) {
        self.operationID = operationID
        self.phase = phase
        self.component = component
        self.completedBytes = completedBytes
        self.totalBytes = totalBytes
        self.overallProgress = overallProgress
        self.statusText = statusText
        self.failure = failure
    }
}

public enum DeploymentOptionsError: Error, Equatable, Sendable {
    case unsupportedContextSize(Int)
    case rootDoesNotMatchLayout
}

public struct DeploymentOptions: Codable, Equatable, Sendable {
    public static let supportedContextSizes: Set<Int> = [4_096, 8_192, 16_384]

    public let root: URL
    public let contextSize: Int
    public let accessMode: NetworkAccessMode

    public init(root: URL, contextSize: Int, accessMode: NetworkAccessMode) {
        self.root = root
        self.contextSize = contextSize
        self.accessMode = accessMode
    }

    public func validate(for layout: InstallationLayout) throws {
        guard root == layout.root else {
            throw DeploymentOptionsError.rootDoesNotMatchLayout
        }
        guard Self.supportedContextSizes.contains(contextSize) else {
            throw DeploymentOptionsError.unsupportedContextSize(contextSize)
        }
    }
}

public protocol RuntimeInstalling: Sendable {
    func install(
        archive: URL,
        manifest: RuntimeArtifact,
        layout: InstallationLayout
    ) async throws

    func rollBackCurrentRuntime(
        to previousVersion: String,
        layout: InstallationLayout
    ) throws

    func commitCurrentRuntime(layout: InstallationLayout) throws
}

public extension RuntimeInstalling {
    func commitCurrentRuntime(layout: InstallationLayout) throws {}
}

public protocol APIKeyStoring: Sendable {
    func load() throws -> String?
    func generate() throws -> String
    func remove() throws
}

public protocol LaunchAgentPreparing: Sendable {
    /// Prepares dependencies and returns plist bytes without publishing the plist.
    func prepareInstallation(
        layout: InstallationLayout,
        options: DeploymentOptions,
        manifest: DeploymentManifest
    ) throws -> Data
}

public protocol LaunchAgentInstalling: Sendable {
    func install(
        layout: InstallationLayout,
        options: DeploymentOptions,
        manifest: DeploymentManifest
    ) throws

    func restoreLegacyPlist(layout: InstallationLayout) throws
    func uninstall() throws
    func regenerateAPIKey(layout: InstallationLayout) throws -> String
    func captureInstallationState(layout: InstallationLayout) throws -> LaunchAgentInstallationState
    func restoreInstallationState(
        _ state: LaunchAgentInstallationState,
        layout: InstallationLayout
    ) throws
    func restoreAPIKeyState(_ state: LaunchAgentInstallationState, layout: InstallationLayout) throws
    func restorePlistState(_ state: LaunchAgentInstallationState, layout: InstallationLayout) throws
}

public struct LaunchAgentInstallationState: Sendable {
    public let plist: Data?
    public let apiKey: Data?

    public init(plist: Data?, apiKey: Data?) {
        self.plist = plist
        self.apiKey = apiKey
    }
}

public enum KeyRotationRecoveryStep: Equatable, Sendable {
    case stopService
    case restoreAPIKey
    case restorePlist
    case restartService
}

public struct KeyRotationRecoveryError: Error, Equatable, Sendable {
    public let failedSteps: [KeyRotationRecoveryStep]

    public init(failedSteps: [KeyRotationRecoveryStep]) {
        self.failedSteps = failedSteps
    }
}

public extension LaunchAgentInstalling {
    func regenerateAPIKey(layout: InstallationLayout) throws -> String {
        try APIKeyStore(fileURL: layout.apiKeyFile).generate()
    }

    func captureInstallationState(layout: InstallationLayout) throws -> LaunchAgentInstallationState {
        LaunchAgentInstallationState(
            plist: nil,
            apiKey: try? Data(contentsOf: layout.apiKeyFile)
        )
    }

    func restoreInstallationState(
        _ state: LaunchAgentInstallationState,
        layout: InstallationLayout
    ) throws {}

    func restoreAPIKeyState(_ state: LaunchAgentInstallationState, layout: InstallationLayout) throws {
        try restoreInstallationState(state, layout: layout)
    }

    func restorePlistState(_ state: LaunchAgentInstallationState, layout: InstallationLayout) throws {
        try restoreInstallationState(state, layout: layout)
    }
}
