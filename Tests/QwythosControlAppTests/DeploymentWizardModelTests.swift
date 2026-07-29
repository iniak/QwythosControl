import Foundation
import XCTest
@testable import QwythosControlApp
import QwythosDeployment

@MainActor
final class DeploymentWizardModelTests: XCTestCase {
    func testWizardCannotAdvanceUntilPreflightPasses() async {
        let coordinator = WizardCoordinator(status: .notInstalled)
        let model = DeploymentWizardModel(
            coordinator: coordinator,
            preflight: { _ in PreflightFixtures.failing }
        )

        await model.start()

        XCTAssertEqual(model.step, .deviceCheck)
        XCTAssertFalse(model.canContinue)
    }

    func testHealthyInstallOpensManagementInsteadOfDeployFlow() async {
        let record = Self.record(accessMode: .local)
        let model = DeploymentWizardModel(
            coordinator: WizardCoordinator(status: .managedHealthy(record)),
            preflight: { _ in PreflightFixtures.healthy }
        )

        await model.start()

        XCTAssertEqual(model.step, .management)
        XCTAssertEqual(model.selectedRoot, record.root)
        XCTAssertEqual(model.contextSize, record.contextSize)
    }

    func testUnreadableInstallationLocationShowsRecoveryState() async {
        let model = DeploymentWizardModel(
            coordinator: WizardCoordinator(
                status: .managedIncompatible(
                    "The installation location cannot be read."
                )
            ),
            preflight: { _ in PreflightFixtures.healthy }
        )

        await model.start()

        XCTAssertEqual(model.step, .deviceCheck)
        XCTAssertEqual(
            model.installationRecoveryMessage,
            "The installation location cannot be read."
        )
    }

    func testUnavailableSavedRootIsRestoredWithoutCreatingOrPreflightingIt() async {
        let unavailableRoot = URL(
            fileURLWithPath: "/Volumes/Qwythos Missing/Qwythos Control"
        )
        let preflightRoots = LockedURLValues()
        let model = DeploymentWizardModel(
            coordinator: WizardCoordinator(
                status: .installationRootUnavailable(unavailableRoot)
            ),
            defaultRoot: URL(fileURLWithPath: "/tmp/default-qwythos"),
            preflight: { root in
                preflightRoots.append(root)
                return PreflightFixtures.healthy
            }
        )

        await model.start()

        XCTAssertEqual(model.selectedRoot, unavailableRoot.standardizedFileURL)
        XCTAssertTrue(preflightRoots.values.isEmpty)
        XCTAssertEqual(
            model.installationRecoveryMessage,
            "The installation location is unavailable: \(unavailableRoot.path)"
        )
    }

    func testCleanFirstLaunchPreflightsTheDefaultRoot() async {
        let defaultRoot = InstallationLocator.defaultInstallationRoot
        let preflightRoots = LockedURLValues()
        let model = DeploymentWizardModel(
            coordinator: WizardCoordinator(status: .notInstalled),
            defaultRoot: defaultRoot,
            preflight: { root in
                preflightRoots.append(root)
                return PreflightFixtures.healthy
            }
        )

        await model.start()

        XCTAssertEqual(preflightRoots.values, [defaultRoot])
        XCTAssertNil(model.installationRecoveryMessage)
        XCTAssertTrue(model.canContinue)
    }

    func testPartiallyDownloadedInstallationKeepsLocatorRestoredRoot() async {
        let customRoot = URL(fileURLWithPath: "/private/tmp/Qwythos Custom")
        let preflightRoots = LockedURLValues()
        let model = DeploymentWizardModel(
            coordinator: WizardCoordinator(status: .partiallyDownloaded),
            defaultRoot: customRoot,
            preflight: { root in
                preflightRoots.append(root)
                return PreflightFixtures.healthy
            }
        )

        await model.start()

        XCTAssertEqual(model.selectedRoot, customRoot.standardizedFileURL)
        XCTAssertEqual(preflightRoots.values, [customRoot.standardizedFileURL])
    }

    func testAutomaticContextUsesSuppliedPerformanceProfile() {
        let model = DeploymentWizardModel(
            coordinator: WizardCoordinator(status: .notInstalled),
            automaticContextSize: 16_384
        )

        XCTAssertEqual(model.contextSize, 16_384)
        XCTAssertEqual(model.automaticContextSize, 16_384)
    }

    func testSelectingCustomStorageStandardizesPathAndRequiresRemovableAcknowledgement() async {
        let root = URL(fileURLWithPath: "/Volumes/Qwythos/../Qwythos")
        let model = DeploymentWizardModel(
            coordinator: WizardCoordinator(status: .notInstalled),
            preflight: { _ in PreflightFixtures.healthy },
            isRemovableVolume: { _ in true }
        )

        model.selectRoot(root)
        await model.refreshPreflight()

        XCTAssertEqual(model.selectedRoot, root.standardizedFileURL)
        XCTAssertTrue(model.requiresRemovableVolumeAcknowledgement)
        XCTAssertFalse(model.canContinue)

        model.acknowledgeRemovableVolume()

        XCTAssertTrue(model.canContinue)
    }

    func testSharedModeMakesLANWarningVisibleWithoutExposingAPIKey() async {
        let model = DeploymentWizardModel(
            coordinator: WizardCoordinator(status: .notInstalled),
            preflight: { _ in PreflightFixtures.healthy }
        )
        await model.start()
        model.continueToNextStep()

        model.pendingAccessMode = .shared

        XCTAssertTrue(model.showsLANWarning)
        XCTAssertNil(model.lanAuthorizationValue)
    }

    func testSharedKeyRequiresExplicitSecureReadForCopyAndReveal() async {
        let key = String(repeating: "A", count: 43)
        let reads = LockedURLValues()
        let clipboard = LockedStringValues()
        let record = Self.record(accessMode: .shared)
        let model = DeploymentWizardModel(
            coordinator: WizardCoordinator(status: .managedHealthy(record)),
            preflight: { _ in PreflightFixtures.healthy },
            apiKeyLoader: { url in
                reads.append(url)
                return key
            },
            clipboardWriter: { clipboard.append($0) }
        )
        await model.start()

        XCTAssertNil(model.revealedAPIKey)
        XCTAssertTrue(reads.values.isEmpty)

        model.copyAPIKey()

        XCTAssertEqual(
            reads.values,
            [InstallationLayout(root: record.root).apiKeyFile]
        )
        XCTAssertEqual(clipboard.values, [key])
        XCTAssertNil(model.revealedAPIKey)

        model.toggleAPIKeyReveal()
        XCTAssertEqual(model.revealedAPIKey, key)
        model.toggleAPIKeyReveal()
        XCTAssertNil(model.revealedAPIKey)
        XCTAssertNil(model.lanAuthorizationValue)
    }

