import Core
import Foundation
import Services
import Testing
@testable import Genre_Updater

@Suite("Workflow selected update scope")
@MainActor
struct WorkflowSelectedUpdateScopeTests {
    @Test("selected scope configuration applies flags and preview counts")
    func selectedScopeConfigurationAppliesFlagsAndPreviewCounts() {
        let viewModel = makeWorkflowViewModel()
        let scopedTracks = [
            Track(id: "1", name: "One", artist: "Alpha", album: "First"),
            Track(id: "2", name: "Two", artist: "Alpha", album: "First"),
        ]

        viewModel.configureSelectedTracksScope(
            tracks: scopedTracks,
            updateGenre: true,
            updateYear: false,
            previewOnly: true
        )

        #expect(viewModel.mode == .selectedTracks)
        #expect(viewModel.updateGenre)
        #expect(!viewModel.updateYear)
        #expect(viewModel.previewOnly)
        #expect(viewModel.scopeTrackCount == 2)
        #expect(viewModel.scopeArtistCount == 1)
    }

    @Test("empty selected scope stays empty instead of becoming full library")
    func emptySelectedScopeStaysEmptyInsteadOfBecomingFullLibrary() {
        let viewModel = makeWorkflowViewModel()

        viewModel.configureSelectedTracksScope(
            tracks: [],
            updateGenre: true,
            updateYear: true,
            previewOnly: false
        )

        #expect(viewModel.mode == .selectedTracks)
        #expect(viewModel.scopeTrackCount == 0)
        #expect(viewModel.scopeArtistCount == 0)
    }

    @Test("preview only apply is ignored")
    func previewOnlyApplyIsIgnored() {
        let viewModel = makeWorkflowViewModel()
        viewModel.phase = .review
        viewModel.previewOnly = true
        viewModel.proposedChanges = [makeProposedChange(id: "1", isAccepted: true)]

        viewModel.applyAccepted()

        guard case .review = viewModel.phase else {
            #expect(Bool(false), "preview-only apply should preserve review phase")
            return
        }
        #expect(viewModel.result == nil)
    }

    @Test("reviewed apply writes only accepted proposed changes")
    func reviewedApplyWritesOnlyAcceptedProposedChanges() async throws {
        let fixture = makeWorkflowFixture()
        let viewModel = fixture.viewModel
        viewModel.phase = .review
        viewModel.previewOnly = false
        viewModel.proposedChanges = [
            makeProposedChange(id: "accepted", isAccepted: true),
            makeProposedChange(id: "rejected", isAccepted: false),
        ]

        viewModel.applyAccepted()
        await viewModel.processingTask?.value
        await Task.yield()

        guard case .done = viewModel.phase else {
            #expect(Bool(false), "reviewed apply should complete after writing accepted proposals")
            return
        }

        let writes = await fixture.scriptClient.updatedProperties()
        let write = try #require(writes.first)
        #expect(writes.count == 1)
        #expect(write.trackID == "accepted")
        #expect(write.property == "genre")
        #expect(write.value == "Rock")
        #expect(viewModel.result?.failedTrackIDs.isEmpty == true)
        #expect(viewModel.result?.entries.count == 1)
    }

    @Test("reviewed apply cancellation returns to configuration")
    func reviewedApplyCancellationReturnsToConfiguration() async {
        let fixture = makeWorkflowFixture(cancellingWriteTrackIDs: ["accepted"])
        let viewModel = fixture.viewModel
        viewModel.phase = .review
        viewModel.previewOnly = false
        viewModel.proposedChanges = [
            makeProposedChange(id: "accepted", isAccepted: true),
        ]

        viewModel.applyAccepted()
        await viewModel.processingTask?.value
        await Task.yield()

        guard case .configure = viewModel.phase else {
            #expect(Bool(false), "cancelled reviewed apply should return to configuration")
            return
        }
        #expect(viewModel.progress == nil)
        #expect(viewModel.result == nil)
        #expect(viewModel.trackStatuses.isEmpty)
        #expect(viewModel.failedTracks.isEmpty)
        #expect(viewModel.failedCount == 0)
        #expect(await fixture.scriptClient.updatedProperties().isEmpty)
    }

