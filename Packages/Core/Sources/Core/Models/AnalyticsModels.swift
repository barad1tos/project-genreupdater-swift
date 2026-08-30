import Foundation

/// High-level subsystem that owns a measured operation.
public enum AnalyticsCategory: String, Codable, CaseIterable, Sendable {
    case library
    case appleScript
    case provider
    case cache
    case determination
    case write
}

/// Privacy-safe result of a measured operation.
public enum AnalyticsOutcome: String, Codable, CaseIterable, Sendable {
    case succeeded
    case failed
    case cancelled
    case degraded

    /// Classifies a thrown operation without retaining its error details.
    public init(error: any Error, isTaskCancelled: Bool) {
        let isURLCancellation = (error as? URLError)?.code == .cancelled
        self = isTaskCancelled || error is CancellationError || isURLCancellation ? .cancelled : .failed
    }
}

/// Stable identity of an operation represented in the performance report.
public enum AnalyticsOperation: String, Codable, CaseIterable, Sendable {
    case libraryLoad = "library.load"
    case musicAppFetch = "musicapp.fetch"
    case appleScriptRun = "applescript.run"
    case appleScriptFetchIDs = "applescript.fetch_ids"
    case appleScriptIdentitySnapshot = "applescript.identity_snapshot"
    case appleScriptMetadataSnapshot = "applescript.metadata_snapshot"
    case appleScriptBatchWrite = "applescript.batch_write"
    case musicBrainzArtistSearch = "musicbrainz.artist_search"
    case musicBrainzReleaseSearch = "musicbrainz.release_search"
    case discogsReleaseDetails = "discogs.release_details"
    case discogsPrimaryRelease = "discogs.master_release"
    case discogsYearSearch = "discogs.year_search"
    case discogsReleaseSearch = "discogs.release_search"
    case iTunesReleaseSearch = "itunes.release_search"
    case albumYearCacheRead = "cache.album_year_read"
    case apiResultCacheRead = "cache.api_result_read"
    case genreDetermination = "genre.determine"
    case yearDetermination = "year.determine"
    case batchProcess = "batch.process"
    case batchWrite = "batch.write"

    /// Subsystem used to group this operation in reports.
    public var category: AnalyticsCategory {
        switch self {
        case .libraryLoad, .musicAppFetch:
            .library
        case .appleScriptRun, .appleScriptFetchIDs, .appleScriptIdentitySnapshot,
             .appleScriptMetadataSnapshot, .appleScriptBatchWrite:
            .appleScript
        case .musicBrainzArtistSearch, .musicBrainzReleaseSearch, .discogsReleaseDetails,
             .discogsPrimaryRelease, .discogsYearSearch, .discogsReleaseSearch, .iTunesReleaseSearch:
            .provider
        case .albumYearCacheRead, .apiResultCacheRead:
            .cache
        case .genreDetermination, .yearDetermination:
            .determination
        case .batchProcess, .batchWrite:
            .write
        }
    }

    /// User-facing label for this operation.
    public var displayName: String {
        switch self {
        case .libraryLoad: "Library load"
        case .musicAppFetch: "Music.app fetch"
        case .appleScriptRun: "AppleScript run"
        case .appleScriptFetchIDs: "AppleScript ID fetch"
        case .appleScriptIdentitySnapshot: "AppleScript identity snapshot"
        case .appleScriptMetadataSnapshot: "AppleScript metadata snapshot"
        case .appleScriptBatchWrite: "AppleScript batch write"
        case .musicBrainzArtistSearch: "MusicBrainz artist search"
        case .musicBrainzReleaseSearch: "MusicBrainz release search"
        case .discogsReleaseDetails: "Discogs release details"
        case .discogsPrimaryRelease: "Discogs master release"
        case .discogsYearSearch: "Discogs year search"
        case .discogsReleaseSearch: "Discogs release search"
        case .iTunesReleaseSearch: "iTunes release search"
        case .albumYearCacheRead: "Album year cache read"
        case .apiResultCacheRead: "API result cache read"
        case .genreDetermination: "Genre determination"
        case .yearDetermination: "Year determination"
        case .batchProcess: "Batch processing"
        case .batchWrite: "Batch write"
        }
    }

    /// Resolves a persisted operation value without failing on future values.
    public static func displayName(for persistedValue: String) -> String {
        Self(rawValue: persistedValue)?.displayName ?? "Unknown operation"
    }
}
