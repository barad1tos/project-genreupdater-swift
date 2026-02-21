// SignpostMarkers.swift — os_signpost performance instrumentation
// Phase 7B: Performance monitoring for Instruments

import OSLog

/// Centralized signpost markers for Instruments profiling.
///
/// Usage with Instruments:
/// ```swift
/// let state = AppSignpost.libraryLoad.beginInterval("fetchAllTracks")
/// defer { AppSignpost.libraryLoad.endInterval("fetchAllTracks", state) }
/// // ... operation ...
/// ```
///
/// View in Instruments → os_signpost → filter by category.
public enum AppSignpost {
    private static let subsystem = "com.genreupdater.app"

    /// Library loading and MusicKit operations.
    public static let libraryLoad = OSSignposter(subsystem: subsystem, category: "library-load")

    /// External API calls (MusicBrainz, Discogs, Apple Music).
    public static let apiCall = OSSignposter(subsystem: subsystem, category: "api-call")

    /// Cache read/write operations (GRDB, SwiftData).
    public static let cacheOperation = OSSignposter(subsystem: subsystem, category: "cache")

    /// AppleScript execution for Music.app writes.
    public static let appleScriptWrite = OSSignposter(subsystem: subsystem, category: "applescript-write")

    /// Batch processing operations.
    public static let batchProcessing = OSSignposter(subsystem: subsystem, category: "batch-processing")

    /// Genre determination algorithm.
    public static let genreDetermination = OSSignposter(subsystem: subsystem, category: "genre")

    /// Year determination algorithm.
    public static let yearDetermination = OSSignposter(subsystem: subsystem, category: "year")
}
