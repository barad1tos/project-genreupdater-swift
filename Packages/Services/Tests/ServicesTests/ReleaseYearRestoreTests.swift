import Foundation
import Testing
@testable import Core
@testable import Services

private struct ReleaseYearRestoreFixture {
    let coordinator: UpdateCoordinator
    let bridge: MockAppleScriptClient
}

private func makeReleaseYearRestoreFixture(
    runtimeConfiguration: UpdateRuntimeConfiguration = UpdateRuntimeConfiguration()
) async -> ReleaseYearRestoreFixture {
    let bridge = MockAppleScriptClient()
    let store = MockTrackStore()
    let cache = MockCacheService()
    let undoDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent("ReleaseYearRestoreTests-\(UUID().uuidString)")
    let undo = UndoCoordinator(scriptBridge: bridge, directory: undoDirectory)
    let apiService = MockAPIService()
    let orchestrator = makeAPIOrchestrator(
        musicBrainz: apiService,
        discogs: apiService,
        appleMusic: apiService
    )
    let coordinator = UpdateCoordinator(
        dependencies: UpdateCoordinatorDependencies(
            apiOrchestrator: orchestrator,
            scriptBridge: bridge,
            trackStore: store,
            cache: cache,
            undoCoordinator: undo
        ),
        genreDeterminator: GenreDeterminator(),
        runtimeConfiguration: runtimeConfiguration
    )
    return ReleaseYearRestoreFixture(coordinator: coordinator, bridge: bridge)
}

private func makeReleaseYearTrack(
    id: String,
    artist: String = "Crematory",
    album: String = "Awake",
    year: Int?,
    releaseYear: Int?,
    trackStatus: String? = nil,
    albumArtist: String? = nil
) -> Track {
    Track(
        id: id,
        name: "Track \(id)",
        artist: artist,
        album: album,
        year: year,
        trackStatus: trackStatus,
        releaseYear: releaseYear,
        albumArtist: albumArtist
    )
}

@Suite("UpdateCoordinator - release year restore")
struct ReleaseYearRestoreTests {
    @Test("Restores tracks whose year differs from release year beyond threshold")
    func restoresTracksBeyondThreshold() async {
        let fixture = await makeReleaseYearRestoreFixture()
        let tracks = [
            makeReleaseYearTrack(id: "T1", year: 2025, releaseYear: 1997),
            makeReleaseYearTrack(id: "T2", year: 2025, releaseYear: 1997),
            makeReleaseYearTrack(id: "T3", year: 2020, releaseYear: 2019),
            makeReleaseYearTrack(id: "T4", year: 2025, releaseYear: nil),
        ]

        let result = await fixture.coordinator.restoreReleaseYears(
            in: tracks,
            threshold: 5,
            progressHandler: ignoreReleaseYearProgress
        )

        let written = await fixture.bridge.writtenProperties
        #expect(result.entries.count == 2)
        #expect(result.failedTrackIDs.isEmpty)
        #expect(result.entries.allSatisfy { $0.changeType == .yearRevert })
        #expect(written.count == 2)
        #expect(written.allSatisfy { $0.property == "year" && $0.value == "1997" })
    }

    @Test("Does not restore when difference equals threshold")
    func skipsExactThreshold() async {
        let fixture = await makeReleaseYearRestoreFixture()
        let tracks = [
            makeReleaseYearTrack(id: "T1", year: 2020, releaseYear: 2015),
        ]

        let result = await fixture.coordinator.restoreReleaseYears(
            in: tracks,
            threshold: 5,
            progressHandler: ignoreReleaseYearProgress
        )

        let written = await fixture.bridge.writtenProperties
        #expect(result.entries.isEmpty)
        #expect(written.isEmpty)
    }

    @Test("Restores missing year when release year exists")
    func restoresMissingYear() async {
        let fixture = await makeReleaseYearRestoreFixture()
        let tracks = [
            makeReleaseYearTrack(id: "T1", year: nil, releaseYear: 1997),
        ]

        let result = await fixture.coordinator.restoreReleaseYears(
            in: tracks,
            threshold: 5,
            progressHandler: ignoreReleaseYearProgress
        )

        let written = await fixture.bridge.writtenProperties
        #expect(result.entries.count == 1)
        #expect(written.first?.value == "1997")
    }

    @Test("Skips prerelease tracks before release-year restore consensus")
    func skipsPrereleaseTracksBeforeReleaseYearRestoreConsensus() async {
        let fixture = await makeReleaseYearRestoreFixture()
        let tracks = [
            makeReleaseYearTrack(
                id: "T1",
                year: 2025,
                releaseYear: 2001,
                trackStatus: TrackKind.prerelease.rawValue
            ),
            makeReleaseYearTrack(id: "T2", year: 2025, releaseYear: 1997),
        ]

        let result = await fixture.coordinator.restoreReleaseYears(
            in: tracks,
            threshold: 5,
            progressHandler: ignoreReleaseYearProgress
        )

        let written = await fixture.bridge.writtenProperties
        #expect(result.entries.count == 1)
        #expect(result.entries.first?.trackID == "T2")
        #expect(written.count == 1)
        #expect(written.first?.trackID == "T2")
        #expect(written.first?.value == "1997")
    }

