import Foundation
import XCTest
@testable import QwythosCore

final class URLSessionHealthCheckerTests: XCTestCase {
    func testAcceptsValidOKJSONRegardlessOfWhitespaceAndKeyOrdering() {
        let data = Data(#"{ "detail": "ready", "status" : "ok" }"#.utf8)

        XCTAssertTrue(
            URLSessionHealthChecker.isHealthyResponse(statusCode: 200, data: data)
        )
    }

    func testRejectsMalformedAndNonOKBodies() {
        XCTAssertFalse(
            URLSessionHealthChecker.isHealthyResponse(
                statusCode: 200,
                data: Data(#"{"status":"starting"}"#.utf8)
            )
        )
        XCTAssertFalse(
            URLSessionHealthChecker.isHealthyResponse(
                statusCode: 200,
                data: Data("not json".utf8)
            )
        )
    }

    func testRejectsNon200ResponseEvenWithOKBody() {
        XCTAssertFalse(
            URLSessionHealthChecker.isHealthyResponse(
                statusCode: 503,
                data: Data(#"{"status":"ok"}"#.utf8)
            )
        )
    }

    func testHardDeadlineCancelsARequestThatNeverCompletes() async {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [NeverCompletingURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let checker = URLSessionHealthChecker(
            session: session,
            timeout: .milliseconds(50)
        )
        let clock = ContinuousClock()
        let start = clock.now

        let healthy = await checker.isHealthy(
            URL(string: "http://health.test/never")!
        )

        XCTAssertFalse(healthy)
        XCTAssertLessThan(start.duration(to: clock.now), .seconds(1))
    }
}

private final class NeverCompletingURLProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {}

    override func stopLoading() {}
}
