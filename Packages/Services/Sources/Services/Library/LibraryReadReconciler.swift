import Core

/// Reconciles fast library reads with the persisted Music.app metadata mirror.
public enum LibraryReadReconciler {
    /// Preserves mutation metadata omitted by partial reads while allowing an
    /// authoritative AppleScript read to clear writable fields explicitly.
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
