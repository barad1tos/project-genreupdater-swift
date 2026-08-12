import Foundation
import SwiftData

@Model
final class PersistedTrack {
    @Attribute(.unique) var trackID: String
    var appleScriptID: String?
    var name: String
    var artist: String
    var album: String
    var genre: String?
    var year: Int?
    var genreUpdated: Bool
    var yearUpdated: Bool
    var processedDate: Date?
    var lastError: String?
    var dateAdded: Date?
    var albumArtist: String?
    var trackStatus: String?
    var releaseYear: Int?

    @Relationship(deleteRule: .cascade, inverse: \PersistedChangeLogEntry.track)
    var changeLog: [PersistedChangeLogEntry] = []

    init(trackID: String, name: String, artist: String, album: String, year: Int? = nil) {
        self.trackID = trackID
        self.name = name
        self.artist = artist
        self.album = album
        self.year = year
        genreUpdated = true
        yearUpdated = true
    }
}

@Model
final class PersistedChangeLogEntry {
    @Attribute(.unique) var entryID: UUID
    var timestamp: Date
    var changeTypeRaw: String
    var trackID: String
    var artist: String
    var trackName: String
    var albumName: String
    var oldGenre: String?
    var newGenre: String?
    var oldYear: Int?
    var newYear: Int?
    var oldTrackName: String?
    var newTrackName: String?
    var oldAlbumName: String?
    var newAlbumName: String?
    var oldArtist: String?
    var newArtist: String?
    var runID: UUID?
    var track: PersistedTrack?

    init(track: PersistedTrack, timestamp: Date, oldArtist: String, newArtist: String) {
        entryID = UUID()
        self.timestamp = timestamp
        changeTypeRaw = "artist_rename"
        trackID = track.trackID
        artist = "Florence and the Machine"
        trackName = track.name
        albumName = track.album
        self.oldArtist = oldArtist
        self.newArtist = newArtist
        self.track = track
    }

    init(track: PersistedTrack, timestamp: Date, type: String, oldYear: Int, newYear: Int) {
        entryID = UUID()
        self.timestamp = timestamp
        changeTypeRaw = type
        trackID = track.trackID
        artist = track.artist
        trackName = track.name
        albumName = track.album
        self.oldYear = oldYear
        self.newYear = newYear
        self.track = track
    }
}

guard CommandLine.arguments.count == 2 else {
    fatalError("Expected a store path")
}

let storeURL = URL(fileURLWithPath: CommandLine.arguments[1])
let schema = Schema([PersistedTrack.self, PersistedChangeLogEntry.self])
let configuration = ModelConfiguration(
    "GenreUpdaterTrackMigration",
    schema: schema,
    url: storeURL,
    cloudKitDatabase: .none
)
let container = try ModelContainer(for: schema, configurations: [configuration])
let context = ModelContext(container)
let track = PersistedTrack(
    trackID: "T1",
    name: "Dog Days Are Over",
    artist: "Florence & the Machine",
    album: "Lungs"
)
let firstEntry = PersistedChangeLogEntry(
    track: track,
    timestamp: Date(timeIntervalSince1970: 100),
    oldArtist: "Florence and the Machine",
    newArtist: "Florence + the Machine"
)
let secondEntry = PersistedChangeLogEntry(
    track: track,
    timestamp: Date(timeIntervalSince1970: 200),
    oldArtist: "Florence + the Machine",
    newArtist: "Florence & the Machine"
)
let yearTrack = PersistedTrack(
    trackID: "T2",
    name: "Angel",
    artist: "Massive Attack",
    album: "Mezzanine",
    year: 1998
)
let yearUpdate = PersistedChangeLogEntry(
    track: yearTrack,
    timestamp: Date(timeIntervalSince1970: 300),
    type: "year_update",
    oldYear: 1998,
    newYear: 2019
)
let yearRevert = PersistedChangeLogEntry(
    track: yearTrack,
    timestamp: Date(timeIntervalSince1970: 400),
    type: "year_revert",
    oldYear: 2019,
    newYear: 1998
)
context.insert(track)
context.insert(firstEntry)
context.insert(secondEntry)
context.insert(yearTrack)
context.insert(yearUpdate)
context.insert(yearRevert)
try context.save()
