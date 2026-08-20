import Foundation
import Testing
@testable import Core
@testable import Services

@Suite("APIOrchestrator — global provider admission")
struct ProviderAdmissionTests {
    @Test("Candidate and direct-year lookups share one concurrency budget")
    func sharesConcurrencyBudget() async {
        let probe = ProviderCallProbe()
        let service = ProbedProviderService(probe: probe)
        let orchestrator = makeAPIOrchestrator(
            musicBrainz: service,
            discogs: service,
            appleMusic: service
        ) {
            $0.maxConcurrentSourceCalls = 2
            $0.timeout = .seconds(2)
        }

        await withTaskGroup(of: Void.self) { group in
            for index in 0 ..< 3 {
                group.addTask {
                    _ = await orchestrator.getReleaseCandidates(
                        artist: "Candidate Artist \(index)",
                        album: "Candidate Album \(index)",
                        currentLibraryYear: nil,
                        earliestTrackAddedYear: nil
                    )
                }
                group.addTask {
                    _ = await orchestrator.getAlbumYear(
                        artist: "Year Artist \(index)",
                        album: "Year Album \(index)",
                        currentLibraryYear: nil,
                        earliestTrackAddedYear: nil
                    )
                }
            }
        }

        #expect(await probe.maximumActiveCalls == 2)
    }

    @Test(
        "Timeout returns while a non-cooperative provider retains its permit",
        arguments: ProviderLookup.allCases
    )
    func timeoutRetainsPermit(_ lookup: ProviderLookup) async {
        let stall = ProviderStall()
        let service = StalledProviderService(stall: stall)
        let orchestrator = makeAPIOrchestrator(
            musicBrainz: service,
            discogs: MockAPIService(),
            appleMusic: MockAPIService(),
            disabledSources: [.discogs, .itunes]
        ) {
            $0.maxConcurrentSourceCalls = 1
            $0.timeout = .milliseconds(20)
        }

        let firstLookup = providerLookup(orchestrator, lookup: lookup, artist: "First")
        #expect(await stall.waitForCalls(1))

        do {
            _ = try await taskValue(firstLookup, timeout: .milliseconds(200))
        } catch {
            await stall.release()
            _ = try? await firstLookup.value
            Issue.record("Lookup did not return at its provider timeout: \(error)")
            return
        }

        let secondLookup = providerLookup(orchestrator, lookup: lookup, artist: "Second")
        do {
            _ = try await taskValue(secondLookup, timeout: .milliseconds(200))
        } catch {
            Issue.record("Queued lookup did not honor its provider timeout: \(error)")
        }
        #expect(await stall.callCount == 1)

        await stall.release()
        _ = try? await secondLookup.value
        #expect(await stall.waitForCompletions(1))
    }

