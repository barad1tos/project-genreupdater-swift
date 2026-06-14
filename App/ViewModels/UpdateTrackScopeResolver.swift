// UpdateTrackScopeResolver.swift -- resolves Update workflow track scope.

import Core

enum UpdateTrackScopeResolver {
    static func tracksForWorkflow(
        libraryTracks: [Track],
        selectedScopeTracks: [Track]?,
        mode: WorkflowMode
    ) -> [Track] {
        guard mode == .selectedTracks else { return libraryTracks }
        return selectedScopeTracks ?? libraryTracks
    }

    static func reconciledSelectedScope(
        currentScopeTracks: [Track]?,
        libraryTracks: [Track]
    ) -> [Track]? {
        guard let currentScopeTracks else { return nil }

        let scopedTrackIDs = Set(currentScopeTracks.map(\.id))
        return libraryTracks.filter { scopedTrackIDs.contains($0.id) }
    }
}
