import Foundation
import Testing
@testable import Core

@Suite("Track — computed properties, Codable round-trip, and extensions")
struct TrackModelTests {
    // MARK: - effectiveArtist

    @Test("effectiveArtist returns albumArtist when present and non-empty")
    func effectiveArtistPrefersAlbumArtist() {
        let track = Track(
            id: "1", name: "Song", artist: "Solo Artist", album: "Album",
            albumArtist: "Band Name"
        )
        #expect(track.effectiveArtist == "Band Name")
    }

    @Test("effectiveArtist falls back to artist when albumArtist is nil")
    func effectiveArtistFallsBackWhenNil() {
        let track = Track(
            id: "1", name: "Song", artist: "Solo Artist", album: "Album",
            albumArtist: nil
        )
        #expect(track.effectiveArtist == "Solo Artist")
    }

    @Test("effectiveArtist falls back to artist when albumArtist is empty")
    func effectiveArtistFallsBackWhenEmpty() {
        let track = Track(
            id: "1", name: "Song", artist: "Solo Artist", album: "Album",
            albumArtist: ""
        )
        #expect(track.effectiveArtist == "Solo Artist")
    }

    // MARK: - hasBeenProcessed

    @Test("hasBeenProcessed is true when yearSetByMGU is set")
    func hasBeenProcessedWithYearSet() {
        let track = Track(
            id: "1", name: "Song", artist: "Artist", album: "Album",
            yearSetByMGU: 2020
        )
        #expect(track.hasBeenProcessed == true)
    }

    @Test("hasBeenProcessed is true when yearBeforeMGU is set")
    func hasBeenProcessedWithYearBefore() {
        let track = Track(
            id: "1", name: "Song", artist: "Artist", album: "Album",
            yearBeforeMGU: 1995
        )
        #expect(track.hasBeenProcessed == true)
    }

    @Test("hasBeenProcessed is true when both MGU year fields are set")
    func hasBeenProcessedWithBothSet() {
        let track = Track(
            id: "1", name: "Song", artist: "Artist", album: "Album",
            yearBeforeMGU: 1995, yearSetByMGU: 2020
        )
        #expect(track.hasBeenProcessed == true)
    }

    @Test("hasBeenProcessed is false when both MGU year fields are nil")
    func hasBeenProcessedFalseWhenBothNil() {
        let track = Track(id: "1", name: "Song", artist: "Artist", album: "Album")
        #expect(track.hasBeenProcessed == false)
    }

    // MARK: - kind

    @Test(
        "kind maps trackStatus via normalizeTrackStatus",
        arguments: [
            ("subscription", TrackKind.subscription),
            ("prerelease", TrackKind.prerelease),
            ("matched", TrackKind.matched),
            ("purchased", TrackKind.purchased),
            ("uploaded", TrackKind.uploaded),
            ("downloaded", TrackKind.downloaded),
            ("local only", TrackKind.localOnly),
            ("no longer available", TrackKind.noLongerAvailable),
        ] as [(String, TrackKind)]
    )
    func kindMapsStatus(status: String, expected: TrackKind) {
        let track = Track(
            id: "1", name: "Song", artist: "Artist", album: "Album",
            trackStatus: status
        )
        #expect(track.kind == expected)
    }

    @Test("kind is nil when trackStatus is nil")
    func kindIsNilForNilStatus() {
        let track = Track(id: "1", name: "Song", artist: "Artist", album: "Album")
        #expect(track.kind == nil)
    }

    @Test("kind is nil for unrecognized trackStatus")
    func kindIsNilForUnrecognizedStatus() {
        let track = Track(
            id: "1", name: "Song", artist: "Artist", album: "Album",
            trackStatus: "unknown_status"
        )
        #expect(track.kind == nil)
    }

    // MARK: - canEdit

    @Test("canEdit is true for nil status (CRITICAL: nil = available)")
    func canEditTrueForNilStatus() {
        let track = Track(id: "1", name: "Song", artist: "Artist", album: "Album")
        #expect(track.canEdit == true)
    }

    @Test("canEdit is false for prerelease status")
    func canEditFalseForPrerelease() {
        let track = Track(
            id: "1", name: "Song", artist: "Artist", album: "Album",
            trackStatus: "prerelease"
        )
        #expect(track.canEdit == false)
    }

    @Test("canEdit is false for unavailable status")
    func canEditFalseForUnavailable() {
        let track = Track(
            id: "1", name: "Song", artist: "Artist", album: "Album",
            trackStatus: "no longer available"
        )
        #expect(track.canEdit == false)
    }

    @Test(
        "canEdit is true for writable statuses",
        arguments: ["subscription", "matched", "purchased", "uploaded", "downloaded", "local only"]
    )
    func canEditTrueForNonPrerelease(status: String) {
        let track = Track(
            id: "1", name: "Song", artist: "Artist", album: "Album",
            trackStatus: status
        )
        #expect(track.canEdit == true)
    }

    @Test("canEdit is true for unrecognized status (falls through to nil kind)")
    func canEditTrueForUnrecognizedStatus() {
        let track = Track(
            id: "1", name: "Song", artist: "Artist", album: "Album",
            trackStatus: "something_new"
        )
        #expect(track.canEdit == true)
    }

    // MARK: - Codable Round-Trip

