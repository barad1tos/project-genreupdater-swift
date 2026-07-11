import Core
import Foundation
import Services
import Testing
@testable import Genre_Updater

@Suite("Reports write recovery")
struct ReportsWriteTests {
    @Test("Unknown undo blocks retry until clearance")
    func unknownUndoBlocksRetry() async throws {
        let fixture = try await makeFixture()
        let entry = makeEntry()

        await #expect(throws: AppleScriptOutcomeError.self) {
            try await fixture.write.undo(entry, hasRunRecovery: false)
        }
        let recoveryID = try #require(await fixture.processor.recoveryHoldID())
        await #expect(throws: BatchProcessorError.self) {
            try await fixture.write.undo(entry, hasRunRecovery: false)
        }
        #expect(await fixture.client.writeCount == 1)

        try await fixture.processor.clearRecovery(batchID: recoveryID)
        await fixture.client.allowWrites()
        try await fixture.write.undo(entry, hasRunRecovery: false)
        #expect(await fixture.client.writeCount == 2)
    }

    @Test("Run recovery blocks session undo")
    func runRecoveryBlocksSession() async throws {
        let fixture = try await makeFixture()

        await #expect(throws: WriteAdmissionError.self) {
            try await fixture.write.undoSession([makeEntry()], hasRunRecovery: true)
        }
        #expect(await fixture.client.writeCount == 0)
    }

    @Test("Run recovery blocks CSV restore")
    func runRecoveryBlocksCSV() async throws {
        let fixture = try await makeFixture()
        let track = Track(id: "T1", name: "Track", artist: "Artist", album: "Album", year: 2000)
        let csv = "artist,name,album,id,year\nArtist,Track,Album,T1,1999"

        await #expect(throws: WriteAdmissionError.self) {
            _ = try await fixture.write.restoreYears(
                csv: csv,
                artist: "Artist",
                album: nil,
                tracks: [track],
                hasRunRecovery: true
            )
        }
        #expect(await fixture.client.writeCount == 0)
    }

    @MainActor
    private func makeFixture() async throws -> ReportsWriteFixture {
        let client = ReportsScriptClient()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ReportsWriteTests-\(UUID().uuidString)")
        let undo = UndoCoordinator(scriptBridge: client, directory: directory)
        let processor = BatchProcessor(
            checkpointManager: CheckpointManager(directory: directory),
            featureGate: FeatureGate(fixedTier: .pro)
        )
        let dependencies = AppDependencies(configurationLoader: { AppConfiguration() })
        dependencies.installTestWrites(TestWriteServices(
            batchProcessor: processor,
            undoCoordinator: undo
        ))
        return try ReportsWriteFixture(
            write: dependencies.makeReportsWrite(),
            processor: processor,
            client: client
        )
    }

    private func makeEntry() -> ChangeLogEntry {
        var entry = ChangeLogEntry(
            changeType: .genreUpdate,
            trackID: "T1",
            artist: "Artist",
            trackName: "Track",
            albumName: "Album"
        )
        entry.oldGenre = "Rock"
        entry.newGenre = "Metal"
        return entry
    }
}

private struct ReportsWriteFixture {
    let write: ReportsWrite
    let processor: BatchProcessor
    let client: ReportsScriptClient
}

private actor ReportsScriptClient: AppleScriptClient {
    private var shouldReturnUnknown = true
    private(set) var writeCount = 0

    func initialize() async throws {
        // This in-memory client requires no setup.
    }

    func runScript(name _: String, arguments _: [String], timeout _: Duration?) async throws -> String? {
        nil
    }

    func fetchTracksByIDs(_ trackIDs: [String], batchSize _: Int, timeout _: Duration?) async throws -> [Track] {
        trackIDs.map { Track(id: $0, name: "Track", artist: "Artist", album: "Album") }
    }

    func fetchAllTrackIDs(timeout _: Duration?) async throws -> [String] {
        ["T1"]
    }

    func updateTrackProperty(trackID _: String, property _: String, value _: String) async throws
        -> AppleScriptWriteResult {
        writeCount += 1
        if shouldReturnUnknown {
            throw AppleScriptOutcomeError(scriptName: "update_property", duration: .seconds(3))
        }
        return .changed
    }

    func batchUpdateTracks(_: [(trackID: String, property: String, value: String)]) async throws {
        // Reports tests only exercise single-track writes.
    }

    func allowWrites() {
        shouldReturnUnknown = false
    }
}