    @Test("full library preview only avoids batch writes")
    func fullLibraryPreviewOnlyAvoidsBatchWrites() {
        let viewModel = makeWorkflowViewModel()
        viewModel.mode = .fullLibrary
        viewModel.previewOnly = true

        #expect(!viewModel.shouldRunBatchProcessing)

        viewModel.previewOnly = false

        #expect(viewModel.shouldRunBatchProcessing)
    }

    @Test("full library preview only start uses dry run path")
    func fullLibraryPreviewOnlyStartUsesDryRunPath() async throws {
        let fixture = makeWorkflowFixture(apiService: DashboardStateAPIService(year: 2020, confidence: 90))
        let viewModel = fixture.viewModel
        viewModel.mode = .fullLibrary
        viewModel.previewOnly = true
        viewModel.updateGenre = false
        viewModel.updateYear = true

        viewModel.start(tracks: [
            Track(id: "1", name: "One", artist: "Alpha", album: "First", year: 1999),
        ])

        try await waitForWorkflowToLeaveScanning(viewModel)

        guard case .review = viewModel.phase else {
            #expect(Bool(false), "preview-only full-library start should enter review instead of writing")
            return
        }
        #expect(viewModel.dryRunReport != nil)
        #expect(await fixture.scriptClient.updatedProperties().isEmpty)
    }

    @Test("full library preview reports scope and analysis progress")
    func fullLibraryPreviewReportsScopeAndAnalysisProgress() async throws {
        let albumYearLookupHold = LiveBatchHold()
        let fixture = makeWorkflowFixture(
            apiService: DashboardStateAPIService(
                year: 2020,
                confidence: 90,
                beforeAlbumYearLookup: {
                    await albumYearLookupHold.holdOnce()
                }
            )
        )
        let viewModel = fixture.viewModel
        viewModel.mode = .fullLibrary
        viewModel.previewOnly = true
        viewModel.updateGenre = false
        viewModel.updateYear = true

        viewModel.start(tracks: [
            Track(id: "1", name: "One", artist: "Alpha", album: "First", year: 1999),
        ])

        #expect(viewModel.progress?.phase == .fetching)
        #expect(viewModel.progress?.current == 0)
        #expect(viewModel.progress?.total == 1)
        #expect(viewModel.progress?.message == "Checking library state")

        await albumYearLookupHold.waitUntilHeld()

        #expect(viewModel.progress?.phase == .analyzing)
        #expect(viewModel.progress?.current == 1)
        #expect(viewModel.progress?.total == 1)
        #expect(viewModel.progress?.message == "Analyzing: One")

        await albumYearLookupHold.release()
        try await waitForWorkflowToLeaveScanning(viewModel)

        guard case .review = viewModel.phase else {
            #expect(Bool(false), "preview-only full-library start should enter review after analysis")
            return
        }
        #expect(viewModel.progress == nil)
    }

    @Test("full library preview uses artist context for genre mismatch repair")
    func fullLibraryPreviewUsesArtistContextForGenreMismatchRepair() async throws {
        let fixture = makeWorkflowFixture()
        let viewModel = fixture.viewModel
        viewModel.mode = .fullLibrary
        viewModel.previewOnly = true
        viewModel.updateGenre = true
        viewModel.updateYear = false

        viewModel.start(tracks: [
            Track(
                id: "genre-mismatch",
                name: "Second Song",
                artist: "The Clash",
                album: "Second Album",
                genre: "Pop",
                dateAdded: Date(timeIntervalSince1970: 200)
            ),
            Track(
                id: "genre-source",
                name: "First Song",
                artist: "The Clash",
                album: "First Album",
                genre: "Punk",
                dateAdded: Date(timeIntervalSince1970: 100)
            ),
        ])

        try await waitForWorkflowToLeaveScanning(viewModel)

        let genreChange = try #require(viewModel.proposedChanges.first { $0.changeType == .genreUpdate })
        #expect(genreChange.track.id == "genre-mismatch")
        #expect(genreChange.oldValue == "Pop")
        #expect(genreChange.newValue == "Punk")
        #expect(await fixture.scriptClient.updatedProperties().isEmpty)
    }

