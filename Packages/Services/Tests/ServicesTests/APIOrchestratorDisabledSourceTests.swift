import Testing
@testable import Core
@testable import Services

@Suite("APIOrchestrator — disabled sources")
struct APIOrchestratorDisabledSourceTests {
    @Test("Disabled sources are skipped before API calls")
    func disabledSourcesAreSkippedBeforeAPICalls() async {
        let recorder = APISourceCallRecorder()
        let musicBrainz = SourceRecordingAPIService(source: .musicBrainz, recorder: recorder)
        let discogs = SourceRecordingAPIService(source: .discogs, recorder: recorder)
        let appleMusic = SourceRecordingAPIService(source: .itunes, recorder: recorder)
        let orchestrator = makeAPIOrchestrator(
            musicBrainz: musicBrainz,
            discogs: discogs,
            appleMusic: appleMusic,
            disabledSources: [.discogs]
        ) {
            $0.sourcePriorityConfiguration = APISourcePriorityConfiguration(preferredAPI: .musicbrainz)
        }

        _ = await orchestrator.getAlbumYear(
            artist: "In Flames",
            album: "Clayman",
            currentLibraryYear: nil,
            earliestTrackAddedYear: nil
        )

        let calledSources = await recorder.calledSources
        #expect(calledSources.contains(.musicBrainz))
        #expect(calledSources.contains(.itunes))
        #expect(!calledSources.contains(.discogs))
    }

    @Test("Disabled sources are skipped before release candidate calls")
    func disabledSourcesAreSkippedBeforeReleaseCandidateCalls() async {
        let recorder = APISourceCallRecorder()
        let musicBrainz = SourceRecordingAPIService(source: .musicBrainz, recorder: recorder)
        let discogs = SourceRecordingAPIService(source: .discogs, recorder: recorder)
        let appleMusic = SourceRecordingAPIService(source: .itunes, recorder: recorder)
        let orchestrator = makeAPIOrchestrator(
            musicBrainz: musicBrainz,
            discogs: discogs,
            appleMusic: appleMusic,
            disabledSources: [.discogs]
        ) {
            $0.sourcePriorityConfiguration = APISourcePriorityConfiguration(preferredAPI: .musicbrainz)
        }

        let candidates = await orchestrator.getReleaseCandidates(
            artist: "In Flames",
            album: "Clayman",
            currentLibraryYear: nil,
            earliestTrackAddedYear: nil
        )

        let calledSources = await recorder.calledSources
        #expect(calledSources.contains(.musicBrainz))
        #expect(calledSources.contains(.itunes))
        #expect(!calledSources.contains(.discogs))
        #expect(!candidates.contains { $0.source == .discogs })
    }
}

private actor APISourceCallRecorder {
    private var sources: [APISource] = []

    var calledSources: [APISource] {
        sources
    }

    func record(_ source: APISource) {
        sources.append(source)
    }
}

private struct SourceRecordingAPIService: ExternalAPIService {
    let source: APISource
    let recorder: APISourceCallRecorder

    func getAlbumYear(
        artist _: String,
        album _: String,
        currentLibraryYear _: Int?,
        earliestTrackAddedYear _: Int?
    ) async throws -> YearResult {
        await recorder.record(source)
        return YearResult(
            year: 1999,
            confidence: 60,
            yearScores: [1999: 60]
        )
    }

    func getReleaseCandidates(
        artist: String,
        album: String,
        currentLibraryYear _: Int?,
        earliestTrackAddedYear _: Int?
    ) async throws -> [ReleaseCandidate] {
        await recorder.record(source)
        return [
            ReleaseCandidate(
                artist: artist,
                album: album,
                year: 2000,
                source: source
            ),
        ]
    }

    func getArtistActivityPeriod(
        normalizedArtist _: String
    ) async throws -> (start: Int?, end: Int?) {
        (nil, nil)
    }

    func getArtistStartYear(
        normalizedArtist _: String
    ) async throws -> Int? {
        nil
    }

    func initialize(force _: Bool) async throws {
        try Task.checkCancellation()
    }

    func close() async {
        await Task.yield()
    }
}
