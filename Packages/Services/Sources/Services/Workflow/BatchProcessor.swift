import Core
import Foundation
import OSLog

// MARK: - Batch Error

public enum BatchProcessorError: Error, LocalizedError {
    case featureNotAvailable(feature: AppFeature, currentTier: Tier)
    case alreadyRunning
    case notRunning
    case cancelled(processedCount: Int, totalCount: Int)

    public var errorDescription: String? {
        switch self {
        case let .featureNotAvailable(feature, tier):
            "\(feature.rawValue) requires a higher tier than \(tier)"
        case .alreadyRunning:
            "Batch processor is already running"
        case .notRunning:
            "Batch processor is not running"
        case let .cancelled(processed, total):
            "Batch cancelled after processing \(processed)/\(total) tracks"
        }
    }
}

// MARK: - Resume State

/// State loaded from a checkpoint for resume operations.
private struct ResumeState {
    let batchID: UUID
    let startIndex: Int
    var changes: [ChangeLogEntry]
    var processedIDs: [String]
}

// MARK: - Checkpoint Snapshot

/// Bundles data needed to save a checkpoint.
private struct CheckpointSnapshot {
    let batchID: UUID
    let processedIDs: [String]
    let totalCount: Int
    let lastIndex: Int
    let changes: [ChangeLogEntry]
}

// MARK: - Batch Processing Configuration

public struct BatchProcessingConfiguration: Sendable, Equatable {
    public let batchSize: Int
    public let delayBetweenBatchesMilliseconds: Int
    public let adaptiveDelay: Bool

    public init(
        batchSize: Int = AppConfiguration().processing.batchSize,
        delayBetweenBatches: Double = AppConfiguration().processing.delayBetweenBatches,
        adaptiveDelay: Bool = AppConfiguration().processing.adaptiveDelay,
        maxBatchSize: Int? = nil
    ) {
        let configuredBatchSize = max(1, batchSize)
        self.batchSize = maxBatchSize.map { max(1, min(configuredBatchSize, $0)) } ?? configuredBatchSize
        delayBetweenBatchesMilliseconds = max(0, Int((delayBetweenBatches * 1000).rounded()))
        self.adaptiveDelay = adaptiveDelay
    }

