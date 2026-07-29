import AppKit
import Combine
import Foundation
import QwythosDeployment

@MainActor
final class DeploymentWizardModel: ObservableObject {
    enum Step: Equatable {
        case deviceCheck
        case configuration
        case review
        case progress
        case completion
        case management
    }

    private enum Operation: Equatable {
        case deploy
        case migrate
        case repair
        case reinstallRuntime
        case updateAccessMode
        case regenerateKey
        case uninstall
    }

    private struct OperationToken: Equatable {
        let sequence: UInt
        let operation: Operation
        var coordinatorOperationID: UUID?
    }

    private struct CancellationIntent {
        let operationToken: OperationToken
        var coordinatorOperationID: UUID?
    }

    private struct CancellationTombstone {
        let sequence: UInt
        var coordinatorOperationID: UUID?
    }

    @Published private(set) var step: Step = .deviceCheck
    @Published private(set) var snapshot = DeploymentSnapshot(
        phase: .idle,
        statusText: "Not installed."
    )
    @Published private(set) var preflightReport: PreflightReport?
    @Published var selectedRoot: URL
    @Published var contextSize: Int
    @Published var pendingAccessMode: NetworkAccessMode = .local {
        didSet {
            if pendingAccessMode == .local {
                revealedAPIKey = nil
                apiKeyActionMessage = nil
            }
        }
    }
    @Published var deleteModelOnUninstall = false
    @Published private(set) var isOperationInProgress = false
    @Published private(set) var externalOperationInProgress = false
    @Published private(set) var isShowingUninstallConfirmation = false
    @Published private(set) var requiresRemovableVolumeAcknowledgement = false
    @Published private(set) var hasAcknowledgedRemovableVolume = false
    @Published private(set) var installationRecoveryMessage: String?
    @Published private(set) var revealedAPIKey: String?
    @Published private(set) var apiKeyActionMessage: String?

    let automaticContextSize: Int
    let bundledRuntimeVersion: String

    private let coordinator: any DeploymentCoordinating
    private let preflight: @Sendable (URL) async -> PreflightReport
    private let isRemovableVolume: @Sendable (URL) -> Bool
    private let lanAddresses: @Sendable () -> [String]
    private let apiKeyLoader: (URL) throws -> String?
    private let clipboardWriter: (String) -> Void
    private let deploymentResourceError: String?
    private var snapshotTask: Task<Void, Never>?
    private var preflightTask: Task<Void, Never>?
    private var installationRefreshTask: Task<Void, Never>?
    private var preflightGeneration = 0
    private var installationRefreshGeneration = 0
    private var activeOperation: Operation?
    private var lastOperation: Operation?
    private var operationSequence: UInt = 0
    private var activeOperationToken: OperationToken?
    private var lastOperationToken: OperationToken?
    private var lastAcceptedOperationToken: OperationToken?
    private var cancellationIntent: CancellationIntent?
    private var cancellationTombstones: [CancellationTombstone] = []
    private var hasStarted = false
    private var completedHealthyDeployment = false
    private var hasAuthenticatedSharedAccess = false
    private var hasPendingUninstallConfirmation = false
    private var installationStatus: InstallationStatus = .notInstalled

    var onBusyStateChanged: (() -> Void)?
    var onInstallationStatusChanged: ((InstallationStatus) -> Void)?

