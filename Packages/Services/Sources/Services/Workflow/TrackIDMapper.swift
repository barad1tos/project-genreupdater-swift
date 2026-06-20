import Core
import Foundation
import OSLog

// MARK: - Track ID Mapper

/// Maps MusicKit IDs to AppleScript persistent IDs by matching on (name, artist, album).
///
/// MusicKit returns numeric `MusicItemID` strings while AppleScript uses hex
/// persistent IDs. These are different ID spaces with no direct translation.
/// This actor builds a lookup table by matching tracks on their metadata tuple.
public actor TrackIDMapper: TrackIDMapping {
    private var mapping: [String: String] = [:]
    private var appleScriptMetadataByMusicKitID: [String: Track] = [:]
    private let log = Logger(subsystem: "com.genreupdater", category: "TrackIDMapper")

    public init() {}

    public func refreshMapping(
        musicKitTracks: [Track],
        appleScriptTracks: [Track]
    ) {
        var appleScriptLookup: [String: Track] = [:]
        for track in appleScriptTracks {
            let key = normalizedKey(track)
            appleScriptLookup[key] = track
        }

        mapping = [:]
        appleScriptMetadataByMusicKitID = [:]
        for track in musicKitTracks {
            let key = normalizedKey(track)
            if let appleScriptTrack = appleScriptLookup[key] {
                mapping[track.id] = appleScriptTrack.id
                appleScriptMetadataByMusicKitID[track.id] = appleScriptTrack
            }
        }

        log
            .info(
                "Built ID mapping: \(self.mapping.count, privacy: .public)/\(musicKitTracks.count, privacy: .public) matched"
            )
    }

    @discardableResult
    public func refreshMapping(
        musicKitTracks: [Track],
        appleScriptClient: any AppleScriptClient,
        batchSize: Int,
        allTrackIDsTimeout: Duration?,
        tracksByIDsTimeout: Duration?,
        testArtists: [String] = []
    ) async throws -> Int {
        let appleScriptTracks = try await fetchAppleScriptTracks(
            client: appleScriptClient,
            batchSize: batchSize,
            allTrackIDsTimeout: allTrackIDsTimeout,
            tracksByIDsTimeout: tracksByIDsTimeout,
            testArtists: testArtists
        )
        refreshMapping(
            musicKitTracks: musicKitTracks,
            appleScriptTracks: appleScriptTracks
        )
        return mapping.count
    }

    public func appleScriptID(forMusicKitID musicKitID: String) -> String? {
        mapping[musicKitID]
    }

    public func trackWithAppleScriptMetadata(for musicKitTrack: Track) -> Track? {
        guard let appleScriptTrack = appleScriptMetadataByMusicKitID[musicKitTrack.id] else {
            return nil
        }

        return Track(
            id: musicKitTrack.id,
            name: appleScriptTrack.name,
            artist: appleScriptTrack.artist,
            album: appleScriptTrack.album,
            genre: appleScriptTrack.genre,
            year: appleScriptTrack.year,
            dateAdded: appleScriptTrack.dateAdded ?? musicKitTrack.dateAdded,
            lastModified: appleScriptTrack.lastModified,
            trackStatus: appleScriptTrack.trackStatus,
            originalArtist: musicKitTrack.originalArtist,
            originalAlbum: musicKitTrack.originalAlbum,
            yearBeforeMGU: musicKitTrack.yearBeforeMGU,
            yearSetByMGU: musicKitTrack.yearSetByMGU,
            releaseYear: appleScriptTrack.releaseYear ?? musicKitTrack.releaseYear,
            originalPosition: musicKitTrack.originalPosition,
            albumArtist: appleScriptTrack.albumArtist ?? musicKitTrack.albumArtist
        )
    }

    public func hasMappingFor(musicKitID: String) -> Bool {
        mapping[musicKitID] != nil
    }

    private func normalizedKey(_ track: Track) -> String {
        "\(track.name.lowercased())|\(track.artist.lowercased())|\(track.album.lowercased())"
    }

    private func fetchAppleScriptTracks(
        client: any AppleScriptClient,
        batchSize: Int,
        allTrackIDsTimeout: Duration?,
        tracksByIDsTimeout: Duration?,
        testArtists: [String]
    ) async throws -> [Track] {
        let scopedArtists = MusicLibraryReader.fetchTargets(
            requestedArtist: nil,
            testArtists: testArtists,
            ignoreTestFilter: false
        )
        .compactMap(\.self)

        guard !scopedArtists.isEmpty else {
            let appleScriptTrackIDs = try await client.fetchAllTrackIDs(
                timeout: allTrackIDsTimeout
            )
            return try await client.fetchTracksByIDs(
                appleScriptTrackIDs,
                batchSize: batchSize,
                timeout: tracksByIDsTimeout
            )
        }

        var scopedTracks: [Track] = []
        for artist in scopedArtists {
            let tracks = try await client.fetchTracks(
                artist: artist,
                timeout: tracksByIDsTimeout
            )
            scopedTracks.append(contentsOf: tracks)
        }
        return scopedTracks
    }
}
