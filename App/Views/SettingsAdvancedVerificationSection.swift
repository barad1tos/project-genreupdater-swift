// SettingsAdvancedVerificationSection.swift — database and pending verification controls.

import Core
import Services
import SwiftUI

struct SettingsAdvancedVerificationSection: View {
    let dependencies: AppDependencies

    @State private var isVerifyingDatabase = false
    @State private var databaseVerificationStatus = ""

    var body: some View {
        Section("Verification") {
            Stepper(value: configBinding(dependencies, \.databaseVerification.autoVerifyDays), in: 1 ... 90) {
                LabeledContent(
                    "Database verify interval",
                    value: "\(dependencies.config.databaseVerification.autoVerifyDays)d"
                )
            }

            Stepper(value: configBinding(dependencies, \.databaseVerification.batchSize), in: 1 ... 100) {
                LabeledContent(
                    "Verification batch size",
                    value: "\(dependencies.config.databaseVerification.batchSize)"
                )
            }

            Stepper(value: configBinding(dependencies, \.pendingVerification.autoVerifyDays), in: 1 ... 90) {
                LabeledContent(
                    "Pending verify interval",
                    value: "\(dependencies.config.pendingVerification.autoVerifyDays)d"
                )
            }

            Stepper(value: configBinding(dependencies, \.reporting.minAttemptsForReport), in: 1 ... 20, step: 1) {
                LabeledContent(
                    "Problem report threshold",
                    value: "\(Int(dependencies.config.reporting.minAttemptsForReport.rounded())) attempts"
                )
            }

            HStack(spacing: 12) {
                Button {
                    verifyDatabaseNow()
                } label: {
                    Label(
                        isVerifyingDatabase ? "Verifying" : "Verify Now",
                        systemImage: "checkmark.shield"
                    )
                }
                .disabled(isVerifyingDatabase || dependencies.librarySyncService == nil)

                if !databaseVerificationStatus.isEmpty {
                    Text(databaseVerificationStatus)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func verifyDatabaseNow() {
        guard !isVerifyingDatabase else { return }
        guard let librarySyncService = dependencies.librarySyncService else {
            databaseVerificationStatus = "Library services are still loading"
            return
        }

        isVerifyingDatabase = true
        databaseVerificationStatus = "Verifying database..."
        Task {
            do {
                let result = try await librarySyncService.verifyAndCleanDatabase(force: true)
                await MainActor.run {
                    databaseVerificationStatus = databaseVerificationMessage(for: result)
                    isVerifyingDatabase = false
                }
            } catch {
                await MainActor.run {
                    databaseVerificationStatus = "Verification failed: \(error.localizedDescription)"
                    isVerifyingDatabase = false
                }
            }
        }
    }

    private func databaseVerificationMessage(for result: DatabaseVerificationResult) -> String {
        if result.skippedDueToRecentVerification {
            return "Already verified recently"
        }
        if result.removedCount == 0 {
            return "Verified \(result.verifiedTrackCount) tracks"
        }
        return "Removed \(result.removedCount) stale tracks"
    }
}
