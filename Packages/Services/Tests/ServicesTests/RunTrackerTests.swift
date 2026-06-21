// RunTrackerTests.swift — Incremental run timestamp parity tests.

import Foundation
import Testing
@testable import Services

@Suite("IncrementalRunTracker")
struct RunTrackerTests {
    @Test("Writes current timestamp to configured relative file")
    func writesCurrentTimestampToConfiguredRelativeFile() async throws {
        let logsDirectory = temporaryDirectory()
        defer { removeTemporaryDirectory(logsDirectory) }
        let currentDate = Date(timeIntervalSince1970: 1_704_067_200)
        let tracker = IncrementalRunTracker(
            logsBaseDirectory: logsDirectory.path,
            lastIncrementalRunFile: "state/last_incremental_run.log",
            currentDate: { currentDate }
        )

        await tracker.updateLastRunTimestamp()

        let timestampURL = logsDirectory.appending(path: "state/last_incremental_run.log")
        let timestamp = try String(contentsOf: timestampURL, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(try #require(ISO8601DateFormatter().date(from: timestamp)) == currentDate)
        #expect(await tracker.getLastRunTimestamp() == currentDate)
    }

    @Test("Missing timestamp returns nil")
    func missingTimestampReturnsNil() async {
        let logsDirectory = temporaryDirectory()
        defer { removeTemporaryDirectory(logsDirectory) }
        let tracker = IncrementalRunTracker(logsBaseDirectory: logsDirectory.path)

        #expect(await tracker.getLastRunTimestamp() == nil)
    }

    @Test("Invalid timestamp returns nil")
    func invalidTimestampReturnsNil() async throws {
        let logsDirectory = temporaryDirectory()
        defer { removeTemporaryDirectory(logsDirectory) }
        try writeTimestamp("not-a-date", in: logsDirectory)
        let tracker = IncrementalRunTracker(logsBaseDirectory: logsDirectory.path)

        #expect(await tracker.getLastRunTimestamp() == nil)
    }

    @Test("Naive timestamp is treated as UTC")
    func naiveTimestampIsTreatedAsUTC() async throws {
        let logsDirectory = temporaryDirectory()
        defer { removeTemporaryDirectory(logsDirectory) }
        try writeTimestamp("2024-01-01T00:00:00", in: logsDirectory)
        let tracker = IncrementalRunTracker(logsBaseDirectory: logsDirectory.path)

        #expect(await tracker.getLastRunTimestamp() == Date(timeIntervalSince1970: 1_704_067_200))
    }

    @Test("Python UTC timestamp with microseconds is parsed")
    func pythonUTCTimestampWithMicrosecondsIsParsed() async throws {
        let logsDirectory = temporaryDirectory()
        defer { removeTemporaryDirectory(logsDirectory) }
        try writeTimestamp("2024-01-01T00:00:00.123456+00:00", in: logsDirectory)
        let tracker = IncrementalRunTracker(logsBaseDirectory: logsDirectory.path)

        let timestamp = try #require(await tracker.getLastRunTimestamp())
        #expect(abs(timestamp.timeIntervalSince1970 - 1_704_067_200.123_456) < 0.000_001)
    }
}

private func temporaryDirectory() -> URL {
    FileManager.default.temporaryDirectory
        .appending(path: UUID().uuidString, directoryHint: .isDirectory)
}

private func removeTemporaryDirectory(_ url: URL) {
    try? FileManager.default.removeItem(at: url)
}

private func writeTimestamp(_ timestamp: String, in logsDirectory: URL) throws {
    try FileManager.default.createDirectory(
        at: logsDirectory,
        withIntermediateDirectories: true
    )
    try timestamp.write(
        to: logsDirectory.appending(path: "last_incremental_run.log"),
        atomically: true,
        encoding: .utf8
    )
}
