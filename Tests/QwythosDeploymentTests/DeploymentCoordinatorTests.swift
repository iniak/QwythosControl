import XCTest
@testable import QwythosDeployment

final class DeploymentCoordinatorTests: XCTestCase {
    func testInspectorFactoryUsesTheCurrentLocatedRoot() async throws {
        let firstRoot = FileManager.default.temporaryDirectory
            .appending(path: "Qwythos-first-\(UUID().uuidString)")
        let secondRoot = FileManager.default.temporaryDirectory
            .appending(path: "Qwythos-second-\(UUID().uuidString)")
        let locator = FakeInstallationLocator(root: firstRoot)
        let inspectedRoots = LockedCallLog()
        let runtimeInstaller = FakeRuntimeInstaller()
        let launchAgentInstaller = FakeLaunchAgentInstaller()
        let recordStore = FakeInstallationRecordStore()

        let coordinator = DeploymentCoordinator(
            manifest: .fixture,
            locator: locator,
            preflight: .passingFixture,
            downloader: FakeArtifactDownloader(),
            hasher: FakeFileHasher(manifest: .fixture),
            runtimeInstaller: runtimeInstaller,
            launchAgentInstaller: launchAgentInstaller,
            inspectorFactory: { layout in
                inspectedRoots.append(layout.root.standardizedFileURL.path)
                return FakeInstallationInspector()
            },
            migratorFactory: { _ in FakeLegacyMigrator() },
            recordStore: recordStore,
            service: FakeManagedService(),
            healthChecker: SequenceHealthChecker(
                results: [true],
                events: LockedCoordinatorEvents()
            )
        )

        let firstStatus = await coordinator.inspect()
        XCTAssertEqual(firstStatus, .notInstalled)
        try locator.save(InstallationLocation(root: secondRoot))
        let secondStatus = await coordinator.inspect()
        XCTAssertEqual(secondStatus, .notInstalled)

        XCTAssertEqual(
            inspectedRoots.values,
            [firstRoot.standardizedFileURL.path, secondRoot.standardizedFileURL.path]
        )
    }

    func testInspectorFactoryUsesDefaultRootToDetectLegacyWithoutLocator() async {
        let locator = FakeInstallationLocator()
        let inspectedRoots = LockedCallLog()
        let coordinator = makeFactoryCoordinator(
            locator: locator,
            inspectedRoots: inspectedRoots,
            unlocatedStatus: .legacyDetected
        )

        let status = await coordinator.inspect()
        XCTAssertEqual(status, .legacyDetected)
        XCTAssertEqual(inspectedRoots.values.count, 1)
    }

    func testUnreadableLocationReportsRecoveryStatusInsteadOfThrowing() async {
        let coordinator = makeFactoryCoordinator(
            locator: ThrowingInstallationLocator(),
            inspectedRoots: LockedCallLog()
        )

        let status = await coordinator.inspect()
        XCTAssertEqual(
            status,
            .managedIncompatible("The installation location cannot be read.")
        )
    }

