import Foundation
import Testing
@testable import Core
@testable import Services

// MARK: - Thread-Safe Accumulator

// Safety: all mutable state is protected by `lock`, and snapshots copy while holding it.
private final class Accumulator<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [T] = []

    func append(_ item: T) {
        lock.lock()
        defer { lock.unlock() }
        items.append(item)
    }

    func getAll() -> [T] {
        lock.lock()
        defer { lock.unlock() }
        return items
    }
}

private actor Counter {
    var value: Int = 0

    func increment() -> Int {
        value += 1
        return value
    }
}

// MARK: - Helpers

private func makeTrack(id: String) -> Track {
    Track(id: id, name: "Track \(id)", artist: "Artist", album: "Album")
}

private func makeTracks(count: Int) -> [Track] {
    (0 ..< count).map { makeTrack(id: "T\($0)") }
}

// MARK: - Tests

@Suite("BatchProcessor — batch processing with pause/resume/cancel")
struct BatchProcessorTests {
    @Test("Progress handler called for each track")
    func progressCallback() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("BP-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let checkpoint = CheckpointManager(directory: dir)
        let gate = await FeatureGate(fixedTier: .weekPass)

        let processor = BatchProcessor(
            checkpointManager: checkpoint,
            featureGate: gate,
            checkpointInterval: 100
        )

        let tracks = makeTracks(count: 5)
        let accumulator = Accumulator<ProgressUpdate>()

        _ = try await processor.process(
            tracks: tracks,
            operation: { _ in [] },
            progressHandler: { update in
                accumulator.append(update)
            }
        )

        let updates = accumulator.getAll()
        // 5 tracks + 1 completion
        #expect(updates.count == 6)
        #expect(updates.last?.phase == .complete)
    }

    @Test("Batch configuration clamps to experimental max batch size")
    func clampsExperimentalBatchSize() {
        var appConfiguration = AppConfiguration()
        appConfiguration.processing.batchSize = 25
        appConfiguration.processing.delayBetweenBatches = 0.25
        appConfiguration.experimental.batchUpdatesEnabled = true
        appConfiguration.experimental.maxBatchSize = 4

        let configuration = BatchProcessingConfiguration(configuration: appConfiguration)

        #expect(configuration.batchSize == 4)
        #expect(configuration.delayBetweenBatchesMilliseconds == 250)
        #expect(configuration.shouldDelayAfterBatch(processedCount: 4, isLastTrack: false))
        #expect(!configuration.shouldDelayAfterBatch(processedCount: 5, isLastTrack: false))
        #expect(!configuration.shouldDelayAfterBatch(processedCount: 4, isLastTrack: true))

        let disabledConfiguration = BatchProcessingConfiguration(
            batchSize: 1,
            delayBetweenBatches: 0.25,
            adaptiveDelay: false
        )
        #expect(!disabledConfiguration.shouldDelayAfterBatch(processedCount: 1, isLastTrack: false))
    }

    @Test("Batch configuration disables adaptive delay for restricted scopes")
    func batchConfigurationDisablesAdaptiveDelayForRestrictedScopes() {
        var appConfiguration = AppConfiguration()
        appConfiguration.processing.batchSize = 25
        appConfiguration.processing.delayBetweenBatches = 20
        appConfiguration.processing.adaptiveDelay = true

        let configuration = BatchProcessingConfiguration(
            configuration: appConfiguration,
            isScopeRestricted: true
        )

        #expect(configuration.batchSize == 25)
        #expect(configuration.delayBetweenBatchesMilliseconds == 0)
        #expect(!configuration.shouldDelayAfterBatch(processedCount: 25, isLastTrack: false))
    }