    init(
        coordinator: any DeploymentCoordinating,
        defaultRoot: URL? = nil,
        automaticContextSize: Int? = nil,
        bundledRuntimeVersion: String? = nil,
        deploymentResourceError: String? = nil,
        preflight: (@Sendable (URL) async -> PreflightReport)? = nil,
        isRemovableVolume: (@Sendable (URL) -> Bool)? = nil,
        lanAddresses: @escaping @Sendable () -> [String] = { LANAddressProvider().activeIPv4Addresses() },
        apiKeyLoader: @escaping (URL) throws -> String? = {
            try APIKeyStore(fileURL: $0).load()
        },
        clipboardWriter: @escaping (String) -> Void = {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString($0, forType: .string)
        }
    ) {
        self.coordinator = coordinator
        selectedRoot = (defaultRoot ?? Self.defaultRoot).standardizedFileURL
        let automaticContextSize = automaticContextSize ?? Self.automaticContextSize
        self.automaticContextSize = automaticContextSize
        self.bundledRuntimeVersion = bundledRuntimeVersion ?? Self.currentRuntimeVersion
        contextSize = automaticContextSize
        self.preflight = preflight ?? defaultWizardPreflight
        self.isRemovableVolume = isRemovableVolume ?? volumeIsRemovable
        self.lanAddresses = lanAddresses
        self.apiKeyLoader = apiKeyLoader
        self.clipboardWriter = clipboardWriter
        self.deploymentResourceError = deploymentResourceError
        refreshStorageAcknowledgement()
        if let deploymentResourceError {
            snapshot = DeploymentSnapshot(
                phase: .failed,
                statusText: deploymentResourceError,
                failure: DeploymentFailure(
                    phase: .failed,
                    component: nil,
                    reason: deploymentResourceError,
                    diagnostic: deploymentResourceError,
                    recoveryActions: [.viewLogs]
                )
            )
            installationRecoveryMessage = deploymentResourceError
            step = .progress
        }
    }

    deinit {
        snapshotTask?.cancel()
        preflightTask?.cancel()
        installationRefreshTask?.cancel()
    }

    var canContinue: Bool {
        guard preflightReport?.canDeploy == true else { return false }
        return !requiresRemovableVolumeAcknowledgement || hasAcknowledgedRemovableVolume
    }

    var canDeploy: Bool {
        step == .review && canContinue && DeploymentOptions.supportedContextSizes.contains(contextSize)
            && !isBusy
    }

    var isBusy: Bool {
        if externalOperationInProgress || isOperationInProgress || activeOperation != nil { return true }
        switch snapshot.phase {
        case .preflighting,
                .downloadingRuntime,
                .verifyingRuntime,
                .installingRuntime,
                .downloadingModel,
                .verifyingModel,
                .writingConfiguration,
                .startingService,
                .checkingHealth,
                .repairing,
                .uninstalling:
            return true
        default:
            return false
        }
    }

    var showsLANWarning: Bool {
        pendingAccessMode == .shared
    }

    // API key contents stay in the key file and are never exposed to SwiftUI.
    var lanAuthorizationValue: String? { nil }

    var progressFraction: Double? {
        guard let progress = snapshot.overallProgress else { return nil }
        return min(max(progress, 0), 1)
    }

    var usesDeterminateProgress: Bool {
        snapshot.totalBytes != nil && snapshot.completedBytes != nil
    }

    var localEndpoint: String? {
        guard completedHealthyDeployment else { return nil }
        return "http://127.0.0.1:18080"
    }

    var lanEndpoints: [String] {
        guard completedHealthyDeployment,
              pendingAccessMode == .shared,
              hasAuthenticatedSharedAccess
        else { return [] }
        return lanAddresses().map { "http://\($0):18080" }
    }

    var installedRecord: InstallationRecord? {
        switch installationStatus {
        case .managedHealthy(let record), .managedRepairable(let record, _):
            return record
        default:
            return nil
        }
    }

    var requiresRuntimeUpdate: Bool {
        runtimeVersionComparison == .orderedAscending
    }

    var runtimeActionTitle: String? {
        switch runtimeVersionComparison {
        case .orderedAscending:
            return "Update Runtime"
        case .orderedSame, .orderedDescending:
            return "Reinstall Runtime"
        case .none:
            return nil
        }
    }

    var canRunRuntimeAction: Bool {
        runtimeActionTitle != nil && !isBusy
    }

    var canRepair: Bool {
        guard !isBusy else { return false }
        if case .managedRepairable = installationStatus { return true }
        return false
    }

    var canApplyAccessMode: Bool {
        guard !isBusy, let installedRecord else { return false }
        return pendingAccessMode != installedRecord.accessMode
    }

    var isMigrationCandidate: Bool {
        if case .legacyDetected = installationStatus { return true }
        return false
    }

    var primaryDeploymentTitle: String {
        isMigrationCandidate ? "Migrate Existing Installation" : "Deploy Qwythos"
    }