    func testNetworkAccessApplyRequiresAnActualChange() async {
        let model = DeploymentWizardModel(
            coordinator: WizardCoordinator(
                status: .managedHealthy(Self.record(accessMode: .local))
            ),
            preflight: { _ in PreflightFixtures.healthy }
        )
        await model.start()

        XCTAssertFalse(model.canApplyAccessMode)
        model.pendingAccessMode = .shared
        XCTAssertTrue(model.canApplyAccessMode)
    }

    func testLegacyInstallationUsesMigrationAsTheReviewAction() async {
        let model = DeploymentWizardModel(
            coordinator: WizardCoordinator(status: .legacyDetected),
            preflight: { _ in PreflightFixtures.healthy }
        )
        await model.start()
        model.continueToNextStep()
        model.continueToNextStep()

        XCTAssertEqual(model.primaryDeploymentTitle, "Migrate Existing Installation")
    }

    func testDeploymentSnapshotRoutesToProgressAndCompletion() async {
        let coordinator = WizardCoordinator(status: .notInstalled)
        let model = DeploymentWizardModel(
            coordinator: coordinator,
            preflight: { _ in PreflightFixtures.healthy },
            lanAddresses: { ["192.168.1.44"] }
        )
        await model.start()
        model.pendingAccessMode = .shared
        await coordinator.emit(.init(
            phase: .downloadingModel,
            component: .model,
            completedBytes: 50,
            totalBytes: 100,
            overallProgress: 0.5,
            statusText: "Downloading model..."
        ))
        await Task.yield()

        XCTAssertEqual(model.step, .progress)
        XCTAssertEqual(model.progressFraction, 0.5)

        await coordinator.emit(.init(
            phase: .installed,
            overallProgress: 1,
            statusText: "Qwythos is installed."
        ))
        await Task.yield()

        XCTAssertEqual(model.step, .completion)
        XCTAssertEqual(model.localEndpoint, "http://127.0.0.1:18080")
        XCTAssertEqual(model.lanEndpoints, ["http://192.168.1.44:18080"])
    }

    func testUninstallRequiresConfirmationAndRoutesDeleteModelChoice() async {
        let coordinator = WizardCoordinator(status: .managedHealthy(Self.record(accessMode: .local)))
        let model = DeploymentWizardModel(
            coordinator: coordinator,
            preflight: { _ in PreflightFixtures.healthy }
        )
        await model.start()

        model.deleteModelOnUninstall = true
        model.requestUninstall()
        XCTAssertTrue(model.isShowingUninstallConfirmation)
        let callsBeforeConfirmation = await coordinator.recordedCalls()
        XCTAssertEqual(callsBeforeConfirmation, [])

        model.setUninstallConfirmationPresented(false)
        await model.confirmUninstall()

        XCTAssertFalse(model.isShowingUninstallConfirmation)
        let callsAfterConfirmation = await coordinator.recordedCalls()
        XCTAssertEqual(callsAfterConfirmation, [.uninstall(deleteModel: true)])
    }

    func testRuntimeVersionDriftAlwaysKeepsManagementActionAvailable() async {
        let older = DeploymentWizardModel(
            coordinator: WizardCoordinator(
                status: .managedHealthy(Self.record(runtimeVersion: "b10000"))
            ),
            bundledRuntimeVersion: "b10159",
            preflight: { _ in PreflightFixtures.healthy }
        )
        await older.start()

        XCTAssertEqual(older.step, .management)
        XCTAssertEqual(older.runtimeActionTitle, "Update Runtime")
        XCTAssertTrue(older.canRunRuntimeAction)

        let newer = DeploymentWizardModel(
            coordinator: WizardCoordinator(
                status: .managedHealthy(Self.record(runtimeVersion: "b20000"))
            ),
            bundledRuntimeVersion: "b10159",
            preflight: { _ in PreflightFixtures.healthy }
        )
        await newer.start()

        XCTAssertEqual(newer.step, .management)
        XCTAssertEqual(newer.runtimeActionTitle, "Reinstall Runtime")
        XCTAssertTrue(newer.canRunRuntimeAction)
    }

    func testActionsRouteToCoordinatorAndPauseOnTermination() async {
        let coordinator = WizardCoordinator(status: .managedHealthy(Self.record(accessMode: .local)))
        let model = DeploymentWizardModel(
            coordinator: coordinator,
            preflight: { _ in PreflightFixtures.healthy }
        )
        await model.start()

        await model.repair()
        await model.reinstallRuntime()
        await model.pauseForTermination()

        let calls = await coordinator.recordedCalls()
        XCTAssertEqual(calls, [.repair, .reinstallRuntime, .pauseAndWait])
    }

    func testTerminationWaitsForTheCoordinatorCheckpoint() async {
        let coordinator = TerminationAwareWizardCoordinator()
        let model = DeploymentWizardModel(
            coordinator: coordinator,
            preflight: { _ in PreflightFixtures.healthy }
        )
        let completion = AsyncCompletion()
        let termination = Task {
            await model.pauseForTermination()
            await completion.markComplete()
        }

        await coordinator.waitUntilPauseRequested()
        let pauseCalls = await coordinator.recordedCalls()
        let completedBeforeCheckpoint = await completion.isComplete
        XCTAssertEqual(pauseCalls, [.pauseAndWait])
        XCTAssertFalse(completedBeforeCheckpoint)

        await coordinator.completeCheckpoint()
        await termination.value
        let completedAfterCheckpoint = await completion.isComplete
        XCTAssertTrue(completedAfterCheckpoint)
    }

    func testReviewAndManagementActionsRouteToCoordinator() async {
        let deployCoordinator = WizardCoordinator(status: .notInstalled)
        let deployModel = DeploymentWizardModel(
            coordinator: deployCoordinator,
            preflight: { _ in PreflightFixtures.healthy }
        )
        await deployModel.start()
        deployModel.continueToNextStep()
        deployModel.continueToNextStep()
        await deployModel.deploy()

        let deployCalls = await deployCoordinator.recordedCalls()
        guard let deployCall = deployCalls.first,
              case .deploy(let deployOptions) = deployCall
        else {
            return XCTFail("Deploy must route deployment options to the coordinator")
        }
        XCTAssertEqual(deployOptions.contextSize, 8_192)
        XCTAssertEqual(deployOptions.accessMode, .local)

        let legacyCoordinator = WizardCoordinator(status: .legacyDetected)
        let legacyModel = DeploymentWizardModel(
            coordinator: legacyCoordinator,
            preflight: { _ in PreflightFixtures.healthy }
        )
        await legacyModel.start()
        await legacyModel.migrate()
        let legacyCalls = await legacyCoordinator.recordedCalls()
        XCTAssertEqual(legacyCalls.count, 1)
        guard case .migrate = legacyCalls[0] else {
            return XCTFail("Legacy flow must call migrate")
        }

        let managementCoordinator = WizardCoordinator(
            status: .managedHealthy(Self.record(accessMode: .local))
        )
        let managementModel = DeploymentWizardModel(
            coordinator: managementCoordinator,
            preflight: { _ in PreflightFixtures.healthy }
        )
        await managementModel.start()
        managementModel.pendingAccessMode = .shared
        await managementModel.updateAccessMode()
        await managementCoordinator.setStatus(
            .managedHealthy(Self.record(accessMode: .shared))
        )
        await managementCoordinator.emit(.init(
            phase: .installed,
            overallProgress: 1,
            statusText: "Qwythos is installed."
        ))
        try? await Task.sleep(for: .milliseconds(10))
        await managementModel.regenerateAPIKey()

        let managementCalls = await managementCoordinator.recordedCalls()
        XCTAssertEqual(managementCalls, [.setAccessMode(.shared), .regenerateAPIKey])
    }

