import Foundation
import Testing
@testable import Core

@Suite("Track.fromAppleScriptOutput — AppleScript field parsing")
struct TrackAppleScriptTests {
    /// ASCII Record Separator used between fields.
    private let fs = String(Track.fieldSeparator)

    // MARK: - Full Record Parsing

    @Test("Parses full 12-field AppleScript record")
    func parseFullRecord() {
        let fields = [
            "12345", // [0] id
            "Enter Sandman", // [1] name
            "Metallica", // [2] artist
            "Metallica", // [3] albumArtist
            "Metallica (Remastered)", // [4] album
            "Metal", // [5] genre
            "2024-02-21 13:45:00", // [6] dateAdded
            "2024-03-01 10:00:00", // [7] modDate
            "matched", // [8] status
            "1991", // [9] year
            "1991", // [10] releaseYear
            "", // [11] empty placeholder
        ]
        let raw = fields.joined(separator: fs)
        let track = Track.fromAppleScriptOutput(raw)

        #expect(track != nil)
        #expect(track?.id == "12345")
        #expect(track?.name == "Enter Sandman")
        #expect(track?.artist == "Metallica")
        #expect(track?.albumArtist == "Metallica")
        #expect(track?.album == "Metallica (Remastered)")
        #expect(track?.genre == "Metal")
        #expect(track?.year == 1991)
        #expect(track?.releaseYear == 1991)
        #expect(track?.trackStatus == "matched")
        #expect(track?.dateAdded != nil)
        #expect(track?.lastModified != nil)
    }

    @Test("AppleScript parsing records AppleScript ID as mutation metadata")
    func appleScriptParsingRecordsAppleScriptIDAsMutationMetadata() throws {
        let fieldSeparator = String(Track.fieldSeparator)
        let raw = [
            "AS-123",
            "Battery",
            "Metallica",
            "Metallica",
            "Master of Puppets",
            "Metal",
            "2024-01-02 03:04:05",
            "2024-01-03 03:04:05",
            "local only",
            "1986",
            "1986",
            "",
        ].joined(separator: fieldSeparator)

        let track = try #require(Track.fromAppleScriptOutput(raw))

        #expect(track.id == "AS-123")
        #expect(track.appleScriptID == "AS-123")
    }

    // MARK: - Minimal Record

    @Test("Parses minimal 5-field record (id, name, artist, albumArtist, album)")
    func parseMinimalRecord() {
        let raw = ["99999", "Song", "Artist", "Album Artist", "Album"].joined(separator: fs)
        let track = Track.fromAppleScriptOutput(raw)

        #expect(track != nil)
        #expect(track?.id == "99999")
        #expect(track?.name == "Song")
        #expect(track?.artist == "Artist")
        #expect(track?.albumArtist == "Album Artist")
        #expect(track?.album == "Album")
        #expect(track?.genre == nil)
        #expect(track?.year == nil)
        #expect(track?.releaseYear == nil)
    }

    @Test("Rejects record with fewer than 5 fields")
    func rejectTooFewFields() {
        let raw = ["12345", "Song", "Artist", "AlbumArtist"].joined(separator: fs)
        #expect(Track.fromAppleScriptOutput(raw) == nil)
    }

    @Test("Rejects full-width record with missing AppleScript ID")
    func rejectMissingAppleScriptID() {
        let raw = [
            "", "Song", "Artist", "AlbumArtist", "Album",
            "Rock", "2024-01-01 00:00:00", "2024-01-02 00:00:00",
            "matched", "2024", "2024", "",
        ].joined(separator: fs)

        #expect(Track.fromAppleScriptOutput(raw) == nil)
    }

    // MARK: - Empty Optional Fields

    @Test("Empty optional fields parse as nil")
    func emptyOptionalFields() {
        let fields = [
            "12345", // id
            "Song", // name
            "Artist", // artist
            "", // albumArtist — empty
            "Album", // album
            "", // genre — empty
            "", // dateAdded — empty
            "", // modDate — empty
            "", // status — empty
            "", // year — empty string, not a number
            "", // releaseYear — empty
            "", // placeholder
        ]
        let raw = fields.joined(separator: fs)
        let track = Track.fromAppleScriptOutput(raw)

        #expect(track != nil)
        #expect(track?.albumArtist == nil)
        #expect(track?.genre == nil)
        #expect(track?.dateAdded == nil)
        #expect(track?.lastModified == nil)
        #expect(track?.trackStatus == nil)
        #expect(track?.year == nil)
        #expect(track?.releaseYear == nil)
    }

    // MARK: - Field Order Verification

    @Test("Field order matches AppleScript serializeTrack output")
    func fieldOrderMatchesAppleScript() throws {
        // AppleScript: {track_id, track_name, track_artist, album_artist, track_album, track_genre, ...}
        // albumArtist is at [3], album at [4] — NOT the other way around
        let fields = [
            "ID1", "Name1", "ArtistX", "AlbumArtistY", "AlbumZ",
            "Rock", "2024-01-01 00:00:00", "2024-06-15 12:30:00",
            "subscription", "2020", "2019", "",
        ]
        let raw = fields.joined(separator: fs)
        let track = try #require(Track.fromAppleScriptOutput(raw))

        #expect(track.artist == "ArtistX")
        #expect(track.albumArtist == "AlbumArtistY")
        #expect(track.album == "AlbumZ")
        #expect(track.genre == "Rock")
        #expect(track.year == 2020)
        #expect(track.releaseYear == 2019)
    }

    // MARK: - Date Parsing