    @Test("selected dry run passes forced year lookup to workflow options")
    func selectedDryRunPassesForcedYearLookupToWorkflowOptions() async throws {
        let fixture = makeWorkflowFixture(apiService: DashboardStateAPIService(year: 1999, confidence: 100))
        let viewModel = fixture.viewModel
        viewModel.mode = .selectedTracks
        viewModel.previewOnly = true
        viewModel.updateGenre = false
        viewModel.updateYear = true
        viewModel.forceYearLookup = true

        viewModel.start(tracks: [
            Track(
                id: "processed-year",
                name: "Borrowed Time",
                artist: "SubRosa",
                album: "No Help for the Mighty Ones",
                year: 2008,
                yearSetByMGU: 2008
            ),
        ])

        try await waitForWorkflowToLeaveScanning(viewModel)

        let change = try #require(viewModel.proposedChanges.first)
        #expect(change.changeType == .yearUpdate)
        #expect(change.oldValue == "2008")
        #expect(change.newValue == "1999")
    }

    @Test("selected dry run does not use full-library incremental scope")
    func selectedDryRunDoesNotUseFullLibraryIncrementalScope() async throws {
        let incrementalResolverCalls = AsyncCallCounter()
        let fixture = makeWorkflowFixture(
            apiService: DashboardStateAPIService(year: 2001, confidence: 100),
            resolveIncrementalTracks: { _, _ in
                await incrementalResolverCalls.record()
                return []
            }
        )
        let viewModel = fixture.viewModel
        viewModel.mode = .selectedTracks
        viewModel.previewOnly = true
        viewModel.updateGenre = false
        viewModel.updateYear = true

        viewModel.start(tracks: [
            Track(id: "selected-year", name: "Song", artist: "Artist", album: "Album", year: 1999),
        ])

        try await waitForWorkflowToLeaveScanning(viewModel)

        let change = try #require(viewModel.proposedChanges.first)
        #expect(await incrementalResolverCalls.count() == 0)
        #expect(change.track.id == "selected-year")
        #expect(change.changeType == .yearUpdate)
        #expect(change.newValue == "2001")
    }

    @Test("full library force lookup bypasses incremental scope")
    func fullLibraryForceLookupBypassesIncrementalScope() async throws {
        let incrementalResolverCalls = AsyncCallCounter()
        let fixture = makeWorkflowFixture(
            apiService: DashboardStateAPIService(year: 2001, confidence: 100),
            resolveIncrementalTracks: { _, _ in
                await incrementalResolverCalls.record()
                return []
            }
        )
        let viewModel = fixture.viewModel
        viewModel.mode = .fullLibrary
        viewModel.previewOnly = true
        viewModel.updateGenre = false
        viewModel.updateYear = true
        viewModel.forceYearLookup = true

        viewModel.start(tracks: [
            Track(id: "old-track", name: "Song", artist: "Artist", album: "Album", year: 1999),
        ])

        try await waitForWorkflowToLeaveScanning(viewModel)

        let change = try #require(viewModel.proposedChanges.first)
        #expect(await incrementalResolverCalls.count() == 0)
        #expect(change.track.id == "old-track")
        #expect(change.changeType == .yearUpdate)
        #expect(change.oldValue == "1999")
        #expect(change.newValue == "2001")
    }

    @Test("full library preview only still requires batch feature")
    func fullLibraryPreviewOnlyStillRequiresBatchFeature() async {
        let fixture = makeWorkflowFixture(
            apiService: DashboardStateAPIService(year: 2020, confidence: 90),
            tier: .free
        )
        let viewModel = fixture.viewModel
        viewModel.mode = .fullLibrary
        viewModel.previewOnly = true

        viewModel.start(tracks: [
            Track(id: "1", name: "One", artist: "Alpha", album: "First", year: 1999),
        ])

        guard case let .error(message) = viewModel.phase else {
            #expect(Bool(false), "free tier full-library preview should stop at feature gate")
            return
        }
        #expect(message.contains("batchProcessing"))
        #expect(await fixture.scriptClient.updatedProperties().isEmpty)
    }

