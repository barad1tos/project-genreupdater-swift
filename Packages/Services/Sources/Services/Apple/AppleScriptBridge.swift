// AppleScriptBridge.swift — Music.app write access via NSUserAppleScriptTask
// Ported from: src/services/apple/applescript_client.py (455 LOC)
//              + applescript_executor.py (337 LOC) → merged into actor
//
// CRITICAL ARCHITECTURE DECISION:
// NSUserAppleScriptTask runs scripts OUTSIDE the app sandbox — this is
// Apple's documented mechanism for sandboxed apps to execute AppleScripts.
// Scripts must live in ~/Library/Application Scripts/<bundle-id>/.
// ScriptInstaller handles copying them there during onboarding.
//
// Python used subprocess.run(["osascript", ...]) which can't work in a sandbox.
// NSUserAppleScriptTask is the MAS-compatible replacement.

import Core
import Foundation
import OSLog

private let log = AppLogger.make(category: "applescript")

enum ProcessingMetadataReadRoute: Equatable, Sendable {
    case targeted
    case fullSnapshot
    case artistSnapshots([String])
}

// MARK: - AppleScript Bridge Actor

/// Actor that manages all AppleScript interactions with Music.app.
///
/// Uses NSUserAppleScriptTask for sandbox-compatible script execution.
/// The actor applies configured read retries, rate, and concurrency limits before
/// reaching Music.app.
public actor AppleScriptBridge: MusicAppIdentifying, MusicAppMutating, MusicAppVerifying {
    private static let batchUpdateScriptName = "batch_update_tracks"

    private let installer: ScriptInstaller
    private var config: AppleScriptConfig
    private var libraryPath: String?
    private var rateLimiter: TokenBucketRateLimiter?
    private let concurrencyGate: ScriptGate
    private var analytics: (any AnalyticsService)?

    public init(
        installer: ScriptInstaller,
        config: AppleScriptConfig = .init(),
        libraryPath: String? = nil,
        analytics: (any AnalyticsService)? = nil
    ) {
        self.installer = installer
        self.config = config
        self.libraryPath = libraryPath?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.rateLimiter = Self.makeRateLimiter(configuration: config.rateLimit)
        self.concurrencyGate = ScriptGate(limit: config.concurrency)
        self.analytics = analytics
    }

    var trackIDBatchSize: Int {
        BatchProcessingConfig.clampIDBatch(config.batchProcessing.idsBatchSize)
    }

    func processingMetadataReadRoute(
        requestedCount: Int,
        scope: ProcessingScopeSnapshot
    ) -> ProcessingMetadataReadRoute {
        switch scope.source {
        case .testArtists:
            .artistSnapshots(scope.normalizedTestArtists)
        case .fullLibrary:
            requestedCount >= config.batchProcessing.bulkMetadataThreshold ? .fullSnapshot : .targeted
        }
    }

    public func updateConfiguration(_ config: AppleScriptConfig) async {
        await concurrencyGate.updateLimit(config.concurrency)
        self.config = config
        rateLimiter = Self.makeRateLimiter(configuration: config.rateLimit)
    }

    public func updateLibraryPath(_ path: String) {
        libraryPath = path.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Replaces the optional performance recorder without rebuilding script dispatch state.
    public func updateAnalytics(_ analytics: (any AnalyticsService)?) {
        self.analytics = analytics
    }

    func acquirePermit(
        scriptName: String,
        deadline: ContinuousClock.Instant,
        timeout: Duration
    ) async throws -> ScriptPermit {
        try await concurrencyGate.acquire(
            scriptName: scriptName,
            deadline: deadline,
            timeout: timeout
        )
    }

    func dispatchScript<Value: Sendable>(
        _ call: ScriptCall,
        start: @escaping @Sendable (@escaping @Sendable (Result<Value, any Error>) -> Void) -> Void
    ) async throws -> Value {
        try await ScriptDispatch.run(
            call,
            limiter: rateLimiter,
            gate: concurrencyGate,
            start: start
        )
    }

    public func initialize() async throws {
        let installed = await installer.areScriptsCurrent()
        guard installed else {
            throw AppleScriptBridgeError.scriptsNotInstalled
        }
        log.info("AppleScript bridge initialized — all scripts present")
    }

    // MARK: - Script Execution

    func runScript(
        name: String,
        arguments: [String] = [],
        timeout: Duration? = nil
    ) async throws -> String? {
        guard let analytics else {
            return try await runScriptBody(name: name, arguments: arguments, timeout: timeout)
        }
        return try await analytics.measure(.appleScriptRun) {
            try await self.runScriptBody(name: name, arguments: arguments, timeout: timeout)
        }
    }

    private func runScriptBody(
        name: String,
        arguments: [String],
        timeout: Duration?
    ) async throws -> String? {
        let scriptURL = await installer.scriptURL(for: name)

        guard FileManager.default.fileExists(atPath: scriptURL.path) else {
            throw AppleScriptBridgeError.scriptNotFound(name: name, searchPath: scriptURL.deletingLastPathComponent())
        }

        let runScriptSignpost = AppSignpost.appleScriptWrite.beginInterval("runScript")
        defer { AppSignpost.appleScriptWrite.endInterval("runScript", runScriptSignpost) }

        let validatedArguments = try InputSanitizer.validateAppleEventArguments(arguments)
        let effectiveTimeout = timeout ?? config.timeouts.defaultTimeout
        let retryConfiguration = config.retry

        log
            .info(
                """
                Executing script: \(name, privacy: .public) with \
                \(validatedArguments.count, privacy: .public) arguments
                """
            )

        let deadline = ContinuousClock().now.advanced(by: effectiveTimeout)
        let call = ScriptCall(
            name: name,
            intent: Self.intent(forScript: name),
            deadline: deadline,
            timeout: effectiveTimeout
        )
        return try await executeByIntent(
            scriptName: name,
            retry: retryConfiguration,
            deadline: deadline,
            timeout: effectiveTimeout
        ) { _ in
            try await self.executeScriptAttempt(
                call,
                scriptURL: scriptURL,
                arguments: validatedArguments
            )
        }
    }

    // MARK: - Track Operations

    func fetchTracksByIDs(
        _ trackIDs: [String],
        batchSize: Int = 1000,
        timeout: Duration? = nil
    ) async throws -> [Core.Track] {
        guard let analytics else {
            return try await fetchTracksByIDsBody(trackIDs, batchSize: batchSize, timeout: timeout)
        }
        return try await analytics.measure(.appleScriptFetchIDs) {
            try await self.fetchTracksByIDsBody(trackIDs, batchSize: batchSize, timeout: timeout)
        }
    }

    private func fetchTracksByIDsBody(
        _ trackIDs: [String],
        batchSize: Int,
        timeout: Duration?
    ) async throws -> [Core.Track] {
        let effectiveBatchSize = BatchProcessingConfig.clampIDBatch(batchSize)
        if effectiveBatchSize != batchSize {
            log.info(
                """
                Clamped ID lookup batch size from \(batchSize, privacy: .public) to \
                \(effectiveBatchSize, privacy: .public)
                """
            )
        }
        let effectiveTimeout = timeout ?? config.timeouts.idsBatchFetch
        let tracks = try await TrackLookup(
            batchSize: effectiveBatchSize,
            timeout: effectiveTimeout
        ) { [self] ids, remaining in
            try await runScriptBody(
                name: TrackLookup<Core.Track>.scriptName,
                arguments: [ids.joined(separator: ",")],
                timeout: remaining
            )
        } parse: { output in
            try Self.parseTrackOutput(output)
        }.run(ids: trackIDs)

        log
            .info(
                """
                Fetched \(tracks.count, privacy: .public) tracks by IDs \
                (\(trackIDs.count, privacy: .public) requested)
                """
            )
        return tracks
    }

    func fetchTrackIDCensus(timeout: Duration? = nil) async throws -> TrackIDCensus {
        let effectiveTimeout = timeout ?? config.timeouts.fullLibraryFetch
        return try await scanTrackIDs(timeout: effectiveTimeout) { [self] remaining in
            try await runScriptBody(
                name: "fetch_track_ids",
                arguments: trackIDArguments(),
                timeout: remaining
            )
        }
    }

    func fetchCensus() async throws -> TrackIDCensus {
        try await fetchTrackIDCensus()
    }

    func fetchIdentitySnapshot() async throws -> LibraryIdentitySnapshot {
        guard let analytics else {
            return try await fetchIdentitySnapshotBody()
        }
        return try await analytics.measure(.appleScriptIdentitySnapshot) {
            try await self.fetchIdentitySnapshotBody()
        }
    }

    private func fetchIdentitySnapshotBody() async throws -> LibraryIdentitySnapshot {
        let output = try await runScriptBody(
            name: LibraryIdentitySnapshot.scriptName,
            arguments: trackIDArguments(),
            timeout: config.timeouts.fullLibraryFetch
        )
        guard let output else {
            throw AppleScriptBridgeError.parseError(
                scriptName: LibraryIdentitySnapshot.scriptName,
                detail: "Empty identity snapshot response"
            )
        }
        return try LibraryIdentitySnapshot.decode(output)
    }

    func fetchBulkMetadata(artist: String?) async throws -> LibraryMetadataSnapshot {
        guard let analytics else {
            return try await fetchBulkMetadataBody(artist: artist)
        }
        return try await analytics.measure(.appleScriptMetadataSnapshot) {
            try await self.fetchBulkMetadataBody(artist: artist)
        }
    }

    private func fetchBulkMetadataBody(artist: String?) async throws -> LibraryMetadataSnapshot {
        let output = try await runScriptBody(
            name: LibraryMetadataSnapshot.scriptName,
            arguments: trackIDArguments() + [artist ?? ""],
            timeout: config.timeouts.fullLibraryFetch
        )
        guard let output else {
            throw AppleScriptBridgeError.parseError(
                scriptName: LibraryMetadataSnapshot.scriptName,
                detail: "Empty metadata snapshot response"
            )
        }
        return try LibraryMetadataSnapshot.decode(output)
    }

    func fetchProcessingMetadata(
        for databaseIDs: [MusicDatabaseTrackID],
        scope: ProcessingScopeSnapshot
    ) async throws -> [Core.Track] {
        let requestedIDs = Set(databaseIDs)
        switch processingMetadataReadRoute(requestedCount: databaseIDs.count, scope: scope) {
        case .targeted:
            return try await fetchMetadata(for: databaseIDs)
        case .fullSnapshot:
            let snapshot = try await fetchBulkMetadata(artist: nil)
            return snapshot.tracks.filter { track in
                track.databaseID.map(requestedIDs.contains) ?? false
            }
        case let .artistSnapshots(artists):
            var tracks = [Core.Track]()
            for artist in artists {
                let snapshot = try await fetchBulkMetadata(artist: artist)
                tracks.append(contentsOf: snapshot.tracks.filter { track in
                    track.databaseID.map(requestedIDs.contains) ?? false
                })
            }
            return tracks
        }
    }

    public func fetchMetadata(for databaseIDs: [MusicDatabaseTrackID]) async throws -> [Core.Track] {
        let tracks = try await fetchTracksByIDs(
            databaseIDs.map(\.rawValue),
            batchSize: trackIDBatchSize,
            timeout: config.timeouts.idsBatchFetch
        )
        return try Self.validatedMetadata(tracks, requestedIDs: databaseIDs)
    }

    public func fetchIdentityMetadata(scopedTo artists: [String]) async throws -> [Core.Track] {
        let artists = ArtistAllowList.normalized(artists)
        let tracks: [Core.Track]
        let requestedIDs: Set<MusicDatabaseTrackID>?
        if artists.isEmpty {
            let census = try await fetchTrackIDCensus(timeout: config.timeouts.fullLibraryFetch)
            tracks = try await fetchTracksByIDs(
                census.ids.map(\.rawValue),
                batchSize: trackIDBatchSize,
                timeout: config.timeouts.idsBatchFetch
            )
            requestedIDs = Set(census.ids)
        } else {
            var scopedTracks: [Core.Track] = []
            for artist in artists {
                let artistTracks = try await fetchTracks(artist: artist)
                scopedTracks.append(contentsOf: artistTracks)
            }
            tracks = scopedTracks
            requestedIDs = nil
        }
        return try Self.validatedIdentityMetadata(tracks, requestedIDs: requestedIDs)
    }

    func fetchTracks(artist: String) async throws -> [Core.Track] {
        let output = try await runScript(
            name: "fetch_tracks",
            arguments: [artist],
            timeout: config.timeouts.singleArtistFetch
        )
        guard let output, output != "NO_TRACKS_FOUND" else { return [] }
        do {
            return try TrackWireCodec.decodeRecords(output, scriptName: "fetch_tracks")
        } catch let error as TrackWireError {
            throw AppleScriptBridgeError.parseError(scriptName: error.scriptName, detail: error.detail)
        }
    }

    static func validatedIdentityMetadata(
        _ tracks: [Core.Track],
        requestedIDs: Set<MusicDatabaseTrackID>?
    ) throws -> [Core.Track] {
        var tracksByID: [MusicDatabaseTrackID: Core.Track] = [:]
        var orderedIDs: [MusicDatabaseTrackID] = []
        for track in tracks {
            guard let databaseID = track.databaseID else {
                throw MusicAppIdentityError.unresolvedMetadataIdentity
            }
            guard requestedIDs?.contains(databaseID) != false else {
                throw MusicAppIdentityError.unexpectedMetadata(databaseID)
            }
            if let existing = tracksByID[databaseID] {
                guard existing == track else {
                    throw MusicAppIdentityError.conflictingMetadata(databaseID)
                }
                continue
            }
            tracksByID[databaseID] = track
            orderedIDs.append(databaseID)
        }
        return orderedIDs.compactMap { tracksByID[$0] }
    }

    static func validatedMetadata(
        _ tracks: [Core.Track],
        requestedIDs: [MusicDatabaseTrackID]
    ) throws -> [Core.Track] {
        let requestedIDs = Set(requestedIDs)
        var observedIDs = Set<MusicDatabaseTrackID>()
        for track in tracks {
            guard let databaseID = track.databaseID else {
                throw MusicAppVerificationError.unresolvedMetadataIdentity
            }
            guard requestedIDs.contains(databaseID) else {
                throw MusicAppVerificationError.unexpectedMetadata(databaseID)
            }
            guard observedIDs.insert(databaseID).inserted else {
                throw MusicAppVerificationError.duplicateMetadata(databaseID)
            }
        }
        return tracks
    }

    func scanTrackIDs(timeout: Duration, fetch: @escaping TrackIDScan.Fetch) async throws -> TrackIDCensus {
        let operation = {
            try await TrackIDScan(
                timeout: timeout,
                fetch: fetch
            ).run()
        }
        guard let analytics else {
            return try await operation()
        }
        return try await analytics.measure(.appleScriptFetchIDs, body: operation)
    }

    func trackIDArguments() throws -> [String] {
        guard let libraryPath, !libraryPath.isEmpty else {
            throw AppleScriptBridgeError.invalidLibraryPath
        }
        return [libraryPath]
    }
}

extension AppleScriptBridge {
    // MARK: - Music.app Write Operations

    func applySingleUpdate(
        _ update: MusicTrackUpdate,
        onAttempt: WriteAttemptHook,
        execute: () async throws -> String?
    ) async throws -> MusicWriteResult {
        let output: String?
        do {
            output = try await execute()
        } catch let error as AppleScriptOutcomeError {
            try await recordUnknownAttempt(onAttempt, outcome: error)
            throw error
        }
        try await onAttempt()
        let result = try Self.validateUpdatePropertyOutput(output, update: update)

        log
            .info(
                """
                Completed update_property for \(update.property.rawValue, privacy: .public) on track \
                \(update.databaseID.rawValue, privacy: .private): \(update.value, privacy: .private)
                """
            )
        return result
    }

    public func update(
        _ updates: [MusicTrackUpdate],
        onAttempt: @escaping WriteAttemptHook
    ) async throws {
        try await update(updates, onAttempt: onAttempt) { [self] batchArgument in
            try await runScriptBody(
                name: Self.batchUpdateScriptName,
                arguments: [batchArgument],
                timeout: config.timeouts.batchUpdate
            )
        }
    }

    func update(
        _ updates: [MusicTrackUpdate],
        onAttempt: WriteAttemptHook,
        execute: (String) async throws -> String?
    ) async throws {
        guard !updates.isEmpty else { return }
        guard let analytics else {
            return try await applyBatch(updates, onAttempt: onAttempt, execute: execute)
        }
        return try await analytics.measure(.appleScriptBatchWrite) {
            try await self.applyBatch(updates, onAttempt: onAttempt, execute: execute)
        }
    }

    private func applyBatch(
        _ updates: [MusicTrackUpdate],
        onAttempt: WriteAttemptHook,
        execute: (String) async throws -> String?
    ) async throws {
        let batchSignpost = AppSignpost.appleScriptWrite.beginInterval("batchUpdate")
        defer { AppSignpost.appleScriptWrite.endInterval("batchUpdate", batchSignpost) }

        // Format matches batch_update_tracks.applescript:
        // Fields separated by ASCII 30 (Record Separator), commands by ASCII 29 (Group Separator).
        try await ensureBatchUpdateScriptExists()
        let batchArg = try Self.makeBatchUpdateArgument(updates)
        _ = try InputSanitizer.validateAppleEventArguments([batchArg])

        let output: String?
        do {
            output = try await execute(batchArg)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as AppleScriptBridgeError where Self.isDispatchDeadline(error) {
            // Music.app was never reached, so the caller may safely fall back to single writes.
            throw error
        } catch let error as AppleScriptOutcomeError {
            try await recordUnknownAttempt(onAttempt, outcome: error)
            throw error
        }
        try await onAttempt()

        do {
            try Self.validateBatchUpdateOutput(output, updateCount: updates.count)
        } catch {
            throw MusicBatchVerificationError(
                updateCount: updates.count,
                failedCount: nil,
                reason: "Batch script returned an unverifiable response: \(error.localizedDescription)"
            )
        }
        try await verifyBatchUpdateResult(updates)
        log.info("Batch updated \(updates.count, privacy: .public) tracks")
    }

    private func recordUnknownAttempt(
        _ onAttempt: WriteAttemptHook,
        outcome: AppleScriptOutcomeError
    ) async throws {
        do {
            try await onAttempt()
        } catch let WorkCheckpointError.store(failure) {
            throw WorkCheckpointError.store(failure.withOutcome(outcome))
        } catch {
            log.error("""
            Unknown AppleScript outcome \(outcome.localizedDescription, privacy: .private); attempt hook failed with \
            \(String(describing: type(of: error)), privacy: .public): \
            \(error.localizedDescription, privacy: .private)
            """)
            // The unknown outcome must win over the hook error: it carries the
            // ScriptCompletion (when the script is still pending) that recovery
            // awaits before allowing another physical Music.app write.
            throw outcome
        }
    }

    private func ensureBatchUpdateScriptExists() async throws {
        let scriptURL = await installer.scriptURL(for: Self.batchUpdateScriptName)
        guard FileManager.default.fileExists(atPath: scriptURL.path) else {
            throw AppleScriptBridgeError.scriptNotFound(
                name: Self.batchUpdateScriptName,
                searchPath: scriptURL.deletingLastPathComponent()
            )
        }
    }

    private func verifyBatchUpdateResult(
        _ updates: [MusicTrackUpdate]
    ) async throws {
        let databaseIDs = Array(Set(updates.map(\.databaseID)))
        let refreshedTracks: [Core.Track]
        do {
            refreshedTracks = try await fetchMetadata(for: databaseIDs)
        } catch {
            throw MusicBatchVerificationError(
                updateCount: updates.count,
                failedCount: nil,
                reason: "Could not refresh tracks after batch write: \(error.localizedDescription)"
            )
        }
        try Self.verifyBatchUpdateValues(updates, in: refreshedTracks)
    }

    // MARK: - Private Helpers

    /// Parse AppleScript output into Track objects.
    static func parseTrackOutput(_ output: String) throws -> [Core.Track] {
        do {
            return try TrackWireCodec.decodeRecords(output, scriptName: TrackLookup<Core.Track>.scriptName)
        } catch let error as TrackWireError {
            throw AppleScriptBridgeError.parseError(scriptName: error.scriptName, detail: error.detail)
        }
    }
}

extension AppleScriptBridge {
    static func makeRateLimiter(configuration: AppleScriptRateLimit) -> TokenBucketRateLimiter? {
        guard configuration.enabled else { return nil }

        let requestCount = max(1, configuration.requestsPerWindow)
        let refillMilliseconds = max(1, Int((configuration.windowSizeSeconds / Double(requestCount)) * 1000))
        return TokenBucketRateLimiter(
            maxTokens: requestCount,
            refillInterval: .milliseconds(refillMilliseconds)
        )
    }
}
