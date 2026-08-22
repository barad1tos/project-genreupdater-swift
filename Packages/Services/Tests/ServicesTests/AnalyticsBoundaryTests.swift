import Foundation
import Testing
@testable import Core
@testable import Services

@Suite("Analytics instrumentation")
struct AnalyticsBoundaryTests {
    @Test("MusicKit snapshot loading records one successful fetch without changing its result")
    func musicKitFetch() async throws {
        let analytics = InstrumentationAnalytics()
        let expected = LibraryReadSnapshot(
            tracks: [instrumentationTrack(id: "T1")],
            scannedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let provider = MeasuredLibraryProvider(
            base: AnalyticsLibraryProvider(snapshot: expected),
            analytics: analytics
        )

        let actual = try await provider.loadLibrarySnapshot(request: LibraryReadRequest())

        #expect(actual == expected)
        #expect(await analytics.results == [
            InstrumentationResult(operation: .musicAppFetch, outcome: .succeeded),
        ])
    }

    @Test("AppleScript boundaries preserve failure and cancellation outcomes")
    func appleScriptOutcomes() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AnalyticsInstrumentation-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data().write(to: directory.appendingPathComponent("batch_update_tracks.scpt"))

        let analytics = InstrumentationAnalytics()
        let bridge = AppleScriptBridge(
            installer: ScriptInstaller(scriptsDirectory: directory, bundleScriptsDirectory: nil),
            analytics: analytics
        )

        await #expect(throws: AppleScriptBridgeError.self) {
            _ = try await bridge.runScript(name: "missing")
        }
        await #expect(throws: CancellationError.self) {
            try await bridge.batchUpdateTracks(
                [TrackPropertyUpdate(trackID: "T1", property: "genre", value: "Rock")],
                onAttempt: nil,
                execute: { _ in throw CancellationError() }
            )
        }

        #expect(await analytics.results == [
            InstrumentationResult(operation: .appleScriptRun, outcome: .failed),
            InstrumentationResult(operation: .appleScriptBatchWrite, outcome: .cancelled),
        ])
    }

    @Test("AppleScript ID scanning records one aggregate operation")
    func appleScriptIDFetch() async throws {
        let analytics = InstrumentationAnalytics()
        let bridge = AppleScriptBridge(
            installer: ScriptInstaller(
                scriptsDirectory: FileManager.default.temporaryDirectory,
                bundleScriptsDirectory: nil
            ),
            analytics: analytics
        )

        let ids = try await bridge.scanTrackIDs(timeout: .seconds(1)) { _, _, _ in "BATCH:0:0:G1:" }

        #expect(ids.isEmpty)
        #expect(await analytics.results == [
            InstrumentationResult(operation: .appleScriptFetchIDs, outcome: .succeeded),
        ])
    }

    @Test("Determination records genre, cache, and year boundaries exactly once")
    func determinationBoundaries() async throws {
        let analytics = InstrumentationAnalytics()
        let coordinator = await makeInstrumentationCoordinator(analytics: analytics)
        let target = instrumentationTrack(
            id: "T1",
            album: "Later Album",
            genre: nil,
            year: 1999,
            dateAdded: Date(timeIntervalSince1970: 200)
        )
        let artistTracks = [
            instrumentationTrack(
                id: "T2",
                album: "Earlier Album",
                genre: "Rock",
                year: 1999,
                dateAdded: Date(timeIntervalSince1970: 100)
            ),
            target,
        ]

        let changes = try await coordinator.updateTrack(
            target,
            albumTracks: [target],
            artistTracks: artistTracks,
            options: UpdateOptions(updateGenre: true, updateYear: true),
            dryRun: true
        )

        #expect(changes.contains { $0.changeType == .genreUpdate })
        #expect(changes.contains { $0.changeType == .yearUpdate })
        #expect(await analytics.results.map(\.operation) == [
            .genreDetermination,
            .albumYearCacheRead,
            .yearDetermination,
        ])
        #expect(await analytics.results.allSatisfy { $0.outcome == .succeeded && $0.duration >= .zero })
    }

    @Test("Reviewed application records one verified batch-write boundary")
    func reviewedBatchWrite() async throws {
        let analytics = InstrumentationAnalytics()
        let fixture = await makeCoordinator(analytics: analytics)
        let track = makeEditableTrack(id: "T1", genre: "Rock", year: 1999)
        let proposal = ProposedChange(
            track: track,
            changeType: .genreUpdate,
            oldValue: "Rock",
            newValue: "Metal",
            confidence: 90,
            source: "Library",
            isAccepted: true
        )

        let result = try await fixture.coordinator.applyAcceptedChanges(
            [proposal],
            progressHandler: ignoreAcceptedChangeProgress
        )

        #expect(result.entries.map(\.newGenre) == ["Metal"])
        #expect(await analytics.results == [
            InstrumentationResult(operation: .batchWrite, outcome: .succeeded),
        ])
    }

    @Test("Batch processing classifies its typed cancellation as cancelled")
    func batchCancellation() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AnalyticsBatch-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let analytics = InstrumentationAnalytics()
        let processor = await BatchProcessor(
            checkpointManager: CheckpointManager(directory: directory),
            featureGate: FeatureGate(fixedTier: .pro),
            analytics: analytics
        )

        await #expect(throws: BatchProcessorError.self) {
            try await processor.process(
                tracks: [instrumentationTrack(id: "T1")],
                operation: { _ in throw CancellationError() },
                progressHandler: ignoreAcceptedChangeProgress
            )
        }

        #expect(await analytics.results == [
            InstrumentationResult(operation: .batchProcess, outcome: .cancelled),
        ])
    }
}