    var canPause: Bool {
        guard isBusy else { return false }
        switch activeOperation {
        case .deploy, .migrate:
            return true
        default:
            return false
        }
    }

    var canCancel: Bool {
        guard isBusy else { return false }
        switch activeOperation {
        case .deploy, .migrate:
            return true
        default:
            return false
        }
    }

    var canResume: Bool {
        guard snapshot.phase == .paused else { return false }
        switch lastOperation {
        case .deploy, .migrate:
            return canContinue
        default:
            return false
        }
    }

    var canRetryRecovery: Bool {
        snapshot.failure?.recoveryActions.contains(.retry) == true
    }

    var canViewLogs: Bool {
        snapshot.failure?.recoveryActions.contains(.viewLogs) == true
    }

    var failureMessage: String {
        snapshot.failure?.reason ?? snapshot.statusText
    }

    var progressPrimaryActionTitle: String? {
        if canResume { return "Resume Deployment" }
        if canRetryRecovery { return "Retry" }
        return nil
    }

    func start() async {
        guard !hasStarted else { return }
        hasStarted = true
        guard deploymentResourceError == nil else {
            return
        }
        await subscribeToSnapshots()

        await scheduleInstallationStatusRefresh(
            preservingCurrentStep: false
        ).value
        if shouldRunStartupPreflight {
            await refreshPreflight()
        }
    }

    func refreshPreflight() async {
        preflightGeneration &+= 1
        preflightTask?.cancel()
        let checkedRoot = selectedRoot
        let generation = preflightGeneration
        preflightReport = nil
        await runPreflight(checkedRoot: checkedRoot, generation: generation)
    }

    func selectRoot(_ root: URL) {
        selectedRoot = root.standardizedFileURL
        refreshStorageAcknowledgement()
        preflightGeneration &+= 1
        preflightReport = nil
        preflightTask?.cancel()
        let checkedRoot = selectedRoot
        let generation = preflightGeneration
        preflightTask = Task { [weak self] in
            await self?.runPreflight(
                checkedRoot: checkedRoot,
                generation: generation
            )
        }
    }

    func acknowledgeRemovableVolume() {
        hasAcknowledgedRemovableVolume = true
    }

    func continueToNextStep() {
        guard canContinue, !isBusy else { return }
        switch step {
        case .deviceCheck:
            step = .configuration
        case .configuration:
            step = .review
        default:
            return
        }
    }

    func goBack() {
        guard !isBusy else { return }
        switch step {
        case .configuration:
            step = .deviceCheck
        case .review:
            step = .configuration
        default:
            return
        }
    }

    func deploy() async {
        guard canDeploy else { return }
        let options = options()
        await perform(.deploy) {
            try await self.coordinator.deploy(options: options)
        }
    }

    func migrate() async {
        guard canContinue, !isBusy else { return }
        let options = options()
        await perform(.migrate) {
            try await self.coordinator.migrate(options: options)
        }
    }

    func performPrimaryProgressAction() async {
        if canResume {
            await resume()
        } else {
            await retryRecovery()
        }
    }

    func resume() async {
        guard canResume else { return }
        switch lastOperation {
        case .migrate:
            await migrate()
        case .deploy:
            await resumeDeployment()
        default:
            return
        }
    }

    func retryRecovery() async {
        guard canRetryRecovery else { return }
        switch lastOperation {
        case .migrate:
            await migrate()
        case .repair:
            await repair()
        case .reinstallRuntime:
            await reinstallRuntime()
        case .updateAccessMode:
            await updateAccessMode()
        case .regenerateKey:
            await regenerateAPIKey()
        case .uninstall:
            requestUninstall()
        case .deploy, .none:
            await resumeDeployment()
        }
    }

    func repair() async {
        guard !isBusy else { return }
        await perform(.repair) {
            try await self.coordinator.repair()
        }
    }

    func reinstallRuntime() async {
        guard !isBusy else { return }
        await perform(.reinstallRuntime) {
            try await self.coordinator.reinstallRuntime()
        }
    }

    func performRuntimeAction() async {
        guard canRunRuntimeAction else { return }
        await reinstallRuntime()
    }