    @Test("Skips release-year restore when album consensus is tied")
    func skipsReleaseYearRestoreWhenAlbumConsensusIsTied() async {
        let fixture = await makeReleaseYearRestoreFixture()
        let tracks = [
            makeReleaseYearTrack(id: "T1", year: 2025, releaseYear: 1997),
            makeReleaseYearTrack(id: "T2", year: 2025, releaseYear: 2001),
        ]

        let result = await fixture.coordinator.restoreReleaseYears(
            in: tracks,
            threshold: 5,
            progressHandler: ignoreReleaseYearProgress
        )

        let written = await fixture.bridge.writtenProperties
        #expect(result.entries.isEmpty)
        #expect(result.noOpEntries.isEmpty)
        #expect(result.failedTrackIDs.isEmpty)
        #expect(written.isEmpty)
    }

    @Test("Release-year restore consensus groups guest tracks by album artist")
    func releaseYearRestoreConsensusGroupsGuestTracksByAlbumArtist() {
        let tracks = [
            makeReleaseYearTrack(
                id: "T1",
                artist: "Daft Punk",
                album: "Random Access Memories",
                year: 1999,
                releaseYear: 2013,
                albumArtist: "Daft Punk"
            ),
            makeReleaseYearTrack(
                id: "T2",
                artist: "Daft Punk & Pharrell Williams",
                album: "Random Access Memories",
                year: 1999,
                releaseYear: 2013,
                albumArtist: "Daft Punk"
            ),
        ]

        let consensus = UpdateCoordinator.releaseYearConsensusByAlbum(for: tracks)

        #expect(consensus.count == 1)
        #expect(consensus[AlbumIdentity.key(artist: "Daft Punk", album: "Random Access Memories")] == 2013)
    }

    @Test("Release-year restore consensus keeps different album artists separate")
    func releaseYearRestoreConsensusKeepsDifferentAlbumArtistsSeparate() {
        let tracks = [
            makeReleaseYearTrack(
                id: "T1",
                artist: "Featured Singer",
                album: "Greatest Hits",
                year: 2005,
                releaseYear: 1998,
                albumArtist: "Original Artist"
            ),
            makeReleaseYearTrack(
                id: "T2",
                artist: "Featured Singer",
                album: "Greatest Hits",
                year: 2005,
                releaseYear: 2004,
                albumArtist: "Compilation Artist"
            ),
        ]

        let consensus = UpdateCoordinator.releaseYearConsensusByAlbum(for: tracks)

        #expect(consensus.count == 2)
        #expect(consensus[AlbumIdentity.key(artist: "Original Artist", album: "Greatest Hits")] == 1998)
        #expect(consensus[AlbumIdentity.key(artist: "Compilation Artist", album: "Greatest Hits")] == 2004)
    }

    @Test("Skips out-of-scope restore without recording success")
    func skipsOutOfScopeRestoreWithoutRecordingSuccess() async {
        let fixture = await makeReleaseYearRestoreFixture(
            runtimeConfiguration: UpdateRuntimeConfiguration(testArtists: ["In Flames"])
        )
        let tracks = [
            makeReleaseYearTrack(id: "T1", artist: "Crematory", year: 2025, releaseYear: 1997),
            makeReleaseYearTrack(id: "T2", artist: "Crematory", year: 2025, releaseYear: 1997),
        ]

        let result = await fixture.coordinator.restoreReleaseYears(
            in: tracks,
            threshold: 5,
            progressHandler: ignoreReleaseYearProgress
        )

        let written = await fixture.bridge.writtenProperties
        #expect(result.entries.isEmpty)
        #expect(result.failedTrackIDs.isEmpty)
        #expect(written.isEmpty)
    }

    @Test("Treats cancellation as cancellation instead of a failed track")
    func treatsCancellationAsCancellationInsteadOfFailedTrack() async {
        let fixture = await makeReleaseYearRestoreFixture()
        await fixture.bridge.setCustomWriteError(CancellationError())

        let result = await fixture.coordinator.restoreReleaseYears(
            in: [makeReleaseYearTrack(id: "T1", year: 2025, releaseYear: 1997)],
            threshold: 5,
            progressHandler: ignoreReleaseYearProgress
        )

        let written = await fixture.bridge.writtenProperties
        #expect(result.entries.isEmpty)
        #expect(result.failedTrackIDs.isEmpty)
        #expect(result.errorDescriptions.isEmpty)
        #expect(written.isEmpty)
    }

    @Test("Records no-op release-year restore outcomes")
    func recordsNoOpReleaseYearRestoreOutcomes() async {
        let fixture = await makeReleaseYearRestoreFixture()
        await fixture.bridge.setSingleWriteResult(.noChange)

        let result = await fixture.coordinator.restoreReleaseYears(
            in: [makeReleaseYearTrack(id: "T1", year: 2025, releaseYear: 1997)],
            threshold: 5,
            progressHandler: ignoreReleaseYearProgress
        )

        let written = await fixture.bridge.writtenProperties
        #expect(result.entries.isEmpty)
        #expect(result.noOpEntries.count == 1)
        #expect(result.failedTrackIDs.isEmpty)
        #expect(written.count == 1)
        #expect(written.first?.value == "1997")
    }
}

private func ignoreReleaseYearProgress(_ update: ProgressUpdate) {
    _ = update
}
