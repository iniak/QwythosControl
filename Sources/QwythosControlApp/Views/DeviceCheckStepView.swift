import AppKit
import SwiftUI

struct DeviceCheckStepView: View {
    @ObservedObject var model: DeploymentWizardModel

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Qwythos checks the selected location before downloading anything.")
                .foregroundStyle(.secondary)

            HStack(spacing: 10) {
                Image(systemName: "internaldrive")
                    .foregroundStyle(.secondary)
                Text(model.selectedRoot.path)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 8)
                WizardIconAction(
                    symbolName: "folder",
                    help: "Choose installation folder",
                    accessibilityIdentifier: "wizard.chooseStorage"
                ) {
                    chooseStorage()
                }
                .frame(width: 30, height: 30)
            }

            VStack(spacing: 8) {
                checkRow("Apple Silicon", model.preflightReport?.architectureSupported)
                checkRow("macOS 13 or newer", model.preflightReport?.operatingSystemSupported)
                checkRow("At least 16 GB unified memory", model.preflightReport?.memorySufficient)
                checkRow("At least 8 GB free storage", model.preflightReport?.storageSufficient)
                checkRow("Selected folder is writable", model.preflightReport?.rootWritable)
                checkRow("Port 18080 is available", model.preflightReport?.portAvailable)
            }

            if let report = model.preflightReport, !report.canDeploy {
                Label("Resolve the marked device checks before continuing.", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }

            if let recoveryMessage = model.installationRecoveryMessage {
                Label(recoveryMessage, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .font(.caption)
            }

            Spacer(minLength: 0)

            HStack {
                Button {
                    Task { await model.refreshPreflight() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("Run device checks again")
                .accessibilityIdentifier("wizard.refreshPreflight")

                Spacer()

                WizardPrimaryAction(
                    "Continue",
                    accessibilityIdentifier: "wizard.continue",
                    isEnabled: model.canContinue
                ) {
                    model.continueToNextStep()
                }
                .frame(width: 112, height: 30)
            }
        }
        .padding(24)
    }

    private func chooseStorage() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = model.selectedRoot
        if panel.runModal() == .OK, let url = panel.url {
            model.selectRoot(url)
        }
    }

    private func checkRow(_ title: String, _ passed: Bool?) -> some View {
        HStack(spacing: 10) {
            Image(systemName: passed == true ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(passed == true ? .green : passed == false ? .orange : .secondary)
                .frame(width: 18)
            Text(title)
            Spacer(minLength: 0)
            Text(passed == nil ? "Checking" : passed == true ? "Ready" : "Needs attention")
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }
}