    func updateAccessMode() async {
        guard canApplyAccessMode else { return }
        let mode = pendingAccessMode
        await perform(.updateAccessMode) {
            try await self.coordinator.setAccessMode(mode)
        }
    }

    func regenerateAPIKey() async {
        guard canRegenerateAPIKey else { return }
        revealedAPIKey = nil
        apiKeyActionMessage = nil
        await perform(.regenerateKey) {
            _ = try await self.coordinator.regenerateAPIKey()
        }
    }

    func requestUninstall() {
        guard !isBusy else { return }
        hasPendingUninstallConfirmation = true
        isShowingUninstallConfirmation = true
    }

    func setUninstallConfirmationPresented(_ isPresented: Bool) {
        isShowingUninstallConfirmation = isPresented
    }

    func cancelUninstall() {
        hasPendingUninstallConfirmation = false
        isShowingUninstallConfirmation = false
    }

    func openManagement() {
        guard !isBusy else { return }
        step = .management
    }

    func confirmUninstall() async {
        guard hasPendingUninstallConfirmation, !isBusy else { return }
        hasPendingUninstallConfirmation = false
        isShowingUninstallConfirmation = false
        let deleteModel = deleteModelOnUninstall
        await perform(.uninstall) {
            try await self.coordinator.uninstall(deleteModel: deleteModel)
        }
    }

    func uninstall() async {
        await confirmUninstall()
    }

    func pause() async {
        guard canPause else { return }
        await coordinator.pause()
    }

    func cancel() async {
        guard canCancel, let operationToken = activeOperationToken else { return }
        cancellationIntent = CancellationIntent(
            operationToken: operationToken,
            coordinatorOperationID: operationToken.coordinatorOperationID
        )
        recordCancellationTombstone(for: operationToken)
        await coordinator.cancel()
    }

    func pauseForTermination() async {
        await coordinator.pauseAndWait()
    }

    func setExternalOperationInProgress(_ isInProgress: Bool) {
        guard externalOperationInProgress != isInProgress else { return }
        externalOperationInProgress = isInProgress
        onBusyStateChanged?()
    }

    func copy(_ value: String) {
        clipboardWriter(value)
    }

    func copyAPIKey() {
        guard let key = loadAPIKeyForExplicitAction() else { return }
        clipboardWriter(key)
    }

    func toggleAPIKeyReveal() {
        if revealedAPIKey != nil {
            revealedAPIKey = nil
            apiKeyActionMessage = nil
            return
        }
        revealedAPIKey = loadAPIKeyForExplicitAction()
    }

    func revealSelectedRoot() {
        NSWorkspace.shared.activateFileViewerSelecting([selectedRoot])
    }

    func revealLogs() {
        NSWorkspace.shared.open(InstallationLayout(root: selectedRoot).logsDirectory)
    }

    func open(_ endpoint: String) {
        guard let url = URL(string: endpoint) else { return }
        NSWorkspace.shared.open(url)
    }

    private func options() -> DeploymentOptions {
        DeploymentOptions(
            root: selectedRoot,
            contextSize: contextSize,
            accessMode: pendingAccessMode
        )
    }

    private func resumeDeployment() async {
        guard canContinue, !isBusy else { return }
        let options = options()
        await perform(.deploy) {
            try await self.coordinator.deploy(options: options)
        }
    }

    private func subscribeToSnapshots() async {
        let snapshots = await coordinator.snapshots()
        snapshotTask = Task { [weak self] in
            for await next in snapshots {
                guard !Task.isCancelled else { return }
                self?.consume(next)
            }
        }
    }

