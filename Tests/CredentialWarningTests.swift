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
            libraryReadiness: .incomplete(.freshObservationRequired)
        )

        #expect(view.credentialWarningMessage?.contains("Discogs") == true)
        #expect(view.credentialWarningMessage?.contains("slower") == true)
    }

    @Test(
        "Non-ready update surfaces show the typed reason",
        arguments: [
            ReadinessSample.expiredMetadata,
            ReadinessSample.freshObservation,
            ReadinessSample.storage,
        ]
    )
    func showsReadinessBlock(sample: ReadinessSample) {
        let viewModel = makeWorkflowViewModel()
        let tracks = [Track(id: "1", name: "Track", artist: "Artist", album: "Album")]
        viewModel.computeScopePreview(tracks: tracks)
        let view = UpdateConfigSection(
            viewModel: viewModel,
            tracks: tracks,
            testArtists: [],
            credentialIssue: nil,
            libraryReadiness: sample.readiness
        )

        #expect(view.readinessStatusMessage == sample.detail)
        #expect(view.startButtonTitle == sample.buttonTitle)
        #expect(view.isStartDisabled)
    }

    @Test("Ready update surface enables the configured action")
    func showsReadyAction() throws {
        let viewModel = makeWorkflowViewModel()
        let tracks = [Track(id: "1", name: "Track", artist: "Artist", album: "Album")]
        viewModel.computeScopePreview(tracks: tracks)
        let view = try UpdateConfigSection(
            viewModel: viewModel,
            tracks: tracks,
            testArtists: [],
            credentialIssue: nil,
            libraryReadiness: makeReadyEvidence()
        )

        #expect(view.readinessStatusMessage == nil)
        #expect(view.startButtonTitle == "Start Processing")
        #expect(!view.isStartDisabled)
    }

    @Test("preview-only review can enable writes without applying changes")
    func previewOnlyReviewCanEnableWrites() async {
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
