// AppleMusicSearchClientTests.swift — Unit tests for Apple Music catalog client
// Phase 4: API + Cache
//
// MusicKit requires an entitlement and running app context for catalog searches.
// Unit tests here verify only non-MusicKit logic. Catalog search coverage lives
// in the app-hosted IntegrationTests target.

import Testing
@testable import Core
@testable import Services

// MARK: - AppleMusicSearchClientTests

@Suite("AppleMusicSearchClient — Apple Music catalog search via MusicKit")
struct AppleMusicSearchClientTests {
    @Test("Client conforms to ExternalAPIService")
    func conformsToProtocol() {
        requireExternalAPIService(AppleMusicSearchClient())
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

    private func requireExternalAPIService(_ service: any ExternalAPIService) {
        _ = service
    }
}
