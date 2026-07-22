import Foundation

extension RunOrchestrator {
    public struct WriteDependencies: Sendable {
        public let persistCheckpoint: (@Sendable (RunID, WorkCheckpoint) async throws -> Void)?
        public let writeFixPlan: @Sendable (
            FixPlanWriteInput,
            @escaping WorkCheckpointSink
        ) async throws -> BatchUpdateResult
        public let beginRecoveryHold: (@Sendable () async -> UUID)?

        public init(
            persistCheckpoint: (@Sendable (RunID, WorkCheckpoint) async throws -> Void)? = nil,
            writeFixPlan: @escaping @Sendable (
                FixPlanWriteInput,
                @escaping WorkCheckpointSink
            ) async throws -> BatchUpdateResult,
            beginRecoveryHold: (@Sendable () async -> UUID)? = nil
        ) {
            self.persistCheckpoint = persistCheckpoint
            self.writeFixPlan = writeFixPlan
            self.beginRecoveryHold = beginRecoveryHold
        }
    }

    public struct Dependencies: Sendable {
        public let synchronizeLibrary: @Sendable () async throws -> SyncResult
        public let synchronizePreview: (@Sendable (
            ProcessingScopeSnapshot,
            FixPlanConfig
        ) async throws -> SyncResult)?
        public let persistRunRecord: @Sendable (RunRecord) async throws -> Void
        public let produceFixPlan: (@Sendable (
            RunID,
            ProcessingScopeSnapshot,
            FixPlanConfig
        ) async throws -> FixPlanProduction)?
        public let releasePreview: (@Sendable (FixPlanConfig) async -> Void)?
        public let write: WriteDependencies?
        public let now: @Sendable () -> Date

        public init(
            synchronizeLibrary: @escaping @Sendable () async throws -> SyncResult,
            synchronizePreview: (@Sendable (
                ProcessingScopeSnapshot,
                FixPlanConfig
            ) async throws -> SyncResult)? = nil,
            persistRunRecord: @escaping @Sendable (RunRecord) async throws -> Void,
            produceFixPlan: (@Sendable (
                RunID,
                ProcessingScopeSnapshot,
                FixPlanConfig
            ) async throws -> FixPlanProduction)? = nil,
            releasePreview: (@Sendable (FixPlanConfig) async -> Void)? = nil,
            write: WriteDependencies? = nil,
            now: @escaping @Sendable () -> Date = { Date() }
        ) {
            self.synchronizeLibrary = synchronizeLibrary
            self.synchronizePreview = synchronizePreview
            self.persistRunRecord = persistRunRecord
            self.produceFixPlan = produceFixPlan
            self.releasePreview = releasePreview
            self.write = write
            self.now = now
        }
    }
}
