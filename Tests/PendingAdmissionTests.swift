import Core
import Foundation
import Services
import Testing
@testable import Genre_Updater

@Suite("Pending verification admission")
@MainActor
struct PendingAdmissionTests {
    @Test("reviewed apply revalidates the admitted subset")
    func reviewedApplyRevalidatesAdmittedSubset() async {
        let fixture = makeWorkflowFixture()
        let viewModel = fixture.viewModel
        viewModel.phase = .review
        viewModel.previewOnly = false
        viewModel.proposedChanges = [makeProposedChange(id: "accepted", isAccepted: true)]

        viewModel.applyAccepted()
        await viewModel.processingTask?.value

        let admitted = await fixture.admissionProbe.admitted.first
        let validated = await fixture.admissionProbe.validated.first
        #expect(admitted?.match == .subset)
        #expect(validated?.match == .subset)
        #expect(validated?.admission == admitted?.admission)
    }

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
        #expect(writes.map(\.databaseID.rawValue) == ["as-ram-1", "as-ram-2"])
        #expect(viewModel.failedTracks.isEmpty)
    }

    @Test("pending verification rejects a replaced certificate before writing")
    func pendingRejectsReplacedCertificateBeforeWriting() async throws {
        let pendingVerification = WorkflowPendingVerificationService(
            entries: [randomAccessMemoriesPendingEntry()],
            dueEntries: [randomAccessMemoriesPendingEntry()]
        )
        let admissionProbe = WorkflowAdmissionProbe()
        await admissionProbe.rejectValidation()
        let fixture = makeRandomAccessWorkflowFixture(
            pendingVerificationService: pendingVerification
        ) { options in
            options.admissionProbe = admissionProbe
        }
        let viewModel = fixture.viewModel
        viewModel.mode = .pendingVerification

        viewModel.startPendingVerification(tracks: randomAccessMemoriesMusicKitTracks())
        try await waitForWorkflowToLeaveScanning(viewModel)

        #expect(await admissionProbe.admitted.first?.match == .subset)
        #expect(await admissionProbe.validated.first?.match == .subset)
        #expect(await fixture.scriptClient.updatedProperties().isEmpty)
    }

    @Test("release year restore rejects a replaced certificate before writing")
    func restoreRejectsReplacedCertificateBeforeWriting() async {
        let admissionProbe = WorkflowAdmissionProbe()
        await admissionProbe.rejectValidation()
        let fixture = makeWorkflowFixture(configure: { options in
            options.admissionProbe = admissionProbe
        })
        let viewModel = fixture.viewModel
        viewModel.mode = .releaseYearRestore
        viewModel.releaseYearRestoreThreshold = 5

        viewModel.start(tracks: [
            makeWritableTrack(
                "restore-stale",
                name: "Stale Restore",
                artist: "The Cure",
                album: "Wish",
                fields: WritableTrackFields(year: 2025, releaseYear: 1992)
            ),
        ])
        await viewModel.processingTask?.value

        #expect(await admissionProbe.admitted.first?.match == .subset)
        #expect(await admissionProbe.validated.first?.match == .subset)
        #expect(await fixture.scriptClient.updatedProperties().isEmpty)
        guard case .error = viewModel.phase else {
            Issue.record("Expected stale restore admission to fail")
            return
        }
    }
}