    func testMigrationPreparesManagedRuntimeBeforeLegacyMutationAndAllowsOwnedPort() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "Qwythos-migration-\(UUID().uuidString)")
        let options = DeploymentOptions(
            root: root,
            contextSize: 8_192,
            accessMode: .local
        )
        let runtimeInstaller = FakeRuntimeInstaller()
        let migrator = SequencedLegacyMigrator(
            runtimeInstaller: runtimeInstaller
        )
        let downloader = FakeArtifactDownloader()
        let coordinator = DeploymentCoordinator(
            manifest: .fixture,
            locator: FakeInstallationLocator(),
            preflight: DeploymentPreflight(
                profile: FakeSystemProfile(
                    architecture: "arm64",
                    operatingSystem: .init(
                        majorVersion: 14,
                        minorVersion: 0,
                        patchVersion: 0
                    ),
                    physicalMemory: 24 * 1_073_741_824,
                    availableCapacity: 20_000_000_000,
                    writable: true
                ),
                portChecker: FakePortChecker(isAvailable: false)
            ),
            downloader: downloader,
            hasher: FakeFileHasher(manifest: .fixture),
            runtimeInstaller: runtimeInstaller,
            launchAgentInstaller: FakeLaunchAgentInstaller(),
            inspector: FixedInstallationInspector(
                status: .legacyDetected,
                ownsPort: true
            ),
            migrator: migrator,
            recordStore: FakeInstallationRecordStore(),
            service: FakeManagedService(),
            healthChecker: SequenceHealthChecker(
                results: [true],
                events: LockedCoordinatorEvents()
            ),
            files: RecordingDeploymentFiles(),
            sleeper: ImmediateDeploymentSleeper(),
            healthPollAttempts: 1
        )

        try await coordinator.migrate(options: options)

        XCTAssertEqual(
            downloader.calls.values,
            [DeploymentManifest.fixture.runtime.archive.filename]
        )
        XCTAssertEqual(
            runtimeInstaller.calls.values,
            ["install:\(DeploymentManifest.fixture.runtime.version)"]
        )
        XCTAssertEqual(migrator.callCount, 1)
    }

    func testMigrationRejectsOccupiedPortNotOwnedBySupportedService() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "Qwythos-unowned-port-\(UUID().uuidString)")
        let options = DeploymentOptions(
            root: root,
            contextSize: 8_192,
            accessMode: .local
        )
        let runtimeInstaller = FakeRuntimeInstaller()
        let coordinator = DeploymentCoordinator(
            manifest: .fixture,
            locator: FakeInstallationLocator(),
            preflight: DeploymentPreflight(
                profile: FakeSystemProfile(
                    architecture: "arm64",
                    operatingSystem: .init(
                        majorVersion: 14,
                        minorVersion: 0,
                        patchVersion: 0
                    ),
                    physicalMemory: 24 * 1_073_741_824,
                    availableCapacity: 20_000_000_000,
                    writable: true
                ),
                portChecker: FakePortChecker(isAvailable: false)
            ),
            downloader: FakeArtifactDownloader(),
            hasher: FakeFileHasher(manifest: .fixture),
            runtimeInstaller: runtimeInstaller,
            launchAgentInstaller: FakeLaunchAgentInstaller(),
            inspector: FixedInstallationInspector(
                status: .legacyDetected,
                ownsPort: false
            ),
            migrator: FakeLegacyMigrator(),
            recordStore: FakeInstallationRecordStore(),
            service: FakeManagedService(),
            healthChecker: SequenceHealthChecker(
                results: [true],
                events: LockedCoordinatorEvents()
            ),
            files: RecordingDeploymentFiles(),
            sleeper: ImmediateDeploymentSleeper(),
            healthPollAttempts: 1
        )

        do {
            try await coordinator.migrate(options: options)
            XCTFail("Expected the occupied port to block migration")
        } catch let error as DeploymentCoordinatorError {
            XCTAssertEqual(
                error,
                .preflightFailed([.portUnavailable(DeploymentManifest.fixture.service.port)])
            )
        }
        XCTAssertTrue(runtimeInstaller.calls.values.isEmpty)
    }

    func testMigrationDownloadsVerifiedModelThenRetriesWhenLegacyCacheMisses() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "Qwythos-migration-model-\(UUID().uuidString)")
        let options = DeploymentOptions(
            root: root,
            contextSize: 8_192,
            accessMode: .local
        )
        let runtimeInstaller = FakeRuntimeInstaller()
        let migrator = SequencedLegacyMigrator(
            runtimeInstaller: runtimeInstaller,
            failures: [.modelDownloadRequired]
        )
        let downloader = FakeArtifactDownloader()
        let files = RecordingDeploymentFiles()
        let coordinator = DeploymentCoordinator(
            manifest: .fixture,
            locator: FakeInstallationLocator(),
            preflight: .passingFixture,
            downloader: downloader,
            hasher: FakeFileHasher(manifest: .fixture),
            runtimeInstaller: runtimeInstaller,
            launchAgentInstaller: FakeLaunchAgentInstaller(),
            inspector: FixedInstallationInspector(status: .legacyDetected),
            migrator: migrator,
            recordStore: FakeInstallationRecordStore(),
            service: FakeManagedService(),
            healthChecker: SequenceHealthChecker(
                results: [true],
                events: LockedCoordinatorEvents()
            ),
            files: files,
            sleeper: ImmediateDeploymentSleeper(),
            healthPollAttempts: 1
        )

        try await coordinator.migrate(options: options)

        XCTAssertEqual(
            downloader.calls.values,
            [
                DeploymentManifest.fixture.runtime.archive.filename,
                DeploymentManifest.fixture.model.filename,
            ]
        )
        XCTAssertEqual(migrator.callCount, 2)
        XCTAssertEqual(
            files.promotions.values,
            ["\(DeploymentManifest.fixture.model.filename).partial"]
        )
    }

    func testPauseAndWaitWaitsForDeploymentCheckpointBeforeReturning() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "Qwythos-pause-\(UUID().uuidString)")
        let options = DeploymentOptions(
            root: root,
            contextSize: 8_192,
            accessMode: .local
        )
        let locator = FakeInstallationLocator()
        let downloader = CheckpointArtifactDownloader()
        let files = FakeDeploymentFileManager()
        let coordinator = DeploymentCoordinator(
            manifest: .fixture,
            locator: locator,
            preflight: .passingFixture,
            downloader: downloader,
            hasher: FakeFileHasher(manifest: .fixture),
            runtimeInstaller: FakeRuntimeInstaller(),
            launchAgentInstaller: FakeLaunchAgentInstaller(),
            inspector: FakeInstallationInspector(),
            migrator: FakeLegacyMigrator(),
            recordStore: FakeInstallationRecordStore(),
            service: FakeManagedService(),
            healthChecker: SequenceHealthChecker(
                results: [true],
                events: LockedCoordinatorEvents()
            ),
            files: files,
            sleeper: ImmediateDeploymentSleeper(),
            healthPollAttempts: 1
        )
        let deployment = Task {
            try await coordinator.deploy(options: options)
        }
        await downloader.waitUntilStarted()

        let completion = PauseCompletion()
        let pause = Task {
            await coordinator.pauseAndWait()
            await completion.markComplete()
        }
        await Task.yield()

        let completedBeforeCheckpoint = await completion.isComplete
        XCTAssertFalse(completedBeforeCheckpoint)
        XCTAssertEqual(try locator.load()?.root, options.root)

        await downloader.completeCheckpoint()
        await pause.value
        let completedAfterCheckpoint = await completion.isComplete
        XCTAssertTrue(completedAfterCheckpoint)
        XCTAssertTrue(files.removals.values.isEmpty)

        do {
            try await deployment.value
            XCTFail("Paused deployment must stop")
        } catch is CancellationError {
        }

        let stream = await coordinator.snapshots()
        var iterator = stream.makeAsyncIterator()
        let snapshot = await iterator.next()
        XCTAssertEqual(snapshot?.phase, .paused)
    }

    func testCleanDeploymentPublishesOrderedPhasesAndRecordsOnlyAfterHealth() async throws {
        let fixture = CoordinatorFixture()
        let snapshots = try await fixture.captureSnapshots {
            try await fixture.coordinator.deploy(options: fixture.options)
        }

        XCTAssertEqual(
            snapshots.map(\.phase),
            [
                .preflighting,
                .downloadingRuntime,
                .verifyingRuntime,
                .installingRuntime,
                .downloadingModel,
                .verifyingModel,
                .writingConfiguration,
                .startingService,
                .checkingHealth,
                .installed,
            ]
        )
        let operationIDs = snapshots.compactMap(\.operationID)
        XCTAssertEqual(operationIDs.count, snapshots.count)
        XCTAssertEqual(Set(operationIDs).count, 1)
        XCTAssertEqual(
            fixture.events.values.filter { $0 == .recordSaved }.count,
            1
        )
        XCTAssertLessThan(
            try XCTUnwrap(
                fixture.events.values.firstIndex(of: .healthSucceeded)
            ),
            try XCTUnwrap(
                fixture.events.values.firstIndex(of: .recordSaved)
            )
        )
    }

    func testCleanDeploymentReusesVerifiedRetainedManagedModel() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "Qwythos-retained-model-\(UUID().uuidString)")
        let options = DeploymentOptions(
            root: root,
            contextSize: 8_192,
            accessMode: .local
        )
        let downloader = FakeArtifactDownloader()
        let files = RecordingDeploymentFiles(retainedModelMatches: true)
        let coordinator = DeploymentCoordinator(
            manifest: .fixture,
            locator: FakeInstallationLocator(),
            preflight: .passingFixture,
            downloader: downloader,
            hasher: FakeFileHasher(manifest: .fixture),
            runtimeInstaller: FakeRuntimeInstaller(),
            launchAgentInstaller: FakeLaunchAgentInstaller(),
            inspector: FakeInstallationInspector(),
            migrator: FakeLegacyMigrator(),
            recordStore: FakeInstallationRecordStore(),
            service: FakeManagedService(),
            healthChecker: SequenceHealthChecker(
                results: [true],
                events: LockedCoordinatorEvents()
            ),
            files: files,
            sleeper: ImmediateDeploymentSleeper(),
            healthPollAttempts: 1
        )

        try await coordinator.deploy(options: options)

        XCTAssertEqual(
            downloader.calls.values,
            [DeploymentManifest.fixture.runtime.archive.filename]
        )
        XCTAssertTrue(files.promotions.values.isEmpty)
    }

    func testSecondOperationIsRejectedWhileBusy() async throws {
        let fixture = CoordinatorFixture(suspendDownloads: true)
        let deployment = Task {
            try await fixture.coordinator.deploy(options: fixture.options)
        }
        await waitUntil {
            fixture.downloader.calls.values.count == 1
        }

        do {
            try await fixture.coordinator.uninstall(deleteModel: false)
            XCTFail("A concurrent mutation must be rejected")
        } catch let error as DeploymentCoordinatorError {
            XCTAssertEqual(error, .operationInProgress)
        }

        await fixture.coordinator.pause()
        _ = try? await deployment.value
    }

    func testPauseCancelsDownloadAndPublishesPausedWithoutRemovingPartial() async throws {
        let fixture = CoordinatorFixture(suspendDownloads: true)
        let deployment = Task {
            try await fixture.coordinator.deploy(options: fixture.options)
        }
        await waitUntil {
            fixture.downloader.calls.values.count == 1
        }

        await fixture.coordinator.pause()
        do {
            try await deployment.value
            XCTFail("Paused deployment must stop")
        } catch is CancellationError {
        } catch {
            XCTFail("Expected cancellation, got \(error)")
        }

        let stream = await fixture.coordinator.snapshots()
        var iterator = stream.makeAsyncIterator()
        let snapshot = await iterator.next()
        XCTAssertEqual(snapshot?.phase, .paused)
        XCTAssertTrue(fixture.files.removals.values.isEmpty)
        XCTAssertEqual(
            try fixture.locator.load()?.root,
            fixture.options.root,
            "The locator must be durable before resumable work begins"
        )
    }

    func testHealthTimeoutPreservesModelAndDoesNotWriteInstalledRecord() async {
        let fixture = CoordinatorFixture(healthResults: [false])

        do {
            try await fixture.coordinator.deploy(options: fixture.options)
            XCTFail("Deployment must fail when health never succeeds")
        } catch let error as DeploymentCoordinatorError {
            XCTAssertEqual(error, .healthTimedOut)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        XCTAssertEqual(fixture.recordStore.saveCount, 0)
        XCTAssertFalse(
            fixture.files.removals.values.contains(fixture.options.root
                .appending(path: "models")
                .path)
        )

        let stream = await fixture.coordinator.snapshots()
        var iterator = stream.makeAsyncIterator()
        let snapshot = await iterator.next()
        XCTAssertEqual(
            snapshot?.failure?.recoveryActions,
            [.retry, .viewLogs]
        )
        XCTAssertEqual(snapshot?.failure?.phase, .checkingHealth)
    }

    func testRecordWriteThatThrowsIsRemovedFromFailedDeployment() async {
        let fixture = CoordinatorFixture(
            writeThenFailRecordSaves: true
        )

        do {
            try await fixture.coordinator.deploy(options: fixture.options)
            XCTFail("A failed completion write must fail deployment")
        } catch {
        }

        XCTAssertNil(fixture.recordStore.currentRecord())
        XCTAssertEqual(fixture.recordStore.removeCount, 1)
    }

    func testRuntimeReinstallRollsBackAfterFailedHealth() async {
        let fixture = CoordinatorFixture(
            healthResults: [false],
            existingRuntimeVersion: "previous-runtime"
        )

        do {
            try await fixture.coordinator.reinstallRuntime()
            XCTFail("Runtime reinstall must fail when health never succeeds")
        } catch {
        }

        XCTAssertTrue(
            fixture.runtimeInstaller.calls.values.contains(
                "rollback:previous-runtime"
            )
        )
        XCTAssertEqual(
            fixture.recordStore.currentRecord()?.runtimeVersion,
            "previous-runtime"
        )
        XCTAssertEqual(
            fixture.service.calls.values,
            ["stop", "start", "stop", "start"],
            "The failed replacement must not be restarted before rollback"
        )
        XCTAssertFalse(
            fixture.files.removals.values.contains(
                fixture.options.root.appending(path: "models").path
            )
        )
    }

    func testRuntimeReinstallRejectsUnsafeRecordedVersionBeforeMutation() async {
        let fixture = CoordinatorFixture(
            existingRuntimeVersion: "../../payload"
        )

        do {
            try await fixture.coordinator.reinstallRuntime()
            XCTFail("An unsafe recorded runtime must be rejected")
        } catch let error as DeploymentCoordinatorError {
            XCTAssertEqual(error, .installationNotRepairable)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        XCTAssertTrue(fixture.downloader.calls.values.isEmpty)
        XCTAssertTrue(fixture.runtimeInstaller.calls.values.isEmpty)
        XCTAssertTrue(fixture.service.calls.values.isEmpty)
    }

    func testCancellationAfterRuntimeSwitchRestoresPreviousRuntime() async {
        let fixture = CoordinatorFixture(
            existingRuntimeVersion: "previous-runtime",
            cancelAfterRuntimeInstall: true
        )

        do {
            try await fixture.coordinator.reinstallRuntime()
            XCTFail("The cancelled reinstall must stop")
        } catch is CancellationError {
        } catch {
            XCTFail("Expected cancellation, got \(error)")
        }

        XCTAssertTrue(
            fixture.runtimeInstaller.calls.values.contains(
                "rollback:previous-runtime"
            )
        )
        XCTAssertEqual(
            fixture.recordStore.currentRecord()?.runtimeVersion,
            "previous-runtime"
        )
    }

    func testCallerCancellationRestartsPreviousRuntimeOutsideCancelledTask() async {
        let fixture = CoordinatorFixture(
            existingRuntimeVersion: "previous-runtime",
            suspendAfterRuntimeInstall: true,
            serviceHonorsCancellation: true
        )
        let reinstall = Task {
            try await fixture.coordinator.reinstallRuntime()
        }
        await waitUntil {
            fixture.runtimeInstaller.calls.values.contains(
                "install:fixture-runtime"
            )
        }

        reinstall.cancel()
        do {
            try await reinstall.value
            XCTFail("The cancelled reinstall must stop")
        } catch is CancellationError {
        } catch {
            XCTFail("Expected cancellation, got \(error)")
        }

        XCTAssertTrue(
            fixture.runtimeInstaller.calls.values.contains(
                "rollback:previous-runtime"
            )
        )
        XCTAssertEqual(fixture.service.calls.values.last, "start")
    }

    func testOlderRuntimeIsUpgradedToPinnedVersionOnlyAfterHealth() async throws {
        let fixture = CoordinatorFixture(
            existingRuntimeVersion: "previous-runtime"
        )

        try await fixture.coordinator.reinstallRuntime()

        XCTAssertEqual(
            fixture.recordStore.currentRecord()?.runtimeVersion,
            DeploymentManifest.fixture.runtime.version
        )
        XCTAssertEqual(
            fixture.runtimeInstaller.calls.values,
            ["install:fixture-runtime"]
        )
    }

    func testRepairDownloadsOnlyDamagedComponents() async throws {
        let fixture = CoordinatorFixture(
            damaged: [.model],
            existingRuntimeVersion: DeploymentManifest.fixture.runtime.version
        )

        try await fixture.coordinator.repair()

        XCTAssertEqual(
            fixture.downloader.calls.values,
            [DeploymentManifest.fixture.model.filename]
        )
        XCTAssertTrue(fixture.runtimeInstaller.calls.values.isEmpty)
    }

    func testUninstallPreservesModelByDefault() async throws {
        let fixture = CoordinatorFixture(
            existingRuntimeVersion: DeploymentManifest.fixture.runtime.version
        )

        try await fixture.coordinator.uninstall(deleteModel: false)

        XCTAssertFalse(
            fixture.files.removals.values.contains(
                fixture.options.root.appending(path: "models").path
            )
        )
        XCTAssertEqual(fixture.locator.removeCount, 1)
    }

    func testUninstallDeletesModelOnlyWhenExplicitlySelected() async throws {
        let fixture = CoordinatorFixture(
            existingRuntimeVersion: DeploymentManifest.fixture.runtime.version
        )

        try await fixture.coordinator.uninstall(deleteModel: true)

        XCTAssertTrue(
            fixture.files.removals.values.contains(
                fixture.options.root
                    .appending(path: "models")
                    .appending(path: InstallationLayout.modelFilename)
                    .path
            )
        )
        XCTAssertFalse(
            fixture.files.removals.values.contains(
                fixture.options.root.appending(path: "models").path
            )
        )
    }

    func testUninstallBindsExplicitModelDeletionToRecordedDigest() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "Qwythos-model-delete-\(UUID().uuidString)")
        let record = InstallationRecord(
            manifestSchemaVersion: DeploymentManifest.fixture.schemaVersion,
            root: root,
            runtimeVersion: DeploymentManifest.fixture.runtime.version,
            modelSHA256: DeploymentManifest.fixture.model.sha256,
            contextSize: 8_192,
            accessMode: .local,
            installedAt: Date(timeIntervalSince1970: 1)
        )
        let files = RecordingDeploymentFiles()
        let coordinator = DeploymentCoordinator(
            manifest: .fixture,
            locator: FakeInstallationLocator(root: root),
            preflight: .passingFixture,
            downloader: FakeArtifactDownloader(),
            hasher: FakeFileHasher(manifest: .fixture),
            runtimeInstaller: FakeRuntimeInstaller(),
            launchAgentInstaller: FakeLaunchAgentInstaller(),
            inspector: FakeInstallationInspector(record: record),
            migrator: FakeLegacyMigrator(),
            recordStore: FakeInstallationRecordStore(record: record),
            service: FakeManagedService(),
            healthChecker: SequenceHealthChecker(
                results: [true],
                events: LockedCoordinatorEvents()
            ),
            files: files,
            sleeper: ImmediateDeploymentSleeper(),
            healthPollAttempts: 1
        )

        try await coordinator.uninstall(deleteModel: true)

        XCTAssertEqual(files.modelDeletions.values, [record.modelSHA256])
    }

    func testUninstallRejectsRecordFromAnotherRootBeforeMutation() async throws {
        let fixture = CoordinatorFixture(
            existingRuntimeVersion: DeploymentManifest.fixture.runtime.version,
            recordRootOverride: URL(fileURLWithPath: "/private/tmp/other-root")
        )

        do {
            try await fixture.coordinator.uninstall(deleteModel: true)
            XCTFail("A mismatched installation record must block uninstall")
        } catch let error as DeploymentCoordinatorError {
            XCTAssertEqual(error, .installationNotRepairable)
        }

        XCTAssertTrue(fixture.service.calls.values.isEmpty)
        XCTAssertTrue(fixture.launchAgentInstaller.calls.values.isEmpty)
        XCTAssertEqual(fixture.recordStore.removeCount, 0)
        XCTAssertTrue(fixture.files.removals.values.isEmpty)
        XCTAssertEqual(fixture.locator.removeCount, 0)
    }

    func testUninstallRejectsUnsafeRecordedRuntimeComponentsBeforeMutation() async {
        for runtimeVersion in [
            ".",
            "..",
            "../escape",
            "nested/runtime",
            #"nested\runtime"#,
            "runtime.version",
            "runtime%2Fversion",
            "runtime\nversion",
        ] {
            let fixture = CoordinatorFixture(
                existingRuntimeVersion: runtimeVersion
            )

            do {
                try await fixture.coordinator.uninstall(deleteModel: true)
                XCTFail("Unsafe runtime version was accepted: \(runtimeVersion)")
            } catch let error as DeploymentCoordinatorError {
                XCTAssertEqual(error, .installationNotRepairable)
            } catch {
                XCTFail("Unexpected error for \(runtimeVersion): \(error)")
            }

            XCTAssertTrue(fixture.service.calls.values.isEmpty)
            XCTAssertTrue(fixture.files.removals.values.isEmpty)
            XCTAssertEqual(fixture.locator.removeCount, 0)
        }
    }

    func testFailedUninstallPreservesLocatorForRetry() async throws {
        let failingFixture = CoordinatorFixture(
            existingRuntimeVersion: DeploymentManifest.fixture.runtime.version,
            failingRemovalName: "runtime"
        )

        do {
            try await failingFixture.coordinator.uninstall(
                deleteModel: false
            )
            XCTFail("A partial uninstall must surface its failure")
        } catch {
        }

        XCTAssertEqual(failingFixture.locator.removeCount, 0)
        XCTAssertEqual(
            try failingFixture.locator.load()?.root,
            failingFixture.options.root
        )
        XCTAssertNotNil(failingFixture.recordStore.currentRecord())
    }

    func testLocatorRemovalFailureRetriesWithoutRepeatingContentCleanup() async throws {
        let fixture = CoordinatorFixture(
            existingRuntimeVersion: DeploymentManifest.fixture.runtime.version,
            locatorRemoveFailures: 1
        )

        do {
            try await fixture.coordinator.uninstall(deleteModel: true)
            XCTFail("The first locator removal must fail")
        } catch FakeInstallationLocator.Failure.remove {
        } catch {
            XCTFail("Unexpected locator failure: \(error)")
        }

        XCTAssertNil(fixture.recordStore.currentRecord())
        XCTAssertNotNil(try fixture.locator.load())
        let serviceCalls = fixture.service.calls.values
        let fileRemovals = fixture.files.removals.values
        let directoryPrunes = fixture.files.directoryPrunes.values

        try await fixture.coordinator.uninstall(deleteModel: true)

        XCTAssertNil(try fixture.locator.load())
        XCTAssertEqual(fixture.locator.removeAttempts, 2)
        XCTAssertEqual(fixture.locator.removeCount, 1)
        XCTAssertEqual(fixture.recordStore.removeCount, 1)
        XCTAssertEqual(fixture.service.calls.values, serviceCalls)
        XCTAssertEqual(fixture.files.removals.values, fileRemovals)
        XCTAssertEqual(
            fixture.files.directoryPrunes.values,
            directoryPrunes
        )
    }

    func testRegeneratingKeyRestoresPreviousStateAfterHealthFailureWithoutPublishingKey() async {
        let fixture = CoordinatorFixture(
            healthResults: [false, false],
            existingRuntimeVersion: DeploymentManifest.fixture.runtime.version
        )
        fixture.recordStore.replaceCurrentRecordAccessMode(.shared)

        do {
            _ = try await fixture.coordinator.regenerateAPIKey()
            XCTFail("Key rotation must fail when the new service is unhealthy")
        } catch {
        }

        XCTAssertEqual(fixture.launchAgentInstaller.key, "fixture-original-key")
        XCTAssertEqual(fixture.launchAgentInstaller.calls.values, [
            "capture-state", "regenerate-key", "install:shared", "restore-key", "restore-plist"
        ])
        let snapshot = await fixture.firstSnapshot()
        XCTAssertFalse(snapshot.failure?.diagnostic.contains("fixture-original-key") ?? true)
        XCTAssertFalse(snapshot.failure?.diagnostic.contains("fixture-api-key") ?? true)
    }

    func testRegeneratingKeyLeavesNewKeyOnlyAfterHealthyRestart() async throws {
        let fixture = CoordinatorFixture(
            healthResults: [true],
            existingRuntimeVersion: DeploymentManifest.fixture.runtime.version
        )
        fixture.recordStore.replaceCurrentRecordAccessMode(.shared)

        let key = try await fixture.coordinator.regenerateAPIKey()

        XCTAssertEqual(key, "fixture-api-key")
        XCTAssertEqual(fixture.launchAgentInstaller.key, "fixture-api-key")
        let snapshot = await fixture.firstSnapshot()
        XCTAssertFalse(snapshot.statusText.contains(key))
        XCTAssertFalse(snapshot.failure?.diagnostic.contains(key) ?? false)
    }

    func testAccessModeChangeRewritesConfigurationAndRestartsService() async throws {
        let fixture = CoordinatorFixture(
            existingRuntimeVersion: DeploymentManifest.fixture.runtime.version
        )

        try await fixture.coordinator.setAccessMode(.shared)

        XCTAssertTrue(
            fixture.launchAgentInstaller.calls.values.contains(
                "install:shared"
            )
        )
        XCTAssertEqual(fixture.service.calls.values, ["stop", "start"])
        XCTAssertEqual(
            fixture.recordStore.currentRecord()?.accessMode,
            .shared
        )
    }

    func testFailedAccessModeChangeRestoresPreviousConfiguration() async {
        let fixture = CoordinatorFixture(
            healthResults: [false],
            existingRuntimeVersion: DeploymentManifest.fixture.runtime.version
        )

        do {
            try await fixture.coordinator.setAccessMode(.shared)
            XCTFail("An unhealthy configuration must not be recorded")
        } catch {
        }

        XCTAssertEqual(
            fixture.service.calls.values,
            ["stop", "start", "stop", "start"]
        )
        XCTAssertEqual(
            fixture.launchAgentInstaller.calls.values.suffix(2),
            ["install:shared", "install:local"]
        )
        XCTAssertEqual(
            fixture.recordStore.currentRecord()?.accessMode,
            .local
        )
    }

    func testAccessModeRecordFailureRestoresPreviousConfiguration() async {
        let fixture = CoordinatorFixture(
            existingRuntimeVersion: DeploymentManifest.fixture.runtime.version,
            failRecordSaves: true
        )

        do {
            try await fixture.coordinator.setAccessMode(.shared)
            XCTFail("An unrecorded configuration must be rolled back")
        } catch {
        }

        XCTAssertEqual(
            fixture.service.calls.values,
            ["stop", "start", "stop", "start"]
        )
        XCTAssertEqual(
            fixture.recordStore.currentRecord()?.accessMode,
            .local
        )
    }

    func testFailedRedeploymentRestoresExistingConfiguration() async {
        let fixture = CoordinatorFixture(
            healthResults: [false],
            existingRuntimeVersion: DeploymentManifest.fixture.runtime.version
        )
        let changedOptions = DeploymentOptions(
            root: fixture.options.root,
            contextSize: fixture.options.contextSize,
            accessMode: .shared
        )

        do {
            try await fixture.coordinator.deploy(options: changedOptions)
            XCTFail("An unhealthy redeployment must not be recorded")
        } catch {
        }

        XCTAssertEqual(
            fixture.service.calls.values,
            ["stop", "start", "stop", "start"]
        )
        XCTAssertEqual(
            fixture.recordStore.currentRecord()?.accessMode,
            .local
        )
    }

    func testCallerCancellationRestoresConfigurationOutsideCancelledTask() async {
        let fixture = CoordinatorFixture(
            healthResults: [false],
            existingRuntimeVersion: DeploymentManifest.fixture.runtime.version,
            serviceHonorsCancellation: true,
            suspendHealthCheck: true
        )
        let update = Task {
            try await fixture.coordinator.setAccessMode(.shared)
        }
        await waitUntil {
            fixture.service.calls.values == ["stop", "start"]
        }

        update.cancel()
        do {
            try await update.value
            XCTFail("The cancelled configuration update must stop")
        } catch is CancellationError {
        } catch {
            XCTFail("Expected cancellation, got \(error)")
        }

        XCTAssertEqual(
            fixture.service.calls.values,
            ["stop", "start", "stop", "start"]
        )
        XCTAssertEqual(
            fixture.recordStore.currentRecord()?.accessMode,
            .local
        )
    }

    func testCallerCancellationStopsNewServiceOutsideCancelledTask() async {
        let fixture = CoordinatorFixture(
            healthResults: [false],
            serviceHonorsCancellation: true,
            suspendHealthCheck: true
        )
        let deployment = Task {
            try await fixture.coordinator.deploy(options: fixture.options)
        }
        await waitUntil {
            fixture.service.calls.values == ["start"]
        }

        deployment.cancel()
        do {
            try await deployment.value
            XCTFail("The cancelled deployment must stop")
        } catch is CancellationError {
        } catch {
            XCTFail("Expected cancellation, got \(error)")
        }

        XCTAssertEqual(fixture.service.calls.values, ["start", "stop"])
        XCTAssertEqual(
            fixture.launchAgentInstaller.calls.values.last,
            "uninstall"
        )
        XCTAssertEqual(fixture.recordStore.saveCount, 0)
    }

    func testModelRepairDoesNotFollowReplacedModelsDirectory() throws {
        let base = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString)
        let root = base.appending(path: "root")
        let outside = base.appending(path: "outside")
        let downloads = root.appending(path: "downloads")
        try FileManager.default.createDirectory(
            at: downloads,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: outside,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: base) }

        let layout = InstallationLayout(root: root)
        try FileManager.default.createSymbolicLink(
            at: layout.modelsDirectory,
            withDestinationURL: outside
        )
        let outsideModel = outside.appending(
            path: InstallationLayout.modelFilename
        )
        try Data("outside".utf8).write(to: outsideModel)
        let source = downloads.appending(path: "model.partial")
        try Data("verified".utf8).write(to: source)
        let digest = try SHA256Hasher().sha256(file: source)

        let files = LiveDeploymentFileManager(hasher: SHA256Hasher())
        XCTAssertThrowsError(
            try files.promoteModel(
                from: source,
                layout: layout,
                expectedSHA256: digest
            )
        )
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: outsideModel.path),
            "A replaced managed directory must never redirect deletion"
        )
    }

    private func waitUntil(
        _ predicate: @escaping @Sendable () -> Bool
    ) async {
        for _ in 0..<1_000 {
            if predicate() { return }
            await Task.yield()
        }
        XCTFail("Timed out waiting for asynchronous work")
    }

    private func makeFactoryCoordinator(
        locator: any InstallationLocating,
        inspectedRoots: LockedCallLog,
        unlocatedStatus: InstallationStatus = .notInstalled
    ) -> DeploymentCoordinator {
        DeploymentCoordinator(
            manifest: .fixture,
            locator: locator,
            preflight: .passingFixture,
            downloader: FakeArtifactDownloader(),
            hasher: FakeFileHasher(manifest: .fixture),
            runtimeInstaller: FakeRuntimeInstaller(),
            launchAgentInstaller: FakeLaunchAgentInstaller(),
            inspectorFactory: { layout in
                inspectedRoots.append(layout.root.standardizedFileURL.path)
                return FixedInstallationInspector(status: unlocatedStatus)
            },
            migratorFactory: { _ in FakeLegacyMigrator() },
            recordStore: FakeInstallationRecordStore(),
            service: FakeManagedService(),
            healthChecker: SequenceHealthChecker(
                results: [true],
                events: LockedCoordinatorEvents()
            )
        )
    }
}

