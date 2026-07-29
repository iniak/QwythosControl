import AppKit
import SwiftUI
import XCTest
@testable import QwythosControlApp

@MainActor
final class DeploymentWizardLayoutTests: XCTestCase {
    func testWizardStepsRenderAtFixedSizeWithContainedPrimaryAction() throws {
        _ = NSApplication.shared
        let steps: [(DeploymentWizardModel.Step, String, Bool)] = [
            (.deviceCheck, "wizard.continue", false),
            (.configuration, "wizard.continue", false),
            (.review, "wizard.deploy", false),
            (.progress, "wizard.retry", true),
            (.completion, "wizard.manage", false),
            (.management, "wizard.uninstall", false),
        ]

        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            for (step, identifier, failure) in steps {
                let model = DeploymentWizardModel.preview(step: step, failure: failure)
                if failure {
                    XCTAssertTrue(model.usesDeterminateProgress)
                }
                let host = NSHostingController(
                    rootView: DeploymentWizardView(model: model)
                )
                let window = NSWindow(contentViewController: host)
                host.loadView()
                host.view.frame = NSRect(x: 0, y: 0, width: 640, height: 560)
                window.setContentSize(host.view.frame.size)
                host.view.appearance = NSAppearance(named: appearance)
                window.makeKeyAndOrderFront(nil)
                RunLoop.current.run(until: Date().addingTimeInterval(0.05))
                host.view.layoutSubtreeIfNeeded()

                let image = try render(host.view)
                XCTAssertEqual(image.pixelsWide, 640)
                XCTAssertEqual(image.pixelsHigh, 560)
                add(XCTAttachment(
                    data: try pngData(for: image),
                    uniformTypeIdentifier: "public.png"
                ))

                let button = try XCTUnwrap(
                    findButton(withAccessibilityIdentifier: identifier, in: host.view)
                )
                let buttonFrame = button.convert(button.bounds, to: host.view)
                XCTAssertTrue(host.view.bounds.contains(buttonFrame))
                window.close()
            }
        }
    }

    func testProgressFailureRendersRecoveryControls() throws {
        _ = NSApplication.shared
        let model = DeploymentWizardModel.preview(step: .progress, failure: true)
        let host = NSHostingController(rootView: DeploymentWizardView(model: model))
        host.loadView()
        host.view.frame = NSRect(x: 0, y: 0, width: 640, height: 560)
        host.view.layoutSubtreeIfNeeded()

        XCTAssertNotNil(
            findButton(withAccessibilityIdentifier: "wizard.retry", in: host.view)
        )
        XCTAssertTrue(model.usesDeterminateProgress)
    }

    func testDeviceCheckOffersStorageSelectionBeforePassingPreflight() throws {
        _ = NSApplication.shared
        let model = DeploymentWizardModel.preview(step: .deviceCheck)
        let host = NSHostingController(rootView: DeploymentWizardView(model: model))
        host.loadView()
        host.view.frame = NSRect(x: 0, y: 0, width: 640, height: 560)
        host.view.layoutSubtreeIfNeeded()

        XCTAssertNotNil(
            findButton(
                withAccessibilityIdentifier: "wizard.chooseStorage",
                in: host.view
            )
        )
    }

    func testNormalAndFailureProgressRenderControlsInBothAppearances() throws {
        _ = NSApplication.shared
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            let activeModel = DeploymentWizardModel.preview(
                step: .progress,
                activeDeployment: true
            )
            let activeHost = makeHost(activeModel, appearance: appearance)
            XCTAssertTrue(activeModel.usesDeterminateProgress)
            let pauseButton = try XCTUnwrap(
                findButton(withAccessibilityIdentifier: "wizard.pause", in: activeHost.view)
            )
            let cancelButton = try XCTUnwrap(
                findButton(withAccessibilityIdentifier: "wizard.cancel", in: activeHost.view)
            )
            XCTAssertEqual(pauseButton.title, "Pause Download")
            XCTAssertEqual(cancelButton.title, "Cancel Deployment")
            XCTAssertTrue(
                activeHost.view.bounds.contains(
                    pauseButton.convert(pauseButton.bounds, to: activeHost.view)
                )
            )
            XCTAssertTrue(
                activeHost.view.bounds.contains(
                    cancelButton.convert(cancelButton.bounds, to: activeHost.view)
                )
            )
            let activeImage = try render(activeHost.view)
            let activeAttachment = XCTAttachment(
                data: try pngData(for: activeImage),
                uniformTypeIdentifier: "public.png"
            )
            activeAttachment.name = "Active progress \(appearance.rawValue)"
            add(activeAttachment)

            let failureModel = DeploymentWizardModel.preview(
                step: .progress,
                failure: true
            )
            let failureHost = makeHost(failureModel, appearance: appearance)
            XCTAssertTrue(failureModel.usesDeterminateProgress)
            let retryButton = try XCTUnwrap(
                findButton(withAccessibilityIdentifier: "wizard.retry", in: failureHost.view)
            )
            XCTAssertTrue(
                failureHost.view.bounds.contains(
                    retryButton.convert(retryButton.bounds, to: failureHost.view)
                )
            )
            _ = try render(failureHost.view)
        }
    }

    func testLegacyReviewAndFailureRenderWithoutClippingInBothAppearances() throws {
        _ = NSApplication.shared
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            let legacyModel = DeploymentWizardModel.preview(
                step: .review,
                migration: true
            )
            let legacyHost = makeHost(legacyModel, appearance: appearance)
            let legacyButton = try XCTUnwrap(
                findButton(withAccessibilityIdentifier: "wizard.deploy", in: legacyHost.view)
            )
            XCTAssertEqual(legacyButton.title, "Migrate Existing Installation")
            XCTAssertTrue(
                legacyHost.view.bounds.contains(
                    legacyButton.convert(legacyButton.bounds, to: legacyHost.view)
                )
            )
            _ = try render(legacyHost.view)

            let failureModel = DeploymentWizardModel.preview(step: .progress, failure: true)
            let failureHost = makeHost(failureModel, appearance: appearance)
            let retryButton = try XCTUnwrap(
                findButton(withAccessibilityIdentifier: "wizard.retry", in: failureHost.view)
            )
            XCTAssertEqual(retryButton.title, "Retry")
            XCTAssertTrue(
                failureHost.view.bounds.contains(
                    retryButton.convert(retryButton.bounds, to: failureHost.view)
                )
            )
            _ = try render(failureHost.view)
        }
    }

    private func makeHost(
        _ model: DeploymentWizardModel,
        appearance: NSAppearance.Name
    ) -> NSHostingController<DeploymentWizardView> {
        let host = NSHostingController(rootView: DeploymentWizardView(model: model))
        host.loadView()
        host.view.frame = NSRect(x: 0, y: 0, width: 640, height: 560)
        host.view.appearance = NSAppearance(named: appearance)
        host.view.layoutSubtreeIfNeeded()
        return host
    }

    private func render(_ view: NSView) throws -> NSBitmapImageRep {
        let bounds = view.bounds
        let image = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: bounds))
        view.cacheDisplay(in: bounds, to: image)
        return image
    }

    private func pngData(for image: NSBitmapImageRep) throws -> Data {
        try XCTUnwrap(image.representation(using: .png, properties: [:]))
    }

    private func findButton(
        withAccessibilityIdentifier identifier: String,
        in view: NSView
    ) -> NSButton? {
        if let button = view as? NSButton,
           button.accessibilityIdentifier() == identifier {
            return button
        }
        for subview in view.subviews {
            if let button = findButton(
                withAccessibilityIdentifier: identifier,
                in: subview
            ) {
                return button
            }
        }
        return nil
    }

    private func buttons(in view: NSView) -> [NSButton] {
        let current = (view as? NSButton).map { [$0] } ?? []
        return current + view.subviews.flatMap(buttons(in:))
    }
}
