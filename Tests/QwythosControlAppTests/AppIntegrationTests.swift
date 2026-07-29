import AppKit
import XCTest
@testable import QwythosControlApp
import QwythosCore
import QwythosDeployment

@MainActor
final class AppIntegrationTests: XCTestCase {
    func testInstallationStatusSelectsDeploymentMenuTitle() async {
        let absentTitle = await makeDelegate(status: .notInstalled).prepareForTesting()
        let legacyTitle = await makeDelegate(status: .legacyDetected).prepareForTesting()
        let managedTitle = await makeDelegate(
            status: .managedHealthy(record)
        ).prepareForTesting()

        XCTAssertEqual(absentTitle, "Deploy Qwythos...")
        XCTAssertEqual(legacyTitle, "Migrate Existing Installation...")
        XCTAssertEqual(managedTitle, "Manage Installation...")
    }

    func testMissingPlistShowsNotInstalledAndDisablesServiceToggle() async {
        let delegate = makeDelegate(status: .notInstalled, plistExists: false)

        _ = await delegate.prepareForTesting()

        XCTAssertEqual(delegate.statusTextForTesting, "Status: Not Installed")
        XCTAssertFalse(delegate.isServiceToggleEnabledForTesting)
    }

    func testEveryUnmanagedInspectionStateSuppressesMissingPlistFailure() async {
        let unavailableRoot = URL(fileURLWithPath: "/Volumes/Unavailable/Qwythos")
        let statuses: [(InstallationStatus, String)] = [
            (.notInstalled, "Deploy Qwythos..."),
            (.partiallyDownloaded, "Deploy Qwythos..."),
            (.legacyDetected, "Migrate Existing Installation..."),
            (.installationRootUnavailable(unavailableRoot), "Deploy Qwythos..."),
            (.managedIncompatible("Unsupported record."), "Deploy Qwythos..."),
            (.managedRepairable(record, [.launchAgent]), "Manage Installation..."),
        ]

        for (status, deploymentTitle) in statuses {
            let delegate = makeDelegate(status: status, plistExists: false)
            _ = await delegate.prepareForTesting()

            XCTAssertEqual(delegate.statusTextForTesting, "Status: Not Installed")
            XCTAssertFalse(delegate.isServiceToggleEnabledForTesting)
            XCTAssertEqual(delegate.deploymentMenuTitleForTesting, deploymentTitle)
        }
    }

    func testLegacyAndRepairableStatesFollowActualPlistAvailability() async {
        let legacy = makeDelegate(status: .legacyDetected, plistExists: true)
        _ = await legacy.prepareForTesting()

        XCTAssertEqual(legacy.statusTextForTesting, "Status: Stopped")
        XCTAssertTrue(legacy.isServiceToggleEnabledForTesting)
        XCTAssertEqual(legacy.deploymentMenuTitleForTesting, "Migrate Existing Installation...")

        let repairable = makeDelegate(
            status: .managedRepairable(record, [.configuration]),
            plistExists: true
        )
        _ = await repairable.prepareForTesting()

        XCTAssertEqual(repairable.statusTextForTesting, "Status: Stopped")
        XCTAssertTrue(repairable.isServiceToggleEnabledForTesting)
        XCTAssertEqual(repairable.deploymentMenuTitleForTesting, "Manage Installation...")

        let unloadedLaunchAgent = makeDelegate(
            status: .managedRepairable(record, [.launchAgent]),
            plistExists: true
        )
        _ = await unloadedLaunchAgent.prepareForTesting()

        XCTAssertEqual(unloadedLaunchAgent.statusTextForTesting, "Status: Stopped")
        XCTAssertTrue(unloadedLaunchAgent.isServiceToggleEnabledForTesting)
    }

