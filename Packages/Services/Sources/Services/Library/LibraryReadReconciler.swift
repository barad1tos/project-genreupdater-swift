import Core

/// Reconciles fast library reads with the persisted Music.app metadata mirror.
public enum LibraryReadReconciler {
    /// Merges a live track with its persisted Music.app metadata mirror.
    ///
    /// Stored values fill metadata omitted by partial reads. When `appleScript`
    /// is present and `isAuthoritative` is `true`, `nil` genre, year, release-year,
    /// and album-artist values are explicit clears. A missing AppleScript record
    /// falls back to stored values, then to live values where that field's
    /// precedence permits; year falls back only to the stored mirror. Other
    /// optional fields use their non-`nil` source precedence.
    ///
    /// - Parameters:
    ///   - live: Current provider result and source of the returned identity.
    ///   - stored: Persisted mirror used to fill metadata omitted by `live`.
    ///   - appleScript: Optional Music.app-authoritative metadata enrichment.
    ///   - isAuthoritative: Whether `nil` values in a present AppleScript record
    ///     explicitly clear genre, year, release year, and album artist.
    /// - Returns: A track keyed by `live.id`, reconciled from the supplied sources.
    public static func reconcile(
        live: Track,
        stored: Track,
        appleScript: Track? = nil,
        isAuthoritative: Bool = false
    ) -> Track {
        let genre = isAuthoritative
            ? appleScript.map(\.genre) ?? stored.genre ?? live.genre
            : appleScript?.genre ?? stored.genre ?? live.genre
        let year = isAuthoritative
            ? appleScript.map(\.year) ?? stored.year
            : appleScript?.year ?? stored.year
        let releaseYear = isAuthoritative
            ? appleScript.map(\.releaseYear) ?? stored.releaseYear ?? live.releaseYear
            : appleScript?.releaseYear ?? stored.releaseYear ?? live.releaseYear
        let albumArtist = isAuthoritative
            ? appleScript.map(\.albumArtist) ?? stored.albumArtist ?? live.albumArtist
            : appleScript?.albumArtist ?? stored.albumArtist ?? live.albumArtist

        return Track(
            id: live.id,
            name: live.name,
            artist: live.artist,
            album: live.album,
            genre: genre,
            year: year,
            dateAdded: live.dateAdded ?? stored.dateAdded,
            lastModified: appleScript?.lastModified ?? live.lastModified ?? stored.lastModified,
            trackStatus: appleScript?.trackStatus ?? stored.trackStatus,
            originalArtist: live.originalArtist ?? stored.originalArtist,
            originalAlbum: live.originalAlbum ?? stored.originalAlbum,
            yearBeforeMGU: live.yearBeforeMGU ?? stored.yearBeforeMGU,
            yearSetByMGU: live.yearSetByMGU ?? stored.yearSetByMGU,
            releaseYear: releaseYear,
            originalPosition: live.originalPosition ?? stored.originalPosition,
            albumArtist: albumArtist,
            appleScriptID: appleScript?.appleScriptID ?? live.appleScriptID ?? stored.appleScriptID
        )
    }
}
