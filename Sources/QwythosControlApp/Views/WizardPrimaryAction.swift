import AppKit
import SwiftUI

struct WizardPrimaryAction: NSViewRepresentable {
    let title: String
    let accessibilityIdentifier: String
    let isEnabled: Bool
    let isDestructive: Bool
    let action: () -> Void

    init(
        _ title: String,
        accessibilityIdentifier: String,
        isEnabled: Bool = true,
        isDestructive: Bool = false,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.accessibilityIdentifier = accessibilityIdentifier
        self.isEnabled = isEnabled
        self.isDestructive = isDestructive
        self.action = action
    }

    func makeNSView(context: Context) -> WizardActionButton {
        let button = WizardActionButton(title: title)
        button.accessibilityID = accessibilityIdentifier
        button.identifier = NSUserInterfaceItemIdentifier(accessibilityIdentifier)
        button.handler = action
        button.isEnabled = isEnabled
        button.isDestructive = isDestructive
        return button
    }

    func updateNSView(_ button: WizardActionButton, context: Context) {
        button.title = title
        button.setAccessibilityLabel(title)
        button.accessibilityID = accessibilityIdentifier
        button.identifier = NSUserInterfaceItemIdentifier(accessibilityIdentifier)
        button.handler = action
        button.isEnabled = isEnabled
        button.isDestructive = isDestructive
    }
}

struct WizardIconAction: NSViewRepresentable {
    let symbolName: String
    let help: String
    let accessibilityIdentifier: String
    let action: () -> Void

    func makeNSView(context: Context) -> WizardIconButton {
        let button = WizardIconButton(symbolName: symbolName)
        button.accessibilityID = accessibilityIdentifier
        button.identifier = NSUserInterfaceItemIdentifier(accessibilityIdentifier)
        button.toolTip = help
        button.handler = action
        return button
    }

    func updateNSView(_ button: WizardIconButton, context: Context) {
        button.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: help)
        button.accessibilityID = accessibilityIdentifier
        button.identifier = NSUserInterfaceItemIdentifier(accessibilityIdentifier)
        button.toolTip = help
        button.handler = action
    }
}

final class WizardActionButton: NSButton {
    var handler: (() -> Void)?
    var accessibilityID = ""

    var isDestructive = false {
        didSet {
            contentTintColor = isDestructive ? .systemRed : nil
        }
    }

    init(title: String) {
        super.init(frame: .zero)
        self.title = title
        bezelStyle = .rounded
        setButtonType(.momentaryPushIn)
        target = self
        action = #selector(invoke)
        setAccessibilityLabel(title)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func accessibilityIdentifier() -> String {
        accessibilityID
    }

    @objc private func invoke() {
        handler?()
    }
}

final class WizardIconButton: NSButton {
    var handler: (() -> Void)?
    var accessibilityID = ""

    init(symbolName: String) {
        super.init(frame: .zero)
        image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)
        imagePosition = .imageOnly
        bezelStyle = .rounded
        setButtonType(.momentaryPushIn)
        target = self
        action = #selector(invoke)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func accessibilityIdentifier() -> String {
        accessibilityID
    }

    @objc private func invoke() {
        handler?()
    }
}
