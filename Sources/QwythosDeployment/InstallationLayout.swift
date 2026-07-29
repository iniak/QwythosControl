import Foundation

public enum InstallationLayoutError: Error, Equatable, Sendable {
    case rootDeletionProhibited
    case unmanagedURL(URL)
}

public struct InstallationLayout: Equatable, Sendable {
    public static let modelFilename = "Qwythos-9B-Claude-Mythos-5-1M-uncensored-heretic-Q4_K_M.gguf"

    public let root: URL

    public init(root: URL) {
        self.root = root
    }

    public var configDirectory: URL { root.appending(path: "config") }
    public var downloadsDirectory: URL { root.appending(path: "downloads") }
    public var logsDirectory: URL { root.appending(path: "logs") }
    public var modelsDirectory: URL { root.appending(path: "models") }
    public var runtimeDirectory: URL { root.appending(path: "runtime") }
    public var runtimeVersionsDirectory: URL {
        runtimeDirectory.appending(path: "versions")
    }
    public var runtimeCurrent: URL { runtimeDirectory.appending(path: "current") }
    public var stagingDirectory: URL { root.appending(path: "staging") }

    public var deploymentRecord: URL { configDirectory.appending(path: "deployment.json") }
    var runtimeCleanupTombstone: URL {
        configDirectory.appending(path: "runtime-cleanup.json")
    }
    public var apiKeyFile: URL { configDirectory.appending(path: "api-keys.txt") }
    public var legacyPlistBackup: URL {
        configDirectory.appending(path: "legacy-launch-agent.plist")
    }
    public var modelFile: URL { modelsDirectory.appending(path: Self.modelFilename) }

    public func runtimeVersion(_ version: String) -> URL {
        runtimeVersionsDirectory.appending(path: version)
    }

    public func runtimeServer(version: String) -> URL {
        runtimeVersion(version).appending(path: "llama-server")
    }

    public func partialFile(for artifact: DeploymentArtifact) -> URL {
        downloadsDirectory.appending(path: "\(artifact.filename).partial")
    }

    public func requireManaged(_ url: URL) throws -> URL {
        guard let rootComponents = lexicallyNormalizedComponents(root),
              let candidateComponents = lexicallyNormalizedComponents(url)
        else {
            throw InstallationLayoutError.unmanagedURL(url)
        }
        guard candidateComponents != rootComponents else {
            throw InstallationLayoutError.rootDeletionProhibited
        }

        guard candidateComponents.starts(with: rootComponents) else {
            throw InstallationLayoutError.unmanagedURL(url)
        }
        return URL(
            fileURLWithPath: "/" + candidateComponents.joined(separator: "/")
        )
    }

    private func lexicallyNormalizedComponents(_ url: URL) -> [String]? {
        let urlComponents = URLComponents(
            url: url,
            resolvingAgainstBaseURL: false
        )
        let hasLocalAuthority = urlComponents?.host?.isEmpty ?? true
        guard url.isFileURL,
              url.baseURL == nil,
              urlComponents?.scheme == "file",
              urlComponents?.user == nil,
              urlComponents?.password == nil,
              hasLocalAuthority,
              urlComponents?.port == nil,
              urlComponents?.query == nil,
              urlComponents?.fragment == nil,
              url.path.hasPrefix("/") else {
            return nil
        }
        var components: [String] = []
        for component in url.path.split(
            separator: "/",
            omittingEmptySubsequences: true
        ) {
            switch component {
            case ".":
                continue
            case "..":
                guard !components.isEmpty else { return nil }
                components.removeLast()
            default:
                components.append(String(component))
            }
        }
        return components
    }
}
