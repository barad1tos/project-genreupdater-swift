// PersistenceModelTests.swift — Unit tests for SwiftData persistence models
// Task A7: PersistedTrack, PersistedChangeLogEntry, ModelContainerFactory

import Foundation
import SwiftData
import Testing
@testable import Core
@testable import Services

// MARK: - PersistedTrack Tests

@Suite("PersistedTrack — domain model mapping")
struct PersistedTrackTests {
    private let fixedDate = Date(timeIntervalSince1970: 1_700_000_000)

    private func sampleTrack() -> Core.Track {
        Core.Track(
            id: "T1",
            name: "Song",
            artist: "Artist",
            album: "Album",
            genre: "Rock",
            year: 2020,
            dateAdded: fixedDate,
            trackStatus: "matched",
            releaseYear: 2019,
            albumArtist: "AlbumArtist"
        )
    }

    @Test("init(from:) maps all fields from Core.Track")
    func initFromTrackMapsAllFields() {
        let track = sampleTrack()
        let persisted = PersistedTrack(from: track)

        #expect(persisted.trackID == "T1")
        #expect(persisted.name == "Song")
        #expect(persisted.artist == "Artist")
        #expect(persisted.album == "Album")
        #expect(persisted.genre == "Rock")
        #expect(persisted.year == 2020)
        #expect(persisted.dateAdded == fixedDate)
        #expect(persisted.albumArtist == "AlbumArtist")
        #expect(persisted.trackStatus == "matched")
        #expect(persisted.releaseYear == 2019)
        #expect(persisted.genreUpdated == false)
        #expect(persisted.yearUpdated == false)
        #expect(persisted.processedDate == nil)
    }

    @Test("init(from:) handles nil optional fields")
    func initFromTrackHandlesNils() {
        let track = Core.Track(id: "T2", name: "Minimal", artist: "A", album: "B")
        let persisted = PersistedTrack(from: track)

        #expect(persisted.genre == nil)
        #expect(persisted.year == nil)
        #expect(persisted.dateAdded == nil)
        #expect(persisted.albumArtist == nil)
        #expect(persisted.trackStatus == nil)
        #expect(persisted.releaseYear == nil)
    }

    @Test("toTrack() converts back to matching domain Track")
    func toTrackConvertsBack() {
        let persisted = PersistedTrack(from: sampleTrack())
        let result = persisted.toTrack()

        #expect(result.id == "T1")
        #expect(result.name == "Song")
        #expect(result.artist == "Artist")
        #expect(result.album == "Album")
        #expect(result.genre == "Rock")
        #expect(result.year == 2020)
        #expect(result.dateAdded == fixedDate)
        #expect(result.albumArtist == "AlbumArtist")
        #expect(result.trackStatus == "matched")
        #expect(result.releaseYear == 2019)
    }

    @Test("Round-trip Track -> PersistedTrack -> Track preserves all mapped fields")
    func roundTripPreservesFields() {
        let original = sampleTrack()
        let roundTripped = PersistedTrack(from: original).toTrack()

        #expect(roundTripped.id == original.id)
        #expect(roundTripped.name == original.name)
        #expect(roundTripped.artist == original.artist)
        #expect(roundTripped.album == original.album)
        #expect(roundTripped.genre == original.genre)
        #expect(roundTripped.year == original.year)
        #expect(roundTripped.dateAdded == original.dateAdded)
        #expect(roundTripped.albumArtist == original.albumArtist)
        #expect(roundTripped.trackStatus == original.trackStatus)
        #expect(roundTripped.releaseYear == original.releaseYear)
    }

    @Test("update(from:) updates mutable fields but preserves processing state")
    func updatePreservesProcessingState() {
        let persisted = PersistedTrack(from: sampleTrack())

        // Simulate processing
        persisted.genreUpdated = true
        persisted.yearUpdated = true
        let processedAt = Date(timeIntervalSince1970: 1_700_100_000)
        persisted.processedDate = processedAt
        persisted.lastError = "some error"

        // Update from a new version of the same track
        let newTrack = Core.Track(
            id: "T1",
            name: "New Song",
            artist: "New Artist",
            album: "New Album",
            genre: "Pop",
            year: 2025,
            trackStatus: "uploaded",
            releaseYear: 2024,
            albumArtist: "New AlbumArtist"
        )
        persisted.update(from: newTrack)

        // Mutable fields updated
        #expect(persisted.name == "New Song")
        #expect(persisted.artist == "New Artist")
        #expect(persisted.album == "New Album")
        #expect(persisted.genre == "Pop")
        #expect(persisted.year == 2025)
        #expect(persisted.albumArtist == "New AlbumArtist")
        #expect(persisted.trackStatus == "uploaded")
        #expect(persisted.releaseYear == 2024)

        // Processing state preserved
        #expect(persisted.genreUpdated == true)
        #expect(persisted.yearUpdated == true)
        #expect(persisted.processedDate == processedAt)
        #expect(persisted.lastError == "some error")
    }

