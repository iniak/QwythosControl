import Darwin
import Foundation

public protocol LANAddressProviding: Sendable {
    func activeIPv4Addresses() -> [String]
}

public struct LANInterface: Equatable, Sendable {
    public let address: String
    public let flags: UInt32

    public init(address: String, flags: UInt32) {
        self.address = address
        self.flags = flags
    }
}

public struct LANAddressProvider: LANAddressProviding, Sendable {
    private let interfaces: @Sendable () -> [LANInterface]

    public init() {
        self.interfaces = Self.systemInterfaces
    }

    public init(interfaces: @escaping @Sendable () -> [LANInterface]) {
        self.interfaces = interfaces
    }

    public func activeIPv4Addresses() -> [String] {
        var addresses: [String] = []
        var seen: Set<String> = []

        for interface in interfaces() where interface.flags & UInt32(IFF_UP) != 0 {
            guard isLANAddress(interface.address), seen.insert(interface.address).inserted else {
                continue
            }
            addresses.append(interface.address)
        }
        return addresses
    }

    private func isLANAddress(_ address: String) -> Bool {
        let octets = address.split(separator: ".").compactMap { UInt8($0) }
        guard octets.count == 4 else { return false }
        guard octets[0] != 127 else { return false }
        return !(octets[0] == 169 && octets[1] == 254)
    }

    private static func systemInterfaces() -> [LANInterface] {
        var first: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&first) == 0, let first else { return [] }
        defer { freeifaddrs(first) }

        var result: [LANInterface] = []
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let entry = cursor {
            defer { cursor = entry.pointee.ifa_next }
            guard let socketAddress = entry.pointee.ifa_addr,
                  socketAddress.pointee.sa_family == UInt8(AF_INET) else {
                continue
            }

            var address = socketAddress.withMemoryRebound(
                to: sockaddr_in.self,
                capacity: 1
            ) { $0.pointee.sin_addr }
            var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            guard inet_ntop(AF_INET, &address, &buffer, socklen_t(buffer.count)) != nil else {
                continue
            }
            result.append(
                LANInterface(
                    address: String(
                        decoding: buffer.prefix(while: { $0 != 0 }).map(UInt8.init(bitPattern:)),
                        as: UTF8.self
                    ),
                    flags: UInt32(entry.pointee.ifa_flags)
                )
            )
        }
        return result
    }
}