    func testChangingRootInvalidatesAndIgnoresStalePreflight() async throws {
        let slowRoot = URL(fileURLWithPath: "/tmp/Qwythos-slow")
        let currentRoot = URL(fileURLWithPath: "/tmp/Qwythos-current")
        let model = DeploymentWizardModel(
            coordinator: WizardCoordinator(status: .notInstalled),
            preflight: { root in
                if root == slowRoot {
                    try? await Task.sleep(for: .milliseconds(80))
                    return PreflightFixtures.failing
                }
                try? await Task.sleep(for: .milliseconds(10))
                return PreflightFixtures.healthy
            }
        )

        await model.start()
        XCTAssertEqual(model.preflightReport, PreflightFixtures.healthy)

        model.selectRoot(slowRoot)
        XCTAssertNil(model.preflightReport)
        model.selectRoot(currentRoot)

        XCTAssertNil(model.preflightReport)
        try await Task.sleep(for: .milliseconds(120))

        XCTAssertEqual(model.selectedRoot, currentRoot)
        XCTAssertEqual(model.preflightReport, PreflightFixtures.healthy)
        XCTAssertTrue(model.canContinue)
    }

    func testIdleAfterUninstallClearsManagedPresentationState() async {
        let coordinator = WizardCoordinator(
            status: .managedHealthy(Self.record(accessMode: .shared))
        )
        let model = DeploymentWizardModel(
            coordinator: coordinator,
            preflight: { _ in PreflightFixtures.healthy },
            lanAddresses: { ["192.168.1.44"] }
        )
        await model.start()
        await coordinator.emit(.init(
            phase: .installed,
            overallProgress: 1,
            statusText: "Qwythos is installed."
        ))
        await Task.yield()
        model.requestUninstall()
        await model.uninstall()
        await coordinator.setStatus(.notInstalled)
        await coordinator.emit(.init(phase: .idle, statusText: "Not installed."))
        await Task.yield()

        XCTAssertEqual(model.step, .deviceCheck)
        XCTAssertNil(model.installedRecord)
        XCTAssertNil(model.localEndpoint)
        XCTAssertTrue(model.lanEndpoints.isEmpty)
        XCTAssertFalse(model.isMigrationCandidate)
    }

    func testSuccessfulManagementSnapshotRefreshesCommittedAccessMode() async {
        let localRecord = Self.record(accessMode: .local)
        let sharedRecord = Self.record(accessMode: .shared)
        let coordinator = WizardCoordinator(status: .managedHealthy(localRecord))
        let model = DeploymentWizardModel(
            coordinator: coordinator,
            preflight: { _ in PreflightFixtures.healthy }
        )
        await model.start()

        model.pendingAccessMode = .shared
        XCTAssertFalse(model.canRegenerateAPIKey)
        await model.updateAccessMode()
        await coordinator.setStatus(.managedHealthy(sharedRecord))
        await coordinator.emit(.init(
            phase: .installed,
            overallProgress: 1,
            statusText: "Qwythos is installed."
        ))
        try? await Task.sleep(for: .milliseconds(10))

        XCTAssertEqual(model.installedRecord?.accessMode, .shared)
        XCTAssertTrue(model.canRegenerateAPIKey)
    }

    func testRuntimeActionOffersUpdateOrReinstallForEveryManagedRuntime() async {
        let older = DeploymentWizardModel(
            coordinator: WizardCoordinator(
                status: .managedHealthy(Self.record(runtimeVersion: "b9999"))
            ),
            bundledRuntimeVersion: "b10159"
        )
        let equal = DeploymentWizardModel(
            coordinator: WizardCoordinator(
                status: .managedHealthy(Self.record(runtimeVersion: "b10159"))
            ),
            bundledRuntimeVersion: "b10159"
        )
        let newer = DeploymentWizardModel(
            coordinator: WizardCoordinator(
                status: .managedHealthy(Self.record(runtimeVersion: "b20000"))
            ),
            bundledRuntimeVersion: "b10159"
        )
        await older.start()
        await equal.start()
        await newer.start()

        XCTAssertEqual(older.runtimeActionTitle, "Update Runtime")
        XCTAssertEqual(equal.runtimeActionTitle, "Reinstall Runtime")
        XCTAssertEqual(newer.runtimeActionTitle, "Reinstall Runtime")
        XCTAssertTrue(newer.canRunRuntimeAction)
    }

    func testProgressActionsFollowPausedAndFailureRecoveryStates() async {
        let coordinator = WizardCoordinator(status: .notInstalled)
        let model = DeploymentWizardModel(
            coordinator: coordinator,
            preflight: { _ in PreflightFixtures.healthy }
        )
        await model.start()
        model.continueToNextStep()
        model.continueToNextStep()
        await model.deploy()
        await coordinator.emit(.init(phase: .paused, statusText: "Download paused."))
        await waitUntil { model.canResume }

        XCTAssertTrue(model.canResume)
        XCTAssertFalse(model.canRetryRecovery)
        XCTAssertFalse(model.canCancel)

        await coordinator.emit(.init(
            phase: .failed,
            statusText: "Download failed.",
            failure: DeploymentFailure(
                phase: .downloadingModel,
                component: .model,
                reason: "The model download failed.",
                diagnostic: "Internal transport token must not be shown",
                recoveryActions: [.viewLogs]
            )
        ))
        await waitUntil { model.canViewLogs }

        XCTAssertFalse(model.canResume)
        XCTAssertFalse(model.canRetryRecovery)
        XCTAssertTrue(model.canViewLogs)
        XCTAssertEqual(model.failureMessage, "The model download failed.")
        XCTAssertFalse(model.failureMessage.contains("transport token"))
    }