    @Test("Batch configuration treats configured test artists as restricted scope")
    func restrictsTestArtists() {
        var appConfiguration = AppConfiguration()
        appConfiguration.processing.batchSize = 25
        appConfiguration.processing.delayBetweenBatches = 20
        appConfiguration.processing.adaptiveDelay = true
        appConfiguration.development.testArtists = ["In Flames"]

        let configuration = BatchProcessingConfiguration(configuration: appConfiguration)

        #expect(configuration.delayBetweenBatchesMilliseconds == 0)
        #expect(!configuration.shouldDelayAfterBatch(processedCount: 25, isLastTrack: false))
    }

    @Test("Runtime batch processing configuration applies delay between batches")
    func appliesRuntimeBatchDelay() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("BP-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let checkpoint = CheckpointManager(directory: dir)
        let gate = await FeatureGate(fixedTier: .weekPass)
        let processor = BatchProcessor(
            checkpointManager: checkpoint,
            featureGate: gate,
            checkpointInterval: 100,
            processingConfiguration: BatchProcessingConfiguration(
                batchSize: 10,
                delayBetweenBatches: 0
            )
        )
        await processor.updateProcessingConfiguration(BatchProcessingConfiguration(
            batchSize: 1,
            delayBetweenBatches: 0.03
        ))

        let clock = ContinuousClock()
        let start = clock.now
        _ = try await processor.process(
            tracks: makeTracks(count: 2),
            operation: { _ in [] },
            progressHandler: { _ in }
        )
        let elapsed = start.duration(to: clock.now)

        #expect(elapsed >= .milliseconds(20))
    }

    @Test("Feature gate denies free tier")
    func featureGateDenial() async {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("BP-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let checkpoint = CheckpointManager(directory: dir)
        let gate = await FeatureGate(fixedTier: .free)

        let processor = BatchProcessor(
            checkpointManager: checkpoint,
            featureGate: gate
        )

        await #expect(throws: BatchProcessorError.self) {
            try await processor.process(
                tracks: makeTracks(count: 3),
                operation: { _ in [] },
                progressHandler: { _ in
                    // Progress delivery is unrelated to unknown-outcome propagation.
                }
            )
        }
    }

    @Test("Cancel saves checkpoint and throws")
    func cancelSavesCheckpoint() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("BP-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let checkpoint = CheckpointManager(directory: dir)
        let gate = await FeatureGate(fixedTier: .pro)

        let processor = BatchProcessor(
            checkpointManager: checkpoint,
            featureGate: gate,
            checkpointInterval: 100
        )

        let tracks = makeTracks(count: 100)

        let cancelTask = Task {
            try? await Task.sleep(for: .milliseconds(10))
            await processor.cancel()
        }

        do {
            _ = try await processor.process(
                tracks: tracks,
                operation: { _ in
                    try await Task.sleep(for: .milliseconds(5))
                    return []
                },
                progressHandler: { _ in }
            )
            Issue.record("Expected cancellation error")
        } catch is BatchProcessorError {
            // Expected
        }

        cancelTask.cancel()

        let state = await processor.state
        #expect(state == .cancelled)
    }

    @Test("Returns accumulated changes from all tracks")
    func accumulatesChanges() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("BP-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let checkpoint = CheckpointManager(directory: dir)
        let gate = await FeatureGate(fixedTier: .pro)

        let processor = BatchProcessor(
            checkpointManager: checkpoint,
            featureGate: gate
        )

        let tracks = makeTracks(count: 3)
        let changes = try await processor.process(
            tracks: tracks,
            operation: { track in
                [ChangeLogEntry(
                    changeType: .genreUpdate,
                    trackID: track.id,
                    artist: track.artist
                )]
            },
            progressHandler: { _ in }
        )

        #expect(changes.count == 3)
    }

    @Test("State transitions correctly through lifecycle")
    func stateTransitions() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("BP-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let checkpoint = CheckpointManager(directory: dir)
        let gate = await FeatureGate(fixedTier: .pro)

        let processor = BatchProcessor(
            checkpointManager: checkpoint,
            featureGate: gate
        )

        let initialState = await processor.state
        #expect(initialState == .idle)

        _ = try await processor.process(
            tracks: makeTracks(count: 1),
            operation: { _ in [] },
            progressHandler: { _ in }
        )

        let finalState = await processor.state
        #expect(finalState == .completed)
    }

