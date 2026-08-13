import Core
import Foundation
import Services
import Testing
@testable import Genre_Updater

@Suite("Workflow year stage scope")
@MainActor
struct YearStageScopeTests {
    @Test("empty incremental admission skips the year stage")
    func emptyAdmissionSkipsYearStage() async throws {
        let fixture = makeWorkflowFixture(
            resolveIncrementalTracks: { _, _ in [] }
        )
        let viewModel = fixture.viewModel
        viewModel.mode = .fullLibrary
        viewModel.previewOnly = true
        viewModel.updateGenre = false
        viewModel.updateYear = true

        viewModel.start(tracks: yearSweepTracks())
        try await waitForWorkflowToLeaveScanning(viewModel)

        #expect(viewModel.proposedChanges.isEmpty)
        #expect(viewModel.scopeTrackCount == 0)
        #expect(viewModel.processedCount == 0)
        #expect(await fixture.scriptClient.updatedProperties().isEmpty)
    }

    @Test("incremental preview evaluates old album years without widening other stages")
    func previewIncludesOldAlbumYear() async throws {
        let tracks = yearSweepTracks()
        let fixture = makeWorkflowFixture(
            resolveIncrementalTracks: { tracks, _ in
                tracks.filter { $0.id == "new-trigger" }
            }
        )
        let viewModel = fixture.viewModel
        viewModel.mode = .fullLibrary
        viewModel.previewOnly = true
        viewModel.updateGenre = true
        viewModel.updateYear = true
        viewModel.cleanTrackNames = true
        viewModel.cleanAlbumNames = true

        viewModel.start(tracks: tracks)
        try await waitForWorkflowToLeaveScanning(viewModel)

        #expect(viewModel.proposedChanges.map(\.changeType) == [.yearUpdate])
        #expect(viewModel.proposedChanges.first?.track.id == "old-missing-year")
        #expect(viewModel.proposedChanges.first?.newValue == "2004")
        #expect(viewModel.scopeTrackCount == 5)
        #expect(viewModel.processedCount == 5)
        #expect(await fixture.scriptClient.updatedProperties().isEmpty)
    }

    @Test("incremental write repairs an old album year opened by an unrelated new track")
    func writeRepairsOldAlbumYear() async throws {
        let fixture = makeWorkflowFixture(
            resolveIncrementalTracks: { tracks, _ in
                tracks.filter { $0.id == "new-trigger" }
            }
        )
        let viewModel = fixture.viewModel
        viewModel.mode = .fullLibrary
        viewModel.previewOnly = false
        viewModel.updateGenre = true
        viewModel.updateYear = true
        viewModel.cleanTrackNames = true
        viewModel.cleanAlbumNames = true

        viewModel.start(tracks: yearSweepTracks())
        try await waitForWorkflowToLeaveScanning(viewModel)

        let writes = await fixture.scriptClient.updatedProperties()
        #expect(writes.count == 1)
        #expect(writes.first?.trackID == "old-missing-year")
        #expect(writes.first?.property == "year")
        #expect(writes.first?.value == "2004")
        #expect(viewModel.result?.updatedTrackCount == 1)
        #expect(viewModel.processedCount == 5)
    }

    private func yearSweepTracks() -> [Track] {
        [
            Track(
                id: "new-trigger",
                name: "The Mob Goes Wild",
                artist: "Clutch",
                album: "Robot Hive / Exodus",
                genre: "Stoner Rock",
                year: 2005
            ),
            Track(
                id: "old-missing-year",
                name: "Profits of Doom (Remastered 2020)",
                artist: "Clutch",
                album: "Blast Tyrant",
                genre: "Stoner Rock",
                year: nil
            ),
            Track(
                id: "old-year-1",
                name: "Mercury",
                artist: "Clutch",
                album: "Blast Tyrant",
                genre: "Stoner Rock",
                year: 2004
            ),
            Track(
                id: "old-year-2",
                name: "Cypress Grove",
                artist: "Clutch",
                album: "Blast Tyrant",
                genre: "Stoner Rock",
                year: 2004
            ),
            Track(
                id: "old-year-3",
                name: "Promoter (Of Earthbound Causes)",
                artist: "Clutch",
                album: "Blast Tyrant",
                genre: "Stoner Rock",
                year: 2004
            ),
        ]
    }
}
