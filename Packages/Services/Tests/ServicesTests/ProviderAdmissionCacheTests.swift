import Foundation
import Testing
@testable import Core
@testable import Services

@Suite("APIOrchestrator — provider admission cache")
struct ProviderAdmissionCacheTests {
    @Test("Candidate cache hits bypass a busy permit")
    func candidateHitSkipsAdmission() async throws {
        let fixture = makeFixture()
        let seeded = await fixture.orchestrator.getReleaseCandidates(
            artist: "Cached Candidate",
            album: "Cached Album",
            currentLibraryYear: nil,
            earliestTrackAddedYear: nil
        )
        #expect(seeded.map(\.year) == [1990])

        let candidates = try await cachedResultWhileBusy(fixture) {
            await fixture.orchestrator.getReleaseCandidates(
                artist: "Cached Candidate",
                album: "Cached Album",
                currentLibraryYear: nil,
                earliestTrackAddedYear: nil
            )
        }
        #expect(candidates.map(\.year) == [1990])
    }

    @Test("Direct-year cache hits bypass a busy permit")
    func yearHitSkipsAdmission() async throws {
        let fixture = makeFixture()
        let seeded = await fixture.orchestrator.getAlbumYear(
            artist: "Cached Year",
            album: "Cached Album",
            currentLibraryYear: nil,
            earliestTrackAddedYear: nil
        )
        #expect(seeded.year == 2000)

        let year = try await cachedResultWhileBusy(fixture) {
            await fixture.orchestrator.getAlbumYear(
                artist: "Cached Year",
                album: "Cached Album",
                currentLibraryYear: nil,
                earliestTrackAddedYear: nil
            )
        }
        #expect(year.year == 2000)
    }

    private func makeFixture() -> AdmissionCacheFixture {
        let cache = MockCacheService()
        let probe = AdmissionCacheProbe()
        let service = AdmissionCacheService(probe: probe)
        let orchestrator = makeAPIOrchestrator(
            musicBrainz: service,
            discogs: MockAPIService(),
            appleMusic: MockAPIService(),
            cache: cache,
            disabledSources: [.discogs, .itunes]
        ) {
            $0.maxConcurrentSourceCalls = 1
            $0.timeout = .seconds(2)
        }
        return AdmissionCacheFixture(orchestrator: orchestrator, probe: probe)
    }

    private func cachedResultWhileBusy<Result: Sendable>(
        _ fixture: AdmissionCacheFixture,
        operation: @escaping @Sendable () async -> Result
    ) async throws -> Result {
        let blocker: Task<YearResult, any Error> = Task {
            await fixture.orchestrator.getAlbumYear(
                artist: "Blocker",
                album: "Blocked Album",
                currentLibraryYear: nil,
                earliestTrackAddedYear: nil
            )
        }
        #expect(await fixture.probe.waitUntilBlocked())
        let blockedCalls = await fixture.probe.callCounts
        let cached: Task<Result, any Error> = Task {
            await operation()
        }

        do {
            let result = try await taskValue(cached, timeout: .milliseconds(200))
            #expect(await fixture.probe.callCounts == blockedCalls)
            await fixture.probe.releaseBlocker()
            _ = try await taskValue(blocker, timeout: .seconds(1))
            return result
        } catch {
            await fixture.probe.releaseBlocker()
            _ = try? await blocker.value
            throw error
        }
    }
}

private struct AdmissionCacheFixture: Sendable {
    let orchestrator: APIOrchestrator
    let probe: AdmissionCacheProbe
}

private actor AdmissionCacheProbe {
    private var candidateCalls = 0
    private var yearCalls = 0
    private var isBlocked = false
    private var blockerContinuation: CheckedContinuation<Void, Never>?

    var callCounts: (candidate: Int, year: Int) {
        (candidate: candidateCalls, year: yearCalls)
    }

    func candidates(artist: String, album: String) -> [ReleaseCandidate] {
        candidateCalls += 1
        return [
            ReleaseCandidate(
                artist: artist,
                album: album,
                year: 1990,
                source: .musicBrainz
            ),
        ]
    }

    func year(artist: String) async -> YearResult {
        yearCalls += 1
        guard artist == "Blocker" else {
            return YearResult(year: 2000, confidence: 90, yearScores: [2000: 90])
        }

        isBlocked = true
        await withCheckedContinuation { continuation in
            blockerContinuation = continuation
        }
        return YearResult()
    }

    func waitUntilBlocked() async -> Bool {
        let deadline = ContinuousClock().now.advanced(by: .seconds(1))
        while !isBlocked, ContinuousClock().now < deadline {
            try? await Task.sleep(for: .milliseconds(1))
        }
        return isBlocked
    }

    func releaseBlocker() {
        blockerContinuation?.resume()
        blockerContinuation = nil
    }
}

private struct AdmissionCacheService: ExternalAPIService {
    let probe: AdmissionCacheProbe

    func getAlbumYear(
        artist: String,
        album _: String,
        currentLibraryYear _: Int?,
        earliestTrackAddedYear _: Int?
    ) async throws -> YearResult {
        await probe.year(artist: artist)
    }

    func getReleaseCandidates(
        artist: String,
        album: String,
        currentLibraryYear _: Int?,
        earliestTrackAddedYear _: Int?
    ) async throws -> [ReleaseCandidate] {
        await probe.candidates(artist: artist, album: album)
    }

    func initialize(force _: Bool) async throws {
        try Task.checkCancellation()
    }
}
