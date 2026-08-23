import Core
import Foundation
import Services
import Testing

@Suite("MaintenanceCoordinator")
struct MaintenanceCoordinatorTests {
    @Test("Preflight verifies database without force and reports pending auto-check")
    func preflightRunsDatabaseVerificationAndReportsPendingStatus() async {
        let database = RecordingDatabaseVerificationService()
        let pending = RecordingPendingService(shouldAutoVerify: true)
        let coordinator = MaintenanceCoordinator(
            databaseVerificationService: database,
            pendingVerificationService: pending
        )

        let result = await coordinator.runPreflight()

        #expect(await database.runCount() == 1)
        #expect(await pending.shouldAutoVerifyCallCount() == 1)
        #expect(result.databaseVerification?.verifiedTrackCount == 3)
        #expect(result.databaseVerification?.removedTrackIDs == ["stale-track"])
        #expect(result.isPendingVerificationDue)
        #expect(result.databaseVerificationError == nil)
    }

    @Test("Preflight degrades cleanly when optional services are unavailable")
    func preflightHandlesMissingServices() async {
        let coordinator = MaintenanceCoordinator(
            databaseVerificationService: nil,
            pendingVerificationService: nil
        )

        let result = await coordinator.runPreflight()

        #expect(result.databaseVerification == nil)
        #expect(!result.isPendingVerificationDue)
        #expect(result.databaseVerificationError == nil)
    }

    @Test("Preflight records database verification errors without blocking pending status")
    func preflightRecordsDatabaseErrorAndStillChecksPending() async {
        let database = RecordingDatabaseVerificationService(error: MaintenanceTestError.databaseUnavailable)
        let pending = RecordingPendingService(shouldAutoVerify: true)
        let coordinator = MaintenanceCoordinator(
            databaseVerificationService: database,
            pendingVerificationService: pending
        )

        let result = await coordinator.runPreflight()

        #expect(await database.runCount() == 1)
        #expect(await pending.shouldAutoVerifyCallCount() == 1)
        #expect(result.databaseVerification == nil)
        #expect(result.isPendingVerificationDue)
        #expect(result.databaseVerificationError == "Database unavailable")
    }

    @Test("Preflight reads the live database verification schedule")
    func preflightReadsLiveSchedule() async {
        let bridge = SyncMockScriptClient()
        let store = SyncMockTrackStore()
        let pending = RecordingPendingService(shouldAutoVerify: true)
        let logDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MaintenanceCoordinatorTests-\(UUID().uuidString)")
        let service = LibrarySyncService(
            scriptBridge: bridge,
            trackStore: store,
            runtimeConfiguration: LibrarySyncRuntimeConfiguration(
                databaseVerificationIntervalDays: 0,
                logsBaseDirectory: logDirectory.path,
                lastDatabaseVerifyLog: "last.log"
            )
        )
        let coordinator = MaintenanceCoordinator(
            databaseVerificationService: service,
            pendingVerificationService: pending
        )
        await bridge.setLibrary(ids: ["T1"], tracks: [:])
        await store.setStored([
            Track(id: "T1", name: "One", artist: "Artist", album: "Album"),
        ])

        let disabledResult = await coordinator.runPreflight()

        #expect(disabledResult.databaseVerification == nil)
        #expect(disabledResult.databaseVerificationError == nil)
        #expect(disabledResult.isPendingVerificationDue)
        #expect(await bridge.fetchAllTrackIDsCallCount() == 0)

        await service.updateRuntimeConfiguration(
            LibrarySyncRuntimeConfiguration(
                databaseVerificationIntervalDays: 7,
                logsBaseDirectory: logDirectory.path,
                lastDatabaseVerifyLog: "last.log"
            )
        )
        let enabledResult = await coordinator.runPreflight()

        #expect(enabledResult.databaseVerification?.verifiedTrackCount == 1)
        #expect(await bridge.fetchAllTrackIDsCallCount() == 1)
        #expect(await pending.shouldAutoVerifyCallCount() == 2)
    }
}

private enum MaintenanceTestError: Error, LocalizedError {
    case databaseUnavailable

    var errorDescription: String? {
        "Database unavailable"
    }
}

private actor RecordingDatabaseVerificationService: DatabaseVerificationCleaning {
    private var scheduledRuns = 0
    private let error: Error?

    init(error: Error? = nil) {
        self.error = error
    }

    func runScheduledVerification() async throws -> DatabaseVerificationResult? {
        scheduledRuns += 1
        if let error {
            throw error
        }
        return DatabaseVerificationResult(
            verifiedTrackCount: 3,
            removedTrackIDs: ["stale-track"]
        )
    }

    func runCount() -> Int {
        scheduledRuns
    }
}

private actor RecordingPendingService: PendingVerificationService {
    private let shouldAutoVerifyValue: Bool
    private var shouldAutoVerifyCalls = 0

    init(shouldAutoVerify: Bool) {
        shouldAutoVerifyValue = shouldAutoVerify
    }

    func initialize() async throws {}

    func markForVerification(
        artist _: String,
        album _: String,
        reason _: String,
        metadata _: [String: String]?,
        recheckDays _: Int?
    ) async {}

    func removeFromPending(artist _: String, album _: String) async {}

    func getEntry(artist _: String, album _: String) async -> PendingAlbumEntry? {
        nil
    }

    func getAttemptCount(artist _: String, album _: String) async -> Int {
        0
    }

    func isVerificationNeeded(artist _: String, album _: String) async -> Bool {
        false
    }

    func getAllPendingAlbums() async -> [PendingAlbumEntry] {
        []
    }

    func shouldAutoVerify() async -> Bool {
        shouldAutoVerifyCalls += 1
        return shouldAutoVerifyValue
    }

    func updateVerificationTimestamp() async throws {}

    func shouldAutoVerifyCallCount() -> Int {
        shouldAutoVerifyCalls
    }
}
