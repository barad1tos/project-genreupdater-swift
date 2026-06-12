import Testing
@testable import Core
@testable import Services

@Suite("APIOrchestrator - release candidate collection")
struct APIOrchestratorReleaseCandidateTests {
    @Test("collects release candidates in configured source order")
    func collectsReleaseCandidatesInSourceOrder() async {
        let musicBrainz = MockAPIService(releaseCandidates: [
            ReleaseCandidate(
                artist: "Test Artist",
                album: "Test Album",
                year: 1998,
                source: .musicBrainz
            ),
        ])
        let discogs = MockAPIService(releaseCandidates: [
            ReleaseCandidate(
                artist: "Test Artist",
                album: "Test Album",
                year: 1999,
                source: .discogs
            ),
        ])
        let appleMusic = MockAPIService(releaseCandidates: [
            ReleaseCandidate(
                artist: "Test Artist",
                album: "Test Album",
                year: 2001,
                source: .itunes
            ),
        ])

        let orchestrator = APIOrchestrator(
            musicBrainz: musicBrainz,
            discogs: discogs,
            appleMusic: appleMusic,
            sourcePriorityConfiguration: APISourcePriorityConfiguration(
                preferredAPI: .discogs,
                scriptPriorities: [:]
            )
        )

        let candidates = await orchestrator.getReleaseCandidates(
            artist: "Test Artist",
            album: "Test Album",
            currentLibraryYear: nil,
            earliestTrackAddedYear: nil
        )

        #expect(candidates.map(\.source) == [.discogs, .musicBrainz, .itunes])
        #expect(candidates.map(\.year) == [1999, 1998, 2001])
    }
}
