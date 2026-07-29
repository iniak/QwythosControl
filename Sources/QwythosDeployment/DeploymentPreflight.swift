import Darwin
import Foundation
import Network

public protocol SystemProfileProviding: Sendable {
    var architecture: String { get }
    var operatingSystem: OperatingSystemVersion { get }
    var physicalMemory: UInt64 { get }
    func prepareRootForPreflight(_ url: URL) throws
    func availableCapacity(at url: URL) throws -> Int64
    func isWritable(_ url: URL) -> Bool
}

public extension SystemProfileProviding {
    func prepareRootForPreflight(_ url: URL) throws {}
}

public protocol PortChecking: Sendable {
    func isAvailable(port: UInt16) async -> Bool
}

public enum PerformanceProfileError: Error, Equatable, Sendable {
    case insufficientMemory
}

public struct PerformanceProfile: Equatable, Sendable {
    public static let minimumPhysicalMemory: UInt64 = 16 * 1_073_741_824
    public static let expandedContextPhysicalMemory: UInt64 = 24 * 1_073_741_824

    public let contextSize: Int

    public static func automatic(physicalMemory: UInt64) throws -> PerformanceProfile {
        guard physicalMemory >= minimumPhysicalMemory else {
            throw PerformanceProfileError.insufficientMemory
        }

        return PerformanceProfile(
            contextSize: physicalMemory >= expandedContextPhysicalMemory ? 16_384 : 8_192
        )
    }

    private init(contextSize: Int) {
        self.contextSize = contextSize
    }
}

public enum PreflightIssue: Equatable, Hashable, Sendable {
    case unsupportedArchitecture(String)
    case unsupportedOperatingSystem(Int)
    case insufficientMemory
    case insufficientStorage
    case unavailableStorage
    case unwritableRoot
    case portUnavailable(UInt16)
}

public struct PreflightReport: Equatable, Sendable {
    public let architectureSupported: Bool
    public let operatingSystemSupported: Bool
    public let memorySufficient: Bool
    public let storageSufficient: Bool
    public let rootWritable: Bool
    public let portAvailable: Bool
    public let issues: [PreflightIssue]

    public init(
        architectureSupported: Bool,
        operatingSystemSupported: Bool,
        memorySufficient: Bool,
        storageSufficient: Bool,
        rootWritable: Bool,
        portAvailable: Bool,
        issues: [PreflightIssue]
    ) {
        self.architectureSupported = architectureSupported
        self.operatingSystemSupported = operatingSystemSupported
        self.memorySufficient = memorySufficient
        self.storageSufficient = storageSufficient
        self.rootWritable = rootWritable
        self.portAvailable = portAvailable
        self.issues = issues
    }

    public var canDeploy: Bool {
        architectureSupported && operatingSystemSupported && memorySufficient
            && storageSufficient && rootWritable && portAvailable
    }
}

public struct DeploymentPreflight: Sendable {
    public static let requiredArchitecture = "arm64"
    public static let minimumOperatingSystemMajorVersion = 13
    public static let minimumAvailableCapacity: Int64 = 8_000_000_000

    private let profile: any SystemProfileProviding
    private let portChecker: any PortChecking

    public init(
        profile: any SystemProfileProviding = SystemProfile(),
        portChecker: any PortChecking = LoopbackPortChecker()
    ) {
        self.profile = profile
        self.portChecker = portChecker
    }

