import Foundation
import Testing
@testable import Core
@testable import Services

// MARK: - Tests

@Suite("CheckpointManager — save/load/cleanup batch checkpoints")
struct CheckpointManagerTests {
    private func makeTempDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("CheckpointTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func makeCheckpoint(
        batchID: UUID = UUID(),
        processedIDs: [String] = ["T1", "T2"],
        totalCount: Int = 10,
        lastIndex: Int = 1,
        timestamp: Date = Date()
    ) -> BatchCheckpoint {
        BatchCheckpoint(
            batchID: batchID,
            processedTrackIDs: processedIDs,
            totalCount: totalCount,
            lastProcessedIndex: lastIndex,
            timestamp: timestamp,
            changes: []
        )
    }

    @Test("Save and load round-trip preserves all fields")
    func saveLoadRoundTrip() async throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let manager = CheckpointManager(directory: dir)
        let batchID = UUID()
        let checkpoint = makeCheckpoint(
            batchID: batchID,
            processedIDs: ["T1", "T2", "T3"],
            totalCount: 100,
            lastIndex: 2
        )

        try await manager.save(checkpoint)
        let loaded = try await manager.load(batchID: batchID)

        #expect(loaded != nil)
        #expect(loaded?.batchID == batchID)
        #expect(loaded?.processedTrackIDs == ["T1", "T2", "T3"])
        #expect(loaded?.totalCount == 100)
        #expect(loaded?.lastProcessedIndex == 2)
    }

    @Test("Load returns nil for nonexistent batch")
    func loadNonexistent() async throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let manager = CheckpointManager(directory: dir)
        let result = try await manager.load(batchID: UUID())
        #expect(result == nil)
    }

    @Test("Load latest returns most recent checkpoint")
    func loadLatest() async throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let manager = CheckpointManager(directory: dir)

        let older = makeCheckpoint(
            timestamp: Date().addingTimeInterval(-3600)
        )
        let newer = makeCheckpoint(
            timestamp: Date()
        )

        try await manager.save(older)
        try await manager.save(newer)

        let latest = try await manager.loadLatest()
        #expect(latest?.batchID == newer.batchID)
    }

    @Test("Delete removes checkpoint file")
    func delete() async throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let manager = CheckpointManager(directory: dir)
        let batchID = UUID()

        try await manager.save(makeCheckpoint(batchID: batchID))
        let loaded = try await manager.load(batchID: batchID)
        #expect(loaded != nil)

        try await manager.delete(batchID: batchID)
        let deleted = try await manager.load(batchID: batchID)
        #expect(deleted == nil)
    }

    @Test("Delete nonexistent batch does not throw")
    func deleteNonexistent() async throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let manager = CheckpointManager(directory: dir)
        try await manager.delete(batchID: UUID())
    }

    @Test("Cleanup removes old checkpoints")
    func cleanupOld() async throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let manager = CheckpointManager(directory: dir)

        let old = makeCheckpoint(
            timestamp: Date().addingTimeInterval(-8 * 24 * 3600)
        )
        let recent = makeCheckpoint(
            timestamp: Date()
        )

        try await manager.save(old)
        try await manager.save(recent)

        try await manager.cleanupOld(olderThan: 7 * 24 * 3600)

        let oldLoaded = try await manager.load(batchID: old.batchID)
        let recentLoaded = try await manager.load(batchID: recent.batchID)
        #expect(oldLoaded == nil)
        #expect(recentLoaded != nil)
    }

    @Test("Corrupt JSON returns nil instead of throwing")
    func corruptionHandling() async throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let manager = CheckpointManager(directory: dir)
        let batchID = UUID()

        let checkpointDir = dir.appendingPathComponent("checkpoints", isDirectory: true)
        try FileManager.default.createDirectory(at: checkpointDir, withIntermediateDirectories: true)
        let filePath = checkpointDir.appendingPathComponent("\(batchID.uuidString).json")
        let invalidData = Data("{ invalid json".utf8)
        try invalidData.write(to: filePath)

        let loaded = try await manager.load(batchID: batchID)
        #expect(loaded == nil)
    }

    @Test("Load latest with empty directory returns nil")
    func loadLatestEmpty() async throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let manager = CheckpointManager(directory: dir)
        let result = try await manager.loadLatest()
        #expect(result == nil)
    }
}
