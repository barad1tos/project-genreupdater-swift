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

    @Test("update configuration exposes credential warning message when Discogs is degraded")
    func updateConfigurationExposesCredentialWarningMessage() {
        let view = UpdateConfigSection(
            viewModel: makeWorkflowViewModel(),
            tracks: [],
            testArtists: [],
            credentialIssue: .missingToken,
            isLibraryReadyForUpdates: true
        )

        #expect(view.credentialWarningMessage?.contains("Discogs") == true)
        #expect(view.credentialWarningMessage?.contains("slower") == true)
    }

    @Test("preview-only review can be switched to live apply")
    func previewOnlyReviewCanBeSwitchedToLiveApply() {
        let viewModel = makeWorkflowViewModel()
        viewModel.previewOnly = true
        viewModel.phase = .review
        viewModel.proposedChanges = [
            makeProposedChange(id: "accepted", isAccepted: true),
            makeProposedChange(id: "rejected", isAccepted: false),
        ]

        viewModel.enableWritesForReviewedChanges()

        #expect(viewModel.previewOnly == false)
        #expect(viewModel.acceptedCount == 1)
        #expect(viewModel.proposedChanges.count == 2)
        guard case .review = viewModel.phase else {
            Issue.record("workflow should remain in review phase")
            return
        }
    }
}
