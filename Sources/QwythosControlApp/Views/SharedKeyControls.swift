import SwiftUI

struct SharedKeyControls: View {
    @ObservedObject var model: DeploymentWizardModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text("API key")
                    .foregroundStyle(.secondary)
                    .frame(width: 64, alignment: .leading)
                Text(model.revealedAPIKey ?? "Hidden")
                    .font(.system(.body, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                    .privacySensitive()
                Spacer(minLength: 8)
                Button {
                    model.toggleAPIKeyReveal()
                } label: {
                    Image(
                        systemName: model.revealedAPIKey == nil
                            ? "eye"
                            : "eye.slash"
                    )
                }
                .help(model.revealedAPIKey == nil ? "Reveal API key" : "Hide API key")
                .disabled(!model.canReadAPIKey)
                .accessibilityIdentifier("wizard.revealKey")
                Button {
                    model.copyAPIKey()
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .help("Copy API key")
                .disabled(!model.canReadAPIKey)
                .accessibilityIdentifier("wizard.copyKey")
                Button {
                    Task { await model.regenerateAPIKey() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("Regenerate API key")
                .disabled(!model.canRegenerateAPIKey)
                .accessibilityIdentifier("wizard.regenerateKey")
            }

            if let message = model.apiKeyActionMessage {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
    }
}