    @Test("Parses compact date format from AppleScript formatDate handler")
    func parseCompactDate() throws {
        let fields = [
            "1", "Song", "Artist", "", "Album",
            "", "2024-02-21 13:45:00", "2024-03-01 10:00:00",
            "", "", "", "",
        ]
        let raw = fields.joined(separator: fs)
        let track = try #require(Track.fromAppleScriptOutput(raw))

        #expect(track.dateAdded != nil)
        #expect(track.lastModified != nil)

        let calendar = Calendar(identifier: .gregorian)
        let addedComponents = try calendar.dateComponents([.year, .month, .day], from: #require(track.dateAdded))
        #expect(addedComponents.year == 2024)
        #expect(addedComponents.month == 2)
        #expect(addedComponents.day == 21)
    }

    // MARK: - Year Parsing

    @Test("Parses valid year")
    func parseValidYear() {
        let fields = [
            "1", "Song", "Artist", "", "Album",
            "", "", "", "", "2023", "", "",
        ]
        let raw = fields.joined(separator: fs)
        let track = Track.fromAppleScriptOutput(raw)

        #expect(track?.year == 2023)
    }

    @Test("Zero year parses as 0 (callers decide validity)")
    func parseZeroYear() {
        let fields = [
            "1", "Song", "Artist", "", "Album",
            "", "", "", "", "0", "", "",
        ]
        let raw = fields.joined(separator: fs)
        let track = Track.fromAppleScriptOutput(raw)

        #expect(track?.year == 0)
    }

    @Test("Non-numeric year parses as nil")
    func parseNonNumericYear() {
        let fields = [
            "1", "Song", "Artist", "", "Album",
            "", "", "", "", "unknown", "", "",
        ]
        let raw = fields.joined(separator: fs)
        let track = Track.fromAppleScriptOutput(raw)

        #expect(track?.year == nil)
    }

    // MARK: - Release Year

    @Test("Parses releaseYear independently from year")
    func parseReleaseYear() {
        let fields = [
            "1", "Song", "Artist", "", "Album",
            "", "", "", "", "2023", "2020", "",
        ]
        let raw = fields.joined(separator: fs)
        let track = Track.fromAppleScriptOutput(raw)

        #expect(track?.year == 2023)
        #expect(track?.releaseYear == 2020)
    }

    @Test("Parses releaseYear from AppleScript date field")
    func parseReleaseYearDateField() {
        let fields = [
            "1", "Song", "Artist", "", "Album",
            "", "", "", "", "2023", "2001-07-24 00:00:00", "",
        ]
        let raw = fields.joined(separator: fs)
        let track = Track.fromAppleScriptOutput(raw)

        #expect(track?.year == 2023)
        #expect(track?.releaseYear == 2001)
    }

    @Test("Maps fetch script release field variants to the same Swift fields")
    func mapsFetchScriptReleaseFieldVariants() throws {
        let baseFields = [
            "48291", "Nothing Else Matters", "Metallica", "Metallica",
            "Metallica (Remastered Deluxe Box Set)", "Metal",
            "2019-11-03 14:22:10", "2024-01-15 09:30:45",
            "matched", "1991",
        ]
        let fetchTracksRecord = (baseFields + ["1991", ""]).joined(separator: fs)
        let fetchByIDsRecord = (baseFields + ["1991-08-12 00:00:00", ""]).joined(separator: fs)

        let fetchTracksTrack = try #require(Track.fromAppleScriptOutput(fetchTracksRecord))
        let fetchByIDsTrack = try #require(Track.fromAppleScriptOutput(fetchByIDsRecord))

        for track in [fetchTracksTrack, fetchByIDsTrack] {
            #expect(track.id == "48291")
            #expect(track.name == "Nothing Else Matters")
            #expect(track.artist == "Metallica")
            #expect(track.albumArtist == "Metallica")
            #expect(track.album == "Metallica (Remastered Deluxe Box Set)")
            #expect(track.genre == "Metal")
            #expect(track.year == 1991)
            #expect(track.releaseYear == 1991)
            #expect(track.trackStatus == "matched")
            #expect(track.dateAdded != nil)
            #expect(track.lastModified != nil)
        }
    }

    // MARK: - Round-Trip

    @Test("Known AppleScript output produces expected Track")
    func roundTrip() throws {
        // Simulated output from fetch_tracks.applescript for a real track
        let raw = [
            "48291", "Nothing Else Matters", "Metallica", "Metallica",
            "Metallica (Remastered Deluxe Box Set)", "Metal",
            "2019-11-03 14:22:10", "2024-01-15 09:30:45",
            "matched", "1991", "1991", "",
        ].joined(separator: fs)

        let track = try #require(Track.fromAppleScriptOutput(raw))

        #expect(track.id == "48291")
        #expect(track.name == "Nothing Else Matters")
        #expect(track.artist == "Metallica")
        #expect(track.albumArtist == "Metallica")
        #expect(track.album == "Metallica (Remastered Deluxe Box Set)")
        #expect(track.genre == "Metal")
        #expect(track.year == 1991)
        #expect(track.releaseYear == 1991)
        #expect(track.trackStatus == "matched")
    }

    @Test("Track with parentheses in name is preserved (no sanitizeScriptCode)")
    func parenthesesPreserved() {
        let raw = [
            "1", "Song (Live)", "Artist", "", "Album (Deluxe Edition)",
            "", "", "", "", "", "", "",
        ].joined(separator: fs)
        let track = Track.fromAppleScriptOutput(raw)

        #expect(track?.name == "Song (Live)")
        #expect(track?.album == "Album (Deluxe Edition)")
    }
}