    public init(configuration: AppConfiguration, isScopeRestricted: Bool? = nil) {
        let hasRestrictedScope = isScopeRestricted ?? configuration.development.testArtists.contains {
            !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        self.init(
            batchSize: configuration.processing.batchSize,
            delayBetweenBatches: hasRestrictedScope ? 0 : configuration.processing.delayBetweenBatches,
            adaptiveDelay: hasRestrictedScope ? false : configuration.processing.adaptiveDelay,
            maxBatchSize: configuration.experimental.batchUpdatesEnabled
                ? configuration.experimental.maxBatchSize
                : nil
        )
    }

    var delayBetweenBatches: Duration {
        .milliseconds(delayBetweenBatchesMilliseconds)
    }

    func shouldDelayAfterBatch(processedCount: Int, isLastTrack: Bool) -> Bool {
        adaptiveDelay
            && !isLastTrack
            && delayBetweenBatchesMilliseconds > 0
            && processedCount.isMultiple(of: batchSize)
    }
}

// MARK: - Batch Processor

/// Processes tracks in configurable batches with pause/resume/cancel and progress streaming.
///
/// Feature-gated: requires `.batchProcessing` (Week Pass or Pro tier).
/// Checkpoints every N tracks to allow resume after interruption.
public actor BatchProcessor {
    public enum State: Sendable, Equatable {
        case idle
        case running
        case paused
        case cancelled
        case completed
    }

    private let checkpointManager: CheckpointManager
    private let featureGate: FeatureGate
    private let checkpointInterval: Int
    private var processingConfiguration: BatchProcessingConfiguration
    private var currentState: State = .idle
    private var pauseRequested = false
    private var cancelRequested = false
    private let log = Logger(
        subsystem: "com.genreupdater",
        category: "BatchProcessor"
    )

    public init(
        checkpointManager: CheckpointManager,
        featureGate: FeatureGate,
        checkpointInterval: Int = 50,
        processingConfiguration: BatchProcessingConfiguration = BatchProcessingConfiguration()
    ) {
        self.checkpointManager = checkpointManager
        self.featureGate = featureGate
        self.checkpointInterval = checkpointInterval
        self.processingConfiguration = processingConfiguration
    }

    public func updateProcessingConfiguration(_ processingConfiguration: BatchProcessingConfiguration) {
        self.processingConfiguration = processingConfiguration
    }

    /// Current processing state.
    public var state: State {
        currentState
    }

    // MARK: Process

    /// Process tracks sequentially, calling `operation` for each track.
    public func process(
        tracks: [Track],
        resumeBatchID: UUID? = nil,
        operation: @Sendable (Track) async throws -> [ChangeLogEntry],
        progressHandler: @Sendable (ProgressUpdate) -> Void
    ) async throws -> [ChangeLogEntry] {
        try await validateCanStart()
        var resume = try await loadResumeState(
            tracks: tracks,
            resumeBatchID: resumeBatchID
        )

        let signpostState = AppSignpost.batchProcessing.beginInterval("batchProcess")
        defer { AppSignpost.batchProcessing.endInterval("batchProcess", signpostState) }

        currentState = .running
        pauseRequested = false
        cancelRequested = false
        let processingStart = ContinuousClock.now

        log
            .info(
                "Starting batch \(resume.batchID, privacy: .public): \(tracks.count, privacy: .public) tracks from index \(resume.startIndex, privacy: .public)"
            )
        for index in resume.startIndex ..< tracks.count {
            let snapshot = makeSnapshot(
                resume: resume,
                totalCount: tracks.count,
                lastIndex: max(0, index - 1)
            )
            try await handleCancellation(snapshot: snapshot)
            try await waitWhilePaused()

            let outcome = try await processTrack(
                tracks[index],
                operation: operation,
                cancellationSnapshot: snapshot
            )
            if outcome.didProcess {
                let changes = outcome.changes
                resume.changes.append(contentsOf: changes)
                resume.processedIDs.append(tracks[index].id)
            }

            reportProgress(
                index: index,
                startIndex: resume.startIndex,
                totalCount: tracks.count,
                processingStart: processingStart,
                progressHandler: progressHandler
            )
            let currentSnapshot = makeSnapshot(
                resume: resume,
                totalCount: tracks.count,
                lastIndex: index
            )
            let processedCount = index - resume.startIndex + 1
            try await checkpointIfNeeded(
                processed: processedCount,
                snapshot: currentSnapshot
            )
            try await delayBetweenConfiguredBatches(
                processedCount: processedCount,
                isLastTrack: index == tracks.count - 1
            )
        }

        return try await finishBatch(
            resume: resume,
            totalCount: tracks.count,
            progressHandler: progressHandler
        )
    }

    private func processTrack(
        _ track: Track,
        operation: @Sendable (Track) async throws -> [ChangeLogEntry],
        cancellationSnapshot: CheckpointSnapshot
    ) async throws -> (changes: [ChangeLogEntry], didProcess: Bool) {
        do {
            let changes = try await operation(track)
            return (changes, true)
        } catch is CancellationError {
            try await handleCancellation(snapshot: cancellationSnapshot, force: true)
            throw CancellationError()
        } catch {
            log
                .warning(
                    "Failed to process track \(track.id, privacy: .private): \(error.localizedDescription, privacy: .public)"
                )
            return ([], false)
        }
    }

    // MARK: Controls

    /// Request the processor to pause after the current track.
    public func pause() {
        guard currentState == .running else { return }
        pauseRequested = true
        log.info("Pause requested")
    }

    /// Resume processing after a pause.
    public func resume() {
        guard currentState == .paused else { return }
        pauseRequested = false
        log.info("Resume requested")
    }

    /// Cancel processing, saving a checkpoint first.
    public func cancel() {
        guard currentState == .running || currentState == .paused else { return }
        cancelRequested = true
        pauseRequested = false
        log.info("Cancel requested")
    }

    // MARK: Internal Steps

    private func validateCanStart() async throws {
        guard await featureGate.canAccess(.batchProcessing) else {
            throw await BatchProcessorError.featureNotAvailable(
                feature: .batchProcessing,
                currentTier: featureGate.currentTier
            )
        }
        let canStart = currentState == .idle
            || currentState == .completed
            || currentState == .cancelled
        guard canStart else {
            throw BatchProcessorError.alreadyRunning
        }
    }

    private func loadResumeState(
        tracks _: [Track],
        resumeBatchID: UUID?
    ) async throws -> ResumeState {
        let batchID = resumeBatchID ?? UUID()
        guard let resumeID = resumeBatchID,
              let checkpoint = try await checkpointManager.load(batchID: resumeID)
        else {
            return ResumeState(
                batchID: batchID,
                startIndex: 0,
                changes: [],
                processedIDs: []
            )
        }
        log
            .info(
                "Resuming batch \(resumeID, privacy: .public) from index \(checkpoint.lastProcessedIndex + 1, privacy: .public)"
            )
        return ResumeState(
            batchID: batchID,
            startIndex: checkpoint.lastProcessedIndex + 1,
            changes: checkpoint.changes,
            processedIDs: checkpoint.processedTrackIDs
        )
    }

    private func handleCancellation(
        snapshot: CheckpointSnapshot,
        force: Bool = false
    ) async throws {
        guard force || cancelRequested else { return }
        currentState = .cancelled
        let checkpoint = BatchCheckpoint(
            batchID: snapshot.batchID,
            processedTrackIDs: snapshot.processedIDs,
            totalCount: snapshot.totalCount,
            lastProcessedIndex: snapshot.lastIndex,
            changes: snapshot.changes
        )
        try await checkpointManager.save(checkpoint)
        log.info("Batch cancelled at index \(snapshot.lastIndex, privacy: .public)")
        throw BatchProcessorError.cancelled(
            processedCount: snapshot.processedIDs.count,
            totalCount: snapshot.totalCount
        )
    }

    private func waitWhilePaused() async throws {
        guard pauseRequested else { return }
        currentState = .paused
        while pauseRequested {
            try await Task.sleep(for: .milliseconds(100))
            if cancelRequested {
                break
            }
        }
        currentState = .running
    }

    private func reportProgress(
        index: Int,
        startIndex: Int,
        totalCount: Int,
        processingStart: ContinuousClock.Instant,
        progressHandler: @Sendable (ProgressUpdate) -> Void
    ) {
        let elapsed = ContinuousClock.now - processingStart
        let processed = index - startIndex + 1
        let eta = estimateRemainingTime(
            processed: processed,
            remaining: totalCount - index - 1,
            elapsed: elapsed
        )
        progressHandler(ProgressUpdate(
            phase: .updating,
            current: index + 1,
            total: totalCount,
            message: eta.map { "ETA: \($0)" }
        ))
    }

    private func delayBetweenConfiguredBatches(
        processedCount: Int,
        isLastTrack: Bool
    ) async throws {
        guard processingConfiguration.shouldDelayAfterBatch(
            processedCount: processedCount,
            isLastTrack: isLastTrack
        ) else { return }

        try await Task.sleep(for: processingConfiguration.delayBetweenBatches)
    }

    private func checkpointIfNeeded(
        processed: Int,
        snapshot: CheckpointSnapshot
    ) async throws {
        guard processed > 0,
              processed.isMultiple(of: checkpointInterval)
        else { return }
        let checkpoint = BatchCheckpoint(
            batchID: snapshot.batchID,
            processedTrackIDs: snapshot.processedIDs,
            totalCount: snapshot.totalCount,
            lastProcessedIndex: snapshot.lastIndex,
            changes: snapshot.changes
        )
        try await checkpointManager.save(checkpoint)
    }

    private func makeSnapshot(
        resume: ResumeState,
        totalCount: Int,
        lastIndex: Int
    ) -> CheckpointSnapshot {
        CheckpointSnapshot(
            batchID: resume.batchID,
            processedIDs: resume.processedIDs,
            totalCount: totalCount,
            lastIndex: lastIndex,
            changes: resume.changes
        )
    }

    private func finishBatch(
        resume: ResumeState,
        totalCount: Int,
        progressHandler: @Sendable (ProgressUpdate) -> Void
    ) async throws -> [ChangeLogEntry] {
        currentState = .completed
        try? await checkpointManager.delete(batchID: resume.batchID)
        progressHandler(ProgressUpdate(
            phase: .complete,
            current: totalCount,
            total: totalCount,
            message: "Batch complete"
        ))
        log
            .info(
                "Batch \(resume.batchID, privacy: .public) completed: \(resume.changes.count, privacy: .public) changes"
            )
        return resume.changes
    }

    private func estimateRemainingTime(
        processed: Int,
        remaining: Int,
        elapsed: Duration
    ) -> String? {
        guard processed > 0, remaining > 0 else { return nil }
        let secondsPerTrack = elapsed / processed
        let etaSeconds = secondsPerTrack * remaining
        let totalSeconds = Int(etaSeconds.components.seconds)
        if totalSeconds < 60 {
            return "\(totalSeconds)s"
        }
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        return "\(minutes)m \(seconds)s"
    }
}
