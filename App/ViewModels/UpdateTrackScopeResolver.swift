// UpdateTrackScopeResolver.swift -- resolves Update workflow track scope.

import Core
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
}
