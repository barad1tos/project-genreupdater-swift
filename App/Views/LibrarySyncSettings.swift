// LibrarySyncSettings.swift -- library sync controls for API & Cache settings.

import Core
import Services
import SharedUI
import SwiftUI

extension APICacheTab {
    var librarySyncSection: some View {
        Section("Library Sync") {
            HStack(spacing: Spacing.sm) {
                Button {
                    submitManualLibraryCheck()
                } label: {
                    Label(
                        isSyncingLibrary ? "Syncing" : "Sync Now",
                        systemImage: "arrow.triangle.2.circlepath"
                    )
                }
                .disabled(isSyncingLibrary || !dependencies.isManualRunAvailable)

                if !librarySyncStatus.isEmpty {
                    Text(librarySyncStatus)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            FeatureGatedView(feature: .autoSync) {
                // The persisted strategy (ADR 0003) replaces the volatile
                // Start/Stop toggle: the command path persists the choice
                // and the runtime re-arms its trigger sources on apply.
                Picker("Automation", selection: configBinding(dependencies, \.runtime.automationStrategy)) {
                    ForEach(AutomationStrategy.allCases) { strategy in
                        Text(strategy.displayName).tag(strategy)
                    }
                }

                Stepper(value: configBinding(dependencies, \.runtime.incrementalIntervalMinutes), in: 1 ... 1440) {
                    LabeledContent(
                        "Check interval",
                        value: "\(dependencies.config.runtime.incrementalIntervalMinutes)m"
                    )
                }

                BackgroundWatcherRow()
            }
        }
    }

    /// Explicit opt-in (App Review 2.4.5(iii)): the toggle drives
    /// SMAppService registration and never flips itself. requiresApproval
    /// (revoked consent) deep-links to the Login Items pane.
    struct BackgroundWatcherRow: View {
        @Environment(AppDependencies.self) private var dependencies
        @State private var isEnabled = false
        @State private var needsApproval = false
        @State private var failureMessage: String?

        var body: some View {
            VStack(alignment: .leading, spacing: Spacing.xs) {
                Toggle("Watch library while the app is closed", isOn: toggleBinding)
                if needsApproval {
                    Button("Approve in Login Items…") {
                        dependencies.agentRegistrar?.openApprovalSettings()
                    }
                    .buttonStyle(.link)
                }
                if let failureMessage {
                    Text(failureMessage)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
            .onAppear(perform: refreshFromRegistrar)
        }

        private var toggleBinding: Binding<Bool> {
            Binding(
                get: { isEnabled },
                set: { newValue in
                    Task {
                        failureMessage = await dependencies.setBackgroundWatcherEnabled(newValue)
                        refreshFromRegistrar()
                    }
                }
            )
        }

        private func refreshFromRegistrar() {
            isEnabled = dependencies.agentRegistrar?.isRegistered == true
            needsApproval = dependencies.agentRegistrar?.needsApproval == true
        }
    }

    func submitManualLibraryCheck() {
        guard !isSyncingLibrary else { return }
        isSyncingLibrary = true
        librarySyncStatus = "Syncing library..."

        Task {
            do {
                let result = try await dependencies.submitManualRun()
                await MainActor.run {
                    librarySyncStatus = librarySyncMessage(for: result)
                    isSyncingLibrary = false
                }
            } catch {
                await MainActor.run {
                    librarySyncStatus = "Sync failed: \(error.localizedDescription)"
                    isSyncingLibrary = false
                }
            }
        }
    }

    private func librarySyncMessage(for result: SyncResult) -> String {
        if !result.hasChanges {
            return "Library is current"
        }

        return [
            "\(result.newTracks.count) new",
            "\(result.modifiedTracks.count) modified",
            "\(result.identityChangedTracks.count) identity changed",
            "\(result.refreshedTracks.count) refreshed",
            "\(result.removedTrackIDs.count) removed"
        ].joined(separator: ", ")
    }

    private func librarySyncMessage(for result: RunSubmissionResult) -> String {
        switch result {
        case .alreadyCovered:
            return "Run already active"
        case .queued:
            return "Run queued"
        case let .completed(snapshot),
             let .completedNoOp(snapshot):
            guard let syncResult = snapshot.syncResult else { return "Library is current" }
            return librarySyncMessage(for: syncResult)
        case let .failed(snapshot):
            return "Sync failed: \(snapshot.failureMessage ?? "Unknown error")"
        case .recoverable, .recoveryRequired:
            return "Recovery required"
        case .cancelled:
            return "Sync cancelled"
        }
    }
}