    func testCancelStopsAnActiveDeploymentAndLeavesPausedAndFailedRecoveryDistinct() async {
        let coordinator = CancelAwareWizardCoordinator()
        let model = DeploymentWizardModel(
            coordinator: coordinator,
            preflight: { _ in PreflightFixtures.healthy }
        )
        await model.start()
        model.continueToNextStep()
        model.continueToNextStep()

        let deployment = Task { await model.deploy() }
        await coordinator.waitForDeployment()
        XCTAssertTrue(model.canCancel)

        await model.cancel()
        await deployment.value
        XCTAssertEqual(model.step, .progress)
        let calls = await coordinator.recordedCalls()
        XCTAssertEqual(calls, [.deploy, .cancel])

        await coordinator.emit(.init(phase: .paused, statusText: "Download paused."))
        await waitUntil { model.canResume }
        XCTAssertEqual(model.step, .configuration)
        XCTAssertFalse(model.canCancel)
        XCTAssertTrue(model.canResume)

        await coordinator.emit(.init(
            phase: .failed,
            statusText: "Download failed.",
            failure: DeploymentFailure(
                phase: .downloadingModel,
                component: .model,
                reason: "The model download failed.",
                diagnostic: "Internal transport token must not be shown",
                recoveryActions: [.retry]
            )
        ))
        await waitUntil { model.canRetryRecovery }
        XCTAssertFalse(model.canCancel)
        XCTAssertTrue(model.canRetryRecovery)
    }

    private func waitUntil(
        _ predicate: @escaping () -> Bool
    ) async {
        for _ in 0..<100 {
            if predicate() { return }
            await Task.yield()
        }
        XCTFail("Timed out waiting for wizard state")
    }

    func testCancelKeepsConfigurationWhenPausedSnapshotArrivesAfterCancelReturns() async {
        let coordinator = DelayedCancelSnapshotCoordinator(
            pauseTiming: .afterCancelReturns
        )
        let model = DeploymentWizardModel(
            coordinator: coordinator,
            preflight: { _ in PreflightFixtures.healthy }
        )
        await model.start()
        model.continueToNextStep()
        model.continueToNextStep()

        let deployment = Task { await model.deploy() }
        await coordinator.waitForDeployment(1)
        await model.cancel()
        await deployment.value
        XCTAssertEqual(model.step, .progress)

        await coordinator.emitUnidentifiedPaused()
        await waitUntil { model.step == .configuration }
        XCTAssertEqual(model.step, .configuration)

        await coordinator.emitPaused(for: 1)
        await Task.yield()
        XCTAssertEqual(model.step, .configuration)
    }

    func testCancelKeepsConfigurationWhenPausedSnapshotArrivesBeforeCancelReturns() async {
        let coordinator = DelayedCancelSnapshotCoordinator(
            pauseTiming: .beforeCancelReturns
        )
        let model = DeploymentWizardModel(
            coordinator: coordinator,
            preflight: { _ in PreflightFixtures.healthy }
        )
        await model.start()
        model.continueToNextStep()
        model.continueToNextStep()

        let deployment = Task { await model.deploy() }
        await coordinator.waitForDeployment(1)
        await model.cancel()
        await deployment.value
        XCTAssertEqual(model.step, .configuration)
    }

    func testCancelRetainsCompletionWhenInstalledArrivesBeforeCancelReturns() async {
        let coordinator = TerminalCancelSnapshotCoordinator(terminal: .installed)
        let model = DeploymentWizardModel(
            coordinator: coordinator,
            preflight: { _ in PreflightFixtures.healthy }
        )
        await model.start()
        model.continueToNextStep()
        model.continueToNextStep()

        let deployment = Task { await model.deploy() }
        await coordinator.waitForDeployment()
        await model.cancel()
        await deployment.value
        await waitUntil { model.step == .completion }

        XCTAssertEqual(model.step, .completion)
    }

    func testCancelRetainsFailureWhenFailedSnapshotArrivesBeforeCancelReturns() async {
        let coordinator = TerminalCancelSnapshotCoordinator(terminal: .failed)
        let model = DeploymentWizardModel(
            coordinator: coordinator,
            preflight: { _ in PreflightFixtures.healthy }
        )
        await model.start()
        model.continueToNextStep()
        model.continueToNextStep()

        let deployment = Task { await model.deploy() }
        await coordinator.waitForDeployment()
        await model.cancel()
        await deployment.value
        await waitUntil { model.canRetryRecovery }

        XCTAssertEqual(model.step, .progress)
        XCTAssertTrue(model.canRetryRecovery)
    }

    func testCancelRetainsInstalledTerminalAfterTaggedProgress() async {
        let coordinator = TerminalCancelSnapshotCoordinator(terminal: .installed)
        let model = DeploymentWizardModel(
            coordinator: coordinator,
            preflight: { _ in PreflightFixtures.healthy }
        )
        await model.start()
        model.continueToNextStep()
        model.continueToNextStep()

        let deployment = Task { await model.deploy() }
        await coordinator.waitForDeployment()
        let operationID = await coordinator.currentOperationID()
        await coordinator.emitProgress()
        await waitUntil { model.snapshot.operationID == operationID }

        await model.cancel()
        await deployment.value
        await waitUntil { model.step == .completion }

        XCTAssertEqual(model.step, .completion)
        XCTAssertFalse(model.hasPendingCancellationIntentForTesting)
    }

    func testCancelRetainsFailedTerminalAfterTaggedProgress() async {
        let coordinator = TerminalCancelSnapshotCoordinator(terminal: .failed)
        let model = DeploymentWizardModel(
            coordinator: coordinator,
            preflight: { _ in PreflightFixtures.healthy }
        )
        await model.start()
        model.continueToNextStep()
        model.continueToNextStep()

        let deployment = Task { await model.deploy() }
        await coordinator.waitForDeployment()
        let operationID = await coordinator.currentOperationID()
        await coordinator.emitProgress()
        await waitUntil { model.snapshot.operationID == operationID }

        await model.cancel()
        await deployment.value
        await waitUntil { model.canRetryRecovery }

        XCTAssertEqual(model.step, .progress)
        XCTAssertTrue(model.canRetryRecovery)
        XCTAssertFalse(model.hasPendingCancellationIntentForTesting)
    }

