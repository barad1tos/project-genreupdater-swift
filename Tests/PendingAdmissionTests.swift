import Core
import Foundation
import Services
import Testing
@testable import Genre_Updater

@Suite("Pending verification admission")
@MainActor
struct PendingAdmissionTests {
    @Test("free-tier admission counts the due album, not the whole library")
    func freeTierAdmissionCountsOnlyTheDueAlbum() async throws {
        let pendingVerification = WorkflowPendingVerificationService(
            entries: [randomAccessMemoriesPendingEntry()],
            dueEntries: [randomAccessMemoriesPendingEntry()]
        )
        // One due album sitting in a library well past the free limit. The
        // write iterates due entries only, so admitting on the library would
        // reject a user who has not spent a single free write.
        //
        // The filler has to be ENRICHED, not just passed in: the track context
        // is built from albumContextTracksByTrackID, so unknown tracks fall
        // into missingTracks and never reach the count. A library the app has
        // actually scanned is enriched, which is why this reproduces in
        // production and not with a bare track list.
        let filler = (0 ..< FeatureGate.freeTrackLimit + 100).map { index in
            Track(
                id: "filler-\(index)",
                name: "Filler \(index)",
                artist: "Filler Artist",
                album: "Filler Album"
            )
        }
        let fixture = makeRandomAccessWorkflowFixture(
            pendingVerificationService: pendingVerification
        ) { options in
            options.tier = .free
            options.additionalEnrichedTracks = filler
        }
        let viewModel = fixture.viewModel
        viewModel.mode = .pendingVerification

        viewModel.startPendingVerification(tracks: randomAccessMemoriesMusicKitTracks() + filler)

        try await waitForWorkflowToLeaveScanning(viewModel)

        let writes = await fixture.scriptClient.updatedProperties()
        #expect(writes.map(\.trackID) == ["as-ram-1", "as-ram-2"])
        #expect(viewModel.failedTracks.isEmpty)
    }
}
