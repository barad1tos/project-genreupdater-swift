import Foundation

extension RunOrchestrator {
    public struct WriteDependencies: Sendable {
        public let persistCheckpoint: (@Sendable (RunID, WorkCheckpoint) async throws -> Void)?
        /// The run ID attributes change-log entries the write produces.
        public let writeFixPlan: (@Sendable (
            FixPlanWriteInput,
            RunID,
            @escaping WorkCheckpointSink
        ) async throws -> BatchUpdateResult)?
        public let beginRecoveryHold: (@Sendable () async -> UUID)?
        public let restoreRecoveryHold: (@Sendable (UUID) async -> UUID)?
        public let clearRecoveryHold: (@Sendable (UUID) async throws -> Void)?

        public init(
            persistCheckpoint: (@Sendable (RunID, WorkCheckpoint) async throws -> Void)? = nil,
            writeFixPlan: (@Sendable (
                FixPlanWriteInput,
                RunID,
                @escaping WorkCheckpointSink
            ) async throws -> BatchUpdateResult)? = nil,
            beginRecoveryHold: (@Sendable () async -> UUID)? = nil,
            restoreRecoveryHold: (@Sendable (UUID) async -> UUID)? = nil,
            clearRecoveryHold: (@Sendable (UUID) async throws -> Void)? = nil
        ) {
            self.persistCheckpoint = persistCheckpoint
            self.writeFixPlan = writeFixPlan
            self.beginRecoveryHold = beginRecoveryHold
            self.restoreRecoveryHold = restoreRecoveryHold
            self.clearRecoveryHold = clearRecoveryHold
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
        /// Runs the full-library batch against the live view-model; the
        /// change-log entries persist inside, only the run record is new.
        public let runBatchUpdate: (@Sendable (
            BatchRunInput,
            RunID
        ) async throws -> BatchUpdateResult)?
        /// The currently authoritative write target for a plan, used to prove
        /// a queued write's consent is still fresh before release. nil result
        /// means no current decision; a nil closure makes freshness
        /// unverifiable and release fails closed.
        public let currentDecisionTarget: (@Sendable (FixPlanID) async -> FixPlanWriteTarget?)?
        /// Fired when an observation run completes having seen library
        /// changes — the durable incremental mark advances (Python parity:
        /// empty runs keep the old mark so the next check passes the
        /// interval gate again).
        public let onIncrementalWorkCompleted: (@Sendable () async -> Void)?
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
            runBatchUpdate: (@Sendable (
                BatchRunInput,
                RunID
            ) async throws -> BatchUpdateResult)? = nil,
            currentDecisionTarget: (@Sendable (FixPlanID) async -> FixPlanWriteTarget?)? = nil,
            onIncrementalWorkCompleted: (@Sendable () async -> Void)? = nil,
            now: @escaping @Sendable () -> Date = { Date() }
        ) {
            self.synchronizeLibrary = synchronizeLibrary
            self.synchronizePreview = synchronizePreview
            self.persistRunRecord = persistRunRecord
            self.produceFixPlan = produceFixPlan
            self.releasePreview = releasePreview
            self.write = write
            self.runBatchUpdate = runBatchUpdate
            self.currentDecisionTarget = currentDecisionTarget
            self.onIncrementalWorkCompleted = onIncrementalWorkCompleted
            self.now = now
        }
    }
}