    @Test("update(from:) can set optional fields to nil")
    func updateCanClearOptionalFields() {
        let persisted = PersistedTrack(from: sampleTrack())
        #expect(persisted.genre == "Rock")
        #expect(persisted.year == 2020)

        let nilTrack = Core.Track(id: "T1", name: "Song", artist: "Artist", album: "Album")
        persisted.update(from: nilTrack)

        #expect(persisted.genre == nil)
        #expect(persisted.year == nil)
        #expect(persisted.albumArtist == nil)
        #expect(persisted.trackStatus == nil)
        #expect(persisted.releaseYear == nil)
    }
}

// MARK: - PersistedChangeLogEntry Tests

@Suite("PersistedChangeLogEntry — domain model mapping")
struct PersistedChangeLogEntryTests {
    private func makeGenreEntry() -> Core.ChangeLogEntry {
        var entry = Core.ChangeLogEntry(
            changeType: .genreUpdate,
            trackID: "T1",
            artist: "Artist",
            trackName: "Track",
            albumName: "Album"
        )
        entry.oldGenre = "Rock"
        entry.newGenre = "Pop"
        return entry
    }

    @Test("init(from:) maps all fields from Core.ChangeLogEntry")
    func initFromEntryMapsAllFields() {
        let entry = makeGenreEntry()
        let persisted = PersistedChangeLogEntry(from: entry)

        #expect(persisted.entryID == entry.id)
        #expect(persisted.timestamp == entry.timestamp)
        #expect(persisted.changeTypeRaw == "genre_update")
        #expect(persisted.trackID == "T1")
        #expect(persisted.artist == "Artist")
        #expect(persisted.trackName == "Track")
        #expect(persisted.albumName == "Album")
        #expect(persisted.oldGenre == "Rock")
        #expect(persisted.newGenre == "Pop")
    }

    @Test("init(from:) maps year change fields")
    func initFromEntryMapsYearFields() {
        var entry = Core.ChangeLogEntry(
            changeType: .yearUpdate,
            trackID: "T2",
            artist: "Artist",
            trackName: "Track",
            albumName: "Album"
        )
        entry.oldYear = 1982
        entry.newYear = 1983

        let persisted = PersistedChangeLogEntry(from: entry)

        #expect(persisted.changeTypeRaw == "year_update")
        #expect(persisted.oldYear == 1982)
        #expect(persisted.newYear == 1983)
        #expect(persisted.oldGenre == nil)
        #expect(persisted.newGenre == nil)
    }

    @Test("init(from:) maps name cleaning fields")
    func initFromEntryMapsNameCleaningFields() {
        var entry = Core.ChangeLogEntry(
            changeType: .trackCleaning,
            trackID: "T3",
            artist: "Artist",
            trackName: "Track",
            albumName: "Album"
        )
        entry.oldTrackName = "Song (Remastered)"
        entry.newTrackName = "Song"
        entry.oldAlbumName = "Album (Deluxe)"
        entry.newAlbumName = "Album"

        let persisted = PersistedChangeLogEntry(from: entry)

        #expect(persisted.changeTypeRaw == "track_cleaning")
        #expect(persisted.oldTrackName == "Song (Remastered)")
        #expect(persisted.newTrackName == "Song")
        #expect(persisted.oldAlbumName == "Album (Deluxe)")
        #expect(persisted.newAlbumName == "Album")
    }

    @Test("toChangeLogEntry() converts back to matching domain entry")
    func toChangeLogEntryConvertsBack() {
        let original = makeGenreEntry()
        let result = PersistedChangeLogEntry(from: original).toChangeLogEntry()

        #expect(result.id == original.id)
        #expect(result.timestamp == original.timestamp)
        #expect(result.changeType == .genreUpdate)
        #expect(result.trackID == "T1")
        #expect(result.artist == "Artist")
        #expect(result.trackName == "Track")
        #expect(result.albumName == "Album")
        #expect(result.oldGenre == "Rock")
        #expect(result.newGenre == "Pop")
    }

    @Test("Unknown changeTypeRaw defaults to .genreUpdate")
    func unknownChangeTypeDefaultsToGenreUpdate() {
        let persisted = PersistedChangeLogEntry(
            entryID: UUID(),
            timestamp: Date(),
            changeTypeRaw: "unknown_type",
            trackID: "T1",
            artist: "A",
            trackName: "T",
            albumName: "Al"
        )
        let entry = persisted.toChangeLogEntry()

        #expect(entry.changeType == .genreUpdate)
    }