    @Test("full library preview keeps album context after incremental narrowing")
    func fullLibraryPreviewKeepsAlbumContextAfterIncrementalNarrowing() async throws {
        let missingGenre = Track(
            id: "missing-genre",
            name: "Only for the Weak",
            artist: "In Flames",
            album: "Clayman",
            dateAdded: Date(timeIntervalSince1970: 2000)
        )
        let genreSource = Track(
            id: "genre-source",
            name: "Bullet Ride",
            artist: "In Flames",
            album: "Clayman",
            genre: "Melodic Death Metal",
            dateAdded: Date(timeIntervalSince1970: 1000)
        )
        let fixture = makeWorkflowFixture(
            resolveIncrementalTracks: { tracks, _ in
                tracks.filter { $0.id == missingGenre.id }
            }
        )
        let viewModel = fixture.viewModel
        viewModel.mode = .fullLibrary
        viewModel.previewOnly = true
        viewModel.updateGenre = true
        viewModel.updateYear = false
        viewModel.cleanTrackNames = false
        viewModel.cleanAlbumNames = false

        viewModel.start(tracks: [missingGenre, genreSource])

        try await waitForWorkflowToLeaveScanning(viewModel)

        let genreChange = try #require(viewModel.proposedChanges.first { $0.changeType == .genreUpdate })
        #expect(genreChange.track.id == missingGenre.id)
        #expect(genreChange.newValue == "Melodic Death Metal")
        #expect(viewModel.scopeTrackCount == 1)
        #expect(await fixture.scriptClient.updatedProperties().isEmpty)
    }

