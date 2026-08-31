import Core
import Foundation
import OSLog

private let log = AppLogger.make(category: "TrackIDScan")

/// Complete Music database membership captured in one stable library generation.
struct TrackIDCensus: Equatable, Sendable {
    let ids: [MusicDatabaseTrackID]
    let totalCount: Int
    let generation: LibraryGeneration

    init(
        ids: [MusicDatabaseTrackID],
        totalCount: Int,
        generation: LibraryGeneration
    ) throws {
        guard ids.count == totalCount else {
            throw TrackIDCensusError.countMismatch(expected: totalCount, actual: ids.count)
        }
        var seenIDs = Set<MusicDatabaseTrackID>()
        for databaseID in ids where !seenIDs.insert(databaseID).inserted {
            throw TrackIDCensusError.duplicateID(databaseID)
        }
        guard ids == ids.sorted(by: { $0.rawValue < $1.rawValue }) else {
            throw TrackIDCensusError.unsorted
        }
        self.ids = ids
        self.totalCount = totalCount
        self.generation = generation
    }
}

struct TrackIDScan {
    private static let maxRestarts = 3

    typealias Fetch = @Sendable (Duration) async throws -> String?

    private let timeout: Duration
    private let fetch: Fetch

    init(timeout: Duration, fetch: @escaping Fetch) {
        self.timeout = timeout
        self.fetch = fetch
    }

    func run() async throws -> TrackIDCensus {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        var restartCount = 0

        while true {
            do {
                return try await scan(clock: clock, deadline: deadline)
            } catch TrackIDScanChange.generation {
                guard clock.now < deadline else {
                    throw AppleScriptBridgeError.libraryChanged(
                        detail: "Library generation changed at the scan deadline after \(restartCount) restarts"
                    )
                }
                guard restartCount < Self.maxRestarts else {
                    throw changingLibraryError(restartCount: restartCount)
                }
                restartCount += 1
                log.info(
                    "Restarting track ID scan after library generation change \(restartCount, privacy: .public)"
                )
            }
        }
    }

    private func scan(
        clock: ContinuousClock,
        deadline: ContinuousClock.Instant
    ) async throws -> TrackIDCensus {
        let remaining = clock.now.duration(to: deadline)
        guard remaining > .zero else { throw timeoutError() }
        guard let output = try await fetch(remaining) else {
            throw parseError("Empty census response")
        }
        guard clock.now <= deadline else { throw timeoutError() }
        return try parseCensus(output)
    }

    private func parseCensus(_ output: String) throws -> TrackIDCensus {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed == "RETRY:GENERATION" {
            throw TrackIDScanChange.generation
        }
        if trimmed.hasPrefix("ERROR:LIBRARY_DB_NOT_FOUND:") {
            log.error("Music library path validation failed: \(trimmed, privacy: .private)")
            throw AppleScriptBridgeError.invalidLibraryPath
        }
        if trimmed.localizedCaseInsensitiveContains("ERROR:") {
            throw AppleScriptBridgeError.executionFailed(
                scriptName: "fetch_track_ids",
                detail: String(trimmed.prefix(200))
            )
        }

        let fields = trimmed.split(separator: ":", maxSplits: 3, omittingEmptySubsequences: false)
        guard fields.count == 4,
              fields[0] == "CENSUS",
              let totalCount = Int(fields[1]),
              totalCount >= 0,
              let generation = LibraryGeneration(sourceValue: String(fields[2]))
        else {
            throw parseError("Malformed census response")
        }

        let rawIDs = fields[3].isEmpty
            ? []
            : fields[3]
            .split(separator: ",", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard rawIDs.count == totalCount else {
            throw parseError("ID census count does not match its payload")
        }

        var typedIDs: [MusicDatabaseTrackID] = []
        typedIDs.reserveCapacity(rawIDs.count)
        for rawID in rawIDs {
            guard UInt64(rawID) != nil,
                  let databaseID = MusicDatabaseTrackID(rawValue: rawID)
            else {
                throw parseError("ID census contains an invalid database ID")
            }
            typedIDs.append(databaseID)
        }

        return try TrackIDCensus(
            ids: typedIDs.sorted { $0.rawValue < $1.rawValue },
            totalCount: totalCount,
            generation: generation
        )
    }

    private func timeoutError() -> AppleScriptBridgeError {
        .timeout(scriptName: "fetch_track_ids", duration: timeout)
    }

    private func parseError(_ detail: String) -> AppleScriptBridgeError {
        .parseError(scriptName: "fetch_track_ids", detail: detail)
    }

    private func changingLibraryError(restartCount: Int) -> AppleScriptBridgeError {
        .libraryChanged(detail: "Library generation kept changing after \(restartCount) scan restarts")
    }
}

enum TrackIDCensusError: Error, Equatable {
    case countMismatch(expected: Int, actual: Int)
    case duplicateID(MusicDatabaseTrackID)
    case unsorted
}

private enum TrackIDScanChange: Error {
    case generation
}
