import Foundation
import SwiftData

extension StoreSchemaV9 {
    @Model
    final class PersistedCatalogState {
        @Attribute(.unique)
        var key: String

        var fingerprint: String
        var capturedAt: Date

        init(
            key: String = "music-catalog",
            fingerprint: String,
            capturedAt: Date
        ) {
            self.key = key
            self.fingerprint = fingerprint
            self.capturedAt = capturedAt
        }
    }

    @Model
    final class PersistedCatalogTrack {
        @Attribute(.unique)
        var catalogID: String

        var position: Int
        var title: String
        var artist: String
        var album: String
        var albumArtist: String?
        var genresData: Data
        var releaseYear: Int?
        var dateAdded: Date?

        init(track: CatalogTrack, position: Int) throws {
            catalogID = track.id.displayValue
            self.position = position
            title = track.title
            artist = track.artist
            album = track.album
            albumArtist = track.albumArtist
            genresData = try JSONEncoder().encode(track.genres)
            releaseYear = track.dates.releaseYear
            dateAdded = track.dates.dateAdded
        }

        func catalogTrack() throws -> CatalogTrack {
            guard let id = CatalogTrackID(displayValue: catalogID) else {
                throw CatalogStoreError.invalidCatalogID(catalogID)
            }
            let genres: [String]
            do {
                genres = try JSONDecoder().decode([String].self, from: genresData)
            } catch {
                throw CatalogStoreError.invalidGenres(catalogID)
            }
            return CatalogTrack(
                id: id,
                title: title,
                artist: artist,
                album: album,
                albumArtist: albumArtist,
                genres: genres,
                dates: CatalogDates(releaseYear: releaseYear, dateAdded: dateAdded)
            )
        }
    }
}

typealias PersistedCatalogState = StoreSchemaV9.PersistedCatalogState
typealias PersistedCatalogTrack = StoreSchemaV9.PersistedCatalogTrack
