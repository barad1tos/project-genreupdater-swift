import Foundation

struct TrackIDScan {
    typealias Fetch = @Sendable (Int, Int, Duration) async throws -> String?

    private let batchSize: Int
    private let timeout: Duration
    private let fetch: Fetch

    init(batchSize: Int, timeout: Duration, fetch: @escaping Fetch) {
        self.batchSize = min(1000, max(1, batchSize))
        self.timeout = timeout
        self.fetch = fetch
    }

    func run() async throws -> [String] {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        var trackIDs: [String] = []
        var seenIDs: Set<String> = []
        var expectedCount: Int?
        var offset = 1

        while true {
            let remaining = clock.now.duration(to: deadline)
            guard remaining > .zero else { throw timeoutError() }
            guard let output = try await fetch(offset, batchSize, remaining) else {
                throw parseError("Empty batch response at offset \(offset)")
            }
            guard clock.now <= deadline else { throw timeoutError() }

            let batch = try parseBatch(output, offset: offset)
            if let expectedCount, batch.totalCount != expectedCount {
                throw AppleScriptBridgeError.libraryChanged(detail: "Track count changed during ID scan")
            }
            guard batch.trackIDs.allSatisfy({ seenIDs.insert($0).inserted }) else {
                throw AppleScriptBridgeError.libraryChanged(detail: "ID scan returned duplicate tracks")
            }

            expectedCount = batch.totalCount
            trackIDs.append(contentsOf: batch.trackIDs)
            guard let nextOffset = batch.nextOffset else { return trackIDs }
            offset = nextOffset
        }
    }

    private func parseBatch(_ output: String, offset: Int) throws -> TrackIDBatch {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.localizedCaseInsensitiveContains("ERROR:") {
            throw AppleScriptBridgeError.executionFailed(
                scriptName: "fetch_track_ids",
                detail: String(trimmed.prefix(200))
            )
        }

        let fields = trimmed.split(separator: ":", maxSplits: 3, omittingEmptySubsequences: false)
        guard fields.count == 4,
              fields[0] == "BATCH",
              let endIndex = Int(fields[1]),
              let totalCount = Int(fields[2])
        else {
            throw parseError("Malformed batch response at offset \(offset)")
        }

        let isEmptyLibrary = totalCount == 0 && endIndex == 0 && fields[3].isEmpty
        let isValidRange = offset > 0
            && totalCount >= offset
            && endIndex >= offset
            && endIndex <= totalCount
        guard isEmptyLibrary || isValidRange else {
            throw AppleScriptBridgeError.libraryChanged(detail: "Track range changed during ID scan")
        }

        let trackIDs = fields[3].isEmpty
            ? []
            : fields[3]
            .split(separator: ",", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        let expectedIDCount = isEmptyLibrary ? 0 : endIndex - offset + 1
        guard trackIDs.count == expectedIDCount, trackIDs.allSatisfy({ !$0.isEmpty }) else {
            throw parseError("Batch ID count does not match its range at offset \(offset)")
        }

        return TrackIDBatch(
            trackIDs: trackIDs,
            nextOffset: endIndex < totalCount ? endIndex + 1 : nil,
            totalCount: totalCount
        )
    }

    private func timeoutError() -> AppleScriptBridgeError {
        .timeout(scriptName: "fetch_track_ids", duration: timeout)
    }

    private func parseError(_ detail: String) -> AppleScriptBridgeError {
        .parseError(scriptName: "fetch_track_ids", detail: detail)
    }
}

private struct TrackIDBatch {
    let trackIDs: [String]
    let nextOffset: Int?
    let totalCount: Int
}
