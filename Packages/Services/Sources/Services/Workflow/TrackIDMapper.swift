import Core
import Foundation
import OSLog

// MARK: - Track ID Mapper

struct TrackIDResolution: Equatable, Sendable {
    let matches: [String: Track]
    let ambiguous: [String: [String]]
    let unresolved: [String]
}

/// Maps MusicKit IDs to AppleScript database IDs by matching on (name, artist/albumArtist, album).
///
/// MusicKit returns numeric `MusicItemID` strings while AppleScript uses its
/// own integer database IDs. These are different ID spaces with no direct translation.
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
        appleScriptTracks: [Track],
        mergeExisting: Bool = false
    ) {
        let resolution = Self.resolve(
            sourceTracks: musicKitTracks,
            targetTracks: appleScriptTracks
        )
        let updatedMapping = resolution.matches.mapValues(\.id)
        let updatedMetadata = resolution.matches

        if mergeExisting {
            for track in musicKitTracks {
                mapping.removeValue(forKey: track.id)
                appleScriptMetadataByMusicKitID.removeValue(forKey: track.id)
            }
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
        identitySource: any MusicAppIdentifying,
        testArtists: [String] = [],
        mergeExisting: Bool = false
    ) async throws -> Int {
        let appleScriptTracks = try await identitySource.fetchIdentityMetadata(
            scopedTo: ArtistAllowList.normalized(testArtists)
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

    public func seedKnownMappings(_ entries: [(musicKitTrack: Track, appleScriptTrack: Track)]) {
        for entry in entries {
            let appleScriptID = entry.appleScriptTrack.appleScriptID ?? entry.appleScriptTrack.id
            mapping[entry.musicKitTrack.id] = appleScriptID
            appleScriptMetadataByMusicKitID[entry.musicKitTrack.id] = entry.appleScriptTrack
        }

        log.info("Seeded ID mapping for \(entries.count, privacy: .public) reviewed write tracks")
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

    static func resolve(
        sourceTracks: [Track],
        targetTracks: [Track]
    ) -> TrackIDResolution {
        var matches = matchByKeys(
            sourceTracks: sourceTracks,
            targetTracks: targetTracks,
            keys: normalizedKeys
        )

        let unmatchedSources = sourceTracks.filter { matches[$0.id] == nil }
        if !unmatchedSources.isEmpty {
            let claimedTargetIDs = Set(matches.values.map(\.id))
            let availableTargets = targetTracks.filter { !claimedTargetIDs.contains($0.id) }
            let fallbackMatches = matchByKeys(
                sourceTracks: unmatchedSources,
                targetTracks: availableTargets,
                keys: nameArtistKeys
            )
            matches.merge(fallbackMatches) { existing, _ in existing }
        }

        let candidateIndex = candidateIndex(targetTracks)
        var ambiguous: [String: [String]] = [:]
        var unresolved: [String] = []
        for source in sourceTracks where matches[source.id] == nil {
            let sourceKeys = Set(normalizedKeys(source) + nameArtistKeys(source))
            let candidateIDs = sourceKeys.reduce(into: Set<String>()) { result, key in
                result.formUnion(candidateIndex[key, default: []])
            }
            .sorted()
            if candidateIDs.isEmpty {
                unresolved.append(source.id)
            } else {
                ambiguous[source.id] = candidateIDs
            }
        }

        return TrackIDResolution(
            matches: matches,
            ambiguous: ambiguous,
            unresolved: unresolved.sorted()
        )
    }

    /// Resolves historical aliases independently so multiple legacy IDs may select the same unique Music database row.
    /// Exact album identity wins; name-and-artist matching is used only when the exact key has no candidate.
    static func resolveAliases(
        sourceTracks: [Track],
        targetTracks: [Track]
    ) -> TrackIDResolution {
        let targetsByID = Dictionary(uniqueKeysWithValues: targetTracks.map { ($0.id, $0) })
        let exactIndex = candidateIndex(targetTracks, keys: normalizedKeys)
        let fallbackIndex = candidateIndex(targetTracks, keys: nameArtistKeys)
        var matches: [String: Track] = [:]
        var ambiguous: [String: [String]] = [:]
        var unresolved: [String] = []

        for source in sourceTracks {
            let exactCandidates = candidateIDs(for: source, in: exactIndex, keys: normalizedKeys)
            let candidateIDs = exactCandidates.isEmpty
                ? candidateIDs(for: source, in: fallbackIndex, keys: nameArtistKeys)
                : exactCandidates
            if candidateIDs.count == 1,
               let targetID = candidateIDs.first,
               let target = targetsByID[targetID] {
                matches[source.id] = target
            } else if candidateIDs.isEmpty {
                unresolved.append(source.id)
            } else {
                ambiguous[source.id] = candidateIDs
            }
        }

        return TrackIDResolution(
            matches: matches,
            ambiguous: ambiguous,
            unresolved: unresolved.sorted()
        )
    }

    private static func candidateIndex(_ targets: [Track]) -> [String: Set<String>] {
        var candidateIndex: [String: Set<String>] = [:]
        for target in targets {
            let keys = Set(normalizedKeys(target) + nameArtistKeys(target))
            for key in keys {
                candidateIndex[key, default: []].insert(target.id)
            }
        }
        return candidateIndex
    }

    private static func candidateIndex(
        _ targets: [Track],
        keys: (Track) -> [String]
    ) -> [String: Set<String>] {
        var index: [String: Set<String>] = [:]
        for target in targets {
            for key in keys(target) {
                index[key, default: []].insert(target.id)
            }
        }
        return index
    }

    private static func candidateIDs(
        for source: Track,
        in index: [String: Set<String>],
        keys: (Track) -> [String]
    ) -> [String] {
        keys(source).reduce(into: Set<String>()) { result, key in
            result.formUnion(index[key, default: []])
        }.sorted()
    }

    /// Builds a MusicKit→AppleScript mapping by matching tracks on the keys produced
    /// by `keys`. A key shared by more than one track on either side is ambiguous and
    /// skipped, so only a unique cross-side match is accepted.
    private static func matchByKeys(
        sourceTracks: [Track],
        targetTracks: [Track],
        keys: (Track) -> [String]
    ) -> [String: Track] {
        var targetLookup: [String: Track] = [:]
        var ambiguousTargetKeys: Set<String> = []
        for track in targetTracks {
            for key in keys(track) {
                if targetLookup[key] != nil {
                    targetLookup[key] = nil
                    ambiguousTargetKeys.insert(key)
                } else if !ambiguousTargetKeys.contains(key) {
                    targetLookup[key] = track
                }
            }
        }

        var sourceKeyCounts: [String: Int] = [:]
        for track in sourceTracks {
            for key in keys(track) {
                sourceKeyCounts[key, default: 0] += 1
            }
        }
        let ambiguousSourceKeys = Set(sourceKeyCounts.compactMap { key, count in
            count > 1 ? key : nil
        })

        var matches: [String: Track] = [:]
        for track in sourceTracks {
            let candidates = keys(track)
                .filter { !ambiguousSourceKeys.contains($0) }
                .filter { !ambiguousTargetKeys.contains($0) }
                .compactMap { targetLookup[$0] }
            let uniqueTargetIDs = Set(candidates.map(\.id))
            guard uniqueTargetIDs.count == 1, let target = candidates.first else { continue }

            matches[track.id] = target
        }
        return matches
    }

    private static func normalizedKeys(_ track: Track) -> [String] {
        identityKeys(for: track) { name, artist in
            "\(name)|\(artist)|\(track.album.lowercased())"
        }
    }

    private static func nameArtistKeys(_ track: Track) -> [String] {
        identityKeys(for: track) { name, artist in
            "\(name)|\(artist)"
        }
    }

    /// Returns the lowercased identity keys for a track using both its track artist
    /// and album artist, de-duplicated. `buildKey` receives the already-lowercased
    /// name and artist and decides what else to fold into the key.
    private static func identityKeys(
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
}