    private func consume(_ next: DeploymentSnapshot) {
        associateSnapshot(withCurrentOperation: next)
        if shouldIgnoreUnresolvedCancelledPause(next) {
            return
        }
        if shouldIgnoreCancelledSnapshotOlderThanLastAcceptedOperation(next) {
            return
        }
        if next.phase == .paused, consumeCancelledPause(next) {
            return
        }
        if isStaleCancelledSnapshot(next),
           !isMatchingCancellationTerminal(next) {
            return
        }
        clearCancellationIntentIfTerminal(next)
        recordAcceptedOperation(for: next)
        snapshot = next
        switch next.phase {
        case .downloadingRuntime,
                .verifyingRuntime,
                .installingRuntime,
                .downloadingModel,
                .verifyingModel,
                .writingConfiguration,
                .startingService,
                .checkingHealth,
                .repairing,
                .uninstalling,
                .paused,
                .failed:
            step = .progress
        case .installed:
            completedHealthyDeployment = true
            hasAuthenticatedSharedAccess = pendingAccessMode == .shared
            if completionOperation == .repair || completionOperation == .reinstallRuntime
                || completionOperation == .updateAccessMode || completionOperation == .regenerateKey {
                step = .management
                _ = scheduleInstallationStatusRefresh(preservingCurrentStep: false)
            } else {
                step = .completion
                _ = scheduleInstallationStatusRefresh(preservingCurrentStep: true)
            }
        case .idle:
            if completionOperation == .uninstall {
                resetAfterUninstall()
            }
        case .preflighting, .ready:
            break
        }
    }

    private var completionOperation: Operation? {
        activeOperation ?? lastOperation
    }

    private func applyInstallationStatus(_ status: InstallationStatus) {
        setInstallationStatus(status)
        revealedAPIKey = nil
        apiKeyActionMessage = nil
        switch status {
        case .managedHealthy(let record), .managedRepairable(let record, _):
            installationRecoveryMessage = nil
            selectedRoot = record.root
            contextSize = record.contextSize
            pendingAccessMode = record.accessMode
            refreshStorageAcknowledgement()
            step = .management
        case .legacyDetected:
            installationRecoveryMessage = nil
            step = .deviceCheck
        case .notInstalled, .partiallyDownloaded:
            installationRecoveryMessage = nil
            step = .deviceCheck
        case .installationRootUnavailable(let root):
            restoreSelectedRootWithoutPreflight(root)
            installationRecoveryMessage = "The installation location is unavailable: \(root.path)"
            step = .deviceCheck
        case .managedIncompatible(let reason):
            installationRecoveryMessage = reason
            step = .deviceCheck
        }
    }

    private func refreshStorageAcknowledgement() {
        requiresRemovableVolumeAcknowledgement = isRemovableVolume(selectedRoot)
        hasAcknowledgedRemovableVolume = !requiresRemovableVolumeAcknowledgement
    }

    private func restoreSelectedRootWithoutPreflight(_ root: URL) {
        selectedRoot = root.standardizedFileURL
        preflightGeneration &+= 1
        preflightTask?.cancel()
        preflightReport = nil
        refreshStorageAcknowledgement()
    }

    private func perform(
        _ operation: Operation,
        work: () async throws -> Void
    ) async {
        operationSequence &+= 1
        let token = OperationToken(
            sequence: operationSequence,
            operation: operation,
            coordinatorOperationID: nil
        )
        activeOperation = operation
        activeOperationToken = token
        lastOperationToken = token
        isOperationInProgress = true
        onBusyStateChanged?()
        lastOperation = operation
        step = .progress
        defer {
            if activeOperationToken?.sequence == token.sequence {
                activeOperation = nil
                activeOperationToken = nil
            }
            isOperationInProgress = false
            onBusyStateChanged?()
        }
        do {
            try await work()
        } catch is CancellationError {
            // The coordinator emits the paused immutable snapshot.
        } catch {
            // The coordinator emits a failure snapshot with recovery actions.
        }
    }

    private func associateSnapshot(withCurrentOperation snapshot: DeploymentSnapshot) {
        guard let operationID = snapshot.operationID else { return }

        if var active = activeOperationToken,
           active.coordinatorOperationID == nil {
            active.coordinatorOperationID = operationID
            activeOperationToken = active
            if lastOperationToken?.sequence == active.sequence {
                lastOperationToken = active
            }
            if cancellationIntent?.operationToken.sequence == active.sequence {
                cancellationIntent?.coordinatorOperationID = operationID
            }
            return
        }

        if var last = lastOperationToken,
           last.coordinatorOperationID == nil {
            if cancellationIntent?.operationToken.sequence == last.sequence {
                last.coordinatorOperationID = operationID
                lastOperationToken = last
                cancellationIntent?.coordinatorOperationID = operationID
            } else if activeOperationToken == nil,
                      snapshot.phase == .installed || snapshot.phase == .failed {
                last.coordinatorOperationID = operationID
                lastOperationToken = last
            }
        }
    }

