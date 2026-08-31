import Core
import Foundation
import Testing
@testable import Services

@Suite("Music.app observation conflicts")
struct MusicAppObservationConflictTests {
    @Test("Bulk metadata generation changes become observation conflicts")
    func translatesBulkMetadataGenerationChange() async throws {
        let databaseID = try #require(MusicDatabaseTrackID(rawValue: "1"))
        let generation = try #require(LibraryGeneration(sourceValue: "G1"))
        let census = try TrackIDCensus(ids: [databaseID], totalCount: 1, generation: generation)
        let detail = "Batch ID count does not match its range at offset 1"
        let reader = MusicAppObserver(source: ChangingMetadataObservationSource(census: census, detail: detail))

        do {
            _ = try await reader.observe(LibraryObservationRequest(
                scope: ProcessingScopeSnapshot.capture(
                    requestedTestArtists: [],
                    knownTrackCount: nil,
                    createdAt: Date(timeIntervalSince1970: 1_700_000_000),
                    reason: "observation conflict fixture"
                ),
                refresh: .fast,
                previous: .initial
            ))
            Issue.record("Expected the changed bulk snapshot to reject the observation")
        } catch let MusicAppObservationError.snapshotChanged(observedDetail) {
            #expect(observedDetail == detail)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }
}

private actor ChangingMetadataObservationSource: ObservationSource {
    private let census: TrackIDCensus
    private let detail: String

    init(census: TrackIDCensus, detail: String) {
        self.census = census
        self.detail = detail
    }

    func fetchCensus() -> TrackIDCensus {
        census
    }

    func fetchIdentitySnapshot() async throws -> LibraryIdentitySnapshot {
        Issue.record("Full-library observation must not fetch a separate identity snapshot")
        return LibraryIdentitySnapshot(census: census, rows: [])
    }

    func fetchProcessingMetadata(
        for _: [MusicDatabaseTrackID],
        scope _: ProcessingScopeSnapshot
    ) async throws -> [Track] {
        throw AppleScriptBridgeError.libraryChanged(detail: detail)
    }
}
