// AppleMusicSearchClientTests.swift — Unit tests for Apple Music catalog client
// Phase 4: API + Cache
//
// MusicKit requires an entitlement and running app context for catalog searches.
// Tests here verify non-MusicKit logic: protocol conformance, graceful behavior
// without authorization, and stub method returns. Integration tests with live
// MusicKit deferred to Phase 7 (launch testing).

import Foundation
import Testing
@testable import Core
@testable import Services

// MARK: - AppleMusicSearchClientTests

@Suite("AppleMusicSearchClient — Apple Music catalog search via MusicKit")
struct AppleMusicSearchClientTests {
    @Test("Client conforms to ExternalAPIService")
    func conformsToProtocol() {
        let client = AppleMusicSearchClient()
        #expect(client is any ExternalAPIService)
    }

    @Test("getAlbumYear returns empty or low-confidence result without entitlement")
    func albumYearWithoutEntitlement() async throws {
        let client = AppleMusicSearchClient()
        // In test context, MusicKit authorization is not available.
        // Client should handle this gracefully and return an empty result.
        let result = try await client.getAlbumYear(
            artist: "Test Artist",
            album: "Test Album",
            currentLibraryYear: nil,
            earliestTrackAddedYear: nil
        )
        // Without entitlement, expect empty or low-confidence result
        #expect(result.confidence <= 50)
    }

    @Test("getArtistActivityPeriod returns nil pair — MusicKit does not expose this")
    func artistActivityPeriodReturnsNil() async throws {
        let client = AppleMusicSearchClient()
        let (start, end) = try await client.getArtistActivityPeriod(
            normalizedArtist: "Test Artist"
        )
        #expect(start == nil)
        #expect(end == nil)
    }
}
