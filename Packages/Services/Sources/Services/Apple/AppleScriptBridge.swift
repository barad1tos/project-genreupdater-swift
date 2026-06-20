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

import Carbon.OpenScripting
import Core
import Foundation
import OSLog

private let log = AppLogger.make(category: "applescript")

// MARK: - Errors

/// Errors from AppleScript execution.
public enum AppleScriptBridgeError: Error, LocalizedError {
    case scriptNotFound(name: String, searchPath: URL)
    case executionFailed(scriptName: String, detail: String)
    case timeout(scriptName: String, duration: Duration)
    case parseError(scriptName: String, detail: String)
    case scriptsNotInstalled
    case musicAppNotRunning

    public var errorDescription: String? {
        switch self {
        case let .scriptNotFound(name, path):
            "Script '\(name).scpt' not found at \(path.path)"
        case let .executionFailed(name, detail):
            "AppleScript '\(name)' failed: \(detail)"
        case let .timeout(name, duration):
            "AppleScript '\(name)' timed out after \(duration)"
        case let .parseError(name, detail):
            "Failed to parse output from '\(name)': \(detail)"
        case .scriptsNotInstalled:
            "AppleScript files are not installed. Please run the setup wizard."
        case .musicAppNotRunning:
            "Music.app is not running. Please start Music.app before using Genre Updater."
        }
    }
}

// MARK: - Sendable Wrapper

// Safety: NSUserAppleScriptTask and NSAppleEventDescriptor are not Sendable
// but each wrapped value is confined to one bounded AppleScript execution.
private struct UnsafeSendable<T>: @unchecked Sendable {
    let value: T
}

