// UpdateTrackScopeResolver.swift -- resolves Update workflow track scope.

import Core
import Foundation
import Services

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
        lastRunTime: Date?
    ) -> [Track] {
        guard let lastRunTime else { return tracks }

        let newTracks = tracks.filter { track in
            guard let dateAdded = track.dateAdded else { return false }
            return dateAdded > lastRunTime
        }
        let missingGenreTracks = tracks.filter(isMissingOrUnknownGenre)

        var seenTrackIDs = Set<String>()
        var combinedTracks = [Track]()
        for track in newTracks + missingGenreTracks {
            guard !track.id.isEmpty, seenTrackIDs.insert(track.id).inserted else {
                continue
            }
            combinedTracks.append(track)
        }
        return combinedTracks
    }

    private static func isMissingOrUnknownGenre(_ track: Track) -> Bool {
        guard let genre = track.genre else { return true }
        let normalizedGenre = genre.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalizedGenre.isEmpty || normalizedGenre == "unknown"
    }
}