private actor AnalyticsLibraryProvider: LibraryReadProvider {
    let snapshot: LibraryReadSnapshot

    init(snapshot: LibraryReadSnapshot) {
        self.snapshot = snapshot
    }

    func loadLibrarySnapshot(request _: LibraryReadRequest) async throws -> LibraryReadSnapshot {
        snapshot
    }
}

private struct InstrumentationResult: Equatable, Sendable {
    let operation: AnalyticsOperation
    let duration: Duration
    let outcome: AnalyticsOutcome

    init(
        operation: AnalyticsOperation,
        duration: Duration = .zero,
        outcome: AnalyticsOutcome
    ) {
        self.operation = operation
        self.duration = duration
        self.outcome = outcome
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.operation == rhs.operation && lhs.outcome == rhs.outcome
    }
}

private actor InstrumentationAnalytics: AnalyticsService {
    private(set) var results: [InstrumentationResult] = []

    func record(_ operation: AnalyticsOperation, duration: Duration, outcome: AnalyticsOutcome) {
        results.append(InstrumentationResult(operation: operation, duration: duration, outcome: outcome))
    }
}

private func instrumentationTrack(
    id: String,
    album: String = "Album",
    genre: String? = "Rock",
    year: Int? = 1999,
    dateAdded: Date? = nil
) -> Track {
    Track(
        id: id,
        name: "Song",
        artist: "Artist",
        album: album,
        genre: genre,
        year: year,
        dateAdded: dateAdded,
        trackStatus: nil
    )
}

private func makeInstrumentationCoordinator(
    analytics: any AnalyticsService
) async -> UpdateCoordinator {
    let api = MockAPIService(yearResult: YearResult(
        year: 2001,
        confidence: 90,
        yearScores: [2001: 90]
    ))
    let bridge = MockAppleScriptClient()
    let undo = UndoCoordinator(
        scriptBridge: bridge,
        directory: FileManager.default.temporaryDirectory
            .appendingPathComponent("AnalyticsCoordinator-\(UUID().uuidString)")
    )
    return UpdateCoordinator(
        dependencies: UpdateDependencies(
            apiOrchestrator: makeAPIOrchestrator(musicBrainz: api, discogs: api, appleMusic: api),
            scriptBridge: bridge,
            stores: .init(trackStore: MockTrackStore(), cache: MockCacheService()),
            undoCoordinator: undo,
            analytics: analytics
        ),
        genreDeterminator: GenreDeterminator(),
        yearDeterminator: YearDeterminator()
    )
}
