import Foundation

/// One semantically invalid persisted configuration value.
public struct ConfigurationValidationIssue: Sendable, Equatable {
    /// Canonical Swift configuration path.
    public let fieldPath: String
    /// Stable textual representation of the rejected value.
    public let receivedValue: String
    /// Numeric requirement the value violates.
    public let requirement: String
}

/// Complete deterministic set of numeric configuration violations.
public struct ConfigurationValidationError: Error, LocalizedError, Sendable, Equatable {
    /// Violations sorted by canonical field path.
    public let issues: [ConfigurationValidationIssue]

    init(issues: [ConfigurationValidationIssue]) {
        precondition(!issues.isEmpty)
        self.issues = issues.sorted { $0.fieldPath < $1.fieldPath }
    }

    public var errorDescription: String? {
        let details = issues.map { issue in
            "\(issue.fieldPath): received \(issue.receivedValue); \(issue.requirement)"
        }
        return (["Invalid configuration:"] + details).joined(separator: "\n")
    }
}

extension AppConfiguration {
    /// Rejects numeric settings that cannot safely construct runtime services.
    public func validateNumericValues() throws {
        var validation = NumericValidation()
        validateRuntime(using: &validation)
        validateAppleScript(using: &validation)
        validateWorkflow(using: &validation)
        validateYearRetrieval(using: &validation)
        try validation.finish()
    }

    private func validateRuntime(using validation: inout NumericValidation) {
        validation.requireAtLeast(runtime.cacheTTLSeconds, minimum: 0, path: "runtime.cacheTTLSeconds")
        validation.requireAtLeast(
            runtime.incrementalIntervalMinutes,
            minimum: 1,
            path: "runtime.incrementalIntervalMinutes"
        )
        validation.requireAtLeast(runtime.maxRetries, minimum: 0, path: "runtime.maxRetries")
        validation.requireAtLeast(runtime.retryDelaySeconds, minimum: 0, path: "runtime.retryDelaySeconds")
        validation.requireAtLeast(runtime.maxGenericEntries, minimum: 1, path: "runtime.maxGenericEntries")
        validation.requireAtLeast(experimental.maxBatchSize, minimum: 1, path: "experimental.maxBatchSize")
        validation.requireAtLeast(
            databaseVerification.autoVerifyDays,
            minimum: 0,
            path: "databaseVerification.autoVerifyDays"
        )
        validation.requireAtLeast(
            databaseVerification.batchSize,
            minimum: 1,
            path: "databaseVerification.batchSize"
        )
        validation.requireAtLeast(
            pendingVerification.autoVerifyDays,
            minimum: 0,
            path: "pendingVerification.autoVerifyDays"
        )
    }

    private func validateAppleScript(using validation: inout NumericValidation) {
        validation.requireAtLeast(applescript.concurrency, minimum: 1, path: "applescript.concurrency")
        validation.requireAtLeastSecond(
            applescript.timeouts.defaultTimeout,
            path: "applescript.timeouts.defaultTimeout"
        )
        validation.requireAtLeastSecond(
            applescript.timeouts.fullLibraryFetch,
            path: "applescript.timeouts.fullLibraryFetch"
        )
        validation.requireAtLeastSecond(
            applescript.timeouts.singleArtistFetch,
            path: "applescript.timeouts.singleArtistFetch"
        )
        validation.requireAtLeastSecond(
            applescript.timeouts.batchUpdate,
            path: "applescript.timeouts.batchUpdate"
        )
        validation.requireAtLeastSecond(
            applescript.timeouts.idsBatchFetch,
            path: "applescript.timeouts.idsBatchFetch"
        )
        validation.requireAtLeast(
            applescript.rateLimit.requestsPerWindow,
            minimum: 1,
            path: "applescript.rateLimit.requestsPerWindow"
        )
        validation.requireGreaterThan(
            applescript.rateLimit.windowSizeSeconds,
            minimum: 0,
            path: "applescript.rateLimit.windowSizeSeconds"
        )
        validateAppleScriptRetry(using: &validation)
        validation.requireAtLeast(
            applescript.batchProcessing.idsBatchSize,
            minimum: 1,
            path: "applescript.batchProcessing.idsBatchSize"
        )
        validation.requireAtLeast(
            applescript.batchProcessing.batchSize,
            minimum: 1,
            path: "applescript.batchProcessing.batchSize"
        )
    }

