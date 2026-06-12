// MusicLibraryIntegrationTests.swift — Integration tests with real MusicKit library
//
// These tests exercise MusicLibraryReader against the real Music.app library.
// They are READ-ONLY — no writes to Music.app.
//
// Requirements:
// - Music.app must be running with at least 1 track
// - MusicKit authorization must be granted
// - Run locally only (not CI) — uses XCTSkipUnless for graceful degradation

import Core
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

    // MARK: - Fetch Tests

    func testFetchAllTracksReturnsNonEmpty() async throws {
        let tracks = try await reader.fetchAllTracks()

        XCTAssertFalse(
            tracks.isEmpty,
            "Expected at least 1 track in the Music library, but fetchAllTracks() returned empty. "
                + "Add at least one song to Music.app before running integration tests."
        )
    }

    func testTracksHaveValidFields() async throws {
        let tracks = try await reader.fetchAllTracks()
        try XCTSkipIf(tracks.isEmpty, "No tracks in library — cannot validate fields")

        for track in tracks.prefix(50) {
            XCTAssertFalse(
                track.name.isEmpty,
                "Track \(track.id) has an empty name"
            )
            XCTAssertFalse(
                track.artist.isEmpty,
                "Track \(track.id) has an empty artist"
            )
            XCTAssertFalse(
                track.id.isEmpty,
                "Track has an empty persistent ID"
            )
        }
    }

    func testTrackCountMatchesArray() async throws {
        let tracks = try await reader.fetchAllTracks()
        let count = try await reader.trackCount()

        XCTAssertEqual(
            count,
            tracks.count,
            "trackCount() (\(count)) should match fetchAllTracks().count (\(tracks.count))"
        )
    }

    func testTracksHaveStableIDs() async throws {
        let firstFetch = try await reader.fetchAllTracks()
        try XCTSkipIf(firstFetch.isEmpty, "No tracks in library — cannot verify ID stability")

        let secondFetch = try await reader.fetchAllTracks()

        let firstIDs = Set(firstFetch.map(\.id))
        let secondIDs = Set(secondFetch.map(\.id))

        XCTAssertEqual(
            firstIDs,
            secondIDs,
            "Two consecutive fetches should return the same track IDs"
        )
    }

    // MARK: - Filter Tests (Static — No MusicKit Required)

    func testFilterByTestArtistsWithEmptyList() {
        let tracks = makeSampleTracks()
        let filtered = MusicLibraryReader.filterByTestArtists(tracks, testArtists: [])

        XCTAssertEqual(
            filtered.count,
            tracks.count,
            "Empty testArtists should return all tracks unfiltered"
        )
    }

    func testFilterByTestArtistsMatchesCaseInsensitive() {
        let tracks = makeSampleTracks()
        let filtered = MusicLibraryReader.filterByTestArtists(
            tracks,
            testArtists: ["the beatles"]
        )

        XCTAssertEqual(filtered.count, 1)
        XCTAssertEqual(filtered.first?.artist, "The Beatles")
    }

    func testFilterByTestArtistsMultipleArtists() {
        let tracks = makeSampleTracks()
        let filtered = MusicLibraryReader.filterByTestArtists(
            tracks,
            testArtists: ["The Beatles", "Pink Floyd"]
        )

        XCTAssertEqual(filtered.count, 2)
        let artists = Set(filtered.map(\.artist))
        XCTAssertTrue(artists.contains("The Beatles"))
        XCTAssertTrue(artists.contains("Pink Floyd"))
    }

    func testFilterByTestArtistsNoMatchReturnsEmpty() {
        let tracks = makeSampleTracks()
        let filtered = MusicLibraryReader.filterByTestArtists(
            tracks,
            testArtists: ["Nonexistent Artist"]
        )

        XCTAssertTrue(
            filtered.isEmpty,
            "Filtering by a non-matching artist should return an empty array"
        )
    }

    func testFilterByTestArtistsUsesEffectiveArtist() {
        let track = Core.Track(
            id: "100",
            name: "Come Together",
            artist: "John Lennon",
            album: "Abbey Road",
            albumArtist: "The Beatles"
        )
        let filtered = MusicLibraryReader.filterByTestArtists(
            [track],
            testArtists: ["The Beatles"]
        )

        XCTAssertEqual(
            filtered.count,
            1,
            "Filter should match on effectiveArtist (albumArtist) not just artist"
        )
    }
}

// MARK: - Test Helpers

private func makeSampleTracks() -> [Core.Track] {
    [
        Core.Track(id: "1", name: "Hey Jude", artist: "The Beatles", album: "Past Masters"),
        Core.Track(id: "2", name: "Bohemian Rhapsody", artist: "Queen", album: "A Night at the Opera"),
        Core.Track(id: "3", name: "Comfortably Numb", artist: "Pink Floyd", album: "The Wall"),
    ]
}
