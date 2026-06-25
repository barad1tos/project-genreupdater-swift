import Foundation
import SharedUI
import SwiftUI

struct UpdateRunOperationalDetails: View {
    let report: UpdateRunReport

    private var hasDetails: Bool {
        report.databaseVerification != nil || !(report.pendingVerification?.problematicDetails.isEmpty ?? true)
    }

    var body: some View {
        if hasDetails {
            DisclosureGroup {
                VStack(alignment: .leading, spacing: Spacing.sm) {
                    databaseVerificationSection
                    pendingVerificationSection
                }
                .padding(.top, Spacing.xs)
            } label: {
                Label("Run details", systemImage: "wrench.and.screwdriver")
                    .font(AppFont.caption.weight(.semibold))
                    .foregroundStyle(Ayu.fgSecondary)
            }
            .padding(.horizontal, Spacing.sm)
            .padding(.vertical, Spacing.xs)
            .background(Ayu.bgSecondary.opacity(0.45), in: .rect(cornerRadius: Radius.sm))
        }
    }

    @ViewBuilder private var databaseVerificationSection: some View {
        if let databaseVerification = report.databaseVerification {
            VStack(alignment: .leading, spacing: Spacing.xxs) {
                Text("Database Verification")
                    .font(AppFont.caption.weight(.semibold))
                    .foregroundStyle(Ayu.fgPrimary)

                if let error = databaseVerification.error {
                    detailRow("Skipped", error)
                } else {
                    detailRow("Verified", "\(databaseVerification.verifiedTrackCount.formatted()) tracks")
                    detailRow("Removed", "\(databaseVerification.removedCount.formatted()) stale tracks")
                    if databaseVerification.skippedDueToRecentVerification {
                        detailRow("Reason", "Skipped after a recent verification")
                    }
                    if !databaseVerification.removedTrackIDs.isEmpty {
                        detailRow("Track IDs", databaseVerification.removedTrackIDs.joined(separator: ", "))
                    }
                }
            }
        }
    }

    @ViewBuilder private var pendingVerificationSection: some View {
        if let pendingVerification = report.pendingVerification,
           !pendingVerification.problematicDetails.isEmpty {
            VStack(alignment: .leading, spacing: Spacing.xxs) {
                Text("Problematic Pending Albums")
                    .font(AppFont.caption.weight(.semibold))
                    .foregroundStyle(Ayu.fgPrimary)

                ForEach(pendingVerification.problematicDetails) { detail in
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(detail.artist) - \(detail.album)")
                            .font(AppFont.caption.weight(.semibold))
                            .foregroundStyle(Ayu.fgPrimary)
                        Text(
                            "\(detail.reason), \(detail.attemptCount.formatted()) attempts, "
                                + "last checked \(detail.lastAttempt.operationalDetailDate)"
                        )
                        .font(.caption2)
                        .foregroundStyle(Ayu.fgSecondary)
                        Text("Next verification \(detail.nextVerification.operationalDetailDate); \(detail.status)")
                            .font(.caption2)
                            .foregroundStyle(Ayu.fgMuted)
                        if let lastFailure = detail.lastFailure {
                            Text("Last failure: \(lastFailure)")
                                .font(.caption2)
                                .foregroundStyle(Ayu.warning)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
    }

    private func detailRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.sm) {
            Text(label)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(Ayu.fgSecondary)
                .frame(width: 72, alignment: .leading)
            Text(value)
                .font(.caption2)
                .foregroundStyle(Ayu.fgMuted)
                .textSelection(.enabled)
        }
    }
}

extension Date {
    fileprivate var operationalDetailDate: String {
        formatted(date: .abbreviated, time: .shortened)
    }
}