    private func validateAppleScriptRetry(using validation: inout NumericValidation) {
        validation.requireAtLeast(
            applescript.retry.maxRetries,
            minimum: 0,
            path: "applescript.retry.maxRetries"
        )
        validation.requireAtLeast(
            applescript.retry.baseDelaySeconds,
            minimum: 0,
            path: "applescript.retry.baseDelaySeconds"
        )
        validation.requireAtLeast(
            applescript.retry.maxDelaySeconds,
            minimum: 0,
            path: "applescript.retry.maxDelaySeconds"
        )
        validation.requireInRange(
            applescript.retry.jitterRange,
            range: 0 ... 1,
            path: "applescript.retry.jitterRange"
        )
        validation.requireAtLeast(
            applescript.retry.operationTimeoutSeconds,
            minimum: 0,
            path: "applescript.retry.operationTimeoutSeconds"
        )
    }

    private func validateWorkflow(using validation: inout NumericValidation) {
        validateProcessing(using: &validation)
        validateCaching(using: &validation)
        validateAnalyticsAndReporting(using: &validation)
    }

    private func validateProcessing(using validation: inout NumericValidation) {
        validation.requireAtLeast(genreUpdate.batchSize, minimum: 1, path: "genreUpdate.batchSize")
        validation.requireAtLeast(genreUpdate.concurrentLimit, minimum: 1, path: "genreUpdate.concurrentLimit")
        validation.requireAtLeast(processing.batchSize, minimum: 1, path: "processing.batchSize")
        validation.requireAtLeast(
            processing.delayBetweenBatches,
            minimum: 0,
            path: "processing.delayBetweenBatches"
        )
        validation.requireAtLeast(processing.cacheTTLDays, minimum: 0, path: "processing.cacheTTLDays")
        validation.requireAtLeast(
            processing.pendingVerificationIntervalDays,
            minimum: 0,
            path: "processing.pendingVerificationIntervalDays"
        )
        validation.requireAtLeast(
            processing.futureYearThreshold,
            minimum: 0,
            path: "processing.futureYearThreshold"
        )
        validation.requireAtLeast(
            processing.prereleaseRecheckDays,
            minimum: 0,
            path: "processing.prereleaseRecheckDays"
        )
        validation.requireInRange(
            processing.releaseYearRestoreThreshold,
            range: 0 ... 100,
            path: "processing.releaseYearRestoreThreshold"
        )
        validation.requireInRange(
            processing.minConfidenceToCache,
            range: 0 ... 100,
            path: "processing.minConfidenceToCache"
        )
        validation.requireAtLeast(
            processing.suspiciousAlbumMinLen,
            minimum: 0,
            path: "processing.suspiciousAlbumMinLen"
        )
        validation.requireAtLeast(
            processing.suspiciousManyYears,
            minimum: 1,
            path: "processing.suspiciousManyYears"
        )
    }

    private func validateCaching(using validation: inout NumericValidation) {
        validation.requireAtLeast(caching.defaultTTLSeconds, minimum: 0, path: "caching.defaultTTLSeconds")
        validation.requireAtLeast(
            caching.albumCacheSyncInterval,
            minimum: 0,
            path: "caching.albumCacheSyncInterval"
        )
        validation.requireAtLeast(
            caching.cleanupErrorRetryDelay,
            minimum: 0,
            path: "caching.cleanupErrorRetryDelay"
        )
        validation.requireAtLeast(
            caching.cleanupIntervalSeconds,
            minimum: 0,
            path: "caching.cleanupIntervalSeconds"
        )
        validation.requireAtLeast(caching.negativeResultTTL, minimum: 0, path: "caching.negativeResultTTL")
        validation.requireAtLeast(
            caching.librarySnapshot.maxAgeHours,
            minimum: 1,
            path: "caching.librarySnapshot.maxAgeHours"
        )
        validation.requireInRange(
            caching.librarySnapshot.compressLevel,
            range: 1 ... 9,
            path: "caching.librarySnapshot.compressLevel"
        )
    }

    private func validateAnalyticsAndReporting(using validation: inout NumericValidation) {
        validation.requireAtLeast(
            analytics.durationThresholds.shortMax,
            minimum: 0,
            path: "analytics.durationThresholds.shortMax"
        )
        validation.requireAtLeast(
            analytics.durationThresholds.mediumMax,
            minimum: 0,
            path: "analytics.durationThresholds.mediumMax"
        )
        validation.requireAtLeast(
            analytics.durationThresholds.longMax,
            minimum: 0,
            path: "analytics.durationThresholds.longMax"
        )
        validation.requireAtLeast(analytics.maxEvents, minimum: 0, path: "analytics.maxEvents")
        validation.requireAtLeast(
            reporting.minAttemptsForReport,
            minimum: 1,
            path: "reporting.minAttemptsForReport"
        )
        validation.requireAtLeast(reporting.runHistoryLimit, minimum: 1, path: "reporting.runHistoryLimit")
        validation.requireAtLeast(logging.maxRuns, minimum: 0, path: "logging.maxRuns")
    }