    func testResolvedCancelledPauseDoesNotReplaceNewerCompletion() async {
        let coordinator = DelayedCancelSnapshotCoordinator(
            pauseTiming: .beforeCancelReturns
        )
        let model = DeploymentWizardModel(
            coordinator: coordinator,
            preflight: { _ in PreflightFixtures.healthy }
        )
        await model.start()
        model.continueToNextStep()
        model.continueToNextStep()

        let firstDeployment = Task { await model.deploy() }
        await coordinator.waitForDeployment(1)
        let firstOperationID = await coordinator.operationID(for: 1)
        await coordinator.emitProgress(for: 1)
        await waitUntil { model.snapshot.operationID == firstOperationID }
        await model.cancel()
        await firstDeployment.value
        await waitUntil { model.step == .configuration }

        model.continueToNextStep()
        model.continueToNextStep()
        let secondDeployment = Task { await model.deploy() }
        await coordinator.waitForDeployment(2)
        let secondOperationID = await coordinator.operationID(for: 2)
        await coordinator.emitInstalled(for: 2)
        await coordinator.finishDeployment(2)
        await secondDeployment.value
        await waitUntil { model.step == .completion }

        await coordinator.emitPaused(for: 1)
        await coordinator.emitReady(for: 2)
        await waitUntil {
            model.snapshot.phase == .ready
                && model.snapshot.operationID == secondOperationID
        }
        XCTAssertEqual(model.step, .completion)
    }

    func testResolvedCancelledPauseDoesNotReplaceNewerFailure() async {
        let coordinator = DelayedCancelSnapshotCoordinator(
            pauseTiming: .beforeCancelReturns
        )
        let model = DeploymentWizardModel(
            coordinator: coordinator,
            preflight: { _ in PreflightFixtures.healthy }
        )
        await model.start()
        model.continueToNextStep()
        model.continueToNextStep()

        let firstDeployment = Task { await model.deploy() }
        await coordinator.waitForDeployment(1)
        let firstOperationID = await coordinator.operationID(for: 1)
        await coordinator.emitProgress(for: 1)
        await waitUntil { model.snapshot.operationID == firstOperationID }
        await model.cancel()
        await firstDeployment.value
        await waitUntil { model.step == .configuration }

        model.continueToNextStep()
        model.continueToNextStep()
        let secondDeployment = Task { await model.deploy() }
        await coordinator.waitForDeployment(2)
        let secondOperationID = await coordinator.operationID(for: 2)
        await coordinator.emitFailed(for: 2)
        await coordinator.finishDeployment(2)
        await secondDeployment.value
        await waitUntil { model.canRetryRecovery }

        await coordinator.emitPaused(for: 1)
        await coordinator.emitReady(for: 2)
        await waitUntil {
            model.snapshot.phase == .ready
                && model.snapshot.operationID == secondOperationID
        }
        XCTAssertEqual(model.step, .progress)
    }

    func testStalePausedSnapshotFromCancelledOperationDoesNotReplaceNewProgress() async {
        let coordinator = DelayedCancelSnapshotCoordinator(
            pauseTiming: .afterCancelReturns
        )
        let model = DeploymentWizardModel(
            coordinator: coordinator,
            preflight: { _ in PreflightFixtures.healthy }
        )
        await model.start()
        model.continueToNextStep()
        model.continueToNextStep()

        let firstDeployment = Task { await model.deploy() }
        await coordinator.waitForDeployment(1)
        await model.cancel()
        await firstDeployment.value
        await coordinator.emitUnidentifiedPaused()
        await waitUntil { model.step == .configuration }
        XCTAssertTrue(model.hasPendingCancellationIntentForTesting)

        model.continueToNextStep()
        model.continueToNextStep()
        let secondDeployment = Task { await model.deploy() }
        await coordinator.waitForDeployment(2)
        await coordinator.emitProgress(for: 2)
        await Task.yield()
        XCTAssertEqual(model.step, .progress)

        await coordinator.emitPaused(for: 1)
        await Task.yield()
        XCTAssertEqual(model.step, .progress)
        let secondOperationID = await coordinator.operationID(for: 2)
        XCTAssertEqual(model.snapshot.operationID, secondOperationID)

        await coordinator.finishDeployment(2)
        await secondDeployment.value
    }

    func testDelayedOldPauseDoesNotReplaceNewerCompletion() async {
        let coordinator = DelayedCancelSnapshotCoordinator(
            pauseTiming: .afterCancelReturns
        )
        let model = DeploymentWizardModel(
            coordinator: coordinator,
            preflight: { _ in PreflightFixtures.healthy }
        )
        await model.start()
        model.continueToNextStep()
        model.continueToNextStep()

        let firstDeployment = Task { await model.deploy() }
        await coordinator.waitForDeployment(1)
        await model.cancel()
        await firstDeployment.value
        await coordinator.emitUnidentifiedPaused()
        await waitUntil { model.step == .configuration }

        model.continueToNextStep()
        model.continueToNextStep()
        let secondDeployment = Task { await model.deploy() }
        await coordinator.waitForDeployment(2)
        let secondOperationID = await coordinator.operationID(for: 2)
        await coordinator.emitInstalled(for: 2)
        await coordinator.finishDeployment(2)
        await secondDeployment.value
        await waitUntil { model.step == .completion }
        XCTAssertTrue(model.hasPendingCancellationIntentForTesting)

        await coordinator.emitPaused(for: 1)
        await coordinator.emitReady(for: 2)
        await waitUntil {
            model.snapshot.phase == .ready
                && model.snapshot.operationID == secondOperationID
        }
        XCTAssertEqual(model.step, .completion)
    }

    func testDelayedOldPauseDoesNotReplaceNewerPausedSnapshot() async {
        let coordinator = DelayedCancelSnapshotCoordinator(
            pauseTiming: .afterCancelReturns
        )
        let model = DeploymentWizardModel(
            coordinator: coordinator,
            preflight: { _ in PreflightFixtures.healthy }
        )
        await model.start()
        model.continueToNextStep()
        model.continueToNextStep()

        let firstDeployment = Task { await model.deploy() }
        await coordinator.waitForDeployment(1)
        await model.cancel()
        await firstDeployment.value
        await coordinator.emitUnidentifiedPaused()
        await waitUntil { model.step == .configuration }

        model.continueToNextStep()
        model.continueToNextStep()
        let secondDeployment = Task { await model.deploy() }
        await coordinator.waitForDeployment(2)
        let secondOperationID = await coordinator.operationID(for: 2)
        await coordinator.emitPaused(for: 2)
        await waitUntil { model.snapshot.operationID == secondOperationID }
        XCTAssertTrue(model.hasPendingCancellationIntentForTesting)

        await coordinator.emitPaused(for: 1)
        await coordinator.emitReady(for: 2)
        await waitUntil {
            model.snapshot.phase == .ready
                && model.snapshot.operationID == secondOperationID
        }
        XCTAssertEqual(model.snapshot.operationID, secondOperationID)

        await coordinator.finishDeployment(2)
        await secondDeployment.value
    }

