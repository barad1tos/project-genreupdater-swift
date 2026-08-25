import Foundation

/// Canonicalizes year values read from Music.app.
public enum MusicAppYear {
    /// Music.app's integer representation of an empty year field.
    public static let missingValue = 0
    /// Earliest year accepted by the bundled Music.app writers.
    public static let earliestWritableValue = 1900
    /// Future-year allowance used for prereleases and scheduled albums.
    public static let futureWriteAllowance = 2

    /// Returns `nil` for Music.app's empty-year sentinel and preserves every other value.
    public static func normalized(_ year: Int?) -> Int? {
        guard let year else { return nil }
        return year == missingValue ? nil : year
    }

    /// Whether a value can be sent to the bundled Music.app writers.
    public static func isWritable(_ year: Int, at date: Date = Date()) -> Bool {
        guard year != missingValue else { return true }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        let latestYear = calendar.component(.year, from: date) + futureWriteAllowance
        return year >= earliestWritableValue && year <= latestYear
    }
}
