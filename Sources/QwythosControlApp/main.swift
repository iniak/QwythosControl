import AppKit
import Foundation
import QwythosCore
import UserNotifications

@main
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let configuration: ServiceConfiguration
    private let controller: ServiceController

    private var statusItem: NSStatusItem?
    private let statusTextItem = NSMenuItem(title: "Status: Checking...", action: nil, keyEquivalent: "")
    private let toggleItem = NSMenuItem(title: "Model Service", action: #selector(toggleService), keyEquivalent: "")
    private var currentSnapshot = ServiceSnapshot(
        state: .stopped,
        availableAction: nil
    )
    private var operationInProgress = false
    private var refreshTask: Task<Void, Never>?

    override init() {
        let configuration = Self.productionConfiguration()
        self.configuration = configuration
        self.controller = ServiceController(
            configuration: configuration,
            runner: SystemCommandRunner(),
            healthChecker: URLSessionHealthChecker()
        )
        super.init()
    }

    static func main() {
        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.setActivationPolicy(.accessory)
        application.delegate = delegate
        application.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        installMenu()

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
        menu.addItem(toggleItem)
        menu.addItem(openChatItem)
        menu.addItem(viewLogsItem)
        menu.addItem(.separator())
        menu.addItem(quitItem)
        item.menu = menu
    }

    private func refresh() async {
        let snapshot = await controller.refreshSnapshot()
        guard !operationInProgress else { return }

        currentSnapshot = snapshot
        render(snapshot)
    }

    @objc private func toggleService() {
        guard !operationInProgress,
              let action = currentSnapshot.availableAction
        else {
            return
        }

        operationInProgress = true
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
            await refresh()

            if let failureMessage {
                await notifyFailure(failureMessage)
            }
        }
    }

    @objc private func openChat() {
        NSWorkspace.shared.open(configuration.chatURL)
    }

    @objc private func viewLogs() {
        NSWorkspace.shared.open(
            URL(fileURLWithPath: configuration.logsPath, isDirectory: true)
        )
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    private func render(_ snapshot: ServiceSnapshot) {
        let presentation: (text: String, accessibilityStatus: String, color: NSColor)

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

        statusTextItem.title = presentation.text
        toggleItem.state = snapshot.availableAction == .stop ? .on : .off
        toggleItem.isEnabled = !operationInProgress && snapshot.availableAction != nil
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
}
