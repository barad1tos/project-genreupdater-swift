import Core
import Foundation

/// Why a run record cannot serve as the source of a linked continuation,
/// or why the follow-up input cannot seed one.
public enum RunContinuationError: Error, Equatable {
    case sourceRunStillOpen
    case sourceRunNotWrite
    case nothingToContinue
    case inputWorkNotPrepared
    case inputPlanMismatch
}

public enum RunTrigger: String, Codable, Equatable, Sendable {
    case manualCheck
    case backgroundSync
    case fileSystemEvent
    case recovery
}

public enum RunIntent: String, Codable, Equatable, Sendable {
    case observeLibrary
    case previewFixes
    case writeFixes
    case batchUpdate

    /// Mutating runs share the record-integrity and recovery guarantees:
    /// they fail fast without run history and route uncertain script
    /// outcomes to recovery instead of a plain failure.
    public var isMutating: Bool {
        switch self {
        case .observeLibrary, .previewFixes: false
        case .writeFixes, .batchUpdate: true
        }
    }
}

public struct FixPlanRunPolicy: Equatable, Sendable {
    public let mode: RunProcessingMode
    public let automation: AutomationStrategy

    public init(mode: RunProcessingMode, automation: AutomationStrategy) {
        self.mode = mode
        self.automation = automation
    }
}

/// The work identity a full-library batch run carries: enough for the
/// arbiter to rank and cover it and for the record to stay honest. The
/// tracks themselves stay with the live view-model the runner reaches.
public struct BatchRunInput: Equatable, Sendable {
    public let options: UpdateOptions
    public let trackCount: Int

    public init(options: UpdateOptions, trackCount: Int) {
        self.options = options
        self.trackCount = trackCount
    }
}

public enum RunRequestKind: Equatable, Sendable {
    case observeLibrary
    case previewFixes(FixPlanConfig)
    case writeFixes(FixPlanWriteInput)
    case batchUpdate(BatchRunInput)

    public var intent: RunIntent {
        switch self {
        case .observeLibrary: .observeLibrary
        case .previewFixes: .previewFixes
        case .writeFixes: .writeFixes
        case .batchUpdate: .batchUpdate
        }
    }

    public var writeTarget: FixPlanWriteTarget? {
        switch self {
        case .observeLibrary, .previewFixes, .batchUpdate: nil
        case let .writeFixes(input): input.target
        }
    }

    public var writeInput: FixPlanWriteInput? {
        if case let .writeFixes(input) = self {
            input
        } else {
            nil
        }
    }

    public var previewConfiguration: FixPlanConfig? {
        if case let .previewFixes(configuration) = self {
            configuration
        } else {
            nil
        }
    }
}

public struct RunRequest: Equatable, Sendable {
    public let id: RunRequestID
    public let trigger: RunTrigger
    public let kind: RunRequestKind
    public let requestedTestArtists: [String]
    public let knownTrackCount: Int?
    public let fixPlanPolicy: FixPlanRunPolicy?
    /// The closed run this request intentionally continues, if any.
    public let continuesRunID: RunID?

    public var intent: RunIntent {
        kind.intent
    }

    public var writeTarget: FixPlanWriteTarget? {
        kind.writeTarget
    }

    public var writeInput: FixPlanWriteInput? {
        kind.writeInput
    }

    public var previewConfiguration: FixPlanConfig? {
        kind.previewConfiguration
    }

    var canWriteLibrary: Bool {
        switch intent {
        case .writeFixes, .batchUpdate:
            true
        case .previewFixes:
            fixPlanPolicy?.mode == .autoFix
        case .observeLibrary:
            false
        }
    }

    private init(
        id: RunRequestID = RunRequestID(),
        trigger: RunTrigger,
        kind: RunRequestKind,
        requestedTestArtists: [String],
        knownTrackCount: Int?,
        fixPlanPolicy: FixPlanRunPolicy? = nil,
        continuesRunID: RunID? = nil
    ) {
        self.id = id
        self.trigger = trigger
        self.kind = kind
        self.requestedTestArtists = requestedTestArtists
        self.knownTrackCount = knownTrackCount
        self.fixPlanPolicy = fixPlanPolicy
        self.continuesRunID = continuesRunID
    }

    public static func observation(
        id: RunRequestID = RunRequestID(),
        trigger: RunTrigger,
        requestedTestArtists: [String],
        knownTrackCount: Int?
    ) -> Self {
        Self(
            id: id,
            trigger: trigger,
            kind: .observeLibrary,
            requestedTestArtists: requestedTestArtists,
            knownTrackCount: knownTrackCount
        )
    }