private struct FixedInstallationInspector: InstallationInspecting {
    let status: InstallationStatus
    let ownsPort: Bool

    init(status: InstallationStatus, ownsPort: Bool = false) {
        self.status = status
        self.ownsPort = ownsPort
    }

    func inspect() async -> InstallationStatus {
        status
    }

    func ownsServicePort(_ port: UInt16) async -> Bool {
        ownsPort
    }
}

private enum MigrationPreparationTestError: Error {
    case runtimeNotPrepared
}

private final class SequencedLegacyMigrator:
    LegacyMigrating,
    @unchecked Sendable
{
    private let lock = NSLock()
    private let runtimeInstaller: FakeRuntimeInstaller
    private var calls = 0
    private var failures: [LegacyMigrationError]

    init(
        runtimeInstaller: FakeRuntimeInstaller,
        failures: [LegacyMigrationError] = []
    ) {
        self.runtimeInstaller = runtimeInstaller
        self.failures = failures
    }

    var callCount: Int {
        lock.withLock { calls }
    }

    func migrate(options: DeploymentOptions) async throws {
        guard runtimeInstaller.calls.values.contains(
            "install:\(DeploymentManifest.fixture.runtime.version)"
        ) else {
            throw MigrationPreparationTestError.runtimeNotPrepared
        }
        let failure = lock.withLock { () -> LegacyMigrationError? in
            calls += 1
            return failures.isEmpty ? nil : failures.removeFirst()
        }
        if let failure {
            throw failure
        }
    }
}

