import Foundation
import XCTest
@testable import QwythosControlApp
import QwythosCore
import QwythosDeployment

final class ProductionDeploymentCoordinatorFactoryTests: XCTestCase {
    func testFactoryInspectsDefaultAndCustomRootsWithoutCapturingStartupLayout() async throws {
        let defaultLocator = FactoryInstallationLocator()
        let defaultCoordinator = try AppDelegate.productionDeploymentCoordinator(
            configuration: configuration,
            service: FactoryService(),
            locator: defaultLocator
        )
        let defaultStatus = await defaultCoordinator.inspect()
        XCTAssertNotEqual(
            defaultStatus,
            .installationRootUnavailable(
                InstallationLocator.defaultInstallationRoot
            )
        )

        let customRoot = FileManager.default.temporaryDirectory
            .appending(path: "Qwythos-custom-\(UUID().uuidString)")
        let customLocator = FactoryInstallationLocator(root: customRoot)
        let customCoordinator = try AppDelegate.productionDeploymentCoordinator(
            configuration: configuration,
            service: FactoryService(),
            locator: customLocator
        )
        let customStatus = await customCoordinator.inspect()
        XCTAssertNotEqual(
            customStatus,
            .managedIncompatible("The installation location cannot be read.")
        )
    }

    func testFactoryTurnsUnreadableLocationIntoRecoveryStatus() async throws {
        let coordinator = try AppDelegate.productionDeploymentCoordinator(
            configuration: configuration,
            service: FactoryService(),
            locator: UnreadableFactoryLocator()
        )

        let status = await coordinator.inspect()
        XCTAssertEqual(
            status,
            .managedIncompatible("The installation location cannot be read.")
        )
    }

    private var configuration: ServiceConfiguration {
        ServiceConfiguration(
            uid: getuid(),
            label: "com.local.qwythos-factory-tests",
            plistPath: "/tmp/com.local.qwythos-factory-tests.plist",
            healthURL: URL(string: "http://127.0.0.1:18080/health")!,
            chatURL: URL(string: "http://127.0.0.1:18080")!,
            logsPath: "/tmp"
        )
    }
}

private final class FactoryInstallationLocator: InstallationLocating, @unchecked Sendable {
    private var location: InstallationLocation?

    init(root: URL? = nil) {
        location = root.map(InstallationLocation.init(root:))
    }

    func load() throws -> InstallationLocation? { location }
    func save(_ location: InstallationLocation) throws { self.location = location }
    func remove() throws { location = nil }
}

private struct UnreadableFactoryLocator: InstallationLocating {
    enum Failure: Error { case unreadable }

    func load() throws -> InstallationLocation? { throw Failure.unreadable }
    func save(_ location: InstallationLocation) throws {}
    func remove() throws {}
}

private actor FactoryService: ManagedServiceControlling {
    func start() async throws {}
    func stop() async throws {}
}