    func testCancellationTombstonesAreBoundedAndKeepTheLatestPauseStale() async {
        let coordinator = DelayedCancelSnapshotCoordinator(
            pauseTiming: .beforeCancelReturns
        )
        let model = DeploymentWizardModel(
            coordinator: coordinator,
            preflight: { _ in PreflightFixtures.healthy }
        )
        await model.start()
        model.continueToNextStep()
        model.continueToNextStep()

        for deploymentNumber in 1...9 {
            let deployment = Task { await model.deploy() }
            await coordinator.waitForDeployment(deploymentNumber)
            await model.cancel()
            await deployment.value
            await waitUntil { model.step == .configuration }

            if deploymentNumber < 9 {
                model.continueToNextStep()
                model.continueToNextStep()
            }
        }

        XCTAssertEqual(model.cancellationTombstoneCountForTesting, 8)

        model.continueToNextStep()
        model.continueToNextStep()
        let currentDeployment = Task { await model.deploy() }
        await coordinator.waitForDeployment(10)
        let currentOperationID = await coordinator.operationID(for: 10)
        await coordinator.emitProgress(for: 10)
        await waitUntil { model.snapshot.operationID == currentOperationID }
        await coordinator.emitInstalled(for: 10)
        await coordinator.finishDeployment(10)
        await currentDeployment.value
        await waitUntil { model.step == .completion }

        await coordinator.emitPaused(for: 9)
        await coordinator.emitReady(for: 10)
        await waitUntil {
            model.snapshot.phase == .ready
                && model.snapshot.operationID == currentOperationID
        }
        XCTAssertEqual(model.step, .completion)
    }

    func testNewestInstalledInspectionWinsWhenOlderResultArrivesLast() async {
        let coordinator = DeferredInspectionCoordinator()
        let model = DeploymentWizardModel(
            coordinator: coordinator,
            preflight: { _ in PreflightFixtures.healthy }
        )
        let start = Task { await model.start() }
        await coordinator.waitForInspection(1)
        await coordinator.resolve(.notInstalled, at: 1)
        await start.value

        await coordinator.emit(.init(phase: .installed, statusText: "Installed."))
        await coordinator.waitForInspection(2)
        await coordinator.emit(.init(phase: .installed, statusText: "Installed again."))
        await coordinator.waitForInspection(3)

        let newest = Self.record(root: "/tmp/newest")
        await coordinator.resolve(.managedHealthy(newest), at: 3)
        await waitUntil { model.installedRecord == newest }
        await coordinator.resolve(.managedHealthy(Self.record(root: "/tmp/stale")), at: 2)
        await Task.yield()

        XCTAssertEqual(model.installedRecord, newest)
    }

    func testNewestRepairInspectionWinsWhenOlderResultArrivesLast() async {
        let coordinator = DeferredInspectionCoordinator()
        let model = DeploymentWizardModel(
            coordinator: coordinator,
            preflight: { _ in PreflightFixtures.healthy }
        )
        let start = Task { await model.start() }
        await coordinator.waitForInspection(1)
        await coordinator.resolve(.managedHealthy(Self.record()), at: 1)
        await start.value

        await model.repair()
        await coordinator.emit(.init(phase: .installed, statusText: "Repaired."))
        await coordinator.waitForInspection(2)
        await coordinator.emit(.init(phase: .installed, statusText: "Repaired again."))
        await coordinator.waitForInspection(3)

        let newest = Self.record(root: "/tmp/repaired")
        await coordinator.resolve(.managedHealthy(newest), at: 3)
        await waitUntil { model.installedRecord == newest }
        await coordinator.resolve(.managedHealthy(Self.record(root: "/tmp/stale-repair")), at: 2)
        await Task.yield()

        XCTAssertEqual(model.installedRecord, newest)
    }

    func testNewestUninstallInspectionWinsWhenOlderResultArrivesLast() async {
        let coordinator = DeferredInspectionCoordinator()
        let model = DeploymentWizardModel(
            coordinator: coordinator,
            preflight: { _ in PreflightFixtures.healthy }
        )
        let start = Task { await model.start() }
        await coordinator.waitForInspection(1)
        await coordinator.resolve(.managedHealthy(Self.record()), at: 1)
        await start.value

        model.requestUninstall()
        await model.uninstall()
        await coordinator.emit(.init(phase: .installed, statusText: "Late install."))
        await coordinator.waitForInspection(2)
        await coordinator.emit(.init(phase: .idle, statusText: "Uninstalled."))
        await coordinator.waitForInspection(3)

        await coordinator.resolve(.notInstalled, at: 3)
        await waitUntil { model.installedRecord == nil && model.step == .deviceCheck }
        await coordinator.resolve(.managedHealthy(Self.record(root: "/tmp/stale-uninstall")), at: 2)
        await Task.yield()

        XCTAssertNil(model.installedRecord)
        XCTAssertEqual(model.step, .deviceCheck)
    }

}

private enum PreflightFixtures {
    static let healthy = makeHealthy()
    static let failing = makeFailing()

    private static func makeHealthy() -> PreflightReport {
        PreflightReport(
            architectureSupported: true,
            operatingSystemSupported: true,
            memorySufficient: true,
            storageSufficient: true,
            rootWritable: true,
            portAvailable: true,
            issues: []
        )
    }

    private static func makeFailing() -> PreflightReport {
        PreflightReport(
            architectureSupported: false,
            operatingSystemSupported: true,
            memorySufficient: true,
            storageSufficient: true,
            rootWritable: true,
            portAvailable: true,
            issues: [.unsupportedArchitecture("x86_64")]
        )
    }

}

private extension DeploymentWizardModelTests {
    static func record(
        accessMode: NetworkAccessMode = .local,
        runtimeVersion: String = "b10159",
        root: String = "/tmp/Qwythos"
    ) -> InstallationRecord {
        InstallationRecord(
            manifestSchemaVersion: 1,
            root: URL(fileURLWithPath: root),
            runtimeVersion: runtimeVersion,
            modelSHA256: String(repeating: "a", count: 64),
            contextSize: 8_192,
            accessMode: accessMode,
            installedAt: Date()
        )
    }
}