    private func consumeCancelledPause(_ next: DeploymentSnapshot) -> Bool {
        if var intent = cancellationIntent,
           cancellationIntentMatches(intent, snapshot: next) {
            if intent.coordinatorOperationID == nil {
                intent.coordinatorOperationID = next.operationID
            }
            bindCancellationTombstone(
                sequence: intent.operationToken.sequence,
                operationID: intent.coordinatorOperationID ?? next.operationID
            )

            if intent.coordinatorOperationID != nil {
                cancellationIntent = nil
            }

            if activeOperationToken?.sequence != intent.operationToken.sequence,
               activeOperationToken != nil {
                return true
            }

            recordAcceptedOperation(for: next)
            snapshot = next
            step = .configuration
            return true
        }

        guard isCancelled(snapshot: next) else { return false }
        if activeOperationToken?.coordinatorOperationID != next.operationID,
           activeOperationToken != nil {
            return true
        }

        snapshot = next
        step = .configuration
        return true
    }

    private func clearCancellationIntentIfTerminal(_ next: DeploymentSnapshot) {
        guard let intent = cancellationIntent,
              cancellationIntentMatches(intent, snapshot: next)
        else {
            return
        }

        switch next.phase {
        case .failed, .installed, .idle:
            bindCancellationTombstone(
                sequence: intent.operationToken.sequence,
                operationID: intent.coordinatorOperationID ?? next.operationID
            )
            cancellationIntent = nil
        default:
            break
        }
    }

    private func isMatchingCancellationTerminal(
        _ snapshot: DeploymentSnapshot
    ) -> Bool {
        guard snapshot.phase == .installed || snapshot.phase == .failed,
              let intent = cancellationIntent
        else {
            return false
        }
        return cancellationIntentMatches(intent, snapshot: snapshot)
    }

    private func cancellationIntentMatches(
        _ intent: CancellationIntent,
        snapshot: DeploymentSnapshot
    ) -> Bool {
        if let expected = intent.coordinatorOperationID {
            return snapshot.operationID == expected
        }

        if snapshot.operationID != nil {
            return activeOperationToken?.sequence == intent.operationToken.sequence
                || lastOperationToken?.sequence == intent.operationToken.sequence
        }
        return activeOperationToken?.sequence == intent.operationToken.sequence
            || lastOperationToken?.sequence == intent.operationToken.sequence
    }

    private func isCancelled(snapshot: DeploymentSnapshot) -> Bool {
        if let operationID = snapshot.operationID {
            return cancellationTombstones.contains {
                $0.coordinatorOperationID == operationID
            }
        }
        return activeOperationToken == nil
            && lastOperationToken.map { token in
                cancellationTombstones.contains { $0.sequence == token.sequence }
            } == true
    }

    private func isStaleCancelledSnapshot(_ next: DeploymentSnapshot) -> Bool {
        guard let operationID = next.operationID else { return false }
        return cancellationTombstones.contains {
            $0.coordinatorOperationID == operationID
        }
    }

    private func shouldIgnoreCancelledSnapshotOlderThanLastAcceptedOperation(
        _ snapshot: DeploymentSnapshot
    ) -> Bool {
        guard let operationID = snapshot.operationID,
              let cancelledOperation = cancellationTombstones.first(
                  where: { $0.coordinatorOperationID == operationID }
              ),
              let lastAcceptedOperation = lastAcceptedOperationToken,
              let lastAcceptedOperationID = lastAcceptedOperation.coordinatorOperationID,
              cancelledOperation.sequence < lastAcceptedOperation.sequence,
              operationID != lastAcceptedOperationID
        else {
            return false
        }
        return true
    }

    private func shouldIgnoreUnresolvedCancelledPause(
        _ next: DeploymentSnapshot
    ) -> Bool {
        guard next.phase == .paused,
              let operationID = next.operationID,
              let newestOperation = activeOperationToken ?? lastOperationToken,
              let newestOperationID = newestOperation.coordinatorOperationID,
              operationID != newestOperationID
        else {
            return false
        }

        return cancellationTombstones.contains {
            $0.sequence < newestOperation.sequence
                && $0.coordinatorOperationID == nil
        }
    }

