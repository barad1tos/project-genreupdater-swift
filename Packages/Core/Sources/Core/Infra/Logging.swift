// Logging.swift — Structured logging via os.Logger
// Ported from: src/core/logger.py (1,092 LOC → ~90 LOC)
//
// macOS Unified Logging replaces Python's custom logging infrastructure:
// - Log rotation: Handled by OS (logd)
// - Log levels: os.LogType maps to DEBUG/INFO/ERROR/FAULT
// - Persistence: Automatic via OSLogStore
// - Filtering: `log stream --predicate` or Console.app
// - No file handlers, formatters, or rotation logic needed

import Foundation
import OSLog

/// Subsystem identifier for all Genre Updater logs.
///
/// Use `log stream --predicate 'subsystem == "com.genreupdater.app"'`
/// to filter in Terminal, or search in Console.app.
private let subsystem = "com.genreupdater.app"

// MARK: - Logger Factory

/// Centralized logger creation for consistent subsystem naming.
///
/// Usage:
/// ```swift
/// let log = AppLogger.make(category: "APIClient")
/// log.info("Fetching year for \(artist, privacy: .private) - \(album, privacy: .private)")
/// ```
public enum AppLogger {
    /// Create a logger for a specific category (module/component).
    ///
    /// Categories map to Python logger names: `"genre_manager"`, `"api_client"`, etc.
    public static func make(category: String) -> Logger {
        Logger(subsystem: subsystem, category: category)
    }

    // Pre-built loggers for common categories
    public static let general = make(category: "general")
    public static let appleScript = make(category: "applescript")
    public static let api = make(category: "api")
    public static let cache = make(category: "cache")
    public static let genre = make(category: "genre")
    public static let year = make(category: "year")
    public static let processing = make(category: "processing")
    public static let subscription = make(category: "subscription")
    public static let sync = make(category: "sync")
}

// MARK: - Log Retrieval (for Analytics / Export)

/// Retrieve recent log entries from the unified log store.
///
/// Used by the analytics dashboard to display recent activity.
/// This replaces Python's file-based log reading.
///
/// - Parameters:
///   - category: Optional category filter
///   - since: How far back to look (default: 1 hour)
///   - maxEntries: Maximum entries to return
/// - Returns: Array of formatted log strings
public func fetchRecentLogs(
    category: String? = nil,
    since: Duration = .seconds(3600),
    maxEntries: Int = 100
) throws -> [String] {
    let store = try OSLogStore(scope: .currentProcessIdentifier)
    let position = store.position(date: Date.now.addingTimeInterval(-since.timeInterval))

    var predicate: NSPredicate
    if let category {
        predicate = NSPredicate(format: "subsystem == %@ AND category == %@", subsystem, category)
    } else {
        predicate = NSPredicate(format: "subsystem == %@", subsystem)
    }

    let entries = try store.getEntries(at: position, matching: predicate)

    return entries
        .compactMap { $0 as? OSLogEntryLog }
        .prefix(maxEntries)
        .map { entry in
            let level = switch entry.level {
            case .debug: "DEBUG"
            case .info: "INFO"
            case .error: "ERROR"
            case .fault: "FAULT"
            default: "NOTICE"
            }
            let timestamp = entry.date.formatted(.iso8601)
            return "[\(timestamp)] [\(level)] [\(entry.category)] \(entry.composedMessage)"
        }
}

// MARK: - Duration Extension

extension Duration {
    /// Convert Duration to TimeInterval for Foundation interop.
    public var timeInterval: TimeInterval {
        let (seconds, attoseconds) = components
        return Double(seconds) + Double(attoseconds) / 1_000_000_000_000_000_000
    }
}
