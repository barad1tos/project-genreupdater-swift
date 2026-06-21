// RunTracker.swift — Incremental run timestamp tracking.

import Core
import Foundation
import OSLog

/// Tracks the last successful incremental pipeline run timestamp.
public actor IncrementalRunTracker {
    private let logsBaseDirectory: String
    private let lastIncrementalRunFile: String
    private let currentDate: @Sendable () -> Date
    private let logger = Logger(subsystem: "GenreUpdater.Services", category: "IncrementalRunTracker")

    /// Creates a tracker for the configured last-run timestamp file.
    public init(
        logsBaseDirectory: String = PathsConfig.defaultLogsBaseDirectory,
        lastIncrementalRunFile: String = LoggingConfig().lastIncrementalRunFile,
        currentDate: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.logsBaseDirectory = logsBaseDirectory
        self.lastIncrementalRunFile = lastIncrementalRunFile
        self.currentDate = currentDate
    }

    /// Writes the current timestamp, logging write failures without failing the caller.
    public func updateLastRunTimestamp() async {
        let timestampURL = lastRunTimestampURL()

        do {
            try FileManager.default.createDirectory(
                at: timestampURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let timestamp = Self.iso8601Formatter.string(from: currentDate())
            try timestamp.write(to: timestampURL, atomically: true, encoding: .utf8)
        } catch {
            logger.warning(
                "Failed to update last run timestamp for file '\(timestampURL.path, privacy: .private)': \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    /// Reads the last run timestamp, returning `nil` when no valid timestamp exists.
    public func getLastRunTimestamp() async -> Date? {
        let timestampURL = lastRunTimestampURL()
        guard FileManager.default.fileExists(atPath: timestampURL.path) else {
            return nil
        }

        do {
            let timestamp = try String(contentsOf: timestampURL, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard let date = Self.parseTimestamp(timestamp) else {
                logger.warning(
                    "Failed to parse last run timestamp from file '\(timestampURL.path, privacy: .private)'"
                )
                return nil
            }
            return date
        } catch {
            logger.warning(
                "Failed to read last run timestamp from file '\(timestampURL.path, privacy: .private)': \(error.localizedDescription, privacy: .public)"
            )
            return nil
        }
    }

    private func lastRunTimestampURL() -> URL {
        let logsDirectory = Self.resolvedURL(path: logsBaseDirectory)
        return Self.resolvedURL(path: lastIncrementalRunFile, relativeTo: logsDirectory)
    }

    private static var iso8601Formatter: ISO8601DateFormatter {
        ISO8601DateFormatter()
    }

    private static func parseTimestamp(_ timestamp: String) -> Date? {
        if let date = iso8601Formatter.date(from: timestamp) {
            return date
        }
        if let date = fractionalISO8601Formatter.date(from: timestamp) {
            return adjustedForMicroseconds(date, timestamp: timestamp)
        }

        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)

        for format in ["yyyy-MM-dd'T'HH:mm:ss.SSSSSS", "yyyy-MM-dd'T'HH:mm:ss"] {
            formatter.dateFormat = format
            if let date = formatter.date(from: timestamp) {
                return adjustedForMicroseconds(date, timestamp: timestamp)
            }
        }
        return nil
    }

    private static var fractionalISO8601Formatter: ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }

    private static func adjustedForMicroseconds(_ date: Date, timestamp: String) -> Date {
        date.addingTimeInterval(microsecondAdjustment(for: timestamp))
    }

    private static func microsecondAdjustment(for timestamp: String) -> TimeInterval {
        guard let dotIndex = timestamp.firstIndex(of: ".") else {
            return 0
        }

        var digits = ""
        var currentIndex = timestamp.index(after: dotIndex)
        while currentIndex < timestamp.endIndex, timestamp[currentIndex].isNumber {
            digits.append(timestamp[currentIndex])
            currentIndex = timestamp.index(after: currentIndex)
        }
        guard digits.count > 3 else {
            return 0
        }

        let microsecondDigits = String(digits.prefix(6)).padding(
            toLength: 6,
            withPad: "0",
            startingAt: 0
        )
        let millisecondDigits = String(digits.prefix(3)).padding(
            toLength: 3,
            withPad: "0",
            startingAt: 0
        )
        guard let microseconds = Double(microsecondDigits),
              let milliseconds = Double(millisecondDigits)
        else {
            return 0
        }
        return microseconds / 1_000_000 - milliseconds / 1000
    }

    private static func resolvedURL(path: String, relativeTo baseURL: URL? = nil) -> URL {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let appSupport = defaultDirectory().path
        var expandedPath = path
            .replacingOccurrences(of: "${APP_SUPPORT}", with: appSupport)
            .replacingOccurrences(of: "${HOME}", with: home)
            .replacingOccurrences(of: "$HOME", with: home)
        if expandedPath == "~" {
            expandedPath = home
        } else if expandedPath.hasPrefix("~/") {
            expandedPath = home + String(expandedPath.dropFirst())
        }

        if expandedPath.hasPrefix("/") {
            return URL(fileURLWithPath: expandedPath)
        }
        return (baseURL ?? FileManager.default.temporaryDirectory).appendingPathComponent(expandedPath)
    }

    private static func defaultDirectory() -> URL {
        let directories = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )
        guard let appSupport = directories.first else {
            return URL(fileURLWithPath: NSTemporaryDirectory())
        }
        return appSupport.appendingPathComponent("GenreUpdater", isDirectory: true)
    }
}
