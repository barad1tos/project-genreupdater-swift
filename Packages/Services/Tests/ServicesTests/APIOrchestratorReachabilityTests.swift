import Testing
@testable import Core
@testable import Services

@Suite("APIOrchestrator — reachability")
struct APIOrchestratorReachabilityTests {
    @Test("Offline reachability skips source requests")
    func offlineReachabilitySkipsSourceRequests() async {
        let callCounter = APICallCounter()
        let offlineReachability = NetworkReachabilityMonitor(initialIsConnected: false)
        let sourceResult = YearResult(year: 1999, confidence: 99, yearScores: [1999: 99])
        let orchestrator = makeAPIOrchestrator(
            musicBrainz: CountingAPIService(callCounter: callCounter, yearResult: sourceResult),
            discogs: CountingAPIService(callCounter: callCounter, yearResult: sourceResult),
            appleMusic: CountingAPIService(callCounter: callCounter, yearResult: sourceResult)
        ) {
            $0.reachability = offlineReachability
        }

        let result = await orchestrator.getAlbumYear(
            artist: "Iron Maiden",
            album: "Powerslave",
            currentLibraryYear: nil,
            earliestTrackAddedYear: nil
        )

        #expect(result.year == nil)
        #expect(result.confidence == 0)
        #expect(await callCounter.count() == 0)
    }
}