    func testDeploymentMenuReopensDuringDeploymentButNotTrayServiceOperation() async {
        let coordinator = AppIntegrationCoordinator(status: .notInstalled)
        let delegate = makeDelegate(coordinator: coordinator)
        _ = await delegate.prepareForTesting()

        await coordinator.emit(.init(
            phase: .downloadingModel,
            statusText: "Downloading model..."
        ))
        await waitUntil("deployment becomes busy") { delegate.deploymentIsBusyForTesting }

        XCTAssertTrue(delegate.isDeploymentMenuEnabledForTesting)
        XCTAssertTrue(delegate.showDeploymentWizardForTesting())
        XCTAssertTrue(delegate.showDeploymentWizardForTesting())
        XCTAssertEqual(delegate.deploymentWindowShowCountForTesting, 2)

    }

    func testUnavailableDeploymentResourcesLeaveControlCenterUsable() async {
        let unavailableModel = AppDelegate.deploymentModel {
            throw AppIntegrationResourceError.unavailable
        }
        let delegate = makeDelegate(
            coordinator: AppIntegrationCoordinator(status: .notInstalled),
            deploymentModel: unavailableModel
        )

        _ = await delegate.prepareForTesting()

        XCTAssertEqual(delegate.statusTextForTesting, "Status: Stopped")
        XCTAssertTrue(delegate.isServiceToggleEnabledForTesting)
        XCTAssertTrue(delegate.isDeploymentMenuEnabledForTesting)
        XCTAssertTrue(delegate.showDeploymentWizardForTesting())
        XCTAssertTrue(delegate.deploymentResourceErrorForTesting?.contains("unavailable") == true)
    }

    func testDeploymentModelUsesRestoredLocatorRootForPartialInstall() async {
        let customRoot = URL(
            fileURLWithPath: "/Volumes/Qwythos Disk/Qwythos Control"
        )
        let model = AppDelegate.deploymentModel(defaultRoot: customRoot) {
            AppIntegrationCoordinator(status: .partiallyDownloaded)
        }

        await model.start()

        XCTAssertEqual(model.selectedRoot, customRoot.standardizedFileURL)
    }

    func testUnavailableDeploymentResourcesDoNotSuppressRunningServiceControls() async {
        let model = AppDelegate.deploymentModel {
            throw AppIntegrationResourceError.unavailable
        }
        let runner = AppIntegrationRunner(
            printExitCode: 0,
            printOutput: "state = running"
        )
        let service = ServiceController(
            configuration: configuration,
            runner: runner,
            healthChecker: AppIntegrationHealthChecker(result: true),
            fileChecker: AppIntegrationFileChecker(exists: true)
        )
        let delegate = AppDelegate(
            configuration: configuration,
            controller: service,
            deploymentModel: model,
            deploymentWindowPresenter: {},
            servicePlistChecker: AppIntegrationFileChecker(exists: true)
        )

        _ = await delegate.prepareForTesting()

        XCTAssertEqual(delegate.statusTextForTesting, "Status: Running")
        XCTAssertTrue(delegate.isServiceToggleEnabledForTesting)
        XCTAssertTrue(delegate.deploymentResourceErrorForTesting?.contains("unavailable") == true)
    }

    func testTrayOperationMakesWizardMutationsExternallyBusyUntilCompletion() async {
        let coordinator = AppIntegrationCoordinator(status: .managedHealthy(record))
        let model = DeploymentWizardModel(
            coordinator: coordinator,
            preflight: { _ in AppIntegrationFixtures.healthyPreflight }
        )
        let runner = BlockingServiceRunner()
        let service = ServiceController(
            configuration: configuration,
            runner: runner,
            healthChecker: AppIntegrationHealthChecker(),
            fileChecker: AppIntegrationFileChecker(exists: true)
        )
        let delegate = AppDelegate(
            configuration: configuration,
            controller: service,
            deploymentModel: model,
            deploymentWindowPresenter: {},
            servicePlistChecker: AppIntegrationFileChecker(exists: true)
        )
        _ = await delegate.prepareForTesting()
        await waitUntil("service toggle becomes available") {
            delegate.isServiceToggleEnabledForTesting
        }

        delegate.triggerServiceToggleForTesting()
        await waitUntil("service operation begins") {
            await runner.isWaitingForServiceOperation()
        }
        await waitUntil("wizard receives tray busy state") { model.externalOperationInProgress }

        await model.repair()
        await model.reinstallRuntime()
        await model.updateAccessMode()
        await model.regenerateAPIKey()
        model.requestUninstall()
        await model.pause()
        await model.cancel()
        let callsWhileTrayBusy = await coordinator.recordedCalls()
        XCTAssertTrue(callsWhileTrayBusy.isEmpty)

        await runner.finishServiceOperation()
        await waitUntil("wizard clears tray busy state") { !model.externalOperationInProgress }
    }