    private func validateYearRetrieval(using validation: inout NumericValidation) {
        validateYearRateLimits(using: &validation)
        validateYearLogic(using: &validation)
        validateYearFallback(using: &validation)
        validateYearScoring(using: &validation)
    }

    private func validateYearRateLimits(using validation: inout NumericValidation) {
        validation.requireAtLeast(
            yearRetrieval.rateLimits.discogsRequestsPerMinute,
            minimum: 1,
            path: "yearRetrieval.rateLimits.discogsRequestsPerMinute"
        )
        validation.requireAtLeast(
            yearRetrieval.rateLimits.musicbrainzRequestsPerSecond,
            minimum: 0,
            path: "yearRetrieval.rateLimits.musicbrainzRequestsPerSecond"
        )
        validation.requireAtLeast(
            yearRetrieval.rateLimits.concurrentAPICalls,
            minimum: 1,
            path: "yearRetrieval.rateLimits.concurrentAPICalls"
        )
    }

    private func validateYearLogic(using validation: inout NumericValidation) {
        validation.requireAtLeast(
            yearRetrieval.logic.minValidYear,
            minimum: 1000,
            path: "yearRetrieval.logic.minValidYear"
        )
        validation.requireAtLeast(
            yearRetrieval.logic.absurdYearThreshold,
            minimum: 1000,
            path: "yearRetrieval.logic.absurdYearThreshold"
        )
        validation.requireAtLeast(
            yearRetrieval.logic.suspicionThresholdYears,
            minimum: 0,
            path: "yearRetrieval.logic.suspicionThresholdYears"
        )
        validation.requireInRange(
            yearRetrieval.logic.definitiveScoreThreshold,
            range: 0 ... 100,
            path: "yearRetrieval.logic.definitiveScoreThreshold"
        )
        validation.requireAtLeast(
            yearRetrieval.logic.definitiveScoreDiff,
            minimum: 0,
            path: "yearRetrieval.logic.definitiveScoreDiff"
        )
        validation.requireInRange(
            yearRetrieval.logic.minConfidenceForNewYear,
            range: 0 ... 100,
            path: "yearRetrieval.logic.minConfidenceForNewYear"
        )
        validation.requireInRange(
            yearRetrieval.logic.dominantYearMinConfidence,
            range: 0 ... 1,
            path: "yearRetrieval.logic.dominantYearMinConfidence"
        )
    }

    private func validateYearFallback(using validation: inout NumericValidation) {
        validation.requireAtLeast(
            yearRetrieval.fallback.yearDifferenceThreshold,
            minimum: 0,
            path: "yearRetrieval.fallback.yearDifferenceThreshold"
        )
        validation.requireInRange(
            yearRetrieval.fallback.trustAPIScoreThreshold,
            range: 0 ... 100,
            path: "yearRetrieval.fallback.trustAPIScoreThreshold"
        )
        validation.requireAtLeast(
            yearRetrieval.fallback.maxVerificationAttempts,
            minimum: 0,
            path: "yearRetrieval.fallback.maxVerificationAttempts"
        )
        validation.requireInRange(
            yearRetrieval.itunesSearch.limit,
            range: 1 ... 200,
            path: "yearRetrieval.itunesSearch.limit"
        )
    }

    private func validateYearScoring(using validation: inout NumericValidation) {
        validateArtistAlbumPenalties(using: &validation)
        validateReleasePenalties(using: &validation)
        validateYearPenalties(using: &validation)
    }

    private func validateArtistAlbumPenalties(using validation: inout NumericValidation) {
        let scoring = yearRetrieval.scoring
        validation.requireAtMost(
            scoring.artistSubstringPenalty,
            maximum: 0,
            path: "yearRetrieval.scoring.artistSubstringPenalty"
        )
        validation.requireAtMost(
            scoring.artistCrossScriptPenalty,
            maximum: 0,
            path: "yearRetrieval.scoring.artistCrossScriptPenalty"
        )
        validation.requireAtMost(
            scoring.artistMismatchPenalty,
            maximum: 0,
            path: "yearRetrieval.scoring.artistMismatchPenalty"
        )
        validation.requireAtMost(
            scoring.albumSubstringPenalty,
            maximum: 0,
            path: "yearRetrieval.scoring.albumSubstringPenalty"
        )
        validation.requireAtMost(
            scoring.albumUnrelatedPenalty,
            maximum: 0,
            path: "yearRetrieval.scoring.albumUnrelatedPenalty"
        )
    }