    @Test(
        "All ChangeType rawValues round-trip correctly",
        arguments: ChangeType.allCases
    )
    func changeTypeRoundTrip(changeType: ChangeType) {
        var entry = Core.ChangeLogEntry(
            changeType: changeType,
            trackID: "RT1",
            artist: "Artist",
            trackName: "Track",
            albumName: "Album"
        )
        // Populate fields relevant to each change type
        entry.oldGenre = "OldGenre"
        entry.newGenre = "NewGenre"
        entry.oldYear = 2000
        entry.newYear = 2001
        entry.oldTrackName = "OldTrack"
        entry.newTrackName = "NewTrack"
        entry.oldAlbumName = "OldAlbum"
        entry.newAlbumName = "NewAlbum"

        let persisted = PersistedChangeLogEntry(from: entry)
        let roundTripped = persisted.toChangeLogEntry()

        #expect(roundTripped.changeType == changeType)
        #expect(persisted.changeTypeRaw == changeType.rawValue)
    }
}

// MARK: - PersistedPendingAlbumEntry Tests

@Suite("PersistedPendingAlbumEntry — domain model mapping")
struct PersistedPendingAlbumEntryTests {
    private let fixedDate = Date(timeIntervalSince1970: 1_700_000_000)

    @Test("init(from:) maps all fields from PendingAlbumEntry")
    func initFromEntryMapsAllFields() {
        let entry = PendingAlbumEntry(
            id: "pending-1",
            artist: "Massive Attack",
            album: "Mezzanine",
            reason: "missing_year",
            retry: .init(
                attemptCount: 2,
                lastAttempt: fixedDate,
                recheckInterval: 604_800
            ),
            metadata: ["source": "musicbrainz"]
        )

        let persisted = PersistedPendingAlbumEntry(from: entry)

        #expect(persisted.entryID == "pending-1")
        #expect(persisted.artist == "Massive Attack")
        #expect(persisted.album == "Mezzanine")
        #expect(persisted.reason == "missing_year")
        #expect(persisted.attemptCount == 2)
        #expect(persisted.lastAttempt == fixedDate)
        #expect(persisted.recheckInterval == 604_800)
        #expect(persisted.metadataData != nil)
    }

    @Test("toPendingAlbumEntry() converts back to matching domain entry")
    func toPendingAlbumEntryConvertsBack() {
        let entry = PendingAlbumEntry(
            id: "pending-1",
            artist: "Low",
            album: "HEY WHAT",
            reason: "low_confidence",
            retry: .init(
                attemptCount: 3,
                lastAttempt: fixedDate,
                recheckInterval: 1_209_600
            ),
            metadata: ["confidence": "42"]
        )

        let result = PersistedPendingAlbumEntry(from: entry).toPendingAlbumEntry()

        #expect(result.id == entry.id)
        #expect(result.artist == "Low")
        #expect(result.album == "HEY WHAT")
        #expect(result.reason == "low_confidence")
        #expect(result.attemptCount == 3)
        #expect(result.lastAttempt == fixedDate)
        #expect(result.recheckInterval == 1_209_600)
        #expect(result.metadata["confidence"] == "42")
    }

    @Test("update(from:) replaces mutable fields")
    func updateFromEntryReplacesFields() {
        let persisted = PersistedPendingAlbumEntry(from: PendingAlbumEntry(
            id: "pending-1",
            artist: "Old",
            album: "Old Album",
            reason: "old_reason",
            retry: .init(
                attemptCount: 1,
                lastAttempt: fixedDate,
                recheckInterval: 604_800
            ),
            metadata: [:]
        ))
        let updated = PendingAlbumEntry(
            id: "pending-1",
            artist: "New",
            album: "New Album",
            reason: "new_reason",
            retry: .init(
                attemptCount: 4,
                lastAttempt: fixedDate.addingTimeInterval(60),
                recheckInterval: 86400
            ),
            metadata: ["source": "discogs"]
        )

        persisted.update(from: updated)
        let result = persisted.toPendingAlbumEntry()

        #expect(result.artist == "New")
        #expect(result.album == "New Album")
        #expect(result.reason == "new_reason")
        #expect(result.attemptCount == 4)
        #expect(result.recheckInterval == 86400)
        #expect(result.metadata["source"] == "discogs")
    }
}

// MARK: - ModelContainerFactory Tests

@Suite("ModelContainerFactory — container creation")
struct ModelContainerFactoryTests {
    @Test("createInMemory() succeeds without throwing")
    func createInMemorySucceeds() {
        #expect(throws: Never.self) {
            _ = try ModelContainerFactory.createInMemory()
        }
    }
}