private actor AppleScriptConcurrencyGate {
    private var availablePermits: Int
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(limit: Int) {
        availablePermits = AppleScriptBridge.normalizedConcurrencyLimit(limit)
    }

    func withPermit<T: Sendable>(_ operation: @Sendable () async throws -> T) async throws -> T {
        await acquire()
        do {
            try Task.checkCancellation()
        } catch {
            release()
            throw error
        }
        defer { release() }
        return try await operation()
    }

    private func acquire() async {
        guard availablePermits <= 0 else {
            availablePermits -= 1
            return
        }

        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    private func release() {
        guard !waiters.isEmpty else {
            availablePermits += 1
            return
        }

        let nextWaiter = waiters.removeFirst()
        nextWaiter.resume()
    }
}

// MARK: - AppleScript Bridge Actor

/// Actor that manages all AppleScript interactions with Music.app.
///
/// Uses NSUserAppleScriptTask for sandbox-compatible script execution.
/// The actor applies configured retry, rate, and concurrency limits before
/// reaching Music.app.
public actor AppleScriptBridge: AppleScriptClient {
    private let installer: ScriptInstaller
    private var config: AppleScriptConfig
    private var rateLimiter: TokenBucketRateLimiter?
    private var concurrencyGate: AppleScriptConcurrencyGate

    public init(installer: ScriptInstaller, config: AppleScriptConfig = .init()) {
        self.installer = installer
        self.config = config
        self.rateLimiter = Self.makeRateLimiter(configuration: config.rateLimit)
        self.concurrencyGate = AppleScriptConcurrencyGate(limit: config.concurrency)
    }

    public func updateConfiguration(_ config: AppleScriptConfig) {
        self.config = config
        rateLimiter = Self.makeRateLimiter(configuration: config.rateLimit)
        concurrencyGate = AppleScriptConcurrencyGate(limit: config.concurrency)
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

        let sanitizedArgs = try InputSanitizer.sanitizeArguments(arguments)
        let effectiveTimeout = timeout ?? config.timeouts.defaultTimeout
        let retryConfiguration = config.retry

        log.info("Executing script: \(name, privacy: .public) with \(sanitizedArgs.count, privacy: .public) arguments")

        return try await retryAppleScriptOperation(scriptName: name, retry: retryConfiguration) {
            try await self.executeScriptAttempt(
                name: name,
                scriptURL: scriptURL,
                arguments: sanitizedArgs,
                timeout: effectiveTimeout
            )
        }
    }

    // MARK: - Track Operations

    public func fetchTracksByIDs(
        _ trackIDs: [String],
        batchSize: Int = 1000,
        timeout: Duration? = nil
    ) async throws -> [Core.Track] {
        var allTracks: [Core.Track] = []
        let effectiveTimeout = timeout ?? config.timeouts.idsBatchFetch

        for batch in trackIDs.chunked(into: batchSize) {
            let idsArg = batch.joined(separator: ",")
            guard let output = try await runScript(
                name: "fetch_tracks_by_ids",
                arguments: [idsArg],
                timeout: effectiveTimeout
            ) else {
                continue
            }

            let tracks = parseTrackOutput(output)
            allTracks.append(contentsOf: tracks)
        }

        log
            .info(
                "Fetched \(allTracks.count, privacy: .public) tracks by IDs (\(trackIDs.count, privacy: .public) requested)"
            )
        return allTracks
    }

    public func fetchAllTrackIDs(timeout: Duration? = nil) async throws -> [String] {
        let effectiveTimeout = timeout ?? config.timeouts.fullLibraryFetch
        guard let output = try await runScript(name: "fetch_track_ids", timeout: effectiveTimeout) else {
            return []
        }

        let ids = Self.parseTrackIDOutput(output)
        log.info("Fetched \(ids.count, privacy: .public) track IDs from library")
        return ids
    }

    // MARK: - Music.app Write Operations

    /// Update a property of a track in Music.app.
    public func updateTrackProperty(trackID: String, property: String, value: String) async throws {
        let output = try await runScript(
            name: "update_property",
            arguments: [trackID, property, value]
        )
        log
            .info(
                "Updated \(property, privacy: .public) for track \(trackID, privacy: .private): \(value, privacy: .private)"
            )

        if let output, output.lowercased().contains("error") {
            throw AppleScriptBridgeError.executionFailed(
                scriptName: "update_property",
                detail: "Track=\(trackID), property=\(property), response=\(output)"
            )
        }
    }

    /// Batch update multiple tracks' properties.
    public func batchUpdateTracks(_ updates: [(trackID: String, property: String, value: String)]) async throws {
        let batchUpdateSignpost = AppSignpost.appleScriptWrite.beginInterval("batchUpdateTracks")
        defer { AppSignpost.appleScriptWrite.endInterval("batchUpdateTracks", batchUpdateSignpost) }

        // Format matches batch_update_tracks.applescript:
        // Fields separated by ASCII 30 (Record Separator), commands by ASCII 29 (Group Separator).
        let fieldSep = String(Core.Track.fieldSeparator) // \x1E — between fields
        let commandSep = String(Core.Track.recordSeparator) // \x1D — between commands
        let batchArg: String = updates.map { update -> String in
            let escapedID = InputSanitizer.escapeStringValue(update.trackID)
            let escapedProperty = InputSanitizer.sanitizeScriptCode(update.property)
            let escapedValue = InputSanitizer.escapeStringValue(update.value)
            return "\(escapedID)\(fieldSep)\(escapedProperty)\(fieldSep)\(escapedValue)"
        }.joined(separator: commandSep)

        let output = try await runScript(
            name: "batch_update_tracks",
            arguments: [batchArg],
            timeout: config.timeouts.batchUpdate
        )

        log.info("Batch updated \(updates.count, privacy: .public) tracks")

        if let output, output.lowercased().contains("error") {
            throw AppleScriptBridgeError.executionFailed(
                scriptName: "batch_update_tracks",
                detail: "Batch of \(updates.count) updates, response=\(String(output.prefix(200)))"
            )
        }
    }

    // MARK: - Private Helpers

    /// Build an NSAppleEventDescriptor with string arguments.
    private func buildAppleEvent(arguments: [String]) throws -> NSAppleEventDescriptor? {
        Self.makeRunAppleEvent(arguments: arguments)
    }

    static func makeRunAppleEvent(arguments: [String]) -> NSAppleEventDescriptor? {
        guard !arguments.isEmpty else { return nil }

        let event = NSAppleEventDescriptor(
            eventClass: AEEventClass(kCoreEventClass),
            eventID: AEEventID(kAEOpenApplication),
            targetDescriptor: nil,
            returnID: AEReturnID(kAutoGenerateReturnID),
            transactionID: AETransactionID(kAnyTransactionID)
        )

        let argList = NSAppleEventDescriptor.list()
        for (index, arg) in arguments.enumerated() {
            argList.insert(NSAppleEventDescriptor(string: arg), at: index + 1)
        }
        event.setDescriptor(argList, forKeyword: keyDirectObject)

        return event
    }

    /// Parse comma-separated IDs returned by fetch_track_ids.applescript.
    static func parseTrackIDOutput(_ output: String) -> [String] {
        let trimmedOutput = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedOutput.isEmpty else { return [] }
        guard !trimmedOutput.hasPrefix("ERROR:") else { return [] }
        guard trimmedOutput != "NO_TRACKS_FOUND" else { return [] }

        return output
            .split(separator: ",", omittingEmptySubsequences: false)
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    /// Parse AppleScript output into Track objects.
    private func parseTrackOutput(_ output: String) -> [Core.Track] {
        output.split(separator: Core.Track.recordSeparator)
            .compactMap { Core.Track.fromAppleScriptOutput(String($0)) }
    }
}

extension AppleScriptBridge {
    func executeScriptAttempt(
        name: String,
        scriptURL: URL,
        arguments: [String],
        timeout: Duration
    ) async throws -> String? {
        if let rateLimiter {
            let waitTime = await rateLimiter.acquire()
            if waitTime > .zero {
                log.debug("AppleScript rate limited, waited \(waitTime, privacy: .public)")
            }
        }

        let task = try NSUserAppleScriptTask(url: scriptURL)
        let event = try buildAppleEvent(arguments: arguments)

        let wrappedTask = UnsafeSendable(value: task)
        let wrappedEvent = UnsafeSendable(value: event)
        let gate = concurrencyGate
        return try await gate.withPermit {
            try await Self.executeTaskWithTimeout(
                task: wrappedTask,
                event: wrappedEvent,
                scriptName: name,
                timeout: timeout
            )
        }
    }

    private static func executeTaskWithTimeout(
        task: UnsafeSendable<NSUserAppleScriptTask>,
        event: UnsafeSendable<NSAppleEventDescriptor?>,
        scriptName: String,
        timeout: Duration
    ) async throws -> String? {
        try await withThrowingTaskGroup(of: String?.self) { group in
            group.addTask {
                let descriptor = try await task.value.execute(withAppleEvent: event.value)
                return descriptor.stringValue
            }

            group.addTask {
                try await Task.sleep(for: timeout)
                throw AppleScriptBridgeError.timeout(scriptName: scriptName, duration: timeout)
            }

            let result = try await group.next()
            group.cancelAll()
            return result.flatMap(\.self)
        }
    }

    static func normalizedConcurrencyLimit(_ limit: Int) -> Int {
        max(1, limit)
    }

    func retryAppleScriptOperation<T: Sendable>(
        scriptName: String,
        retry: AppleScriptRetry,
        operation: () async throws -> T
    ) async throws -> T {
        let clock = ContinuousClock()
        let startedAt = clock.now
        let maxRetries = max(0, retry.maxRetries)
        var delaySeconds = max(0, retry.baseDelaySeconds)

        for attempt in 0 ... maxRetries {
            if Self.hasExceededTotalTimeout(startedAt: startedAt, retry: retry, clock: clock) {
                throw AppleScriptBridgeError.timeout(
                    scriptName: scriptName,
                    duration: Self.duration(seconds: retry.operationTimeoutSeconds)
                )
            }

            do {
                return try await operation()
            } catch {
                guard attempt < maxRetries, Self.isRetryableAppleScriptError(error) else {
                    throw error
                }

                let delay = Self.retryDelaySeconds(
                    afterFailureAt: attempt,
                    baseDelaySeconds: delaySeconds,
                    jitterRange: retry.jitterRange
                )
                if delay > 0 {
                    try await Task.sleep(for: Self.duration(seconds: delay))
                }
                delaySeconds = min(max(0, retry.maxDelaySeconds), max(0, delaySeconds * 2))
            }
        }

        throw AppleScriptBridgeError.executionFailed(
            scriptName: scriptName,
            detail: "Retry loop exited without a result"
        )
    }

    static func isRetryableAppleScriptError(_ error: any Error) -> Bool {
        guard let bridgeError = error as? AppleScriptBridgeError else {
            return isTransientError(error)
        }

        switch bridgeError {
        case .executionFailed, .musicAppNotRunning, .timeout:
            return true
        case .parseError, .scriptNotFound, .scriptsNotInstalled:
            return false
        }
    }

    static func retryDelaySeconds(
        afterFailureAt attempt: Int,
        baseDelaySeconds: Double,
        jitterRange: Double
    ) -> Double {
        let baseDelay = max(0, baseDelaySeconds)
        let clampedJitter = min(max(0, jitterRange), 1)
        let jitterSeed = Double((attempt * 31 + 17) % 100) / 100
        let jitterOffset = (jitterSeed - 0.5) * 2 * baseDelay * clampedJitter
        return max(0, baseDelay + jitterOffset)
    }

    static func makeRateLimiter(configuration: AppleScriptRateLimit) -> TokenBucketRateLimiter? {
        guard configuration.enabled else { return nil }

        let requestCount = max(1, configuration.requestsPerWindow)
        let refillMilliseconds = max(1, Int((configuration.windowSizeSeconds / Double(requestCount)) * 1000))
        return TokenBucketRateLimiter(
            maxTokens: requestCount,
            refillInterval: .milliseconds(refillMilliseconds)
        )
    }

    private static func hasExceededTotalTimeout(
        startedAt: ContinuousClock.Instant,
        retry: AppleScriptRetry,
        clock: ContinuousClock
    ) -> Bool {
        guard retry.operationTimeoutSeconds > 0 else { return false }
        return startedAt.duration(to: clock.now) > duration(seconds: retry.operationTimeoutSeconds)
    }

    private static func duration(seconds: Double) -> Duration {
        .milliseconds(max(0, Int(seconds * 1000)))
    }
}

// MARK: - Array Chunking

extension Array {
    /// Split array into chunks of the given size.
    func chunked(into size: Int) -> [[Element]] {
        stride(from: 0, to: count, by: size).map {
            Array(self[$0 ..< Swift.min($0 + size, count)])
        }
    }
}