    @Test("Track Codable round-trip preserves all 16 fields")
    func codableRoundTrip() throws {
        let dateAdded = Date(timeIntervalSince1970: 1_600_000_000)
        let lastModified = Date(timeIntervalSince1970: 1_700_000_000)

        let original = Track(
            id: "track-42",
            name: "Nothing Else Matters",
            artist: "Metallica",
            album: "Metallica (Remastered)",
            genre: "Metal",
            year: 1991,
            dateAdded: dateAdded,
            lastModified: lastModified,
            trackStatus: "matched",
            originalArtist: "Metallica (Original)",
            originalAlbum: "Metallica",
            yearBeforeMGU: 0,
            yearSetByMGU: 1991,
            releaseYear: 1991,
            originalPosition: 7,
            albumArtist: "Metallica"
        )

        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        let data = try encoder.encode(original)
        let decoded = try decoder.decode(Track.self, from: data)

        #expect(decoded.id == original.id)
        #expect(decoded.name == original.name)
        #expect(decoded.artist == original.artist)
        #expect(decoded.album == original.album)
        #expect(decoded.genre == original.genre)
        #expect(decoded.year == original.year)
        #expect(decoded.dateAdded == original.dateAdded)
        #expect(decoded.lastModified == original.lastModified)
        #expect(decoded.trackStatus == original.trackStatus)
        #expect(decoded.originalArtist == original.originalArtist)
        #expect(decoded.originalAlbum == original.originalAlbum)
        #expect(decoded.yearBeforeMGU == original.yearBeforeMGU)
        #expect(decoded.yearSetByMGU == original.yearSetByMGU)
        #expect(decoded.releaseYear == original.releaseYear)
        #expect(decoded.originalPosition == original.originalPosition)
        #expect(decoded.albumArtist == original.albumArtist)
    }
}

// MARK: - ChangeLogEntry Tests

@Suite("ChangeLogEntry — init, round-trip, and ChangeType raw values")
struct ChangeLogEntryTests {
    @Test("Default init generates non-nil UUID and recent timestamp")
    func defaultInitGeneratesIDAndTimestamp() {
        let before = Date.now
        let entry = ChangeLogEntry(
            changeType: .genreUpdate, trackID: "1", artist: "Artist"
        )
        let after = Date.now

        #expect(entry.id != UUID(uuidString: "00000000-0000-0000-0000-000000000000"))
        #expect(entry.timestamp >= before)
        #expect(entry.timestamp <= after)
    }

    @Test("Round-trip init preserves specific id and timestamp")
    func roundTripInitPreservesIDAndTimestamp() throws {
        let specificID = try #require(UUID(uuidString: "A1B2C3D4-E5F6-7890-ABCD-EF1234567890"))
        let specificDate = Date(timeIntervalSince1970: 1_000_000)

        let entry = ChangeLogEntry(
            id: specificID,
            timestamp: specificDate,
            changeType: .yearUpdate,
            trackID: "42",
            artist: "Artist"
        )

        #expect(entry.id == specificID)
        #expect(entry.timestamp == specificDate)
        #expect(entry.changeType == .yearUpdate)
        #expect(entry.trackID == "42")
    }

    @Test(
        "ChangeType raw values match expected strings",
        arguments: [
            (ChangeType.genreUpdate, "genre_update"),
            (ChangeType.yearUpdate, "year_update"),
            (ChangeType.trackCleaning, "track_cleaning"),
            (ChangeType.albumCleaning, "album_cleaning"),
            (ChangeType.artistRename, "artist_rename"),
            (ChangeType.yearRevert, "year_revert"),
        ] as [(ChangeType, String)]
    )
    func changeTypeRawValues(changeType: ChangeType, expectedRawValue: String) {
        #expect(changeType.rawValue == expectedRawValue)
    }

    @Test("ChangeType has exactly 6 cases")
    func changeTypeCaseCount() {
        #expect(ChangeType.allCases.count == 6)
    }
}

// MARK: - Extension Tests

@Suite("String.nilIfEmpty and Collection[safe:]")
struct TrackExtensionTests {
    @Test("nilIfEmpty returns nil for empty string")
    func nilIfEmptyReturnsNilForEmpty() {
        #expect("".nilIfEmpty == nil)
    }

    @Test("nilIfEmpty returns self for non-empty string")
    func nilIfEmptyReturnsSelfForNonEmpty() {
        #expect("hello".nilIfEmpty == "hello")
    }

    @Test("Collection safe subscript returns element for valid index")
    func safeSubscriptReturnsElement() {
        let array = ["a", "b", "c"]
        #expect(array[safe: 0] == "a")
        #expect(array[safe: 1] == "b")
        #expect(array[safe: 2] == "c")
    }

    @Test("Collection safe subscript returns nil for out-of-bounds index")
    func safeSubscriptReturnsNilForOutOfBounds() {
        let array = ["a", "b", "c"]
        #expect(array[safe: 3] == nil)
        #expect(array[safe: -1] == nil)
        #expect(array[safe: 100] == nil)
    }

    @Test("Collection safe subscript returns nil for empty collection")
    func safeSubscriptReturnsNilForEmptyCollection() {
        let array: [String] = []
        #expect(array[safe: 0] == nil)
    }
}
