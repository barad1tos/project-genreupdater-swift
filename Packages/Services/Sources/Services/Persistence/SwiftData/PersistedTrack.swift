// PersistedTrack.swift — SwiftData model for track processing state
// Phase 2A: Persistence Layer

import Core
import Foundation
import SwiftData

/// Persistent representation of a track's processing state.
///
/// This is the SwiftData `@Model` counterpart to `Core.Track`.
/// It stores which tracks have been processed and what changes were made,
/// surviving app restarts and supporting 30K+ track libraries.
///
/// The domain model (`Core.Track`) remains a plain struct with no persistence
/// dependencies, keeping Core free of SwiftData.
extension StoreSchemaV2 {
    @Model
    public final class PersistedTrack {
        @Attribute(.unique)
        public var trackID: String

        public var appleScriptID: String?

        public var name: String
        public var artist: String
        public var album: String
        public var genre: String?
        public var year: Int?
        public var genreUpdated: Bool
        public var yearUpdated: Bool
        public var processedDate: Date?
        public var lastError: String?
        public var dateAdded: Date?
        public var albumArtist: String?
        public var trackStatus: String?
        public var originalArtist: String?
        public var originalAlbum: String?
        public var yearBeforeMGU: Int?
        public var yearSetByMGU: Int?
        public var releaseYear: Int?

        @Relationship(deleteRule: .cascade, inverse: \PersistedChangeLogEntry.track)
        public var changeLog: [PersistedChangeLogEntry] = []

        public init(
            trackID: String,
            appleScriptID: String? = nil,
            name: String,
            artist: String,
            album: String,
            genre: String? = nil,
            year: Int? = nil,
            genreUpdated: Bool = false,
            yearUpdated: Bool = false,
            processedDate: Date? = nil,
            lastError: String? = nil,
            dateAdded: Date? = nil,
            albumArtist: String? = nil,
            trackStatus: String? = nil,
            originalArtist: String? = nil,
            originalAlbum: String? = nil,
            yearBeforeMGU: Int? = nil,
            yearSetByMGU: Int? = nil,
            releaseYear: Int? = nil
        ) {
            self.trackID = trackID
            self.appleScriptID = appleScriptID
            self.name = name
            self.artist = artist
            self.album = album
            self.genre = genre
            self.year = MusicAppYear.normalized(year)
            self.genreUpdated = genreUpdated
            self.yearUpdated = yearUpdated
            self.processedDate = processedDate
            self.lastError = lastError
            self.dateAdded = dateAdded
            self.albumArtist = albumArtist
            self.trackStatus = trackStatus
            self.originalArtist = originalArtist
            self.originalAlbum = originalAlbum
            self.yearBeforeMGU = yearBeforeMGU
            self.yearSetByMGU = yearSetByMGU
            self.releaseYear = MusicAppYear.normalized(releaseYear)
        }
    }
}

public typealias PersistedTrack = StoreSchemaV2.PersistedTrack

// MARK: - Conversion to/from Core.Track

extension PersistedTrack {
    convenience init(mirror track: Core.Track, databaseID: MusicDatabaseTrackID) {
        self.init(
            trackID: databaseID.rawValue,
            appleScriptID: databaseID.rawValue,
            name: track.name,
            artist: track.artist,
            album: track.album,
            genre: track.genre,
            year: track.year,
            dateAdded: track.dateAdded,
            albumArtist: track.albumArtist,
            trackStatus: track.trackStatus,
            releaseYear: track.releaseYear
        )
    }

    /// Convert to the domain Track model.
    public func toTrack() -> Core.Track {
        Core.Track(
            id: trackID,
            name: name,
            artist: artist,
            album: album,
            genre: genre,
            year: year,
            dateAdded: dateAdded,
            trackStatus: trackStatus,
            originalArtist: originalArtist,
            originalAlbum: originalAlbum,
            yearBeforeMGU: yearBeforeMGU,
            yearSetByMGU: yearSetByMGU,
            releaseYear: releaseYear,
            albumArtist: albumArtist,
            appleScriptID: appleScriptID
        )
    }

    /// Update this persisted track from a domain track (preserving processing state).
    public func update(from track: Core.Track) {
        name = track.name
        artist = track.artist
        album = track.album
        genre = track.genre
        year = MusicAppYear.normalized(track.year)
        appleScriptID = track.appleScriptID ?? appleScriptID
        dateAdded = track.dateAdded
        albumArtist = track.albumArtist
        trackStatus = track.trackStatus
        originalArtist = originalArtist ?? track.originalArtist
        originalAlbum = originalAlbum ?? track.originalAlbum
        yearBeforeMGU = yearBeforeMGU ?? track.yearBeforeMGU
        yearSetByMGU = track.yearSetByMGU ?? yearSetByMGU
        releaseYear = MusicAppYear.normalized(track.releaseYear)
    }