private actor DeferredInspectionCoordinator: DeploymentCoordinating {
    private var continuations: [AsyncStream<DeploymentSnapshot>.Continuation] = []
    private var inspectionContinuations: [Int: CheckedContinuation<InstallationStatus, Never>] = [:]
    private var inspectionCount = 0
    private var inspectionWaiters: [Int: [CheckedContinuation<Void, Never>]] = [:]

    func snapshots() async -> AsyncStream<DeploymentSnapshot> {
        AsyncStream { continuations.append($0) }
    }

    func inspect() async -> InstallationStatus {
        inspectionCount += 1
        let request = inspectionCount
        inspectionWaiters.removeValue(forKey: request)?.forEach { $0.resume() }
        return await withCheckedContinuation { inspectionContinuations[request] = $0 }
    }

    func deploy(options: DeploymentOptions) async throws {}
    func migrate(options: DeploymentOptions) async throws {}
    func pause() async {}
    func pauseAndWait() async {}
    func repair() async throws {}
    func reinstallRuntime() async throws {}
    func setAccessMode(_ mode: NetworkAccessMode) async throws {}
    func regenerateAPIKey() async throws -> String { "not-exposed" }
    func uninstall(deleteModel: Bool) async throws {}

    func emit(_ snapshot: DeploymentSnapshot) {
        continuations.forEach { $0.yield(snapshot) }
    }

    func resolve(_ status: InstallationStatus, at request: Int) {
        inspectionContinuations.removeValue(forKey: request)?.resume(returning: status)
    }

    func waitForInspection(_ request: Int) async {
        guard inspectionCount < request else { return }
        await withCheckedContinuation { continuation in
            inspectionWaiters[request, default: []].append(continuation)
        }
    }
}

private actor WizardCoordinator: DeploymentCoordinating {
    enum Call: Equatable {
        case deploy(DeploymentOptions)
        case migrate(DeploymentOptions)
        case pause
        case pauseAndWait
        case repair
        case reinstallRuntime
        case setAccessMode(NetworkAccessMode)
        case regenerateAPIKey
        case uninstall(deleteModel: Bool)
    }

    private var status: InstallationStatus
    private var continuations: [AsyncStream<DeploymentSnapshot>.Continuation] = []
    private(set) var calls: [Call] = []

    init(status: InstallationStatus) {
        self.status = status
    }

    func snapshots() async -> AsyncStream<DeploymentSnapshot> {
        AsyncStream { continuation in
            continuations.append(continuation)
            continuation.yield(.init(phase: .idle, statusText: "Not installed."))
        }
    }

    func inspect() async -> InstallationStatus { status }

    func deploy(options: DeploymentOptions) async throws { calls.append(.deploy(options)) }
    func migrate(options: DeploymentOptions) async throws { calls.append(.migrate(options)) }
    func pause() async { calls.append(.pause) }
    func pauseAndWait() async { calls.append(.pauseAndWait) }
    func repair() async throws { calls.append(.repair) }
    func reinstallRuntime() async throws { calls.append(.reinstallRuntime) }
    func setAccessMode(_ mode: NetworkAccessMode) async throws { calls.append(.setAccessMode(mode)) }
    func regenerateAPIKey() async throws -> String {
        calls.append(.regenerateAPIKey)
        return "not-exposed"
    }
    func uninstall(deleteModel: Bool) async throws { calls.append(.uninstall(deleteModel: deleteModel)) }

    func emit(_ snapshot: DeploymentSnapshot) {
        continuations.forEach { $0.yield(snapshot) }
    }

    func setStatus(_ status: InstallationStatus) {
        self.status = status
    }

    func recordedCalls() -> [Call] { calls }
}

private final class LockedURLValues: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [URL] = []

    var values: [URL] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func append(_ value: URL) {
        lock.lock()
        storage.append(value)
        lock.unlock()
    }
}

private final class LockedStringValues: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []

    var values: [String] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func append(_ value: String) {
        lock.lock()
        storage.append(value)
        lock.unlock()
    }
}

private actor TerminationAwareWizardCoordinator: DeploymentCoordinating {
    enum Call: Equatable { case pause, pauseAndWait }

    private var calls: [Call] = []
    private var checkpointWaiter: CheckedContinuation<Void, Never>?
    private var pauseRequestWaiter: CheckedContinuation<Void, Never>?

    func snapshots() async -> AsyncStream<DeploymentSnapshot> {
        AsyncStream { $0.finish() }
    }

    func inspect() async -> InstallationStatus { .notInstalled }
    func deploy(options: DeploymentOptions) async throws {}
    func migrate(options: DeploymentOptions) async throws {}
    func pause() async { calls.append(.pause) }
    func pauseAndWait() async {
        calls.append(.pauseAndWait)
        pauseRequestWaiter?.resume()
        pauseRequestWaiter = nil
        await withCheckedContinuation { checkpointWaiter = $0 }
    }
    func repair() async throws {}
    func reinstallRuntime() async throws {}
    func setAccessMode(_ mode: NetworkAccessMode) async throws {}
    func regenerateAPIKey() async throws -> String { "not-exposed" }
    func uninstall(deleteModel: Bool) async throws {}

    func completeCheckpoint() {
        checkpointWaiter?.resume()
        checkpointWaiter = nil
    }

    func waitUntilPauseRequested() async {
        if calls.contains(.pauseAndWait) { return }
        await withCheckedContinuation { pauseRequestWaiter = $0 }
    }

    func recordedCalls() -> [Call] { calls }
}

private actor CancelAwareWizardCoordinator: DeploymentCoordinating {
    enum Call: Equatable { case deploy, cancel }

    private var continuations: [AsyncStream<DeploymentSnapshot>.Continuation] = []
    private var deploymentWaiter: CheckedContinuation<Void, Never>?
    private var deploymentStarted: CheckedContinuation<Void, Never>?
    private var calls: [Call] = []

    func snapshots() async -> AsyncStream<DeploymentSnapshot> {
        AsyncStream { continuation in
            continuations.append(continuation)
            continuation.yield(.init(phase: .idle, statusText: "Not installed."))
        }
    }

    func inspect() async -> InstallationStatus { .notInstalled }
    func deploy(options: DeploymentOptions) async throws {
        calls.append(.deploy)
        deploymentStarted?.resume()
        deploymentStarted = nil
        await withCheckedContinuation { deploymentWaiter = $0 }
    }
    func migrate(options: DeploymentOptions) async throws {}
    func pause() async {}
    func pauseAndWait() async {}
    func cancel() async {
        calls.append(.cancel)
        deploymentWaiter?.resume()
        deploymentWaiter = nil
    }
    func repair() async throws {}
    func reinstallRuntime() async throws {}
    func setAccessMode(_ mode: NetworkAccessMode) async throws {}
    func regenerateAPIKey() async throws -> String { "not-exposed" }
    func uninstall(deleteModel: Bool) async throws {}

    func waitForDeployment() async {
        if !calls.isEmpty { return }
        await withCheckedContinuation { deploymentStarted = $0 }
    }

    func emit(_ snapshot: DeploymentSnapshot) {
        continuations.forEach { $0.yield(snapshot) }
    }

    func recordedCalls() -> [Call] { calls }
}

