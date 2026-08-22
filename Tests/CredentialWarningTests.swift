import Core
import Foundation
import Services
import Testing
@testable import Genre_Updater

@Suite("Update workflow credential warnings")
@MainActor
struct CredentialWarningTests {
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
    func previewOnlyReviewCanBeSwitchedToLiveApply() async {
        let metered = MeteredTracksBox()
        let fixture = makeWorkflowFixture(configure: { options in
            options.tier = .free
            options.recordTrackUsage = { metered.count += $0 }
        })
        let viewModel = fixture.viewModel
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
        #expect(await fixture.scriptClient.updatedProperties().isEmpty)
        #expect(metered.count == .zero)
        guard case .review = viewModel.phase else {
            Issue.record("workflow should remain in review phase")
            return
        }
    }
}
