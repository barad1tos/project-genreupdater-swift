import Core

enum LibrarySyncRemovalDecision {
    static func removedTrackID(
        for track: Track,
        libraryIDSet: Set<String>,
        hasReadProvider: Bool
    ) -> String? {
        if libraryIDSet.contains(track.id) {
            return nil
        }
        if let appleScriptID = track.appleScriptID {
            return libraryIDSet.contains(appleScriptID) ? nil : track.id
        }
        // Rows without AppleScript identity can be legacy AppleScript-keyed rows
        // from older stores. Preserve them until an explicit identity migration
        // can distinguish legacy rows from MusicKit-only rows.
        return hasReadProvider ? nil : track.id
    }
}
