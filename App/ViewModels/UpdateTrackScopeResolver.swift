// UpdateTrackScopeResolver.swift -- resolves Update workflow track scope.

import Core
import Foundation
import Services

struct IncrementalTrackScopeOptions: Equatable {
    let updateGenre: Bool

    init(updateGenre: Bool = true) {
        self.updateGenre = updateGenre
    }
}

enum UpdateTrackScopeResolver {
    static func tracksForWorkflow(
        libraryTracks: [Track],
        selectedScopeTracks: [Track]?,
        mode: WorkflowMode,
        testArtists: [String] = []
    ) -> [Track] {
        let scopedTracks = if mode == .selectedTracks {
            selectedScopeTracks ?? []
        } else {
            libraryTracks
        }

        return filteredByTestArtists(scopedTracks, testArtists: testArtists)
    }

    static func reconciledSelectedScope(
        currentScopeTracks: [Track]?,
        libraryTracks: [Track],
        testArtists: [String] = []
    ) -> [Track]? {
        guard let currentScopeTracks else { return nil }

        let scopedTrackIDs = Set(currentScopeTracks.map(\.id))
        let reconciledTracks = libraryTracks.filter { scopedTrackIDs.contains($0.id) }
        return filteredByTestArtists(reconciledTracks, testArtists: testArtists)
    }

    static func filteredByTestArtists(
        _ tracks: [Track],
        testArtists: [String]
    ) -> [Track] {
        MusicLibraryReader.filterByTestArtists(tracks, testArtists: testArtists)
    }

    static func incrementalTracks(
        _ tracks: [Track],
        lastRunTime: Date?,
        previousTracks: [Track] = [],
        options: IncrementalTrackScopeOptions = IncrementalTrackScopeOptions()
    ) -> [Track] {
        guard let lastRunTime else { return tracks }

        let newTracks = tracks.filter { track in
            guard let dateAdded = track.dateAdded else { return false }
            return dateAdded > lastRunTime
        }
        let missingGenreTracks = tracks.filter(isMissingOrUnknownGenre)
        let genreMismatchTracks = if options.updateGenre {
            tracksWithGenreMismatch(tracks)
        } else {
            [Track]()
        }
        let changedTracks = tracksChangedSincePreviousSnapshot(
            tracks,
            previousTracks: previousTracks
        )

        return deduplicated(newTracks + missingGenreTracks + genreMismatchTracks + changedTracks)
    }

    private static func deduplicated(_ tracks: [Track]) -> [Track] {
        var seenTrackIDs = Set<String>()
        var combinedTracks = [Track]()
        for track in tracks {
            guard !track.id.isEmpty, seenTrackIDs.insert(track.id).inserted else {
                continue
            }
            combinedTracks.append(track)
        }
        return combinedTracks
    }

    private static func tracksWithGenreMismatch(_ tracks: [Track]) -> [Track] {
        var artistKeys = [String]()
        var tracksByArtist: [String: [Track]] = [:]
        for track in tracks {
            let artistKey = normalizeForMatching(track.effectiveArtist)
            if tracksByArtist[artistKey] == nil {
                artistKeys.append(artistKey)
            }
            tracksByArtist[artistKey, default: []].append(track)
        }
        let genreDeterminator = GenreDeterminator()

        return artistKeys.flatMap { artistKey in
            let artistTracks = tracksByArtist[artistKey] ?? []
            guard let dominantGenre = genreDeterminator.determineDominantGenre(artistTracks: artistTracks).genre else {
                return [Track]()
            }
            return artistTracks.filter { hasGenreMismatch(track: $0, dominantGenre: dominantGenre) }
        }
    }

    private static func tracksChangedSincePreviousSnapshot(
        _ tracks: [Track],
        previousTracks: [Track]
    ) -> [Track] {
        guard !previousTracks.isEmpty else { return [] }

        var previousTracksByID = [String: Track]()
        for previousTrack in previousTracks where !previousTrack.id.isEmpty {
            previousTracksByID[previousTrack.id] = previousTrack
        }

        return tracks.filter { track in
            guard let previousTrack = previousTracksByID[track.id] else { return false }
            return hasRelevantMetadataChange(current: track, previous: previousTrack)
        }
    }

    private static func hasRelevantMetadataChange(current: Track, previous: Track) -> Bool {
        hasMeaningfulStatusChange(current.trackStatus, previous.trackStatus)
            || hasMeaningfulChange(current.genre, previous.genre)
            || hasMeaningfulChange(current.year.map(String.init), previous.year.map(String.init))
    }

    private static func hasMeaningfulStatusChange(_ current: String?, _ previous: String?) -> Bool {
        guard let current, !current.isEmpty, let previous, !previous.isEmpty else { return false }
        return current != previous
    }

    private static func hasMeaningfulChange(_ current: String?, _ previous: String?) -> Bool {
        guard let current, !current.isEmpty else { return false }
        return current != (previous ?? "")
    }

    private static func hasGenreMismatch(track: Track, dominantGenre: String) -> Bool {
        guard let genre = track.genre else { return false }
        let normalizedGenre = genre.trimmingCharacters(in: .whitespacesAndNewlines)
        return !normalizedGenre.isEmpty && genre != dominantGenre
    }

    private static func isMissingOrUnknownGenre(_ track: Track) -> Bool {
        guard let genre = track.genre else { return true }
        let normalizedGenre = genre.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalizedGenre.isEmpty || normalizedGenre == "unknown"
    }
}
