import Core
import Foundation
import Services
import Testing
@testable import Genre_Updater

@Suite("Dashboard credential warnings")
@MainActor
struct DashboardCredentialWarningTests {
    @Test("dashboard exposes credential warning message when Discogs credential issue exists")
    func dashboardExposesCredentialWarningMessage() {
        let view = DashboardView(
            tracks: [],
            metricsSnapshot: nil,
            isLoadingTracks: false,
            loadError: nil,
            lastScanDate: Date(timeIntervalSince1970: 1_800_000_000),
            isDryRun: true,
            workflowState: .empty,
            credentialIssue: .keychain(.invalidTokenData),
            onScanNow: {
                // View-only assertion does not exercise dashboard actions.
            },
            onReviewChanges: {
                // View-only assertion does not exercise dashboard actions.
            }
        )

        #expect(view.credentialWarningMessage?.contains("invalid") == true)
    }
}
