// MusicLibraryIntegrationTests.swift — Integration tests with real MusicKit library
//
// These tests exercise MusicLibraryReader against the real Music.app library.
// They are READ-ONLY — no writes to Music.app.
//
// Requirements:
// - Music.app must be running with at least 1 track
// - MusicKit authorization must be granted
// - Run locally only (not CI) — uses XCTSkipUnless for graceful degradation

import MusicKit
import Services
import XCTest

// MARK: - MusicKit Authorization Helper

/// Check whether MusicKit access has already been authorized.
///
/// Returns `true` only when status is `.authorized`. This avoids
/// triggering the system prompt during test runs — if authorization
/// hasn't been granted, the test is skipped instead.
private func isMusicKitAuthorized() -> Bool {
    MusicAuthorization.currentStatus == .authorized
}

// MARK: - MusicLibrary Integration Tests

final class MusicLibraryIntegrationTests: XCTestCase {
    private var reader: MusicLibraryReader!

    override func setUp() async throws {
        try await super.setUp()

        try XCTSkipUnless(
            isMusicKitAuthorized(),
            "MusicKit authorization not granted — skipping integration tests. "
                + "Grant access in System Settings > Privacy & Security > Media & Apple Music."
        )

        reader = MusicLibraryReader()
    }

    override func tearDown() async throws {
        reader = nil
        try await super.tearDown()
    }

    // MARK: - Catalog Tests

    func testCatalogIsNotEmpty() async throws {
        let snapshot = try await reader.loadCatalog(testArtists: [])

        XCTAssertFalse(
            snapshot.tracks.isEmpty,
            "Expected at least 1 track in the Music library, but loadCatalog(testArtists:) returned empty. "
                + "Add at least one song to Music.app before running integration tests."
        )
    }

    func testCatalogFieldsAreValid() async throws {
        let tracks = try await reader.loadCatalog(testArtists: []).tracks
        try XCTSkipIf(tracks.isEmpty, "No tracks in library — cannot validate fields")

        for track in tracks.prefix(50) {
            XCTAssertFalse(
                track.title.isEmpty,
                "Track \(track.id.displayValue) has an empty title"
            )
            XCTAssertFalse(
                track.artist.isEmpty,
                "Track \(track.id.displayValue) has an empty artist"
            )
            XCTAssertFalse(
                track.id.displayValue.isEmpty,
                "Catalog track has an empty MusicKit ID"
            )
        }
    }

    func testRawCountCoversSnapshot() async throws {
        let snapshot = try await reader.loadCatalog(testArtists: [])
        let count = try await reader.trackCount()

        XCTAssertGreaterThan(
            count,
            0,
            "trackCount() should report at least one raw MusicKit row for a non-empty library"
        )
        XCTAssertGreaterThanOrEqual(
            count,
            snapshot.tracks.count,
            "trackCount() (\(count)) must cover the deduplicated catalog snapshot (\(snapshot.tracks.count))"
        )
    }

    func testCatalogIDsAreStable() async throws {
        let firstSnapshot = try await reader.loadCatalog(testArtists: [])
        try XCTSkipIf(firstSnapshot.tracks.isEmpty, "No tracks in library — cannot verify ID stability")

        let secondSnapshot = try await reader.loadCatalog(testArtists: [])

        let firstIDs = Set(firstSnapshot.tracks.map(\.id.displayValue))
        let secondIDs = Set(secondSnapshot.tracks.map(\.id.displayValue))

        XCTAssertEqual(
            firstIDs,
            secondIDs,
            "Two consecutive fetches should return the same track IDs"
        )
    }
}
