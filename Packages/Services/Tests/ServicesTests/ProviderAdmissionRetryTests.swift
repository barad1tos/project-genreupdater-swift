import Foundation
import Testing
@testable import Core
@testable import Services

@Suite("APIOrchestrator — provider admission retries")
struct ProviderAdmissionRetryTests {
    @Test(
        "Retry chains retain one permit until their final attempt",
        arguments: ProviderLookup.allCases
    )
    func retryChainRetainsPermit(_ lookup: ProviderLookup) async throws {
        let probe = AdmissionRetryProbe()
        let orchestrator = retryOrchestrator(
            service: AdmissionRetryService(probe: probe),
            timeout: .seconds(2),
            retryDelaySeconds: 0.2
        )
        let retrying = providerLookup(orchestrator, lookup: lookup, artist: "Retry")
        #expect(await probe.waitForRetryAttempt(1))
        let competitor = providerLookup(orchestrator, lookup: lookup, artist: "Competitor")
        #expect(await probe.waitForRetryAttempt(2))

        #expect(await probe.events == ["retry-1", "retry-2"])
        await probe.releaseRetry()
        try await awaitLookups([retrying, competitor])
        #expect(await probe.events == ["retry-1", "retry-2", "competitor"])
    }

    @Test(
        "Retry attempts share one caller timeout",
        arguments: ProviderLookup.allCases
    )
    func retryChainUsesOneTimeout(_ lookup: ProviderLookup) async {
        let orchestrator = retryOrchestrator(
            service: TimedRetryService(),
            timeout: .milliseconds(80),
            retryDelaySeconds: 0
        )

        switch lookup {
        case .candidates:
            let candidates = await orchestrator.getReleaseCandidates(
                artist: "Retry",
                album: "Album",
                currentLibraryYear: nil,
                earliestTrackAddedYear: nil
            )
            #expect(candidates.isEmpty)
        case .albumYear:
            let result = await orchestrator.getAlbumYear(
                artist: "Retry",
                album: "Album",
                currentLibraryYear: nil,
                earliestTrackAddedYear: nil
            )
            #expect(result.year == nil)
        }
    }

    private func retryOrchestrator(
        service: any ExternalAPIService,
        timeout: Duration,
        retryDelaySeconds: Double
    ) -> APIOrchestrator {
        makeAPIOrchestrator(
            musicBrainz: service,
            discogs: MockAPIService(),
            appleMusic: MockAPIService(),
            disabledSources: [.discogs, .itunes]
        ) {
            $0.maxConcurrentSourceCalls = 1
            $0.timeout = timeout
            $0.maxAPIRetries = 1
            $0.apiRetryDelaySeconds = retryDelaySeconds
        }
    }

    private func providerLookup(
        _ orchestrator: APIOrchestrator,
        lookup: ProviderLookup,
        artist: String
    ) -> Task<Void, any Error> {
        Task {
            switch lookup {
            case .candidates:
                _ = await orchestrator.getReleaseCandidates(
                    artist: artist,
                    album: "Album",
                    currentLibraryYear: nil,
                    earliestTrackAddedYear: nil
                )
            case .albumYear:
                _ = await orchestrator.getAlbumYear(
                    artist: artist,
                    album: "Album",
                    currentLibraryYear: nil,
                    earliestTrackAddedYear: nil
                )
            }
        }
    }

    private func awaitLookups(_ tasks: [Task<Void, any Error>]) async throws {
        for task in tasks {
            _ = try await taskValue(task, timeout: .seconds(2))
        }
    }
}

private actor AdmissionRetryProbe {
    private(set) var events: [String] = []
    private var retryAttempts = 0
    private var retryContinuation: CheckedContinuation<Void, Never>?
    private var waitContinuation: CheckedContinuation<Bool, Never>?
    private var waitExpectedCount = 0
    private var waitTimer: Task<Void, Never>?

    func attempt(artist: String) async throws {
        guard artist == "Retry" else {
            events.append("competitor")
            return
        }

        retryAttempts += 1
        events.append("retry-\(retryAttempts)")
        resumeWaiterIfReady()
        if retryAttempts == 1 {
            throw URLError(.timedOut)
        }
        await withCheckedContinuation { continuation in
            retryContinuation = continuation
        }
    }

    func waitForRetryAttempt(_ expectedCount: Int) async -> Bool {
        guard retryAttempts < expectedCount else { return true }

        return await withCheckedContinuation { continuation in
            waitExpectedCount = expectedCount
            waitContinuation = continuation
            waitTimer = Task {
                try? await Task.sleep(for: .seconds(5))
                guard !Task.isCancelled else { return }
                timeoutWaiter(expectedCount: expectedCount)
            }
        }
    }

    func releaseRetry() {
        retryContinuation?.resume()
        retryContinuation = nil
    }

    private func resumeWaiterIfReady() {
        guard retryAttempts >= waitExpectedCount, let continuation = waitContinuation else { return }
        waitTimer?.cancel()
        waitTimer = nil
        waitContinuation = nil
        continuation.resume(returning: true)
    }

    private func timeoutWaiter(expectedCount: Int) {
        guard waitExpectedCount == expectedCount, let continuation = waitContinuation else { return }
        waitTimer = nil
        waitContinuation = nil
        continuation.resume(returning: false)
    }
}

private struct AdmissionRetryService: ExternalAPIService {
    let probe: AdmissionRetryProbe

    func getAlbumYear(
        artist: String,
        album _: String,
        currentLibraryYear _: Int?,
        earliestTrackAddedYear _: Int?
    ) async throws -> YearResult {
        try await probe.attempt(artist: artist)
        return YearResult(year: 1991, confidence: 90, yearScores: [1991: 90])
    }

    func getReleaseCandidates(
        artist: String,
        album: String,
        currentLibraryYear _: Int?,
        earliestTrackAddedYear _: Int?
    ) async throws -> [ReleaseCandidate] {
        try await probe.attempt(artist: artist)
        return [
            ReleaseCandidate(
                artist: artist,
                album: album,
                year: 1991,
                source: .musicBrainz
            ),
        ]
    }

    func initialize(force _: Bool) async throws {
        try Task.checkCancellation()
    }
}

private actor TimedRetryCounter {
    private var attempt = 0

    func next() -> Int {
        attempt += 1
        return attempt
    }
}

private struct TimedRetryService: ExternalAPIService {
    private let counter = TimedRetryCounter()

    func getAlbumYear(
        artist _: String,
        album _: String,
        currentLibraryYear _: Int?,
        earliestTrackAddedYear _: Int?
    ) async throws -> YearResult {
        try await attempt()
        return YearResult(year: 1991, confidence: 90, yearScores: [1991: 90])
    }

    func getReleaseCandidates(
        artist: String,
        album: String,
        currentLibraryYear _: Int?,
        earliestTrackAddedYear _: Int?
    ) async throws -> [ReleaseCandidate] {
        try await attempt()
        return [
            ReleaseCandidate(
                artist: artist,
                album: album,
                year: 1991,
                source: .musicBrainz
            ),
        ]
    }

    func initialize(force _: Bool) async throws {
        try Task.checkCancellation()
    }

    private func attempt() async throws {
        let attempt = await counter.next()
        try await Task.sleep(for: .milliseconds(50))
        if attempt == 1 {
            throw URLError(.timedOut)
        }
    }
}
