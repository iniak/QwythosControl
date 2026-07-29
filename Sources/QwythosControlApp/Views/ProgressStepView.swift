import SwiftUI

struct ProgressStepView: View {
    @ObservedObject var model: DeploymentWizardModel

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(model.snapshot.statusText)
                .font(.title3)

            if model.usesDeterminateProgress,
               let progress = model.progressFraction {
                ProgressView(value: progress)
                    .accessibilityIdentifier("wizard.downloadProgress")
                HStack {
                    Text(bytes(model.snapshot.completedBytes))
                    Spacer()
                    Text(bytes(model.snapshot.totalBytes))
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            } else if model.isBusy {
                ProgressView()
                    .controlSize(.regular)
                    .accessibilityIdentifier("wizard.activityProgress")
            }

            if model.snapshot.failure != nil {
                Label(model.failureMessage, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
            }

            Spacer(minLength: 0)

            HStack {
                if let title = model.progressPrimaryActionTitle {
                    WizardPrimaryAction(
                        title,
                        accessibilityIdentifier: model.canResume
                            ? "wizard.resume"
                            : "wizard.retry"
                    ) {
                        Task { await model.performPrimaryProgressAction() }
                    }
                    .frame(width: title == "Resume Deployment" ? 156 : 92, height: 30)
                }

                if model.canViewLogs {
                    Button {
                        model.revealLogs()
                    } label: {
                        Image(systemName: "doc.text.magnifyingglass")
                    }
                    .help("Reveal service logs")
                    .accessibilityIdentifier("wizard.revealLogs")
                }

                Spacer()

                if model.canPause {
                    WizardPrimaryAction(
                        "Pause Download",
                        accessibilityIdentifier: "wizard.pause"
                    ) {
                        Task { await model.pause() }
                    }
                    .frame(width: 134, height: 30)
                }

                if model.canCancel {
                    WizardPrimaryAction(
                        "Cancel Deployment",
                        accessibilityIdentifier: "wizard.cancel",
                        isDestructive: true
                    ) {
                        Task { await model.cancel() }
                    }
                    .frame(width: 150, height: 30)
                }
            }
        }
        .padding(24)
    }

    private func bytes(_ value: Int64?) -> String {
        guard let value else { return "" }
        return ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
    }
}