    @Test("Non-fatal errors do not stop processing")
    func nonFatalErrors() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("BP-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let checkpoint = CheckpointManager(directory: dir)
        let gate = await FeatureGate(fixedTier: .pro)

        let processor = BatchProcessor(
            checkpointManager: checkpoint,
            featureGate: gate
        )

        let counter = Counter()
        let changes = try await processor.process(
            tracks: makeTracks(count: 3),
            operation: { _ in
                let count = await counter.increment()
                if count == 2 {
                    throw MockOperationError.failed
                }
                return [ChangeLogEntry(
                    changeType: .genreUpdate,
                    trackID: "T",
                    artist: "A"
                )]
            },
            progressHandler: { _ in }
        )

        // 2 succeeded, 1 failed
        #expect(changes.count == 2)
    }

    @Test("Cancellation errors stop processing")
    func cancellationErrorsStopProcessing() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("BP-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let checkpoint = CheckpointManager(directory: dir)
        let gate = await FeatureGate(fixedTier: .pro)

        let processor = BatchProcessor(
            checkpointManager: checkpoint,
            featureGate: gate
        )

        let processedTrackIDs = Accumulator<String>()

        do {
            _ = try await processor.process(
                tracks: makeTracks(count: 3),
                operation: { track in
                    processedTrackIDs.append(track.id)
                    if track.id == "T1" {
                        throw CancellationError()
                    }
                    return [ChangeLogEntry(
                        changeType: .genreUpdate,
                        trackID: track.id,
                        artist: track.artist
                    )]
                },
                progressHandler: { _ in
                    // Progress is irrelevant for cancellation behavior.
                }
            )
            Issue.record("Expected batch cancellation error")
        } catch let error as BatchProcessorError {
            guard case let .cancelled(processedCount, totalCount) = error else {
                Issue.record("Expected cancellation error, got \(error)")
                return
            }
            #expect(processedCount == 1)
            #expect(totalCount == 3)
        } catch {
            Issue.record("Expected batch cancellation error, got \(error)")
        }

        #expect(processedTrackIDs.getAll() == ["T0", "T1"])
        #expect(await processor.state == .cancelled)
        let savedCheckpoint = try await checkpoint.loadLatest()
        #expect(savedCheckpoint?.processedTrackIDs == ["T0"])
        #expect(savedCheckpoint?.lastProcessedIndex == 0)
        #expect(savedCheckpoint?.totalCount == 3)
        #expect(savedCheckpoint?.changes.map(\.trackID) == ["T0"])
    }

    @Test("Pause and resume completes processing")
    func pauseAndResume() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("BP-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let checkpoint = CheckpointManager(directory: dir)
        let gate = await FeatureGate(fixedTier: .pro)

        let processor = BatchProcessor(
            checkpointManager: checkpoint,
            featureGate: gate
        )

        let tracks = makeTracks(count: 10)

        // Pause after a few tracks have been processed, then resume
        let controlTask = Task {
            try? await Task.sleep(for: .milliseconds(50))
            await processor.pause()
            // Wait for pause to take effect (polling interval is 100ms)
            try? await Task.sleep(for: .milliseconds(200))
            let pausedState = await processor.state
            #expect(pausedState == .paused)
            await processor.resume()
        }

        let changes = try await processor.process(
            tracks: tracks,
            operation: { track in
                try await Task.sleep(for: .milliseconds(10))
                return [ChangeLogEntry(
                    changeType: .genreUpdate,
                    trackID: track.id,
                    artist: track.artist
                )]
            },
            progressHandler: { _ in }
        )

        controlTask.cancel()

        let finalState = await processor.state
        #expect(finalState == .completed)
        #expect(changes.count == 10)
    }
}

private enum MockOperationError: Error {
    case failed
}
