import Foundation

public struct InstallationLocation: Codable, Equatable, Sendable {
    public let root: URL

    public init(root: URL) {
        self.root = root
    }
}

public protocol InstallationLocating: Sendable {
    func load() throws -> InstallationLocation?
    func save(_ location: InstallationLocation) throws
    func remove() throws
}

public struct InstallationLocator: InstallationLocating {
    public let supportDirectory: URL

    public init(supportDirectory: URL? = nil) {
        self.supportDirectory = supportDirectory?.standardizedFileURL
            ?? Self.defaultInstallationRoot
    }

    public var fileURL: URL {
        supportDirectory.appending(path: "installation-location.json")
    }

    public func load() throws -> InstallationLocation? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return nil
        }

        let data = try Data(contentsOf: fileURL)
        return try JSONDecoder().decode(InstallationLocation.self, from: data)
    }

    public func save(_ location: InstallationLocation) throws {
        try POSIXDirectoryDescriptor.validateRootURL(location.root)
        try FileManager.default.createDirectory(
            at: supportDirectory,
            withIntermediateDirectories: true
        )
        let data = try JSONEncoder().encode(location)
        try data.write(to: fileURL, options: .atomic)
    }

    public func remove() throws {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return
        }
        try FileManager.default.removeItem(at: fileURL)
    }

    public static var defaultInstallationRoot: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "Qwythos Control", directoryHint: .isDirectory)
            .standardizedFileURL
    }
}
