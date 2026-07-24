import XCTest
@testable import QwythosCore

final class LaunchctlPrintParserTests: XCTestCase {
    func testParsesRunningJob() {
        let outcome = LaunchctlPrintParser.parse(
            CommandResult(
                exitCode: 0,
                output: """
                gui/501/com.local.qwythos-9b = {
                    state = running
                    pid = 1234
                    last exit code = 1
                }
                """
            )
        )

        XCTAssertEqual(outcome, .running)
    }

    func testParsesLoadedJobThatIsStillWaiting() {
        let outcome = LaunchctlPrintParser.parse(
            CommandResult(
                exitCode: 0,
                output: """
                gui/501/com.local.qwythos-9b = {
                    state = waiting
                    last exit code = 0
                }
                """
            )
        )

        XCTAssertEqual(outcome, .loaded)
    }

    func testParsesLoadedJobWithNonzeroLastExitAsFailed() {
        let outcome = LaunchctlPrintParser.parse(
            CommandResult(
                exitCode: 0,
                output: """
                gui/501/com.local.qwythos-9b = {
                    state = waiting
                    last exit code = 78
                }
                """
            )
        )

        guard case .failedLoaded(let message) = outcome else {
            return XCTFail("Expected failed loaded outcome, got \(outcome)")
        }
        XCTAssertTrue(message.contains("waiting"))
        XCTAssertTrue(message.contains("last exit code 78"))
    }

    func testParsesExitedLongRunningJobAsFailedEvenWithZeroExitCode() {
        let outcome = LaunchctlPrintParser.parse(
            CommandResult(
                exitCode: 0,
                output: """
                gui/501/com.local.qwythos-9b = {
                    state = exited
                    last exit code = 0
                }
                """
            )
        )

        guard case .failedLoaded(let message) = outcome else {
            return XCTFail("Expected failed loaded outcome, got \(outcome)")
        }
        XCTAssertTrue(message.contains("exited"))
    }

    func testParsesCanonicalMissingServiceResponseAsAbsent() {
        let outcome = LaunchctlPrintParser.parse(
            CommandResult(
                exitCode: 113,
                output: """
                Bad request.
                Could not find service "com.local.qwythos-9b" in domain for user gui: 501
                """
            )
        )

        XCTAssertEqual(outcome, .absent)
    }

    func testDoesNotTreatOtherNonzeroResultsAsAbsent() {
        let outcome = LaunchctlPrintParser.parse(
            CommandResult(exitCode: 1, output: "Operation not permitted")
        )

        guard case .queryFailed(let message) = outcome else {
            return XCTFail("Expected query failure, got \(outcome)")
        }
        XCTAssertTrue(message.contains("exit 1"))
        XCTAssertTrue(message.contains("Operation not permitted"))
    }

    func testDoesNotTreatUnparseableSuccessfulOutputAsLoaded() {
        let outcome = LaunchctlPrintParser.parse(
            CommandResult(exitCode: 0, output: "unexpected output")
        )

        guard case .queryFailed(let message) = outcome else {
            return XCTFail("Expected query failure, got \(outcome)")
        }
        XCTAssertTrue(message.localizedCaseInsensitiveContains("interpret"))
    }
}
