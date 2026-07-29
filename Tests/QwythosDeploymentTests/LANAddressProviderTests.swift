import Darwin
import XCTest
@testable import QwythosDeployment

final class LANAddressProviderTests: XCTestCase {
    func testFiltersInactiveLoopbackAndLinkLocalAddresses() {
        let cases: [(LANInterface, Bool)] = [
            (.init(address: "127.0.0.1", flags: UInt32(IFF_UP)), false),
            (.init(address: "169.254.10.2", flags: UInt32(IFF_UP)), false),
            (.init(address: "192.168.1.4", flags: 0), false),
            (.init(address: "192.168.1.5", flags: UInt32(IFF_UP)), true),
            (.init(address: "10.0.0.8", flags: UInt32(IFF_UP)), true),
        ]
        let provider = LANAddressProvider(interfaces: { cases.map(\.0) })

        XCTAssertEqual(provider.activeIPv4Addresses(), ["192.168.1.5", "10.0.0.8"])
    }

    func testReturnsEveryActiveWiFiAndEthernetAddressOnce() {
        let provider = LANAddressProvider(interfaces: {
            [
                .init(address: "192.168.0.12", flags: UInt32(IFF_UP)),
                .init(address: "10.0.0.12", flags: UInt32(IFF_UP)),
                .init(address: "192.168.0.12", flags: UInt32(IFF_UP)),
            ]
        })

        XCTAssertEqual(
            provider.activeIPv4Addresses().map { "http://\($0):18080" },
            ["http://192.168.0.12:18080", "http://10.0.0.12:18080"]
        )
    }
}
