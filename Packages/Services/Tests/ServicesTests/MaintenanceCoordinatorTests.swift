import Core
import Foundation
import Services
import Testing

@Suite("MaintenanceCoordinator")
struct MaintenanceCoordinatorTests {
    @Test("Preflight verifies database without force and reports pending auto-check")
    func preflightRunsDatabaseVerificationAndReportsPendingStatus() async {
        let database = RecordingDatabaseVerificationService()
        let pending = MaintenanceRecordingPendingVerificationService(shouldAutoVerify: true)
        let coordinator = MaintenanceCoordinator(
            databaseVerificationService: database,
            pendingVerificationService: pending
        )

        let result = await coordinator.runPreflight()

        #expect(await database.receivedForceValues() == [false])
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
        let pending = MaintenanceRecordingPendingVerificationService(shouldAutoVerify: true)
        let coordinator = MaintenanceCoordinator(
            databaseVerificationService: database,
            pendingVerificationService: pending
        )

        let result = await coordinator.runPreflight()

        #expect(await database.receivedForceValues() == [false])
        #expect(await pending.shouldAutoVerifyCallCount() == 1)
        #expect(result.databaseVerification == nil)
        #expect(result.isPendingVerificationDue)
        #expect(result.databaseVerificationError == "Database unavailable")
    }
}

private enum MaintenanceTestError: Error, LocalizedError {
    case databaseUnavailable

    var errorDescription: String? {
        "Database unavailable"
    }
}

private actor RecordingDatabaseVerificationService: DatabaseVerificationCleaning {
    private var forceValues: [Bool] = []
    private let error: Error?

    init(error: Error? = nil) {
        self.error = error
    }

    func verifyAndCleanDatabase(force: Bool) async throws -> DatabaseVerificationResult {
        forceValues.append(force)
        if let error {
            throw error
        }
        return DatabaseVerificationResult(
            verifiedTrackCount: 3,
            removedTrackIDs: ["stale-track"]
        )
    }

    func receivedForceValues() -> [Bool] {
        forceValues
    }
}

private actor MaintenanceRecordingPendingVerificationService: PendingVerificationService {
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

    func generateProblematicAlbumsReport(minAttempts _: Int, reportURL _: URL?) async throws -> Int {
        0
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
