// SettingsAPIAndCacheTab+LibrarySync.swift -- library sync controls for API & Cache settings.

import Core
import Services
import SharedUI
import SwiftUI

extension APIAndCacheTab {
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
                Stepper(value: configBinding(dependencies, \.runtime.incrementalIntervalMinutes), in: 1 ... 1440) {
                    LabeledContent(
                        "Auto-sync interval",
                        value: "\(dependencies.config.runtime.incrementalIntervalMinutes)m"
                    )
                }
                .disabled(dependencies.isAutoSyncRunning || isUpdatingAutoSync)

                Button {
                    setAutoSyncEnabled(!dependencies.isAutoSyncRunning)
                } label: {
                    Label(
                        dependencies.isAutoSyncRunning ? "Stop Auto-Sync" : "Start Auto-Sync",
                        systemImage: dependencies.isAutoSyncRunning ? "pause.circle" : "play.circle"
                    )
                }
                .disabled(isUpdatingAutoSync || dependencies.librarySyncService == nil)
            }
        }
    }

    func submitManualLibraryCheck() {
        guard !isSyncingLibrary else { return }
        isSyncingLibrary = true
        librarySyncStatus = "Syncing library..."

        Task {
            do {
                let result = try await dependencies.submitManualObservationRun()
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

    func setAutoSyncEnabled(_ isEnabled: Bool) {
        guard !isUpdatingAutoSync else { return }
        isUpdatingAutoSync = true
        librarySyncStatus = isEnabled ? "Starting auto-sync..." : "Stopping auto-sync..."

        Task {
            do {
                try await dependencies.setAutoSyncEnabled(isEnabled)
                await MainActor.run {
                    librarySyncStatus = isEnabled ? "Auto-sync started" : "Auto-sync stopped"
                    isUpdatingAutoSync = false
                }
            } catch {
                await MainActor.run {
                    librarySyncStatus = "Auto-sync failed: \(error.localizedDescription)"
                    isUpdatingAutoSync = false
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
            "\(result.removedTrackIDs.count) removed",
        ].joined(separator: ", ")
    }

    private func librarySyncMessage(for result: RunSubmissionResult) -> String {
        switch result {
        case .alreadyRunning:
            return "Run already active"
        case let .completed(snapshot),
             let .completedNoOp(snapshot):
            guard let syncResult = snapshot.syncResult else { return "Library is current" }
            return librarySyncMessage(for: syncResult)
        case let .failed(snapshot):
            return "Sync failed: \(snapshot.failureMessage ?? "Unknown error")"
        }
    }
}
