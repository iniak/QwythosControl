import SwiftUI

struct CompletionStepView: View {
    @ObservedObject var model: DeploymentWizardModel

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label("The service is running and responded to its health check.", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)

            if let localEndpoint = model.localEndpoint {
                endpointRow("This Mac", endpoint: localEndpoint, identifier: "wizard.copyLocalEndpoint")
            }

            ForEach(Array(model.lanEndpoints.enumerated()), id: \.offset) { index, endpoint in
                endpointRow(
                    "Local network",
                    endpoint: endpoint,
                    identifier: "wizard.copyLANEndpoint.\(index)"
                )
            }

            if model.pendingAccessMode == .shared {
                Label(
                    "Local-network requests require the generated key.",
                    systemImage: "lock.shield"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                SharedKeyControls(model: model)
            }

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

                WizardPrimaryAction(
                    "Manage Installation",
                    accessibilityIdentifier: "wizard.manage"
                ) {
                    model.openManagement()
                }
                .frame(width: 152, height: 30)
            }
        }
        .padding(24)
    }

    private func endpointRow(
        _ title: String,
        endpoint: String,
        identifier: String
    ) -> some View {
        HStack(spacing: 10) {
            Text(title)
                .foregroundStyle(.secondary)
                .frame(width: 108, alignment: .leading)
            Text(endpoint)
                .textSelection(.enabled)
            Spacer(minLength: 8)
            Button {
                model.copy(endpoint)
            } label: {
                Image(systemName: "doc.on.doc")
            }
            .help("Copy endpoint")
            .accessibilityIdentifier(identifier)
            Button {
                model.open(endpoint)
            } label: {
                Image(systemName: "arrow.up.right.square")
            }
            .help("Open endpoint")
        }
        .padding(.vertical, 6)
    }
}