    func updateMirror(from track: Core.Track, databaseID: MusicDatabaseTrackID) {
        name = track.name
        artist = track.artist
        album = track.album
        genre = track.genre
        year = MusicAppYear.normalized(track.year)
        appleScriptID = databaseID.rawValue
        dateAdded = track.dateAdded
        albumArtist = track.albumArtist
        trackStatus = track.trackStatus
        releaseYear = MusicAppYear.normalized(track.releaseYear)
    }

    func mirrorMatches(_ track: Core.Track, databaseID: MusicDatabaseTrackID) -> Bool {
        trackID == databaseID.rawValue
            && appleScriptID == databaseID.rawValue
            && name == track.name
            && artist == track.artist
            && album == track.album
            && genre == track.genre
            && year == MusicAppYear.normalized(track.year)
            && dateAdded == track.dateAdded
            && albumArtist == track.albumArtist
            && trackStatus == track.trackStatus
            && releaseYear == MusicAppYear.normalized(track.releaseYear)
    }

    func mergeRepair(
        _ sources: [PersistedTrack],
        with track: Core.Track,
        databaseID: MusicDatabaseTrackID
    ) throws {
        let isCanonicalTarget = isCanonical(databaseID: databaseID)
        let aliases = sources.filter { !isCanonicalTarget || $0 !== self }
        let evidenceTracks = isCanonicalTarget ? [self] + aliases : aliases
        let evidenceTrackIDs = evidenceTracks.map(\.trackID)
        let consistentOriginalArtist = try Self.consistentEvidence(
            evidenceTracks.map(\.originalArtist), field: "originalArtist", sourceIDs: evidenceTrackIDs
        )
        let consistentOriginalAlbum = try Self.consistentEvidence(
            evidenceTracks.map(\.originalAlbum), field: "originalAlbum", sourceIDs: evidenceTrackIDs
        )
        let consistentYearBeforeMGU = try Self.consistentEvidence(
            evidenceTracks.map(\.yearBeforeMGU), field: "yearBeforeMGU", sourceIDs: evidenceTrackIDs
        )
        let consistentYearSetByMGU = try Self.consistentEvidence(
            evidenceTracks.map(\.yearSetByMGU), field: "yearSetByMGU", sourceIDs: evidenceTrackIDs
        )
        let aliasLastError = aliases
            .sorted { lhs, rhs in
                if lhs.processedDate == rhs.processedDate {
                    return lhs.trackID < rhs.trackID
                }
                return (lhs.processedDate ?? .distantPast) > (rhs.processedDate ?? .distantPast)
            }
            .compactMap(\.lastError)
            .first

        trackID = databaseID.rawValue
        updateMirror(from: track, databaseID: databaseID)
        genreUpdated = evidenceTracks.contains(where: \.genreUpdated)
        yearUpdated = evidenceTracks.contains(where: \.yearUpdated)
        processedDate = evidenceTracks.compactMap(\.processedDate).max()
        lastError = isCanonicalTarget ? lastError ?? aliasLastError : aliasLastError
        originalArtist = consistentOriginalArtist
        originalAlbum = consistentOriginalAlbum
        yearBeforeMGU = consistentYearBeforeMGU
        yearSetByMGU = consistentYearSetByMGU
    }

    var hasDurableProcessingEvidence: Bool {
        genreUpdated || yearUpdated || processedDate != nil || lastError != nil
            || originalArtist != nil || originalAlbum != nil
            || yearBeforeMGU != nil || yearSetByMGU != nil
    }

    private static func consistentEvidence<Value: Equatable>(
        _ values: [Value?],
        field: String,
        sourceIDs: [String]
    ) throws -> Value? {
        let present = values.compactMap(\.self)
        guard let first = present.first else { return nil }
        guard present.dropFirst().allSatisfy({ $0 == first }) else {
            throw TrackStoreError.conflictingRepairEvidence(field: field, sourceIDs: sourceIDs.sorted())
        }
        return first
    }

    func isCanonical(databaseID: MusicDatabaseTrackID) -> Bool {
        trackID == databaseID.rawValue && appleScriptID == databaseID.rawValue
    }
}
