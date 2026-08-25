import Foundation
@testable import Core

func genreUndoEntry(
    trackID: String = "T1",
    oldGenre: String = "Rock",
    newGenre: String = "Pop"
) -> ChangeLogEntry {
    var entry = ChangeLogEntry(
        changeType: .genreUpdate,
        trackID: trackID,
        artist: "Artist",
        trackName: "Track",
        albumName: "Album"
    )
    entry.oldGenre = oldGenre
    entry.newGenre = newGenre
    return entry
}

func yearUndoEntry(
    trackID: String = "T1",
    artist: String = "Artist",
    album: String = "Album",
    oldYear: Int = 1984,
    newYear: Int = 2000
) -> ChangeLogEntry {
    var entry = ChangeLogEntry(
        changeType: .yearUpdate,
        trackID: trackID,
        artist: artist,
        trackName: "Track",
        albumName: album
    )
    entry.oldYear = oldYear
    entry.newYear = newYear
    return entry
}

func artistUndoEntry(
    trackID: String = "T1",
    oldArtist: String = "Old Artist",
    newArtist: String = "New Artist"
) -> ChangeLogEntry {
    var entry = ChangeLogEntry(
        changeType: .artistRename,
        trackID: trackID,
        artist: newArtist,
        trackName: "Track",
        albumName: "Album"
    )
    entry.oldArtist = oldArtist
    entry.newArtist = newArtist
    return entry
}

func albumUndoEntry(
    trackID: String = "T1",
    artist: String = "Artist",
    oldAlbum: String = "Album (Remastered)",
    newAlbum: String = "Album"
) -> ChangeLogEntry {
    var entry = ChangeLogEntry(
        changeType: .albumCleaning,
        trackID: trackID,
        artist: artist,
        trackName: "Track",
        albumName: oldAlbum
    )
    entry.oldAlbumName = oldAlbum
    entry.newAlbumName = newAlbum
    return entry
}

struct MissingUndoTrackIDMapper: TrackIDMapping {
    func appleScriptID(forMusicKitID _: String) async -> String? {
        nil
    }

    func trackWithAppleScriptMetadata(for _: Track) async -> Track? {
        nil
    }

    func hasMappingFor(musicKitID _: String) async -> Bool {
        false
    }
}

struct FixedUndoTrackIDMapper: TrackIDMapping {
    let mapping: [String: String]

    func appleScriptID(forMusicKitID musicKitID: String) async -> String? {
        mapping[musicKitID]
    }

    func trackWithAppleScriptMetadata(for musicKitTrack: Track) async -> Track? {
        var enrichedTrack = musicKitTrack
        enrichedTrack.trackStatus = TrackKind.subscription.rawValue
        return enrichedTrack
    }

    func hasMappingFor(musicKitID: String) async -> Bool {
        mapping[musicKitID] != nil
    }
}

struct MetadataUndoTrackIDMapper: TrackIDMapping {
    let mapping: [String: String]
    let metadata: [String: Track]

    func appleScriptID(forMusicKitID musicKitID: String) async -> String? {
        mapping[musicKitID]
    }

    func trackWithAppleScriptMetadata(for musicKitTrack: Track) async -> Track? {
        metadata[musicKitTrack.id] ?? musicKitTrack
    }

    func hasMappingFor(musicKitID: String) async -> Bool {
        mapping[musicKitID] != nil
    }
}

struct RawTrackIDWriteError: LocalizedError {
    let trackID: String

    var errorDescription: String? {
        "Track=\(trackID), AppleScript write failed"
    }
}