    private func validateReleasePenalties(using validation: inout NumericValidation) {
        let scoring = yearRetrieval.scoring
        validation.requireAtMost(
            scoring.typeEPSinglePenalty,
            maximum: 0,
            path: "yearRetrieval.scoring.typeEPSinglePenalty"
        )
        validation.requireAtMost(
            scoring.typeCompilationLivePenalty,
            maximum: 0,
            path: "yearRetrieval.scoring.typeCompilationLivePenalty"
        )
        validation.requireAtMost(
            scoring.statusBootlegPenalty,
            maximum: 0,
            path: "yearRetrieval.scoring.statusBootlegPenalty"
        )
        validation.requireAtMost(
            scoring.statusPromoPenalty,
            maximum: 0,
            path: "yearRetrieval.scoring.statusPromoPenalty"
        )
        validation.requireAtMost(
            scoring.reissuePenalty,
            maximum: 0,
            path: "yearRetrieval.scoring.reissuePenalty"
        )
    }

    private func validateYearPenalties(using validation: inout NumericValidation) {
        let scoring = yearRetrieval.scoring
        validation.requireAtMost(
            scoring.yearDiffPenaltyScale,
            maximum: 0,
            path: "yearRetrieval.scoring.yearDiffPenaltyScale"
        )
        validation.requireAtMost(
            scoring.yearDiffMaxPenalty,
            maximum: 0,
            path: "yearRetrieval.scoring.yearDiffMaxPenalty"
        )
        validation.requireAtMost(
            scoring.yearBeforeStartPenalty,
            maximum: 0,
            path: "yearRetrieval.scoring.yearBeforeStartPenalty"
        )
        validation.requireAtMost(
            scoring.yearAfterEndPenalty,
            maximum: 0,
            path: "yearRetrieval.scoring.yearAfterEndPenalty"
        )
        validation.requireAtMost(
            scoring.futureYearPenalty,
            maximum: 0,
            path: "yearRetrieval.scoring.futureYearPenalty"
        )
    }
}

private struct NumericValidation {
    private var issues: [ConfigurationValidationIssue] = []

    mutating func requireAtLeast(_ value: Int, minimum: Int, path: String) {
        guard value < minimum else { return }
        append(path: path, value: String(value), requirement: "must be at least \(minimum)")
    }

    mutating func requireAtLeast(_ value: Double, minimum: Double, path: String) {
        guard value < minimum else { return }
        append(path: path, value: String(value), requirement: "must be at least \(bound(minimum))")
    }

    mutating func requireGreaterThan(_ value: Double, minimum: Double, path: String) {
        guard value <= minimum else { return }
        append(path: path, value: String(value), requirement: "must be greater than \(bound(minimum))")
    }

    mutating func requireAtMost(_ value: Int, maximum: Int, path: String) {
        guard value > maximum else { return }
        append(path: path, value: String(value), requirement: "must be at most \(maximum)")
    }

    mutating func requireInRange(_ value: Int, range: ClosedRange<Int>, path: String) {
        guard !range.contains(value) else { return }
        append(
            path: path,
            value: String(value),
            requirement: "must be between \(range.lowerBound) and \(range.upperBound)"
        )
    }

    mutating func requireInRange(_ value: Double, range: ClosedRange<Double>, path: String) {
        guard !range.contains(value) else { return }
        append(
            path: path,
            value: String(value),
            requirement: "must be between \(bound(range.lowerBound)) and \(bound(range.upperBound))"
        )
    }

    mutating func requireAtLeastSecond(_ value: Duration, path: String) {
        guard value < .seconds(1) else { return }
        append(path: path, value: String(Int(value.timeInterval)), requirement: "must be at least 1")
    }

    func finish() throws {
        guard !issues.isEmpty else { return }
        throw ConfigurationValidationError(issues: issues)
    }

    private mutating func append(path: String, value: String, requirement: String) {
        issues.append(ConfigurationValidationIssue(
            fieldPath: path,
            receivedValue: value,
            requirement: requirement
        ))
    }

    private func bound(_ value: Double) -> String {
        guard value.isFinite, value.rounded() == value else { return String(value) }
        return String(Int(value))
    }
}
