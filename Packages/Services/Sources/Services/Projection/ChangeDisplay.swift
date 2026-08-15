import Core

/// Formats a primary metadata change together with an optional coupled album-artist effect.
///
/// For example, an artist rename from `Massive` to `Massive Attack` with matching album-artist
/// evidence is displayed as `Massive (album artist: Massive)` to
/// `Massive Attack (album artist: Massive Attack)`.
public enum ChangeDisplay {
    /// Returns primary values annotated with the coupled album-artist values when present.
    public static func values(
        oldValue: String?,
        newValue: String?,
        albumArtistChange: AlbumArtistChange?
    ) -> (oldValue: String?, newValue: String?) {
        guard let albumArtistChange else { return (oldValue, newValue) }
        return (
            annotated(oldValue, albumArtist: albumArtistChange.oldValue),
            annotated(newValue, albumArtist: albumArtistChange.newValue)
        )
    }

    private static func annotated(_ value: String?, albumArtist: String) -> String {
        "\(value ?? "none") (album artist: \(albumArtist))"
    }
}