    private func recordAcceptedOperation(for snapshot: DeploymentSnapshot) {
        guard let operationID = snapshot.operationID else { return }
        if activeOperationToken?.coordinatorOperationID == operationID {
            lastAcceptedOperationToken = activeOperationToken
        } else if lastOperationToken?.coordinatorOperationID == operationID {
            lastAcceptedOperationToken = lastOperationToken
        }
    }

    private func recordCancellationTombstone(for token: OperationToken) {
        if !cancellationTombstones.contains(where: { $0.sequence == token.sequence }) {
            cancellationTombstones.append(
                CancellationTombstone(
                    sequence: token.sequence,
                    coordinatorOperationID: token.coordinatorOperationID
                )
            )
        }
        trimCancellationTombstones()
    }

    private func bindCancellationTombstone(
        sequence: UInt,
        operationID: UUID?
    ) {
        guard let index = cancellationTombstones.firstIndex(
            where: { $0.sequence == sequence }
        ) else {
            return
        }
        cancellationTombstones[index].coordinatorOperationID = operationID
    }

    private func trimCancellationTombstones() {
        let maximumTombstones = 8
        guard cancellationTombstones.count > maximumTombstones else { return }
        cancellationTombstones.removeFirst(
            cancellationTombstones.count - maximumTombstones
        )
    }

    #if DEBUG
    var cancellationTombstoneCountForTesting: Int {
        cancellationTombstones.count
    }

    var hasPendingCancellationIntentForTesting: Bool {
        cancellationIntent != nil
    }
    #endif

    private var runtimeVersionComparison: ComparisonResult? {
        guard let record = installedRecord else { return nil }
        return record.runtimeVersion.compare(
            bundledRuntimeVersion,
            options: [.numeric, .caseInsensitive]
        )
    }

    var canRegenerateAPIKey: Bool {
        installedRecord?.accessMode == .shared && !isBusy
    }

    var canReadAPIKey: Bool {
        guard pendingAccessMode == .shared, !isBusy else { return false }
        return completedHealthyDeployment || installedRecord?.accessMode == .shared
    }

    private var shouldRunStartupPreflight: Bool {
        switch installationStatus {
        case .managedHealthy, .managedRepairable,
                .installationRootUnavailable, .managedIncompatible:
            return false
        case .notInstalled, .partiallyDownloaded, .legacyDetected:
            return true
        }
    }

    private func loadAPIKeyForExplicitAction() -> String? {
        guard canReadAPIKey else { return nil }
        do {
            guard let key = try apiKeyLoader(
                InstallationLayout(root: selectedRoot).apiKeyFile
            ) else {
                apiKeyActionMessage = "The local-network key is unavailable."
                return nil
            }
            apiKeyActionMessage = nil
            return key
        } catch {
            apiKeyActionMessage = "The local-network key could not be read."
            return nil
        }
    }

    private func runPreflight(
        checkedRoot: URL,
        generation: Int
    ) async {
        let report = await preflight(checkedRoot)
        guard !Task.isCancelled,
              generation == preflightGeneration,
              checkedRoot == selectedRoot
        else {
            return
        }
        preflightReport = report
    }

    private func scheduleInstallationStatusRefresh(
        preservingCurrentStep: Bool
    ) -> Task<Void, Never> {
        installationRefreshGeneration &+= 1
        installationRefreshTask?.cancel()
        let generation = installationRefreshGeneration
        let task = Task { [weak self] in
            guard let self else { return }
            let status = await coordinator.inspect()
            guard !Task.isCancelled,
                  generation == installationRefreshGeneration
            else {
                return
            }
            if preservingCurrentStep {
                setInstallationStatus(status)
            } else {
                applyInstallationStatus(status)
            }
        }
        installationRefreshTask = task
        return task
    }

    private func setInstallationStatus(_ status: InstallationStatus) {
        installationStatus = status
        onInstallationStatusChanged?(status)
    }

