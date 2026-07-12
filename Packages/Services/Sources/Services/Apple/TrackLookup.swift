import Core

struct TrackLookup {
    static let scriptName = "lookup_tracks"

    typealias Fetch = @Sendable ([String], Duration) async throws -> String?
    typealias Now = @Sendable () -> ContinuousClock.Instant
    typealias Parse = @Sendable (String) throws -> [Core.Track]

    private let batchSize: Int
    private let batchTimeout: Duration
    private let fetch: Fetch
    private let now: Now
    private let parse: Parse

    init(
        batchSize: Int,
        timeout: Duration,
        now: @escaping Now = { ContinuousClock().now },
        fetch: @escaping Fetch,
        parse: @escaping Parse
    ) {
        self.batchSize = BatchProcessingConfig.clampIDBatch(batchSize)
        batchTimeout = timeout
        self.fetch = fetch
        self.now = now
        self.parse = parse
    }

    func run(ids: [String]) async throws -> [Core.Track] {
        guard !ids.isEmpty else { return [] }

        let batchCount = 1 + (ids.count - 1) / batchSize
        let totalTimeout = batchTimeout * batchCount
        let deadline = now().advanced(by: totalTimeout)
        var tracks: [Core.Track] = []
        var startIndex = 0

        while startIndex < ids.count {
            let remaining = now().duration(to: deadline)
            guard remaining > .zero else { throw timeoutError(duration: totalTimeout) }

            let endIndex = min(startIndex + batchSize, ids.count)
            let batch = Array(ids[startIndex ..< endIndex])
            let output = try await fetch(batch, min(batchTimeout, remaining))
            guard now() <= deadline else { throw timeoutError(duration: totalTimeout) }
            guard let output else {
                startIndex = endIndex
                continue
            }
            try tracks.append(contentsOf: parse(output))
            guard now() <= deadline else { throw timeoutError(duration: totalTimeout) }
            startIndex = endIndex
        }

        return tracks
    }

    private func timeoutError(duration: Duration) -> AppleScriptBridgeError {
        .timeout(scriptName: Self.scriptName, duration: duration)
    }
}
