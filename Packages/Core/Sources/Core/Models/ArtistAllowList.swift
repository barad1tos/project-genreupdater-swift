import Foundation

/// Shared normalization and matching for artist-scoped update allow-lists.
public enum ArtistAllowList {
    public static func normalized(_ artists: [String]) -> [String] {
        var normalizedArtists: [String] = []

        for artist in artists {
            guard let trimmedArtist = normalizedName(artist) else { continue }

            let alreadyIncluded = normalizedArtists.contains { existingArtist in
                existingArtist.localizedCaseInsensitiveCompare(trimmedArtist) == .orderedSame
            }
            if !alreadyIncluded {
                normalizedArtists.append(trimmedArtist)
            }
        }

        return normalizedArtists
    }

    public static func normalizedName(_ artist: String?) -> String? {
        let trimmedArtist = artist?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmedArtist.isEmpty ? nil : trimmedArtist
    }

    public static func contains(_ artist: String, in allowedArtists: [String]) -> Bool {
        let normalizedArtists = normalized(allowedArtists)
        guard !normalizedArtists.isEmpty else { return true }

        let trackArtist = artist.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalizedArtists.contains { allowedArtist in
            allowedArtist.localizedCaseInsensitiveCompare(trackArtist) == .orderedSame
        }
    }

    public static func contains(_ track: Track, in allowedArtists: [String]) -> Bool {
        contains(track.effectiveArtist, in: allowedArtists)
    }

    public static func filter(_ tracks: [Track], allowedArtists: [String]) -> [Track] {
        let normalizedArtists = normalized(allowedArtists)
        guard !normalizedArtists.isEmpty else { return tracks }

        return tracks.filter { track in
            contains(track.effectiveArtist, in: normalizedArtists)
        }
    }
}
