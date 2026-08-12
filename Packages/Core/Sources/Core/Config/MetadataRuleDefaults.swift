import Foundation

/// User-configurable metadata rule groups shipped with the app.
public enum MetadataRuleGroup: String, CaseIterable, Sendable {
    case editionMarkers
    case albumSuffixes
    case specialAlbums
    case compilations
    case reissues
    case soundtracks
    case variousArtists
}

/// Typed shipped defaults for metadata cleaning, matching, and release evidence.
///
/// Lists stay separate by semantic role. Identical text in two lists does not make
/// the rules interchangeable: removing an edition segment and classifying a reissue
/// have different effects in the workflow. Defaults populate missing or new settings;
/// persisted custom and empty lists remain authoritative and are never merged or repopulated.
public enum MetadataRuleDefaults {
    /// Text that identifies removable edition segments in track and album names.
    public static let editionMarkers = [
        "remaster", "remastered", "reissue", "expanded edition", "soundtrack",
        "original motion picture", "original score", "motion picture", "film score",
    ]

    /// Trailing album-title text proposed for removal after edition-segment cleaning.
    public static let albumSuffixes = [
        "Remaster", "Remastered", "Reissue", "Expanded Edition",
        "The 12 Singles", "The 12\" Singles",
    ]

    /// Album-title evidence that triggers special-album handling.
    public static let specialAlbums = ["b-sides", "demo", "demos"]
    /// Album-title evidence that triggers compilation handling.
    public static let compilations = ["greatest hits", "best of", "compilation"]
    /// Album-title evidence that triggers reissue album handling.
    public static let reissues = ["remaster", "remastered", "anniversary"]
    /// Album-title evidence that enables soundtrack lookup and scoring.
    public static let soundtracks = [
        "soundtrack", "original score", "OST", "motion picture", "film score",
    ]
    /// Artist labels that enable Various Artists search behavior.
    public static let variousArtists = [
        "Various Artists", "Various", "VA", "Різні виконавці",
    ]

    /// Release-result text that marks an API candidate as a reissue.
    public static let releaseReissues = ["reissue", "remaster", "remastered"]
    static let normalBrackets = ["deluxe", "remaster", "bonus", "disc", "cd", "version"]

    /// Returns the shipped default values for a user-configurable metadata rule group.
    public static func values(for group: MetadataRuleGroup) -> [String] {
        switch group {
        case .editionMarkers: editionMarkers
        case .albumSuffixes: albumSuffixes
        case .specialAlbums: specialAlbums
        case .compilations: compilations
        case .reissues: reissues
        case .soundtracks: soundtracks
        case .variousArtists: variousArtists
        }
    }

    /// Checks shipped membership after trimming whitespace and folding case.
    public static func contains(_ value: String, in group: MetadataRuleGroup) -> Bool {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return values(for: group).contains { rule in
            rule.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == normalized
        }
    }
}
