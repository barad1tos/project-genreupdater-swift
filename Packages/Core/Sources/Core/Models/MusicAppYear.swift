/// Canonicalizes year values read from Music.app.
public enum MusicAppYear {
    /// Music.app's integer representation of an empty year field.
    public static let missingValue = 0

    /// Returns `nil` for Music.app's empty-year sentinel and preserves every other value.
    public static func normalized(_ year: Int?) -> Int? {
        guard let year else { return nil }
        return year == missingValue ? nil : year
    }
}
