import Core
import Foundation

public protocol DatabaseVerificationCleaning: Actor {
    /// Runs automatic database verification when the live schedule is enabled.
    func runScheduledVerification() async throws -> DatabaseVerificationResult?
}

extension LibrarySyncService: DatabaseVerificationCleaning {}

public struct MaintenancePreflightResult: Sendable, Equatable {
    public let databaseVerification: DatabaseVerificationResult?
    public let databaseVerificationError: String?
    public let isPendingVerificationDue: Bool

    public init(
        databaseVerification: DatabaseVerificationResult?,
        databaseVerificationError: String?,
        isPendingVerificationDue: Bool
    ) {
        self.databaseVerification = databaseVerification
        self.databaseVerificationError = databaseVerificationError
        self.isPendingVerificationDue = isPendingVerificationDue
    }
}

public actor MaintenanceCoordinator {
    private let databaseVerificationService: (any DatabaseVerificationCleaning)?
    private let pendingVerificationService: (any PendingVerificationService)?

    public init(
        databaseVerificationService: (any DatabaseVerificationCleaning)?,
        pendingVerificationService: (any PendingVerificationService)?
    ) {
        self.databaseVerificationService = databaseVerificationService
        self.pendingVerificationService = pendingVerificationService
    }

    public func runPreflight() async -> MaintenancePreflightResult {
        let databaseVerification = await runDatabaseVerificationIfNeeded()
        let isPendingVerificationDue = await pendingVerificationService?.shouldAutoVerify() ?? false

        return MaintenancePreflightResult(
            databaseVerification: databaseVerification.result,
            databaseVerificationError: databaseVerification.error,
            isPendingVerificationDue: isPendingVerificationDue
        )
    }

    private func runDatabaseVerificationIfNeeded() async -> (result: DatabaseVerificationResult?, error: String?) {
        guard let databaseVerificationService else {
            return (nil, nil)
        }
        do {
            let result = try await databaseVerificationService.runScheduledVerification()
            return (result, nil)
        } catch {
            return (nil, error.localizedDescription)
        }
    }
}