    @Test(
        "Workflow cancellation stops after each nonthrowing provider boundary",
        arguments: CancellationBoundary.allCases
    )
    func workflowCancellationPropagates(_ boundary: CancellationBoundary) async {
        let probe = CancellationBoundaryProbe(boundary: boundary)
        let service = CancellationProviderService(probe: probe)
        let pendingVerification = RecordingPendingVerificationService()
        let orchestrator = makeAPIOrchestrator(
            musicBrainz: service,
            discogs: MockAPIService(),
            appleMusic: MockAPIService(),
            disabledSources: [.discogs, .itunes]
        ) {
            $0.maxConcurrentSourceCalls = 1
            $0.timeout = .seconds(30)
            $0.pendingVerificationService = pendingVerification
        }
        let coordinator = makeCoordinator(
            apiOrchestrator: orchestrator,
            pendingVerificationService: pendingVerification
        )
        let track = Track(
            id: "cancelled-year",
            name: "Track",
            artist: "Artist",
            album: "Album",
            year: nil,
            trackStatus: nil
        )
        let lookup: Task<ProposedChange?, any Error> = Task {
            try await coordinator.determineYearChange(
                track: track,
                albumTracks: [track],
                forceYearLookup: true
            )
        }
        #expect(await probe.waitUntilEntered())

        lookup.cancel()
        await #expect(throws: CancellationError.self) {
            _ = try await taskValue(lookup, timeout: .milliseconds(200))
        }
        #expect(await probe.calls == boundary.expectedCalls)
        #expect(await pendingVerification.markCount() == 0)
        #expect(await pendingVerification.removalCount() == 0)
    }

    @Test("Cancelled pending verification does not update retry state")
    func pendingVerificationCancellationPropagates() async {
        let probe = CancellationBoundaryProbe(boundary: .albumYear)
        let pendingVerification = RecordingPendingVerificationService()
        let orchestrator = makeAPIOrchestrator(
            musicBrainz: CancellationProviderService(probe: probe),
            discogs: MockAPIService(),
            appleMusic: MockAPIService(),
            disabledSources: [.discogs, .itunes]
        ) {
            $0.maxConcurrentSourceCalls = 1
            $0.timeout = .seconds(30)
            $0.pendingVerificationService = pendingVerification
        }
        let coordinator = makeCoordinator(
            apiOrchestrator: orchestrator,
            pendingVerificationService: pendingVerification
        )
        let track = Track(
            id: "pending-cancellation",
            name: "Track",
            artist: "Artist",
            album: "Album",
            year: nil,
            trackStatus: nil
        )
        let entry = PendingAlbumEntry(
            id: "pending-cancellation",
            artist: "Artist",
            album: "Album",
            reason: "no_year_found"
        )
        let verification = Task {
            try await coordinator.verifyPendingAlbum(entry, albumTracks: [track])
        }
        #expect(await probe.waitUntilEntered())

        verification.cancel()
        await #expect(throws: CancellationError.self) {
            _ = try await taskValue(verification, timeout: .milliseconds(200))
        }
        #expect(await pendingVerification.markCount() == 0)
        #expect(await pendingVerification.removalCount() == 0)
    }

    @Test("Queued timeout does not update pending verification")
    func queuedTimeoutKeepsPending() async {
        let stall = ProviderStall()
        let pendingVerification = RecordingPendingVerificationService()
        let orchestrator = makeAPIOrchestrator(
            musicBrainz: StalledProviderService(stall: stall),
            discogs: MockAPIService(),
            appleMusic: MockAPIService(),
            disabledSources: [.discogs, .itunes]
        ) {
            $0.maxConcurrentSourceCalls = 1
            $0.timeout = .milliseconds(20)
            $0.pendingVerificationService = pendingVerification
        }
        let coordinator = makeCoordinator(
            apiOrchestrator: orchestrator,
            pendingVerificationService: pendingVerification
        )
        let blocker = providerLookup(orchestrator, lookup: .albumYear, artist: "Blocker")
        #expect(await stall.waitForCalls(1))
        let track = Track(
            id: "queued-timeout",
            name: "Track",
            artist: "Queued",
            album: "Album",
            year: nil,
            trackStatus: nil
        )
        let entry = PendingAlbumEntry(
            id: "queued-timeout",
            artist: "Queued",
            album: "Album",
            reason: "no_year_found"
        )
        let verification: Task<PendingAlbumVerificationResult, any Error> = Task {
            try await coordinator.verifyPendingAlbum(entry, albumTracks: [track])
        }

        do {
            _ = try await taskValue(verification, timeout: .milliseconds(200))
        } catch {
            await stall.release()
            _ = try? await blocker.value
            Issue.record("Queued pending lookup did not return at its timeout: \(error)")
            return
        }
        #expect(await stall.callCount == 1)
        #expect(await pendingVerification.markCount() == 0)
        #expect(await pendingVerification.removalCount() == 0)

        await stall.release()
        _ = try? await blocker.value
        #expect(await stall.waitForCompletions(1))
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

    private func makeCoordinator(
        apiOrchestrator: APIOrchestrator,
        pendingVerificationService: (any PendingVerificationService)? = nil
    ) -> UpdateCoordinator {
        let bridge = MockAppleScriptClient()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ProviderAdmissionTests-\(UUID().uuidString)")
        return UpdateCoordinator(
            dependencies: UpdateDependencies(
                apiOrchestrator: apiOrchestrator,
                scriptBridge: bridge,
                stores: .init(
                    trackStore: MockTrackStore(),
                    cache: MockCacheService()
                ),
                undoCoordinator: UndoCoordinator(
                    scriptBridge: bridge,
                    directory: directory
                ),
                idMapper: nil,
                librarySnapshotService: nil,
                pendingVerificationService: pendingVerificationService
            ),
            genreDeterminator: GenreDeterminator(),
            yearDeterminator: YearDeterminator()
        )
    }
}

enum ProviderLookup: CaseIterable, Sendable {
    case candidates
    case albumYear
}

enum CancellationBoundary: CaseIterable, Sendable {
    case candidates
    case albumYear
    case activityPeriod
    case region

    var expectedCalls: [Self] {
        switch self {
        case .candidates: [.candidates]
        case .albumYear: [.candidates, .albumYear]
        case .activityPeriod: [.candidates, .activityPeriod]
        case .region: [.candidates, .activityPeriod, .region]
        }
    }
}

