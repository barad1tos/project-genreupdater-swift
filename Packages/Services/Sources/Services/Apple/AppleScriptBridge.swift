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

// MARK: - AppleScript Bridge Actor

/// Actor that manages all AppleScript interactions with Music.app.
///
/// Uses NSUserAppleScriptTask for sandbox-compatible script execution.
/// The actor applies configured read retries, rate, and concurrency limits before
/// reaching Music.app.
public actor AppleScriptBridge: AppleScriptClient {
    private static let batchUpdateScriptName = "batch_update_tracks"

    private let installer: ScriptInstaller
    private var config: AppleScriptConfig
    private var libraryPath: String?
    private var rateLimiter: TokenBucketRateLimiter?
    private let concurrencyGate: ScriptGate

    public init(
        installer: ScriptInstaller,
        config: AppleScriptConfig = .init(),
        libraryPath: String? = nil
    ) {
        self.installer = installer
        self.config = config
        self.libraryPath = libraryPath?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.rateLimiter = Self.makeRateLimiter(configuration: config.rateLimit)
        self.concurrencyGate = ScriptGate(limit: config.concurrency)
    }

    public var trackIDBatchSize: Int {
        BatchProcessingConfig.clampIDBatch(config.batchProcessing.idsBatchSize)
    }

    public func updateConfiguration(_ config: AppleScriptConfig) async {
        await concurrencyGate.updateLimit(config.concurrency)
        self.config = config
        rateLimiter = Self.makeRateLimiter(configuration: config.rateLimit)
    }

    public func updateLibraryPath(_ path: String) {
        libraryPath = path.trimmingCharacters(in: .whitespacesAndNewlines)
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

    public func runScript(
        name: String,
        arguments: [String] = [],
        timeout: Duration? = nil
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

    public func fetchTracksByIDs(
        _ trackIDs: [String],
        batchSize: Int = 1000,
        timeout: Duration? = nil
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
            try await runScript(
                name: TrackLookup.scriptName,
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

    public func fetchAllTrackIDs(timeout: Duration? = nil) async throws -> [String] {
        let effectiveTimeout = timeout ?? config.timeouts.fullLibraryFetch
        let ids = try await scanTrackIDs(timeout: effectiveTimeout) { [self] offset, limit, remaining in
            try await runScript(
                name: "fetch_track_ids",
                arguments: trackIDArguments(offset: offset, limit: limit),
                timeout: remaining
            )
        }
        log.info("Fetched \(ids.count, privacy: .public) track IDs from library")
        return ids
    }

    func scanTrackIDs(timeout: Duration, fetch: @escaping TrackIDScan.Fetch) async throws -> [String] {
        try await TrackIDScan(
            batchSize: config.batchProcessing.batchSize,
            timeout: timeout,
            fetch: fetch
        ).run()
    }

    func trackIDArguments(offset: Int, limit: Int) throws -> [String] {
        guard let libraryPath, !libraryPath.isEmpty else {
            throw AppleScriptBridgeError.invalidLibraryPath
        }
        return [String(offset), String(limit), libraryPath]
    }
}

extension AppleScriptBridge {
    // MARK: - Music.app Write Operations

    func updateTrackProperty(
        trackID: String,
        property: String,
        value: String,
        onAttempt: WriteAttemptHook?,
        execute: () async throws -> String?
    ) async throws -> AppleScriptWriteResult {
        let output: String?
        do {
            output = try await execute()
        } catch let error as AppleScriptOutcomeError {
            try await recordUnknownAttempt(onAttempt, outcome: error)
            throw error
        }
        try await onAttempt?()
        let result = try Self.validateUpdatePropertyOutput(output, trackID: trackID, property: property)

        log
            .info(
                """
                Completed update_property for \(property, privacy: .public) on track \
                \(trackID, privacy: .private): \(value, privacy: .private)
                """
            )
        return result
    }

    /// Batch update multiple tracks' properties.
    public func batchUpdateTracks(_ updates: [TrackPropertyUpdate]) async throws {
        try await batchUpdateTracks(updates, onAttempt: nil) { [self] batchArgument in
            try await runScript(
                name: Self.batchUpdateScriptName,
                arguments: [batchArgument],
                timeout: config.timeouts.batchUpdate
            )
        }
    }

    public func batchUpdateTracks(
        _ updates: [TrackPropertyUpdate],
        onAttempt: @escaping WriteAttemptHook
    ) async throws {
        try await batchUpdateTracks(updates, onAttempt: onAttempt) { [self] batchArgument in
            try await runScript(
                name: Self.batchUpdateScriptName,
                arguments: [batchArgument],
                timeout: config.timeouts.batchUpdate
            )
        }
    }

    func batchUpdateTracks(
        _ updates: [TrackPropertyUpdate],
        onAttempt: WriteAttemptHook?,
        execute: (String) async throws -> String?
    ) async throws {
        let batchUpdateSignpost = AppSignpost.appleScriptWrite.beginInterval("batchUpdateTracks")
        defer { AppSignpost.appleScriptWrite.endInterval("batchUpdateTracks", batchUpdateSignpost) }

        // Format matches batch_update_tracks.applescript:
        // Fields separated by ASCII 30 (Record Separator), commands by ASCII 29 (Group Separator).
        guard !updates.isEmpty else { return }

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
        try await onAttempt?()

        do {
            try Self.validateBatchUpdateOutput(output, updateCount: updates.count)
        } catch {
            throw AppleScriptBatchVerificationError(
                updateCount: updates.count,
                failedCount: nil,
                reason: "Batch script returned an unverifiable response: \(error.localizedDescription)"
            )
        }
        try await verifyBatchUpdateResult(updates)
        log.info("Batch updated \(updates.count, privacy: .public) tracks")
    }

    private func recordUnknownAttempt(
        _ onAttempt: WriteAttemptHook?,
        outcome: AppleScriptOutcomeError
    ) async throws {
        guard let onAttempt else { return }
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
            // ScriptCompletion that recovery awaits before allowing another
            // physical Music.app write.
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
        _ updates: [TrackPropertyUpdate]
    ) async throws {
        let trackIDs = Array(Set(updates.map(\.trackID)))
        let refreshedTracks: [Core.Track]
        do {
            refreshedTracks = try await fetchTracksByIDs(
                trackIDs,
                batchSize: trackIDBatchSize,
                timeout: config.timeouts.idsBatchFetch
            )
        } catch {
            throw AppleScriptBatchVerificationError(
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
            return try parseTrackRecords(output, scriptName: TrackLookup.scriptName)
        } catch let error as AppleScriptClientParseError {
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