private final class RecordingDeploymentFiles:
    DeploymentFileManaging,
    @unchecked Sendable
{
    let promotions = LockedCallLog()
    let modelDeletions = LockedCallLog()
    private let retainedModelMatches: Bool

    init(retainedModelMatches: Bool = false) {
        self.retainedModelMatches = retainedModelMatches
    }

    func promoteModel(
        from source: URL,
        layout: InstallationLayout,
        expectedSHA256: String
    ) throws {
        promotions.append(source.lastPathComponent)
    }

    func removeManagedItem(
        _ url: URL,
        layout: InstallationLayout,
        kind: ManagedRemovalKind
    ) throws {}

    func removeManagedRuntimeVersion(
        record: InstallationRecord,
        layout: InstallationLayout
    ) throws {}

    func finalizeManagedRuntimeCleanup(
        layout: InstallationLayout
    ) throws {}

    func managedModelMatches(
        layout: InstallationLayout,
        expectedSHA256: String
    ) throws -> Bool {
        retainedModelMatches
    }

    func removeManagedModel(
        layout: InstallationLayout,
        expectedSHA256: String
    ) throws {
        modelDeletions.append(expectedSHA256)
    }
}

private struct ThrowingInstallationLocator: InstallationLocating {
    enum Failure: Error { case unreadable }

    func load() throws -> InstallationLocation? { throw Failure.unreadable }
    func save(_ location: InstallationLocation) throws {}
    func remove() throws {}
}

private actor CheckpointArtifactDownloader: ArtifactDownloading {
    private var started = false
    private var startWaiter: CheckedContinuation<Void, Never>?
    private var checkpointWaiter: CheckedContinuation<Void, Never>?

    func download(
        artifact: DeploymentArtifact,
        partialURL: URL,
        progress: @escaping @Sendable (DownloadProgress) -> Void
    ) async throws -> URL {
        started = true
        startWaiter?.resume()
        startWaiter = nil
        await withCheckedContinuation { checkpointWaiter = $0 }
        try Task.checkCancellation()
        return partialURL
    }

    func waitUntilStarted() async {
        if started { return }
        await withCheckedContinuation { startWaiter = $0 }
    }

    func completeCheckpoint() {
        checkpointWaiter?.resume()
        checkpointWaiter = nil
    }
}

private actor PauseCompletion {
    private var completed = false

    func markComplete() { completed = true }
    var isComplete: Bool { completed }
}
