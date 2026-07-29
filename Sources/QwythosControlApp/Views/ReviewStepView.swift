import SwiftUI

struct ReviewStepView: View {
    @ObservedObject var model: DeploymentWizardModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 10) {
                row("Runtime", "llama.cpp \(model.bundledRuntimeVersion)")
                row("Model", "Qwythos 9B Q4_K_M")
                row("Download", "About 5.8 GB model plus runtime")
                row("Location", model.selectedRoot.path)
                row("Context", "\(model.contextSize / 1_024)K")
                row(
                    "Access",
                    model.pendingAccessMode == .shared
                        ? "Local network on port 18080"
                        : "This Mac only on port 18080"
                )
            }

            if model.showsLANWarning {
                Label(
                    "LAN sharing is protected by a generated key. Only use a trusted local network, never public Wi-Fi.",
                    systemImage: "exclamationmark.triangle.fill"
                )
                .foregroundStyle(.orange)
                .padding(.top, 4)
            }

            Spacer(minLength: 0)

            HStack {
                Button("Back") { model.goBack() }
                    .accessibilityIdentifier("wizard.back")
                Spacer()
                WizardPrimaryAction(
                    model.primaryDeploymentTitle,
                    accessibilityIdentifier: "wizard.deploy",
                    isEnabled: model.canDeploy
                ) {
                    Task {
                        if model.isMigrationCandidate {
                            await model.migrate()
                        } else {
                            await model.deploy()
                        }
                    }
                }
                .frame(
                    width: model.isMigrationCandidate ? 220 : 136,
                    height: 30
                )
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
                .textSelection(.enabled)
                .lineLimit(2)
        }
    }
}
