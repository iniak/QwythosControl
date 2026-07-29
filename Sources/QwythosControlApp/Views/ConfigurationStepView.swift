import AppKit
import SwiftUI

struct ConfigurationStepView: View {
    @ObservedObject var model: DeploymentWizardModel

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            GroupBox("Storage") {
                HStack {
                    Text(model.selectedRoot.path)
                        .lineLimit(2)
                        .textSelection(.enabled)
                    Spacer(minLength: 8)
                    Button {
                        chooseStorage()
                    } label: {
                        Image(systemName: "folder")
                    }
                    .help("Choose installation folder")
                    .accessibilityIdentifier("wizard.chooseStorage")
                }
                .padding(.top, 4)
            }

            if model.requiresRemovableVolumeAcknowledgement {
                Toggle(
                    "I understand this removable volume must stay connected while Qwythos runs.",
                    isOn: Binding(
                        get: { model.hasAcknowledgedRemovableVolume },
                        set: { enabled in
                            if enabled { model.acknowledgeRemovableVolume() }
                        }
                    )
                )
                .accessibilityIdentifier("wizard.removableAcknowledgement")
            }

            GroupBox("Context") {
                Picker("Context size", selection: $model.contextSize) {
                    Text("4K").tag(4_096)
                    Text("8K").tag(8_192)
                    Text("16K").tag(16_384)
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("wizard.contextSize")
                Text("Automatic profile: \(model.automaticContextSize / 1_024)K")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            GroupBox("Network access") {
                Toggle("Share on local network", isOn: Binding(
                    get: { model.pendingAccessMode == .shared },
                    set: { model.pendingAccessMode = $0 ? .shared : .local }
                ))
                .accessibilityIdentifier("wizard.networkAccess")

                if model.showsLANWarning {
                    Label(
                        "LAN sharing uses a generated key. Do not expose this service on public Wi-Fi.",
                        systemImage: "exclamationmark.shield.fill"
                    )
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .padding(.top, 4)
                }
            }

            Spacer(minLength: 0)

            HStack {
                Button("Back") { model.goBack() }
                    .accessibilityIdentifier("wizard.back")
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
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = model.selectedRoot
        panel.begin { response in
            guard response == .OK, let root = panel.url else { return }
            model.selectRoot(root)
        }
    }
}