private actor CancellationBoundaryProbe {
    let boundary: CancellationBoundary
    private(set) var calls: [CancellationBoundary] = []
    private var hasEnteredBoundary = false

    init(boundary: CancellationBoundary) {
        self.boundary = boundary
    }

    func record(_ call: CancellationBoundary) async throws {
        calls.append(call)
        guard call == boundary else { return }
        hasEnteredBoundary = true
        try await Task.sleep(for: .seconds(30))
    }

    func waitUntilEntered() async -> Bool {
        let deadline = ContinuousClock().now.advanced(by: .seconds(2))
        while !hasEnteredBoundary, ContinuousClock().now < deadline {
            try? await Task.sleep(for: .milliseconds(1))
        }
        return hasEnteredBoundary
    }
}

private struct CancellationProviderService: ExternalAPIService {
    let probe: CancellationBoundaryProbe

    func getAlbumYear(
        artist _: String,
        album _: String,
        currentLibraryYear _: Int?,
        earliestTrackAddedYear _: Int?
    ) async throws -> YearResult {
        try await probe.record(.albumYear)
        return YearResult()
    }

    func getReleaseCandidates(
        artist _: String,
        album _: String,
        currentLibraryYear _: Int?,
        earliestTrackAddedYear _: Int?
    ) async throws -> [ReleaseCandidate] {
        try await probe.record(.candidates)
        let boundary = probe.boundary
        guard boundary == .activityPeriod || boundary == .region else { return [] }
        return [
            ReleaseCandidate(
                artist: "Artist",
                album: "Album",
                year: 2000,
                source: .musicBrainz
            ),
        ]
    }

    func getArtistActivityPeriod(
        normalizedArtist _: String
    ) async throws -> (start: Int?, end: Int?) {
        try await probe.record(.activityPeriod)
        return (nil, nil)
    }

    func getArtistRegion(artist _: String) async throws -> String? {
        try await probe.record(.region)
        return nil
    }

    func initialize(force _: Bool) async throws {
        try Task.checkCancellation()
    }
}

private actor ProviderCallProbe {
    private var activeCalls = 0
    private(set) var maximumActiveCalls = 0

    func run<Value: Sendable>(_ value: Value) async throws -> Value {
        activeCalls += 1
        maximumActiveCalls = max(maximumActiveCalls, activeCalls)
        do {
            try await Task.sleep(for: .milliseconds(50))
            activeCalls -= 1
            return value
        } catch {
            activeCalls -= 1
            throw error
        }
    }
}

private struct ProbedProviderService: ExternalAPIService {
    let probe: ProviderCallProbe

    func getAlbumYear(
        artist _: String,
        album _: String,
        currentLibraryYear _: Int?,
        earliestTrackAddedYear _: Int?
    ) async throws -> YearResult {
        try await probe.run(YearResult())
    }

    func getReleaseCandidates(
        artist _: String,
        album _: String,
        currentLibraryYear _: Int?,
        earliestTrackAddedYear _: Int?
    ) async throws -> [ReleaseCandidate] {
        try await probe.run([])
    }

    func initialize(force _: Bool) async throws {
        try Task.checkCancellation()
    }
}

private actor ProviderStall {
    private var calls = 0
    private var completions = 0
    private var continuations: [CheckedContinuation<Void, Never>] = []

    var callCount: Int {
        calls
    }

    func wait() async {
        calls += 1
        await withCheckedContinuation { continuation in
            continuations.append(continuation)
        }
    }

    func waitForCalls(_ expectedCount: Int) async -> Bool {
        let deadline = ContinuousClock().now.advanced(by: .seconds(2))
        while calls < expectedCount, ContinuousClock().now < deadline {
            try? await Task.sleep(for: .milliseconds(1))
        }
        return calls >= expectedCount
    }

    func finish() {
        completions += 1
    }

    func waitForCompletions(_ expectedCount: Int) async -> Bool {
        let deadline = ContinuousClock().now.advanced(by: .seconds(2))
        while completions < expectedCount, ContinuousClock().now < deadline {
            try? await Task.sleep(for: .milliseconds(1))
        }
        return completions >= expectedCount
    }

    func release() {
        let pending = continuations
        continuations.removeAll()
        for continuation in pending {
            continuation.resume()
        }
    }
}

private struct StalledProviderService: ExternalAPIService {
    let stall: ProviderStall

    func getAlbumYear(
        artist _: String,
        album _: String,
        currentLibraryYear _: Int?,
        earliestTrackAddedYear _: Int?
    ) async throws -> YearResult {
        await stall.wait()
        await stall.finish()
        return YearResult()
    }

    func getReleaseCandidates(
        artist _: String,
        album _: String,
        currentLibraryYear _: Int?,
        earliestTrackAddedYear _: Int?
    ) async throws -> [ReleaseCandidate] {
        await stall.wait()
        await stall.finish()
        return []
    }

    func initialize(force _: Bool) async throws {
        try Task.checkCancellation()
    }
}
