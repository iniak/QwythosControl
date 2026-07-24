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
    private var currentState = ServiceState.stopped
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
            while !Task.isCancelled {
                guard let self else { return }
                await self.refresh()

                do {
                    try await Task.sleep(for: .seconds(3))
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
        let state = await controller.refresh()
        guard !operationInProgress else { return }

        currentState = state
        render(state)
    }

    @objc private func toggleService() {
        guard !operationInProgress else { return }

        let stateToToggle = currentState
        operationInProgress = true
        render(.starting)

        Task { [weak self] in
            guard let self else { return }
            var failureMessage: String?

            do {
                switch stateToToggle {
                case .running, .starting:
                    try await controller.stop()
                case .stopped, .failed:
                    try await controller.start()
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

    private func render(_ state: ServiceState) {
        let presentation: (text: String, accessibilityStatus: String, color: NSColor, checked: Bool)

        switch state {
        case .stopped:
            presentation = ("Status: Stopped", "Stopped", .systemGray, false)
        case .starting:
            presentation = ("Status: Starting...", "Starting", .systemYellow, false)
        case .running:
            presentation = ("Status: Running", "Running", .systemGreen, true)
        case .failed(let message):
            let detail = message.trimmingCharacters(in: .whitespacesAndNewlines)
            presentation = (
                detail.isEmpty ? "Status: Failed" : "Status: Failed - \(detail)",
                "Failed",
                .systemRed,
                false
            )
        }

        statusTextItem.title = presentation.text
        toggleItem.state = presentation.checked ? .on : .off
        toggleItem.isEnabled = !operationInProgress
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