    @Test("full library live processing uses album context for genre updates")
    func fullLibraryLiveProcessingUsesAlbumContextForGenreUpdates() async throws {
        let fixture = makeWorkflowFixture()
        let viewModel = fixture.viewModel
        viewModel.mode = .fullLibrary
        viewModel.previewOnly = false
        viewModel.updateGenre = true
        viewModel.updateYear = false
        viewModel.cleanTrackNames = false
        viewModel.cleanAlbumNames = false
        let albumGenreSourceDate = Date(timeIntervalSince1970: 1000)
        let missingGenreDate = Date(timeIntervalSince1970: 2000)

        viewModel.start(tracks: [
            Track(
                id: "missing-genre",
                name: "Only for the Weak",
                artist: "In Flames",
                album: "Clayman",
                dateAdded: missingGenreDate
            ),
            Track(
                id: "genre-source",
                name: "Bullet Ride",
                artist: "In Flames",
                album: "Clayman",
                genre: "Melodic Death Metal",
                dateAdded: albumGenreSourceDate
            ),
        ])

        try await waitForWorkflowToLeaveScanning(viewModel)

        guard case .done = viewModel.phase else {
            #expect(Bool(false), "live full-library processing should complete")
            return
        }
        let writes = await fixture.scriptClient.updatedProperties()
        #expect(writes.contains {
            $0.trackID == "missing-genre"
                && $0.property == "genre"
                && $0.value == "Melodic Death Metal"
        })
    }

    @Test("full library live cancellation returns to configuration")
    func fullLibraryLiveCancellationReturnsToConfiguration() async throws {
        let fixture = makeWorkflowFixture(cancellingWriteTrackIDs: ["missing-genre"])
        let viewModel = fixture.viewModel
        viewModel.mode = .fullLibrary
        viewModel.previewOnly = false
        viewModel.updateGenre = true
        viewModel.updateYear = false
        viewModel.cleanTrackNames = false
        viewModel.cleanAlbumNames = false

        viewModel.start(tracks: [
            Track(
                id: "missing-genre",
                name: "Only for the Weak",
                artist: "In Flames",
                album: "Clayman",
                dateAdded: Date(timeIntervalSince1970: 2000)
            ),
            Track(
                id: "genre-source",
                name: "Bullet Ride",
                artist: "In Flames",
                album: "Clayman",
                genre: "Melodic Death Metal",
                dateAdded: Date(timeIntervalSince1970: 1000)
            ),
        ])

        try await waitForWorkflowToReturnToConfigure(viewModel)

        guard case .configure = viewModel.phase else {
            #expect(Bool(false), "cancelled live batch should return to configuration")
            return
        }
        #expect(viewModel.progress == nil)
        #expect(viewModel.result == nil)
        #expect(viewModel.trackStatuses.isEmpty)
        #expect(viewModel.failedTracks.isEmpty)
        #expect(viewModel.failedCount == 0)
        #expect(await fixture.scriptClient.updatedProperties().isEmpty)
    }

    @Test("full library live processing surfaces write failures")
    func fullLibraryLiveProcessingSurfacesWriteFailures() async throws {
        let fixture = makeWorkflowFixture(
            apiService: DashboardStateAPIService(year: 2020, confidence: 90),
            failingWriteTrackIDs: ["missing-year"]
        )
        let viewModel = fixture.viewModel
        viewModel.mode = .fullLibrary
        viewModel.previewOnly = false
        viewModel.updateGenre = false
        viewModel.updateYear = true
        viewModel.cleanTrackNames = false
        viewModel.cleanAlbumNames = false

        viewModel.start(tracks: [
            Track(id: "missing-year", name: "Track", artist: "In Flames", album: "Clayman", year: 1999),
        ])

        try await waitForWorkflowToLeaveScanning(viewModel)

        #expect(!viewModel.failedTracks.isEmpty)
        #expect(viewModel.failedTracks.first?.id == "missing-year")
        #expect(await fixture.scriptClient.updatedProperties().isEmpty)
    }

    @Test("release year restore with no candidates completes without crashing")
    func releaseYearRestoreWithNoCandidatesCompletesWithoutCrashing() async {
        let fixture = makeWorkflowFixture()
        let viewModel = fixture.viewModel
        viewModel.mode = .releaseYearRestore
        viewModel.releaseYearRestoreThreshold = 5

        viewModel.start(tracks: [
            Track(
                id: "near-match",
                name: "Near Match",
                artist: "The Cure",
                album: "Wish",
                year: 1992,
                releaseYear: 1991
            ),
        ])
        await viewModel.processingTask?.value
        await Task.yield()

        guard case .done = viewModel.phase else {
            #expect(Bool(false), "release-year restore with no candidates should complete")
            return
        }
        #expect(viewModel.totalCount == 0)
        #expect(viewModel.processedCount == 0)
        #expect(viewModel.result?.entries.isEmpty == true)
        #expect(await fixture.scriptClient.updatedProperties().isEmpty)
    }

    @Test("full library empty effective scope is not runnable")
    func fullLibraryEmptyEffectiveScopeIsNotRunnable() {
        let viewModel = makeWorkflowViewModel()
        viewModel.mode = .fullLibrary
        viewModel.previewOnly = false
        viewModel.configureFullLibraryScope(tracks: [])

        #expect(!viewModel.hasRunnableScope)

        viewModel.start(tracks: [])

        guard case let .error(message) = viewModel.phase else {
            #expect(Bool(false), "empty full-library scope should surface an error instead of starting")
            return
        }
        #expect(message.contains("No tracks"))
    }

    @Test("pause is ignored outside full-library scanning")
    func pauseIsIgnoredOutsideFullLibraryScanning() async {
        let viewModel = makeWorkflowViewModel()
        viewModel.mode = .fullLibrary
        viewModel.phase = .applying

        await viewModel.pause()

        guard case .applying = viewModel.phase else {
            #expect(Bool(false), "pause should not move apply-accepted work into paused state")
            return
        }
    }

    @Test("full library scope resets finished workflow state")
    func fullLibraryScopeResetsFinishedWorkflowState() {
        let viewModel = makeWorkflowViewModel()
        viewModel.mode = .selectedTracks
        viewModel.phase = .done
        viewModel.proposedChanges = [makeProposedChange(id: "1", isAccepted: true)]
        viewModel.result = BatchUpdateResult(entries: [], failedTrackIDs: ["1"], errorDescriptions: ["failed"])
        viewModel.trackStatuses = ["1": .done]
        viewModel.scopeTrackCount = 99

        viewModel.configureFullLibraryScope(tracks: [
            Track(id: "1", name: "One", artist: "Alpha", album: "First"),
            Track(id: "2", name: "Two", artist: "Beta", album: "Second"),
        ])

        guard case .configure = viewModel.phase else {
            #expect(Bool(false), "full-library setup should reset finished workflow phase")
            return
        }
        #expect(viewModel.mode == .fullLibrary)
        #expect(viewModel.proposedChanges.isEmpty)
        #expect(viewModel.result == nil)
        #expect(viewModel.trackStatuses.isEmpty)
        #expect(viewModel.scopeTrackCount == 2)
        #expect(viewModel.scopeArtistCount == 2)
    }

    @Test("selected tracks mode requires non-empty scope")
    func selectedTracksModeRequiresNonEmptyScope() {
        let viewModel = makeWorkflowViewModel()
        viewModel.mode = .selectedTracks
        viewModel.scopeTrackCount = 0

        #expect(!viewModel.hasRunnableScope)

        viewModel.scopeTrackCount = 1

        #expect(viewModel.hasRunnableScope)
    }
}

private actor AsyncCallCounter {
    private var calls = 0

    func record() {
        calls += 1
    }

    func count() -> Int {
        calls
    }
}
