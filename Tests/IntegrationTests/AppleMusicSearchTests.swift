// AppleMusicSearchTests.swift — App-hosted MusicKit catalog tests
//
// These tests exercise Apple Music catalog search through MusicKit in the
// GenreUpdater app test host. They are READ-ONLY and skip unless MusicKit access
// is already authorized.

import MusicKit
import Services
import XCTest

// MARK: - AppleMusic Search Tests

final class AppleMusicSearchTests: XCTestCase {
    override func setUp() async throws {
        try await super.setUp()

        try XCTSkipUnless(
            MusicAuthorization.currentStatus == .authorized,
            "MusicKit authorization not granted — skipping Apple Music catalog tests. "
                + "Grant access in System Settings > Privacy & Security > Media & Apple Music."
        )
    }

    func testAlbumYearSearchDoesNotCrashInAppHost() async throws {
        let client = AppleMusicSearchClient()

        let result = try await client.getAlbumYear(
            artist: "Daft Punk",
            album: "Random Access Memories",
            currentLibraryYear: nil,
            earliestTrackAddedYear: nil
        )

        XCTAssertGreaterThanOrEqual(result.confidence, 0)
        XCTAssertLessThanOrEqual(result.confidence, 100)
    }
}
