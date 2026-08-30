import Core
import Foundation
import MusicKit

struct MusicKitTrackMetadata: Sendable {
    let id: String
    let title: String
    let artist: String
    let album: String?
    let albumArtist: String?
    let genres: [String]
    let releaseDate: Date?
    let dateAdded: Date?
}

protocol MusicKitCatalogSource: Actor {
    var isAuthorized: Bool { get }

    func requestAuthorization() async throws
    func loadTracks() async throws -> [MusicKitTrackMetadata]
}

enum MusicKitPaginationError: Error, Equatable {
    case missingNextPage
}

enum MusicKitPagination {
    static func collectMetadata<Page>(
        firstPage: Page,
        hasNextPage: (Page) -> Bool,
        metadata: (Page) -> [MusicKitTrackMetadata],
        nextPage: (Page) async throws -> Page?
    ) async throws -> [MusicKitTrackMetadata] {
        var page = firstPage
        var collectedMetadata = metadata(page)

        while hasNextPage(page) {
            try Task.checkCancellation()
            guard let followingPage = try await nextPage(page) else {
                throw MusicKitPaginationError.missingNextPage
            }
            page = followingPage
            collectedMetadata.append(contentsOf: metadata(page))
        }
        return collectedMetadata
    }
}

actor MusicKitCatalogAdapter: MusicKitCatalogSource {
    var isAuthorized: Bool {
        MusicAuthorization.currentStatus == .authorized
    }

    func requestAuthorization() async throws {
        let status = await MusicAuthorization.request()
        switch status {
        case .authorized:
            return
        case .denied, .notDetermined:
            throw MusicLibraryError.authorizationDenied
        case .restricted:
            throw MusicLibraryError.authorizationRestricted
        @unknown default:
            throw MusicLibraryError.authorizationDenied
        }
    }

    func loadTracks() async throws -> [MusicKitTrackMetadata] {
        var request = MusicLibraryRequest<Song>()
        request.sort(by: \.artistName, ascending: true)
        let response = try await request.response()
        return try await MusicKitPagination.collectMetadata(
            firstPage: response.items,
            hasNextPage: { $0.hasNextBatch },
            metadata: { $0.map(Self.metadata) },
            nextPage: { try await $0.nextBatch() }
        )
    }

    static func makeSnapshot(from metadata: [MusicKitTrackMetadata]) -> CatalogSnapshot {
        var seenIDs = Set<CatalogTrackID>()
        var tracks: [CatalogTrack] = []

        for metadataRow in metadata {
            guard let track = makeTrack(from: metadataRow),
                  seenIDs.insert(track.id).inserted
            else { continue }
            tracks.append(track)
        }

        return CatalogSnapshot(tracks: tracks)
    }

    static func makeTrack(from metadata: MusicKitTrackMetadata) -> CatalogTrack? {
        guard let id = CatalogTrackID(displayValue: metadata.id) else { return nil }

        return CatalogTrack(
            id: id,
            title: metadata.title,
            artist: metadata.artist,
            album: metadata.album ?? "",
            albumArtist: metadata.albumArtist,
            genres: metadata.genres,
            dates: CatalogDates(
                releaseYear: metadata.releaseDate.map { Calendar.current.component(.year, from: $0) },
                dateAdded: metadata.dateAdded
            )
        )
    }

    private static func metadata(from song: Song) -> MusicKitTrackMetadata {
        MusicKitTrackMetadata(
            id: song.id.rawValue,
            title: song.title,
            artist: song.artistName,
            album: song.albumTitle,
            albumArtist: song.albums?.first?.artistName,
            genres: song.genreNames,
            releaseDate: song.releaseDate,
            dateAdded: song.libraryAddedDate
        )
    }
}
