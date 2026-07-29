import SwiftUI

struct DeploymentWizardView: View {
    @ObservedObject var model: DeploymentWizardModel

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            Group {
                switch model.step {
                case .deviceCheck:
                    DeviceCheckStepView(model: model)
                case .configuration:
                    ConfigurationStepView(model: model)
                case .review:
                    ReviewStepView(model: model)
                case .progress:
                    ProgressStepView(model: model)
                case .completion:
                    CompletionStepView(model: model)
                case .management:
                    ManagementView(model: model)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: 640, height: 560)
        .confirmationDialog(
            "Uninstall Qwythos?",
            isPresented: Binding(
                get: { model.isShowingUninstallConfirmation },
                set: { visible in
                    model.setUninstallConfirmationPresented(visible)
                }
            ),
            titleVisibility: .visible
        ) {
            Button("Uninstall", role: .destructive) {
                Task { await model.confirmUninstall() }
            }
            Button("Keep Qwythos Installed", role: .cancel) {
                model.cancelUninstall()
            }
        } message: {
            Text(
                model.deleteModelOnUninstall
                    ? "The runtime, configuration, and downloaded model will be removed."
                    : "The runtime and configuration will be removed. The downloaded model will stay on this Mac."
            )
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: headerSymbol)
                .font(.title2)
                .foregroundStyle(headerColor)
            VStack(alignment: .leading, spacing: 2) {
                Text(headerTitle)
                    .font(.headline)
                Text(headerSubtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 18)
    }

    private var headerTitle: String {
        switch model.step {
        case .deviceCheck: "Check this Mac"
        case .configuration: "Choose storage and access"
        case .review: "Review deployment"
        case .progress: "Deploying Qwythos"
        case .completion: "Qwythos is ready"
        case .management: "Manage Qwythos"
        }
    }

    private var headerSubtitle: String {
        switch model.step {
        case .deviceCheck: "Qwythos needs Apple Silicon, macOS 13, memory, storage, and port availability."
        case .configuration: "Choose where Qwythos lives and who can reach it."
        case .review: "The selected, pinned components are ready to deploy."
        case .progress: model.snapshot.statusText
        case .completion: "The local service passed its health check."
        case .management: "Repair, update, or remove the managed installation."
        }
    }

    private var headerSymbol: String {
        switch model.step {
        case .deviceCheck: "checkmark.shield"
        case .configuration: "slider.horizontal.3"
        case .review: "checklist"
        case .progress: "arrow.down.circle"
        case .completion: "checkmark.circle.fill"
        case .management: "wrench.and.screwdriver"
        }
    }

    private var headerColor: Color {
        switch model.step {
        case .completion: .green
        case .progress: .accentColor
        default: .accentColor
        }
    }
}
