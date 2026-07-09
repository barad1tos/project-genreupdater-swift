import Core
import Foundation

extension UpdateCoordinator {
    static func determineArtistRenameChange(
        track: Track,
        mappings: [String: String]
    ) -> ProposedChange? {
        let currentArtist = track.artist.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedArtist = normalizeForMatching(currentArtist)
        guard !normalizedArtist.isEmpty,
              let newArtist = mappings[normalizedArtist],
              normalizeForMatching(newArtist) != normalizedArtist
        else {
            return nil
        }

        var renamedTrack = track
        renamedTrack.originalArtist = track.originalArtist ?? currentArtist
        renamedTrack.artist = newArtist

        return ProposedChange(
            track: renamedTrack,
            changeType: .artistRename,
            oldValue: currentArtist,
            newValue: newArtist,
            confidence: 100,
            source: "Artist Renamer"
        )
    }
}