    func testCompletedDeploymentRefreshesServiceAndMenuState() async {
        let coordinator = AppIntegrationCoordinator(status: .notInstalled)
        let delegate = makeDelegate(coordinator: coordinator)
        _ = await delegate.prepareForTesting()
        let refreshesBeforeCompletion = await delegate.serviceRefreshCountForTesting

        await coordinator.setStatus(.managedHealthy(record))
        await coordinator.emit(.init(phase: .installed, statusText: "Qwythos is installed."))
        await waitUntil("deployment title updates") {
            delegate.deploymentMenuTitleForTesting == "Manage Installation..."
        }
        await waitUntil("service refresh completes") {
            await delegate.serviceRefreshCountForTesting > refreshesBeforeCompletion
        }

        XCTAssertEqual(delegate.deploymentMenuTitleForTesting, "Manage Installation...")
        let refreshesAfterCompletion = await delegate.serviceRefreshCountForTesting
        XCTAssertGreaterThan(refreshesAfterCompletion, refreshesBeforeCompletion)
    }

    private func makeDelegate(
        status: InstallationStatus = .notInstalled,
        plistExists: Bool = true
    ) -> AppDelegate {
        makeDelegate(
            coordinator: AppIntegrationCoordinator(status: status),
            plistExists: plistExists
        )
    }

    private func makeDelegate(
        coordinator: AppIntegrationCoordinator,
        plistExists: Bool = true,
        deploymentResourceError: String? = nil,
        deploymentModel: DeploymentWizardModel? = nil
    ) -> AppDelegate {
        let runner = AppIntegrationRunner()
        let service = ServiceController(
            configuration: configuration,
            runner: runner,
            healthChecker: AppIntegrationHealthChecker(),
            fileChecker: AppIntegrationFileChecker(exists: plistExists)
        )
        let model = deploymentModel ?? DeploymentWizardModel(
            coordinator: coordinator,
            deploymentResourceError: deploymentResourceError,
            preflight: { _ in .init(
                architectureSupported: true,
                operatingSystemSupported: true,
                memorySufficient: true,
                storageSufficient: true,
                rootWritable: true,
                portAvailable: true,
                issues: []
            ) }
        )
        return AppDelegate(
            configuration: configuration,
            controller: service,
            deploymentModel: model,
            deploymentWindowPresenter: {},
            serviceRefreshCount: { await runner.refreshCount },
            servicePlistChecker: AppIntegrationFileChecker(exists: plistExists)
        )
    }

    private var configuration: ServiceConfiguration {
        .init(
            uid: getuid(),
            label: "com.local.qwythos-integration-tests",
            plistPath: "/tmp/com.local.qwythos-integration-tests.plist",
            healthURL: URL(string: "http://127.0.0.1:18080/health")!,
            chatURL: URL(string: "http://127.0.0.1:18080")!,
            logsPath: "/tmp/legacy-logs"
        )
    }

    private var record: InstallationRecord {
        .init(
            manifestSchemaVersion: 1,
            root: URL(fileURLWithPath: "/tmp/Qwythos"),
            runtimeVersion: "1.0.0",
            modelSHA256: String(repeating: "a", count: 64),
            contextSize: 8_192,
            accessMode: .local,
            installedAt: .distantPast
        )
    }

