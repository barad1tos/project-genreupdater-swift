import Core
import Foundation
import OSLog

// MARK: - Track ID Mapper

/// Maps MusicKit IDs to AppleScript persistent IDs by matching on (name, artist/albumArtist, album).
///
/// MusicKit returns numeric `MusicItemID` strings while AppleScript uses hex
/// persistent IDs. These are different ID spaces with no direct translation.
/// This actor builds a lookup table by matching tracks on their metadata tuple.
public actor TrackIDMapper: TrackIDMapping {
    private var mapping: [String: String] = [:]
    private var appleScriptMetadataByMusicKitID: [String: Track] = [:]
    private let log = Logger(subsystem: "com.genreupdater", category: "TrackIDMapper")

    public init() {
        // No initial state: the ID mapping table is populated lazily via refreshMapping.
    }

    public func refreshMapping(
        musicKitTracks: [Track],
        appleScriptTracks: [Track]
    ) {
        refreshMapping(
            musicKitTracks: musicKitTracks,
            appleScriptTracks: appleScriptTracks,
            mergeExisting: false
        )
    }

    public func refreshMapping(
        musicKitTracks: [Track],
        appleScriptTracks: [Track],
        mergeExisting: Bool
    ) {
        var (updatedMapping, updatedMetadata) = matchByKeys(
            musicKitTracks: musicKitTracks,
            appleScriptTracks: appleScriptTracks,
            keys: normalizedKeys
        )

        // Album-agnostic fallback. MusicKit and AppleScript can disagree on the
        // album (e.g. a single later folded into an album), which breaks the
        // (name, artist, album) key even though it is the same writable track.
        // Retry the still-unmapped tracks on (name, artist) alone, staying
        // conservative: only a unique match on both sides is accepted.
        let unmappedMusicKitTracks = musicKitTracks.filter { updatedMapping[$0.id] == nil }
        if !unmappedMusicKitTracks.isEmpty {
            // Exclude AppleScript tracks the primary pass already claimed, so the
            // album-agnostic fallback can never attach a second MusicKit track to a
            // write target another track already owns (which would overwrite it).
            let claimedAppleScriptIDs = Set(updatedMapping.values)
            let availableAppleScriptTracks = appleScriptTracks.filter {
                !claimedAppleScriptIDs.contains($0.id)
            }
            let (fallbackMapping, fallbackMetadata) = matchByKeys(
                musicKitTracks: unmappedMusicKitTracks,
                appleScriptTracks: availableAppleScriptTracks,
                keys: nameArtistKeys
            )
            updatedMapping.merge(fallbackMapping) { existing, _ in existing }
            updatedMetadata.merge(fallbackMetadata) { existing, _ in existing }
        }

        if mergeExisting {
            mapping.merge(updatedMapping) { _, new in new }
            appleScriptMetadataByMusicKitID.merge(updatedMetadata) { _, new in new }
        } else {
            mapping = updatedMapping
            appleScriptMetadataByMusicKitID = updatedMetadata
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
        testArtists: [String] = [],
        mergeExisting: Bool = false
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
            appleScriptTracks: appleScriptTracks,
            mergeExisting: mergeExisting
        )
        return musicKitTracks.reduce(0) { count, track in
            mapping[track.id] == nil ? count : count + 1
        }
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
            albumArtist: appleScriptTrack.albumArtist ?? musicKitTrack.albumArtist,
            appleScriptID: appleScriptTrack.appleScriptID ?? appleScriptTrack.id
        )
    }

    public func hasMappingFor(musicKitID: String) -> Bool {
        mapping[musicKitID] != nil
    }

    /// Builds a MusicKit→AppleScript mapping by matching tracks on the keys produced
    /// by `keys`. A key shared by more than one track on either side is ambiguous and
    /// skipped, so only a unique cross-side match is accepted.
    private func matchByKeys(
        musicKitTracks: [Track],
        appleScriptTracks: [Track],
        keys: (Track) -> [String]
    ) -> (mapping: [String: String], metadata: [String: Track]) {
        var appleScriptLookup: [String: Track] = [:]
        var ambiguousAppleScriptKeys: Set<String> = []
        for track in appleScriptTracks {
            for key in keys(track) {
                if appleScriptLookup[key] != nil {
                    appleScriptLookup[key] = nil
                    ambiguousAppleScriptKeys.insert(key)
                } else if !ambiguousAppleScriptKeys.contains(key) {
                    appleScriptLookup[key] = track
                }
            }
        }

        var musicKitKeyCounts: [String: Int] = [:]
        for track in musicKitTracks {
            for key in keys(track) {
                musicKitKeyCounts[key, default: 0] += 1
            }
        }
        let ambiguousMusicKitKeys = Set(musicKitKeyCounts.compactMap { key, count in
            count > 1 ? key : nil
        })

        var resultMapping: [String: String] = [:]
        var resultMetadata: [String: Track] = [:]
        for track in musicKitTracks {
            let candidates = keys(track)
                .filter { !ambiguousMusicKitKeys.contains($0) }
                .filter { !ambiguousAppleScriptKeys.contains($0) }
                .compactMap { appleScriptLookup[$0] }
            let uniqueAppleScriptIDs = Set(candidates.map(\.id))
            guard uniqueAppleScriptIDs.count == 1, let appleScriptTrack = candidates.first else { continue }

            resultMapping[track.id] = appleScriptTrack.id
            resultMetadata[track.id] = appleScriptTrack
        }
        return (mapping: resultMapping, metadata: resultMetadata)
    }

    private func normalizedKeys(_ track: Track) -> [String] {
        identityKeys(for: track) { name, artist in
            "\(name)|\(artist)|\(track.album.lowercased())"
        }
    }

    private func nameArtistKeys(_ track: Track) -> [String] {
        identityKeys(for: track) { name, artist in
            "\(name)|\(artist)"
        }
    }

    /// Returns the lowercased identity keys for a track using both its track artist
    /// and album artist, de-duplicated. `buildKey` receives the already-lowercased
    /// name and artist and decides what else to fold into the key.
    private func identityKeys(
        for track: Track,
        _ buildKey: (_ name: String, _ artist: String) -> String
    ) -> [String] {
        let albumArtist = track.albumArtist?.trimmingCharacters(in: .whitespacesAndNewlines)
        var artistValues = [track.artist]
        if let albumArtist, !albumArtist.isEmpty {
            artistValues.append(albumArtist)
        }

        let name = track.name.lowercased()
        var keys: [String] = []
        var seenKeys: Set<String> = []
        for artist in artistValues {
            let key = buildKey(name, artist.lowercased())
            guard seenKeys.insert(key).inserted else { continue }
            keys.append(key)
        }
        return keys
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