    public static func preview(
        id: RunRequestID = RunRequestID(),
        trigger: RunTrigger,
        configuration: FixPlanConfig,
        mode: RunProcessingMode = .preview,
        automation: AutomationStrategy = .manualOnly,
        requestedTestArtists: [String],
        knownTrackCount: Int?
    ) -> Self {
        Self(
            id: id,
            trigger: trigger,
            kind: .previewFixes(configuration),
            requestedTestArtists: requestedTestArtists,
            knownTrackCount: knownTrackCount,
            fixPlanPolicy: FixPlanRunPolicy(mode: mode, automation: automation)
        )
    }

    private static func write(
        id: RunRequestID = RunRequestID(),
        trigger: RunTrigger,
        input: FixPlanWriteInput,
        requiredAdmissionFeature: AppFeature?
    ) -> Self {
        Self(
            id: id,
            trigger: trigger,
            kind: .writeFixes(input.requiringAdmission(requiredAdmissionFeature)),
            requestedTestArtists: input.scope.normalizedTestArtists,
            knownTrackCount: input.scope.knownTrackCount
        )
    }

    public static func manualObservation(
        requestedTestArtists: [String],
        knownTrackCount: Int?
    ) -> Self {
        observation(
            trigger: .manualCheck,
            requestedTestArtists: requestedTestArtists,
            knownTrackCount: knownTrackCount
        )
    }

    public static func manualPreview(
        configuration: FixPlanConfig,
        requestedTestArtists: [String],
        knownTrackCount: Int?
    ) -> Self {
        preview(
            trigger: .manualCheck,
            configuration: configuration,
            requestedTestArtists: requestedTestArtists,
            knownTrackCount: knownTrackCount
        )
    }

    public static func batchUpdate(
        id: RunRequestID = RunRequestID(),
        trigger: RunTrigger,
        input: BatchRunInput,
        requestedTestArtists: [String],
        knownTrackCount: Int?
    ) -> Self {
        Self(
            id: id,
            trigger: trigger,
            kind: .batchUpdate(input),
            requestedTestArtists: requestedTestArtists,
            knownTrackCount: knownTrackCount
        )
    }

    public static func manualBatchUpdate(
        input: BatchRunInput,
        requestedTestArtists: [String],
        knownTrackCount: Int?
    ) -> Self {
        batchUpdate(
            trigger: .manualCheck,
            input: input,
            requestedTestArtists: requestedTestArtists,
            knownTrackCount: knownTrackCount
        )
    }

    public static func manualWrite(input: FixPlanWriteInput) -> Self {
        write(
            trigger: .manualCheck,
            input: input,
            requiredAdmissionFeature: input.configuration.writeAuthority == .automaticPlan ? .autoSync : nil
        )
    }

    public static func automaticWrite(
        trigger: RunTrigger,
        input: FixPlanWriteInput
    ) -> Self {
        let feature: AppFeature? = switch trigger {
        case .backgroundSync, .fileSystemEvent: .autoSync
        case .manualCheck, .recovery: nil
        }
        return write(
            trigger: trigger,
            input: input,
            requiredAdmissionFeature: feature
        )
    }

    /// A linked continuation of a closed write run (ADR 0005/0006): a NEW
    /// run with fresh consent carried by `input`, never a resumed loop.
    /// The source must be finished, be a write run, and still hold
    /// continuable work.
    public static func continuation(
        of record: RunRecord,
        input: FixPlanWriteInput
    ) throws -> Self {
        guard record.intent == .writeFixes else {
            throw RunContinuationError.sourceRunNotWrite
        }
        guard record.finishedAt != nil else {
            throw RunContinuationError.sourceRunStillOpen
        }
        guard !record.continuableWork.isEmpty else {
            throw RunContinuationError.nothingToContinue
        }
        // Continuable items are terminal on the source; a continuation must
        // re-prepare them, never carry terminal states into a fresh ledger.
        guard input.workItems.allSatisfy({ $0.state == .prepared }) else {
            throw RunContinuationError.inputWorkNotPrepared
        }
        // ADR 0005 lineage: a continuation re-applies the plan the source run
        // executed. An unverifiable source plan fails closed — stamping
        // `continuesRunID` onto an unrelated plan's write would forge lineage.
        guard let executedTarget = record.writeTarget,
              input.target.planID == executedTarget.planID
        else {
            throw RunContinuationError.inputPlanMismatch
        }
        let feature: AppFeature? = input.configuration.writeAuthority == .automaticPlan ? .autoSync : nil
        return Self(
            trigger: .recovery,
            kind: .writeFixes(input.requiringAdmission(feature)),
            requestedTestArtists: input.scope.normalizedTestArtists,
            knownTrackCount: input.scope.knownTrackCount,
            continuesRunID: record.runID
        )
    }
}
