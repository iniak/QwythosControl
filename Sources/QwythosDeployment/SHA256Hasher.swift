import CryptoKit
import Darwin
import Foundation

public protocol FileHashing: Sendable {
    func sha256(file: URL) throws -> String
    func sha256(fileDescriptor: Int32) throws -> String
}

public extension FileHashing {
    func sha256(fileDescriptor: Int32) throws -> String {
        try sha256(file: URL(fileURLWithPath: "/dev/fd/\(fileDescriptor)"))
    }
}

public struct SHA256Hasher: FileHashing {
    public init() {}

    public func sha256(file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }

        var hasher = SHA256()
        while true {
            try Task.checkCancellation()
            guard let chunk = try handle.read(upToCount: 1_048_576),
                  !chunk.isEmpty else {
                break
            }
            hasher.update(data: chunk)
        }

        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    public func sha256(fileDescriptor: Int32) throws -> String {
        var hasher = SHA256()
        var offset: off_t = 0
        var buffer = [UInt8](repeating: 0, count: 1_048_576)

        while true {
            try Task.checkCancellation()
            let count = pread(fileDescriptor, &buffer, buffer.count, offset)
            if count < 0 {
                if errno == EINTR { continue }
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            if count == 0 { break }
            hasher.update(data: Data(buffer.prefix(count)))
            offset += off_t(count)
        }

        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
