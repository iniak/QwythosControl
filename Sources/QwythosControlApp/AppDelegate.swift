import AppKit
import Foundation
import QwythosCore
import QwythosDeployment
import UserNotifications

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let configuration: ServiceConfiguration
    private let controller: ServiceController
    private let deploymentModel: DeploymentWizardModel
    private let deploymentWindowController: DeploymentWizardWindowController
    private let deploymentWindowPresenter: (() -> Void)?
    private let serviceRefreshCount: (@Sendable () async -> Int)?
    private let servicePlistChecker: any FileExistenceChecking

    private var statusItem: NSStatusItem?
    private let statusTextItem = NSMenuItem(title: "Status: Checking...", action: nil, keyEquivalent: "")
    private let toggleItem = NSMenuItem(title: "Model Service", action: #selector(toggleService), keyEquivalent: "")
    private let deploymentItem = NSMenuItem(title: "Deploy Qwythos...", action: #selector(showDeploymentWizard), keyEquivalent: "")
    private var currentSnapshot = ServiceSnapshot(
        state: .stopped,
        availableAction: nil
    )
    private var operationInProgress = false
    private var operationGeneration = 0
    private var refreshTask: Task<Void, Never>?
    private var terminationPauseRequested = false
    private var installationStatus: InstallationStatus = .notInstalled
    private var deploymentWindowShowCount = 0
    private var serviceInstallationIsAbsent = false

    override init() {
        let configuration = Self.productionConfiguration()
        self.configuration = configuration
        let controller = ServiceController(
            configuration: configuration,
            runner: SystemCommandRunner(),
            healthChecker: URLSessionHealthChecker()
        )
        self.controller = controller
        let locator = InstallationLocator()
        let restoredRoot = (try? locator.load())?.root
        let model = Self.deploymentModel(defaultRoot: restoredRoot) {
            try Self.productionDeploymentCoordinator(
                configuration: configuration,
                service: controller,
                locator: locator
            )
        }
        deploymentModel = model
        deploymentWindowController = DeploymentWizardWindowController(model: model)
        deploymentWindowPresenter = nil
        serviceRefreshCount = nil
        servicePlistChecker = LocalFileExistenceChecker()
        super.init()
        configureDeploymentCallbacks()
    }

    init(
        configuration: ServiceConfiguration,
        controller: ServiceController,
        deploymentModel: DeploymentWizardModel,
        deploymentWindowPresenter: (() -> Void)? = nil,
        serviceRefreshCount: (@Sendable () async -> Int)? = nil,
        servicePlistChecker: any FileExistenceChecking = LocalFileExistenceChecker()
    ) {
        self.configuration = configuration
        self.controller = controller
        self.deploymentModel = deploymentModel
        deploymentWindowController = DeploymentWizardWindowController(model: deploymentModel)
        self.deploymentWindowPresenter = deploymentWindowPresenter
        self.serviceRefreshCount = serviceRefreshCount
        self.servicePlistChecker = servicePlistChecker
        super.init()
        configureDeploymentCallbacks()
    }

    private func configureDeploymentCallbacks() {
        deploymentModel.onBusyStateChanged = { [weak self] in
            guard let self else { return }
            self.render(self.currentSnapshot)
        }
        deploymentModel.onInstallationStatusChanged = { [weak self] status in
            self?.installationStatusDidChange(status)
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        installMenu()

        Task { [weak self] in
            guard let self else { return }
            await deploymentModel.start()
        }

        refreshTask = Task { [weak self] in
            let clock = ContinuousClock()
            var schedule = FixedPollingSchedule(
                startingAt: clock.now,
                interval: .seconds(3)
            )

            while !Task.isCancelled {
                guard let self else { return }
                await self.refresh()

                let nextDeadline = schedule.nextDeadline(after: clock.now)

                do {
                    try await clock.sleep(
                        until: nextDeadline,
                        tolerance: .milliseconds(50)
                    )
                } catch {
                    return
                }
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        refreshTask?.cancel()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !terminationPauseRequested else { return .terminateLater }
        terminationPauseRequested = true
        Task { [weak self] in
            guard let self else {
                NSApp.reply(toApplicationShouldTerminate: true)
                return
            }
            await deploymentModel.pauseForTermination()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    private func installMenu() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem = item

        let initialAccessibilityDescription = "Qwythos service status: Checking"
        item.button?.image = statusImage(
            color: .systemGray,
            accessibilityDescription: initialAccessibilityDescription
        )
        item.button?.setAccessibilityLabel(initialAccessibilityDescription)
        item.button?.toolTip = initialAccessibilityDescription

        statusTextItem.isEnabled = false
        toggleItem.isEnabled = false
        toggleItem.target = self
        deploymentItem.target = self

        let openChatItem = NSMenuItem(
            title: "Open Chat",
            action: #selector(openChat),
            keyEquivalent: ""
        )
        openChatItem.target = self

        let viewLogsItem = NSMenuItem(
            title: "View Logs",
            action: #selector(viewLogs),
            keyEquivalent: ""
        )
        viewLogsItem.target = self

        let quitItem = NSMenuItem(
            title: "Quit Control Center",
            action: #selector(quit),
            keyEquivalent: "q"
        )
        quitItem.target = self

        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.addItem(statusTextItem)
        menu.addItem(deploymentItem)
        menu.addItem(toggleItem)
        menu.addItem(openChatItem)
        menu.addItem(viewLogsItem)
        menu.addItem(.separator())
        menu.addItem(quitItem)
        item.menu = menu
    }

    @discardableResult
    private func refresh(renderSnapshot: Bool = true) async -> ServiceSnapshot? {
        let refreshGeneration = operationGeneration
        let snapshot = await controller.refreshSnapshot()
        guard !operationInProgress,
              refreshGeneration == operationGeneration
        else {
            return nil
        }

        serviceInstallationIsAbsent = !servicePlistChecker.fileExists(
            atPath: configuration.plistPath
        ) && snapshot.availableAction != .stop
        let presentationSnapshot = snapshotForCurrentServiceInstallation(snapshot)
        currentSnapshot = presentationSnapshot
        if renderSnapshot {
            render(presentationSnapshot)
        }
        return presentationSnapshot
    }

    @objc private func toggleService() {
        guard !operationInProgress,
              !deploymentModel.isBusy,
              let action = currentSnapshot.availableAction
        else {
            return
        }

        operationInProgress = true
        deploymentModel.setExternalOperationInProgress(true)
        operationGeneration += 1
        render(
            ServiceSnapshot(
                state: action.inProgressState,
                availableAction: action
            )
        )

        Task { [weak self] in
            guard let self else { return }
            var failureMessage: String?

            do {
                switch action {
                case .start:
                    try await controller.start()
                case .stop:
                    try await controller.stop()
                }
            } catch {
                failureMessage = error.localizedDescription
            }

            operationInProgress = false
            deploymentModel.setExternalOperationInProgress(false)
            let refreshedSnapshot = await refresh(
                renderSnapshot: failureMessage == nil
            )

            if let failureMessage {
                let failureSnapshot = (refreshedSnapshot ?? currentSnapshot)
                    .overlayingOperationFailure(failureMessage)
                currentSnapshot = failureSnapshot
                render(failureSnapshot)
                await notifyFailure(failureMessage)
            }
        }
    }

    @objc private func openChat() {
        NSWorkspace.shared.open(configuration.chatURL)
    }

    @objc private func showDeploymentWizard() {
        guard !operationInProgress else { return }
        deploymentWindowShowCount += 1
        if let deploymentWindowPresenter {
            deploymentWindowPresenter()
        } else {
            deploymentWindowController.showWindow(nil)
        }
    }

    @objc private func viewLogs() {
        NSWorkspace.shared.open(resolvedLogsURL)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem === toggleItem {
            return Self.isServiceToggleEnabled(
                availableAction: currentSnapshot.availableAction,
                operationInProgress: operationInProgress,
                deploymentBusy: deploymentModel.isBusy
            )
        }
        if menuItem === deploymentItem {
            return !operationInProgress
        }
        return true
    }

    private func render(_ snapshot: ServiceSnapshot) {
        let presentation: (text: String, accessibilityStatus: String, color: NSColor)

        if serviceInstallationIsAbsent {
            presentation = ("Status: Not Installed", "Not Installed", .systemGray)
        } else {
            switch snapshot.state {
        case .stopped:
            presentation = ("Status: Stopped", "Stopped", .systemGray)
        case .starting:
            presentation = ("Status: Starting...", "Starting", .systemYellow)
        case .stopping:
            presentation = ("Status: Stopping...", "Stopping", .systemYellow)
        case .running:
            presentation = ("Status: Running", "Running", .systemGreen)
        case .failed(let message):
            let detail = message.trimmingCharacters(in: .whitespacesAndNewlines)
            presentation = (
                detail.isEmpty ? "Status: Failed" : "Status: Failed - \(detail)",
                "Failed",
                .systemRed
            )
        }
        }

        statusTextItem.title = presentation.text
        toggleItem.state = snapshot.availableAction == .stop ? .on : .off
        toggleItem.isEnabled = Self.isServiceToggleEnabled(
            availableAction: snapshot.availableAction,
            operationInProgress: operationInProgress,
            deploymentBusy: deploymentModel.isBusy
        )
        deploymentItem.title = Self.deploymentMenuTitle(for: installationStatus)
        deploymentItem.isEnabled = !operationInProgress
        deploymentItem.setAccessibilityLabel(deploymentItem.title)
        let accessibilityDescription = "Qwythos service status: \(presentation.accessibilityStatus)"
        statusItem?.button?.image = statusImage(
            color: presentation.color,
            accessibilityDescription: accessibilityDescription
        )
        statusItem?.button?.setAccessibilityLabel(accessibilityDescription)
        statusItem?.button?.toolTip = accessibilityDescription
    }

    private func statusImage(color: NSColor, accessibilityDescription: String) -> NSImage? {
        let configuration = NSImage.SymbolConfiguration(hierarchicalColor: color)
        return NSImage(
            systemSymbolName: "circle.fill",
            accessibilityDescription: accessibilityDescription
        )?.withSymbolConfiguration(configuration)
    }

    private func notifyFailure(_ message: String) async {
        let center = UNUserNotificationCenter.current()

        do {
            let authorized = try await center.requestAuthorization(options: [.alert, .sound])
            guard authorized else { return }

            let content = UNMutableNotificationContent()
            content.title = "Qwythos Service Error"
            content.body = message
            content.sound = .default

            let request = UNNotificationRequest(
                identifier: UUID().uuidString,
                content: content,
                trigger: nil
            )
            try await center.add(request)
        } catch {
            // Notification delivery must not block recovery of the menu state.
        }
    }

    private func installationStatusDidChange(_ status: InstallationStatus) {
        installationStatus = status
        render(currentSnapshot)
        Task { [weak self] in
            _ = await self?.refresh()
        }
    }

    private func snapshotForCurrentServiceInstallation(_ snapshot: ServiceSnapshot) -> ServiceSnapshot {
        guard serviceInstallationIsAbsent else { return snapshot }
        return ServiceSnapshot(state: .stopped, availableAction: nil)
    }

    private var resolvedLogsURL: URL {
        guard let record = deploymentModel.installedRecord else {
            return URL(fileURLWithPath: configuration.logsPath, isDirectory: true)
        }
        return InstallationLayout(root: record.root).logsDirectory
    }

    private static func productionConfiguration() -> ServiceConfiguration {
        let homeDirectory = NSHomeDirectory()

        return ServiceConfiguration(
            uid: getuid(),
            label: "com.local.qwythos-9b",
            plistPath: "\(homeDirectory)/Library/LaunchAgents/com.local.qwythos-9b.plist",
            healthURL: URL(string: "http://127.0.0.1:18080/health")!,
            chatURL: URL(string: "http://127.0.0.1:18080")!,
            logsPath: "\(homeDirectory)/Codex/logs"
        )
    }

    private static let deploymentResourceErrorMessage =
        "Deployment resources are unavailable. Reinstall Qwythos Control."

    static func deploymentModel(
        defaultRoot: URL? = nil,
        coordinatorFactory: () throws -> any DeploymentCoordinating
    ) -> DeploymentWizardModel {
        do {
            return DeploymentWizardModel(
                coordinator: try coordinatorFactory(),
                defaultRoot: defaultRoot
            )
        } catch {
            return DeploymentWizardModel(
                coordinator: DeploymentResourceUnavailableCoordinator(),
                defaultRoot: defaultRoot,
                deploymentResourceError: deploymentResourceErrorMessage
            )
        }
    }

    nonisolated static func productionDeploymentCoordinator(
        configuration: ServiceConfiguration,
        service: any ManagedServiceControlling,
        locator: any InstallationLocating = InstallationLocator()
    ) throws -> DeploymentCoordinator {
        let manifest = try DeploymentManifest.load(
            data: DeploymentManifest.productionData()
        )
        let records = InstallationRecordStore()
        let hasher = SHA256Hasher()
        let launchAgentInstaller = LaunchAgentInstaller()

        return DeploymentCoordinator(
            manifest: manifest,
            locator: locator,
            preflight: DeploymentPreflight(),
            downloader: ResumableDownloader(),
            hasher: hasher,
            runtimeInstaller: RuntimeInstaller(),
            launchAgentInstaller: launchAgentInstaller,
            inspectorFactory: { layout in
                InstallationInspector(
                    layout: layout,
                    manifest: manifest,
                    records: records,
                    hasher: hasher
                )
            },
            migratorFactory: { layout in
                LegacyInstallationMigrator(
                    layout: layout,
                    manifest: manifest,
                    records: records,
                    launchAgentInstaller: launchAgentInstaller
                )
            },
            recordStore: records,
            service: service,
            healthChecker: URLSessionHealthChecker()
        )
    }

    nonisolated static func isServiceToggleEnabled(
        availableAction: ServiceAction?,
        operationInProgress: Bool,
        deploymentBusy: Bool
    ) -> Bool {
        !operationInProgress && !deploymentBusy && availableAction != nil
    }

    nonisolated static func deploymentMenuTitle(for status: InstallationStatus) -> String {
        switch status {
        case .legacyDetected:
            return "Migrate Existing Installation..."
        case .managedHealthy, .managedRepairable:
            return "Manage Installation..."
        case .notInstalled,
                .partiallyDownloaded,
                .installationRootUnavailable,
                .managedIncompatible:
            return "Deploy Qwythos..."
        }
    }

    func prepareForTesting() async -> String {
        await deploymentModel.start()
        _ = await refresh()
        return deploymentItem.title
    }

    var deploymentMenuTitleForTesting: String { deploymentItem.title }
    var statusTextForTesting: String { statusTextItem.title }
    var isServiceToggleEnabledForTesting: Bool { toggleItem.isEnabled }
    var isDeploymentMenuEnabledForTesting: Bool { deploymentItem.isEnabled }
    var deploymentIsBusyForTesting: Bool { deploymentModel.isBusy }
    var deploymentWindowShowCountForTesting: Int { deploymentWindowShowCount }
    var deploymentResourceErrorForTesting: String? { deploymentModel.installationRecoveryMessage }
    var serviceRefreshCountForTesting: Int {
        get async { await serviceRefreshCount?() ?? 0 }
    }

    func showDeploymentWizardForTesting() -> Bool {
        let previousCount = deploymentWindowShowCount
        showDeploymentWizard()
        return deploymentWindowShowCount > previousCount
    }

    func triggerServiceToggleForTesting() {
        toggleService()
    }

}

private actor DeploymentResourceUnavailableCoordinator: DeploymentCoordinating {
    func snapshots() async -> AsyncStream<DeploymentSnapshot> { AsyncStream { _ in } }
    func inspect() async -> InstallationStatus { .notInstalled }
    func deploy(options: DeploymentOptions) async throws {}
    func migrate(options: DeploymentOptions) async throws {}
    func pause() async {}
    func pauseAndWait() async {}
    func repair() async throws {}
    func reinstallRuntime() async throws {}
    func setAccessMode(_ mode: NetworkAccessMode) async throws {}
    func regenerateAPIKey() async throws -> String { "" }
    func uninstall(deleteModel: Bool) async throws {}
}
