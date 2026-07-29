import AppKit
import SwiftUI

@MainActor
final class DeploymentWizardWindowController: NSWindowController {
    let model: DeploymentWizardModel

    init(model: DeploymentWizardModel) {
        self.model = model
        let controller = NSHostingController(
            rootView: DeploymentWizardView(model: model)
        )
        let window = NSWindow(
            contentViewController: controller
        )
        window.setContentSize(NSSize(width: 640, height: 560))
        window.minSize = NSSize(width: 640, height: 560)
        window.maxSize = NSSize(width: 640, height: 560)
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.title = "Qwythos Deployment"
        window.titleVisibility = .visible
        window.toolbar = nil
        window.isReleasedWhenClosed = false
        super.init(window: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        window?.makeKeyAndOrderFront(sender)
        NSApp.activate(ignoringOtherApps: true)
        Task { [model] in
            await model.start()
        }
    }
}
