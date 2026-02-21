import Foundation
import Testing
@testable import Core
@testable import Services

// MARK: - Thread-Safe Accumulator

private actor Accumulator<T: Sendable> {
    var items: [T] = []

    func append(_ item: T) {
        items.append(item)
    }

    func getAll() -> [T] {
        items
    }

    var count: Int {
        items.count
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
                Task { await accumulator.append(update) }
            }
        )

        try await Task.sleep(for: .milliseconds(50))
        let updates = await accumulator.getAll()
        // 5 tracks + 1 completion
        #expect(updates.count == 6)
        #expect(updates.last?.phase == .complete)
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
                progressHandler: { _ in }
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
                if count == 2 { throw MockOperationError.failed }
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