    public func run(root: URL, servicePort: UInt16) async -> PreflightReport {
        let architectureSupported = profile.architecture == Self.requiredArchitecture
        let operatingSystemSupported = profile.operatingSystem.majorVersion
            >= Self.minimumOperatingSystemMajorVersion
        let memorySufficient = profile.physicalMemory >= PerformanceProfile.minimumPhysicalMemory
        let portAvailable = await portChecker.isAvailable(port: servicePort)

        var issues: [PreflightIssue] = []
        if !architectureSupported {
            issues.append(.unsupportedArchitecture(profile.architecture))
        }
        if !operatingSystemSupported {
            issues.append(.unsupportedOperatingSystem(profile.operatingSystem.majorVersion))
        }
        if !memorySufficient {
            issues.append(.insufficientMemory)
        }

        let rootPrepared: Bool
        do {
            try profile.prepareRootForPreflight(root)
            rootPrepared = true
        } catch {
            rootPrepared = false
        }
        let rootWritable = rootPrepared && profile.isWritable(root)

        let storageSufficient: Bool
        do {
            guard rootPrepared else {
                throw SystemProfileError.unavailableCapacity
            }
            storageSufficient = try profile.availableCapacity(at: root)
                >= Self.minimumAvailableCapacity
            if !storageSufficient {
                issues.append(.insufficientStorage)
            }
        } catch {
            storageSufficient = false
            issues.append(.unavailableStorage)
        }

        if !rootWritable {
            issues.append(.unwritableRoot)
        }
        if !portAvailable {
            issues.append(.portUnavailable(servicePort))
        }

        return PreflightReport(
            architectureSupported: architectureSupported,
            operatingSystemSupported: operatingSystemSupported,
            memorySufficient: memorySufficient,
            storageSufficient: storageSufficient,
            rootWritable: rootWritable,
            portAvailable: portAvailable,
            issues: issues
        )
    }
}

public struct SystemProfile: SystemProfileProviding {
    public init() {}

    public var architecture: String {
        var systemInfo = utsname()
        uname(&systemInfo)
        let machine = systemInfo.machine
        return withUnsafePointer(to: machine) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: MemoryLayout.size(ofValue: machine)) {
                String(cString: $0)
            }
        }
    }

    public var operatingSystem: OperatingSystemVersion {
        ProcessInfo.processInfo.operatingSystemVersion
    }

    public var physicalMemory: UInt64 {
        ProcessInfo.processInfo.physicalMemory
    }

    public func prepareRootForPreflight(_ url: URL) throws {
        _ = try POSIXDirectoryDescriptor.openOrCreateRoot(url)
    }

    public func availableCapacity(at url: URL) throws -> Int64 {
        let directory: POSIXDirectoryDescriptor
        do {
            directory = try POSIXDirectoryDescriptor.openRoot(url)
        } catch {
            throw SystemProfileError.unavailableCapacity
        }
        var values = statfs()
        guard fstatfs(directory.rawValue, &values) == 0 else {
            throw SystemProfileError.unavailableCapacity
        }
        let blockCount = Int64(clamping: values.f_bavail)
        let blockSize = Int64(clamping: values.f_bsize)
        let (capacity, overflow) = blockCount.multipliedReportingOverflow(
            by: blockSize
        )
        return overflow ? Int64.max : capacity
    }

    public func isWritable(_ url: URL) -> Bool {
        guard let directory = try? POSIXDirectoryDescriptor.openRoot(url) else {
            return false
        }
        let probeName = ".qwythos-preflight-\(UUID().uuidString)"
        let descriptor = openat(
            directory.rawValue,
            probeName,
            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
            0o600
        )
        guard descriptor >= 0 else { return false }
        let closeResult = close(descriptor)
        let removeResult = unlinkat(directory.rawValue, probeName, 0)
        return closeResult == 0 && removeResult == 0
    }
}

public enum SystemProfileError: Error, Equatable, Sendable {
    case unavailableCapacity
}

public final class LoopbackPortChecker: PortChecking, @unchecked Sendable {
    public init() {}

    public func isAvailable(port: UInt16) async -> Bool {
        guard let port = NWEndpoint.Port(rawValue: port) else {
            return false
        }

        return await withCheckedContinuation { continuation in
            let parameters = NWParameters.tcp
            parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: port)

            do {
                let listener = try NWListener(using: parameters)
                let result = PortProbeResult()
                listener.stateUpdateHandler = { state in
                    switch state {
                    case .ready:
                        listener.cancel()
                        result.finish(continuation, with: true)
                    case .failed:
                        listener.cancel()
                        result.finish(continuation, with: false)
                    default:
                        break
                    }
                }
                listener.start(queue: .global(qos: .userInitiated))
            } catch {
                continuation.resume(returning: false)
            }
        }
    }
}

private final class PortProbeResult: @unchecked Sendable {
    private let lock = NSLock()
    private var completed = false

    func finish(_ continuation: CheckedContinuation<Bool, Never>, with value: Bool) {
        lock.lock()
        defer { lock.unlock() }
        guard !completed else { return }
        completed = true
        continuation.resume(returning: value)
    }
}
