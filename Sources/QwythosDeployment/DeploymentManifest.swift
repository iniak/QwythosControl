import Foundation

public enum ManifestError: Error, Equatable, Sendable {
    case missingResource
    case unsupportedSchema(Int)
    case invalidSHA256(String)
}

public struct DeploymentManifest: Codable, Equatable, Sendable {
    public static let supportedSchemaVersion = 1
    static let resourceBundleName = "QwythosControl_QwythosDeployment.bundle"
    private static let resourceName = "deployment-manifest.json"

    public let schemaVersion: Int
    public let runtime: RuntimeArtifact
    public let model: DeploymentArtifact
    public let service: ServiceDefaults

    public init(
        schemaVersion: Int,
        runtime: RuntimeArtifact,
        model: DeploymentArtifact,
        service: ServiceDefaults
    ) {
        self.schemaVersion = schemaVersion
        self.runtime = runtime
        self.model = model
        self.service = service
    }

    public static func productionData() throws -> Data {
        return try productionData(searching: defaultResourceSearchDirectories)
    }

    static func productionData(searching directories: [URL]) throws -> Data {
        for directory in directories {
            let bundledResource = directory
                .appending(path: resourceBundleName, directoryHint: .isDirectory)
                .appending(path: resourceName)
            if FileManager.default.fileExists(atPath: bundledResource.path) {
                return try Data(contentsOf: bundledResource)
            }

            let directResource = directory.appending(path: resourceName)
            if FileManager.default.fileExists(atPath: directResource.path) {
                return try Data(contentsOf: directResource)
            }
        }
        throw ManifestError.missingResource
    }

    public static func load(data: Data) throws -> DeploymentManifest {
        let decoder = JSONDecoder()
        let schema = try decoder.decode(SchemaVersion.self, from: data)

        guard schema.schemaVersion == supportedSchemaVersion else {
            throw ManifestError.unsupportedSchema(schema.schemaVersion)
        }

        let manifest = try decoder.decode(DeploymentManifest.self, from: data)
        try validateSHA256(manifest.runtime.archive.sha256)
        try validateSHA256(manifest.model.sha256)
        return manifest
    }

    private static func validateSHA256(_ value: String) throws {
        let bytes = value.utf8
        guard bytes.count == 64, bytes.allSatisfy(isASCIIHexDigit) else {
            throw ManifestError.invalidSHA256(value)
        }
    }

    private static func isASCIIHexDigit(_ byte: UInt8) -> Bool {
        (48...57).contains(byte) || (65...70).contains(byte) || (97...102).contains(byte)
    }

    private static var defaultResourceSearchDirectories: [URL] {
        let bundles = [Bundle.main] + Bundle.allBundles + Bundle.allFrameworks
        let candidates = bundles.flatMap { bundle in
            [
                bundle.resourceURL,
                bundle.bundleURL,
                bundle.bundleURL.deletingLastPathComponent(),
                bundle.executableURL?.deletingLastPathComponent(),
            ]
        }.compactMap { $0?.standardizedFileURL }

        var seen: Set<String> = []
        return candidates.filter { seen.insert($0.path).inserted }
    }
}

public struct DeploymentArtifact: Codable, Equatable, Sendable {
    public let filename: String
    public let sourceURL: URL
    public let size: Int64
    public let sha256: String

    public init(filename: String, sourceURL: URL, size: Int64, sha256: String) {
        self.filename = filename
        self.sourceURL = sourceURL
        self.size = size
        self.sha256 = sha256
    }
}

public struct RuntimeArtifact: Codable, Equatable, Sendable {
    public let version: String
    public let archive: DeploymentArtifact
    public let directoryName: String
    public let serverRelativePath: String

    public var size: Int64 { archive.size }

    public init(
        version: String,
        archive: DeploymentArtifact,
        directoryName: String,
        serverRelativePath: String
    ) {
        self.version = version
        self.archive = archive
        self.directoryName = directoryName
        self.serverRelativePath = serverRelativePath
    }
}

public struct ServiceDefaults: Codable, Equatable, Sendable {
    public let label: String
    public let port: UInt16

    public init(label: String, port: UInt16) {
        self.label = label
        self.port = port
    }
}

private struct SchemaVersion: Decodable {
    let schemaVersion: Int
}