    private func resetAfterUninstall() {
        setInstallationStatus(.notInstalled)
        completedHealthyDeployment = false
        hasAuthenticatedSharedAccess = false
        pendingAccessMode = .local
        deleteModelOnUninstall = false
        lastOperation = nil
        activeOperation = nil
        activeOperationToken = nil
        lastOperationToken = nil
        lastAcceptedOperationToken = nil
        cancellationIntent = nil
        cancellationTombstones.removeAll()
        hasPendingUninstallConfirmation = false
        isShowingUninstallConfirmation = false
        revealedAPIKey = nil
        apiKeyActionMessage = nil
        step = .deviceCheck
        refreshStorageAcknowledgement()
        selectRoot(selectedRoot)
        _ = scheduleInstallationStatusRefresh(preservingCurrentStep: false)
    }

    private static let defaultRoot: URL = FileManager.default.urls(
        for: .applicationSupportDirectory,
        in: .userDomainMask
    )[0].appending(path: "Qwythos Control", directoryHint: .isDirectory)

    private static var automaticContextSize: Int {
        (try? PerformanceProfile.automatic(
            physicalMemory: ProcessInfo.processInfo.physicalMemory
        ).contextSize) ?? 8_192
    }

    private static var currentRuntimeVersion: String {
        guard let data = try? DeploymentManifest.productionData(),
              let manifest = try? DeploymentManifest.load(data: data)
        else {
            return "b10159"
        }
        return manifest.runtime.version
    }

    #if DEBUG
    static func preview(
        step: Step,
        failure: Bool = false,
        migration: Bool = false,
        activeDeployment: Bool = false
    ) -> DeploymentWizardModel {
        let model = DeploymentWizardModel(
            coordinator: PreviewDeploymentCoordinator(),
            automaticContextSize: 8_192,
            preflight: { _ in
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
        )
        if migration {
            model.installationStatus = .legacyDetected
        }
        if activeDeployment {
            model.activeOperation = .deploy
            model.isOperationInProgress = true
        }
        model.step = step
        if failure {
            model.snapshot = DeploymentSnapshot(
                phase: .failed,
                component: .model,
                completedBytes: 1_024,
                totalBytes: 2_048,
                overallProgress: 0.5,
                statusText: "The model download could not be verified.",
                failure: DeploymentFailure(
                    phase: .verifyingModel,
                    component: .model,
                    reason: "The model download could not be verified.",
                    diagnostic: "Preview failure",
                    recoveryActions: [.retry, .viewLogs]
                )
            )
        } else if step == .progress {
            model.snapshot = DeploymentSnapshot(
                phase: .downloadingModel,
                component: .model,
                completedBytes: 1_024,
                totalBytes: 2_048,
                overallProgress: 0.5,
                statusText: "Downloading model..."
            )
        } else if step == .completion {
            model.snapshot = DeploymentSnapshot(
                phase: .installed,
                overallProgress: 1,
                statusText: "Qwythos is installed."
            )
            model.completedHealthyDeployment = true
            model.hasAuthenticatedSharedAccess = model.pendingAccessMode == .shared
        }
        return model
    }
    #endif
}

private func defaultWizardPreflight(root: URL) async -> PreflightReport {
    await DeploymentPreflight().run(root: root, servicePort: 18_080)
}

private func volumeIsRemovable(_ root: URL) -> Bool {
    let values = try? root.resourceValues(forKeys: [.volumeIsRemovableKey])
    return values?.volumeIsRemovable == true
}

#if DEBUG
private actor PreviewDeploymentCoordinator: DeploymentCoordinating {
    func snapshots() async -> AsyncStream<DeploymentSnapshot> {
        AsyncStream { $0.finish() }
    }

    func inspect() async -> InstallationStatus { .notInstalled }
    func deploy(options _: DeploymentOptions) async throws {}
    func migrate(options _: DeploymentOptions) async throws {}
    func pause() async {}
    func pauseAndWait() async {}
    func repair() async throws {}
    func reinstallRuntime() async throws {}
    func setAccessMode(_: NetworkAccessMode) async throws {}
    func regenerateAPIKey() async throws -> String { "" }
    func uninstall(deleteModel _: Bool) async throws {}
}
#endif
