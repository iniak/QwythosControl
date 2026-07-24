import Foundation

enum LaunchctlPrintOutcome: Equatable, Sendable {
    case absent
    case loaded
    case running
    case failedLoaded(String)
    case queryFailed(String)
}

enum LaunchctlPrintParser {
    static func parse(_ result: CommandResult) -> LaunchctlPrintOutcome {
        let output = result.output.trimmingCharacters(in: .whitespacesAndNewlines)

        guard result.exitCode == 0 else {
            if isCanonicalNotFoundResponse(output) {
                return .absent
            }

            let detail = output.isEmpty ? "No diagnostic output." : output
            return .queryFailed(
                "launchctl print failed with exit \(result.exitCode): \(detail)"
            )
        }

        guard let state = value(for: "state", in: output) else {
            return .queryFailed(
                "Could not interpret launchctl print output for the model service."
            )
        }

        let normalizedState = state.lowercased()
        if normalizedState == "running" {
            return .running
        }

        if let lastExitCode = integerValue(for: "last exit code", in: output),
           lastExitCode != 0 {
            return .failedLoaded(
                "LaunchAgent state is \(state) with last exit code \(lastExitCode). View Logs for details."
            )
        }

        let loadingStates = ["waiting", "spawn scheduled", "spawning"]
        if loadingStates.contains(normalizedState) {
            return .loaded
        }

        return .failedLoaded(
            "LaunchAgent state is \(state). View Logs for details."
        )
    }

    private static func isCanonicalNotFoundResponse(_ output: String) -> Bool {
        let normalized = output.lowercased()
        return normalized.contains("could not find service")
            && normalized.contains("in domain for user gui:")
    }

    private static func integerValue(for key: String, in output: String) -> Int32? {
        guard let rawValue = value(for: key, in: output) else {
            return nil
        }
        return Int32(rawValue)
    }

    private static func value(for key: String, in output: String) -> String? {
        let prefix = "\(key) ="

        for line in output.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix(prefix) else {
                continue
            }

            return trimmed
                .dropFirst(prefix.count)
                .trimmingCharacters(in: .whitespaces)
        }

        return nil
    }
}
