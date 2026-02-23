// BrowseBuilders.swift -- Pure functions for building artist groups and album summaries.

import Core

// MARK: - Browse Builders

/// Pure functions for building artist groups and album summaries from track arrays.
///
/// Extracted to avoid actor isolation constraints in `Task.detached` contexts
/// and to eliminate duplication between main-thread and off-main-thread builders.
enum BrowseBuilders {
    static func buildArtistGroup(from artistTracks: [Track]) -> ArtistGroup {
        var variantCounts: [String: Int] = [:]
        for track in artistTracks {
            variantCounts[track.effectiveArtist, default: 0] += 1
        }
        let sortedVariants = variantCounts.sorted { $0.value > $1.value }
        let canonicalName = sortedVariants.first?.key ?? ""
        let variants = sortedVariants.map(\.key)
        let uniqueAlbums = Set(artistTracks.map(\.album))

        let primaryGenre = dominantGenre(in: artistTracks)
        let healthRatio = computeHealthRatio(artistTracks)
        let lastModified = artistTracks.compactMap(\.lastModified).max()

        return ArtistGroup(
            canonicalName: canonicalName,
            variants: variants,
            albumCount: uniqueAlbums.count,
            totalTrackCount: artistTracks.count,
            primaryGenre: primaryGenre,
            healthRatio: healthRatio,
            lastModified: lastModified
        )
    }

    static func buildAlbumSummary(from albumTracks: [Track]) -> AlbumSummary {
        let artist = albumTracks.first?.effectiveArtist ?? ""
        let albumName = albumTracks.first?.album ?? ""
        let year = albumTracks.compactMap(\.year).first
            ?? albumTracks.compactMap(\.releaseYear).first

        return AlbumSummary(
            name: albumName,
            artist: artist,
            year: year,
            trackCount: albumTracks.count,
            primaryGenre: dominantGenre(in: albumTracks),
            healthRatio: computeHealthRatio(albumTracks)
        )
    }

    private static func dominantGenre(in tracks: [Track]) -> String? {
        var frequency: [String: Int] = [:]
        for track in tracks {
            if let genre = track.genre, !genre.isEmpty {
                frequency[genre, default: 0] += 1
            }
        }
        return frequency.max(by: { $0.value < $1.value })?.key
    }

    private static func computeHealthRatio(_ tracks: [Track]) -> Double {
        guard !tracks.isEmpty else { return 0 }
        let completeCount = tracks.count(where: { track in
            let hasGenre = track.genre.map { !$0.isEmpty } ?? false
            return hasGenre && track.year != nil
        })
        return Double(completeCount) / Double(tracks.count)
    }
}