    private func waitUntil(
        _ description: String,
        predicate: @escaping @MainActor () async -> Bool
    ) async {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(1))
        while !(await predicate()) {
            guard clock.now < deadline else {
                return XCTFail("Timed out waiting for \(description)")
            }
            try? await clock.sleep(for: .milliseconds(10))
        }
    }
}

private enum AppIntegrationResourceError: Error {
    case unavailable
}

private enum AppIntegrationFixtures {
    static let healthyPreflight = PreflightReport(
        architectureSupported: true,
        operatingSystemSupported: true,
        memorySufficient: true,
        storageSufficient: true,
        rootWritable: true,
        portAvailable: true,
        issues: []
    )
}

private actor AppIntegrationCoordinator: DeploymentCoordinating {
    enum Call: Equatable {
        case deploy
        case migrate
        case pause
        case pauseAndWait
        case repair
        case reinstallRuntime
        case setAccessMode
        case regenerateAPIKey
        case uninstall
    }

    private var status: InstallationStatus
    private var continuation: AsyncStream<DeploymentSnapshot>.Continuation?
    private var calls: [Call] = []

    init(status: InstallationStatus) { self.status = status }

    func snapshots() async -> AsyncStream<DeploymentSnapshot> {
        AsyncStream { continuation = $0 }
    }

    func inspect() async -> InstallationStatus { status }
    func deploy(options: DeploymentOptions) async throws { calls.append(.deploy) }
    func migrate(options: DeploymentOptions) async throws { calls.append(.migrate) }
    func pause() async { calls.append(.pause) }
    func pauseAndWait() async { calls.append(.pauseAndWait) }
    func repair() async throws { calls.append(.repair) }
    func reinstallRuntime() async throws { calls.append(.reinstallRuntime) }
    func setAccessMode(_ mode: NetworkAccessMode) async throws { calls.append(.setAccessMode) }
    func regenerateAPIKey() async throws -> String {
        calls.append(.regenerateAPIKey)
        return "test-key"
    }
    func uninstall(deleteModel: Bool) async throws { calls.append(.uninstall) }
    func setStatus(_ status: InstallationStatus) { self.status = status }
    func emit(_ snapshot: DeploymentSnapshot) { continuation?.yield(snapshot) }
    func recordedCalls() -> [Call] { calls }
}

private actor AppIntegrationRunner: CommandRunning {
    private(set) var refreshCount = 0
    private let printExitCode: Int32
    private let printOutput: String

    init(
        printExitCode: Int32 = 113,
        printOutput: String = "Could not find service \"test\" in domain for user gui: 501"
    ) {
        self.printExitCode = printExitCode
        self.printOutput = printOutput
    }

    func run(_ command: LaunchCommand) async -> CommandResult {
        if command.arguments.first == "print" { refreshCount += 1 }
        return CommandResult(exitCode: printExitCode, output: printOutput)
    }
}

private struct AppIntegrationHealthChecker: HealthChecking {
    let result: Bool

    init(result: Bool = false) { self.result = result }
    func isHealthy(_ url: URL) async -> Bool { result }
}

private struct AppIntegrationFileChecker: FileExistenceChecking {
    let exists: Bool
    func fileExists(atPath path: String) -> Bool { exists }
}

private actor BlockingServiceRunner: CommandRunning {
    private var serviceOperationWaiter: CheckedContinuation<Void, Never>?

    func run(_ command: LaunchCommand) async -> CommandResult {
        if command.arguments.first == "print" {
            return CommandResult(
                exitCode: 113,
                output: "Could not find service \"test\" in domain for user gui: 501"
            )
        }
        await withCheckedContinuation { serviceOperationWaiter = $0 }
        return CommandResult(exitCode: 0, output: "")
    }

    func isWaitingForServiceOperation() -> Bool { serviceOperationWaiter != nil }

    func finishServiceOperation() {
        serviceOperationWaiter?.resume()
        serviceOperationWaiter = nil
    }
}
