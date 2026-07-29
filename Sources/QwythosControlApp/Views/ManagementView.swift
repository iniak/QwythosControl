import SwiftUI

struct ManagementView: View {
    @ObservedObject var model: DeploymentWizardModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let record = model.installedRecord {
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
                    row("Runtime", record.runtimeVersion)
                    row("Context", "\(record.contextSize / 1_024)K")
                    row(
                        "Access",
                        record.accessMode == .shared ? "Local network" : "This Mac only"
                    )
                    row("Location", record.root.path)
                }
            } else {
                Text("Manage the current Qwythos installation.")
                    .foregroundStyle(.secondary)
            }

            GroupBox("Network access") {
                Toggle("Share on local network", isOn: Binding(
                    get: { model.pendingAccessMode == .shared },
                    set: { enabled in
                        model.pendingAccessMode = enabled ? .shared : .local
                    }
                ))

                if model.showsLANWarning {
                    Label(
                        "Changing access rewrites the service configuration and uses a generated key.",
                        systemImage: "lock.shield"
                    )
                    .font(.caption)
                    .foregroundStyle(.orange)
                }

                HStack {
                    Button("Apply Network Access") {
                        Task { await model.updateAccessMode() }
                    }
                    .disabled(!model.canApplyAccessMode)
                    .accessibilityIdentifier("wizard.applyNetworkAccess")
                }

                if model.pendingAccessMode == .shared {
                    SharedKeyControls(model: model)
                }
            }

            Toggle("Delete downloaded model when uninstalling", isOn: $model.deleteModelOnUninstall)
                .accessibilityIdentifier("wizard.deleteModel")

            Spacer(minLength: 0)

            HStack {
                Button {
                    model.revealSelectedRoot()
                } label: {
                    Image(systemName: "folder")
                }
                .help("Reveal installation folder")
                .accessibilityIdentifier("wizard.revealInstallation")

                Spacer()

                Button("Repair") {
                    Task { await model.repair() }
                }
                .disabled(!model.canRepair)
                .accessibilityIdentifier("wizard.repair")

                if let title = model.runtimeActionTitle {
                    Button(title) {
                        Task { await model.performRuntimeAction() }
                    }
                    .disabled(!model.canRunRuntimeAction)
                    .accessibilityIdentifier("wizard.runtime")
                }

                WizardPrimaryAction(
                    "Uninstall",
                    accessibilityIdentifier: "wizard.uninstall",
                    isEnabled: !model.isBusy,
                    isDestructive: true
                ) {
                    model.requestUninstall()
                }
                .frame(width: 92, height: 30)
            }
        }
        .padding(24)
    }

    @ViewBuilder
    private func row(_ title: String, _ value: String) -> some View {
        GridRow {
            Text(title)
                .foregroundStyle(.secondary)
            Text(value)
                .lineLimit(2)
                .textSelection(.enabled)
        }
    }
}
