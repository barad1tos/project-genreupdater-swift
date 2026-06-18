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
        let orchestrator = APIOrchestrator(
            musicBrainz: musicBrainz,
            discogs: discogs,
            appleMusic: appleMusic,
            disabledSources: [.discogs],
            sourcePriorityConfiguration: APISourcePriorityConfiguration(preferredAPI: .musicbrainz)
        )

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
        artist _: String,
        album _: String,
        currentLibraryYear _: Int?,
        earliestTrackAddedYear _: Int?
    ) async throws -> [ReleaseCandidate] {
        await recorder.record(source)
        return []
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

    func initialize(force _: Bool) async throws {}
    func close() async {}
}