private actor DelayedCancelSnapshotCoordinator: DeploymentCoordinating {
    enum PauseTiming: Equatable {
        case beforeCancelReturns
        case afterCancelReturns
    }

    private let pauseTiming: PauseTiming
    private var continuations: [AsyncStream<DeploymentSnapshot>.Continuation] = []
    private var deploymentWaiters: [Int: CheckedContinuation<Void, Never>] = [:]
    private var deploymentStartWaiters: [Int: CheckedContinuation<Void, Never>] = [:]
    private var operationIDs: [Int: UUID] = [:]
    private var deploymentCount = 0

    init(pauseTiming: PauseTiming) {
        self.pauseTiming = pauseTiming
    }

    func snapshots() async -> AsyncStream<DeploymentSnapshot> {
        AsyncStream { continuation in
            continuations.append(continuation)
            continuation.yield(.init(phase: .idle, statusText: "Not installed."))
        }
    }

    func inspect() async -> InstallationStatus { .notInstalled }

    func deploy(options: DeploymentOptions) async throws {
        deploymentCount += 1
        let deployment = deploymentCount
        operationIDs[deployment] = UUID()
        await withCheckedContinuation { continuation in
            deploymentWaiters[deployment] = continuation
            deploymentStartWaiters[deployment]?.resume()
            deploymentStartWaiters[deployment] = nil
        }
    }

    func migrate(options: DeploymentOptions) async throws {}
    func pause() async {}
    func cancel() async {
        await pauseAndWait()
    }
    func pauseAndWait() async {
        guard let deployment = deploymentWaiters.keys.max() else { return }
        if pauseTiming == .beforeCancelReturns {
            emitPaused(for: deployment)
        }
        finishDeployment(deployment)
    }
    func repair() async throws {}
    func reinstallRuntime() async throws {}
    func setAccessMode(_ mode: NetworkAccessMode) async throws {}
    func regenerateAPIKey() async throws -> String { "not-exposed" }
    func uninstall(deleteModel: Bool) async throws {}

    func waitForDeployment(_ deployment: Int) async {
        if operationIDs[deployment] != nil { return }
        await withCheckedContinuation { deploymentStartWaiters[deployment] = $0 }
    }

    func emitProgress(for deployment: Int) {
        guard let operationID = operationIDs[deployment] else { return }
        emit(.init(
            phase: .downloadingModel,
            operationID: operationID,
            component: .model,
            completedBytes: 1,
            totalBytes: 2,
            overallProgress: 0.5,
            statusText: "Downloading model..."
        ))
    }

    func emitPaused(for deployment: Int) {
        guard let operationID = operationIDs[deployment] else { return }
        emit(.init(
            phase: .paused,
            operationID: operationID,
            statusText: "Deployment paused."
        ))
    }

    func emitUnidentifiedPaused() {
        emit(.init(
            phase: .paused,
            statusText: "Deployment paused."
        ))
    }

    func emitInstalled(for deployment: Int) {
        guard let operationID = operationIDs[deployment] else { return }
        emit(.init(
            phase: .installed,
            operationID: operationID,
            overallProgress: 1,
            statusText: "Qwythos is installed."
        ))
    }

    func emitFailed(for deployment: Int) {
        guard let operationID = operationIDs[deployment] else { return }
        emit(.init(
            phase: .failed,
            operationID: operationID,
            statusText: "Download failed.",
            failure: DeploymentFailure(
                phase: .downloadingModel,
                component: .model,
                reason: "The model download failed.",
                diagnostic: "test-only",
                recoveryActions: [.retry]
            )
        ))
    }

    func emitReady(for deployment: Int) {
        guard let operationID = operationIDs[deployment] else { return }
        emit(.init(
            phase: .ready,
            operationID: operationID,
            statusText: "Ready."
        ))
    }

    func finishDeployment(_ deployment: Int) {
        deploymentWaiters[deployment]?.resume()
        deploymentWaiters[deployment] = nil
    }

    func operationID(for deployment: Int) -> UUID? {
        operationIDs[deployment]
    }

    private func emit(_ snapshot: DeploymentSnapshot) {
        continuations.forEach { $0.yield(snapshot) }
    }
}

private actor TerminalCancelSnapshotCoordinator: DeploymentCoordinating {
    enum Terminal { case installed, failed }

    private let terminal: Terminal
    private var continuations: [AsyncStream<DeploymentSnapshot>.Continuation] = []
    private var deploymentWaiter: CheckedContinuation<Void, Never>?
    private var deploymentStarted: CheckedContinuation<Void, Never>?
    private var operationID: UUID?

    init(terminal: Terminal) {
        self.terminal = terminal
    }

    func snapshots() async -> AsyncStream<DeploymentSnapshot> {
        AsyncStream { continuation in
            continuations.append(continuation)
            continuation.yield(.init(phase: .idle, statusText: "Not installed."))
        }
    }

    func inspect() async -> InstallationStatus { .notInstalled }
    func deploy(options: DeploymentOptions) async throws {
        operationID = UUID()
        await withCheckedContinuation { continuation in
            deploymentWaiter = continuation
            deploymentStarted?.resume()
            deploymentStarted = nil
        }
    }
    func migrate(options: DeploymentOptions) async throws {}
    func pause() async {}
    func pauseAndWait() async {
        guard let operationID else { return }
        switch terminal {
        case .installed:
            emit(.init(
                phase: .installed,
                operationID: operationID,
                overallProgress: 1,
                statusText: "Qwythos is installed."
            ))
        case .failed:
            emit(.init(
                phase: .failed,
                operationID: operationID,
                statusText: "Download failed.",
                failure: DeploymentFailure(
                    phase: .downloadingModel,
                    component: .model,
                    reason: "The model download failed.",
                    diagnostic: "test-only",
                    recoveryActions: [.retry]
                )
            ))
        }
        deploymentWaiter?.resume()
        deploymentWaiter = nil
    }
    func repair() async throws {}
    func reinstallRuntime() async throws {}
    func setAccessMode(_ mode: NetworkAccessMode) async throws {}
    func regenerateAPIKey() async throws -> String { "not-exposed" }
    func uninstall(deleteModel: Bool) async throws {}

    func waitForDeployment() async {
        if operationID != nil { return }
        await withCheckedContinuation { deploymentStarted = $0 }
    }

    func currentOperationID() -> UUID? { operationID }

    func emitProgress() {
        guard let operationID else { return }
        emit(.init(
            phase: .downloadingModel,
            operationID: operationID,
            component: .model,
            completedBytes: 1,
            totalBytes: 2,
            overallProgress: 0.5,
            statusText: "Downloading model..."
        ))
    }

    private func emit(_ snapshot: DeploymentSnapshot) {
        continuations.forEach { $0.yield(snapshot) }
    }
}

private actor AsyncCompletion {
    private var completed = false

    func markComplete() { completed = true }
    var isComplete: Bool { completed }
}
