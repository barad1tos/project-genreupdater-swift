import Foundation

/// Why a run record cannot serve as the source of a linked continuation,
/// or why the follow-up input cannot seed one.
public enum RunContinuationError: Error, Equatable {
    case sourceRunStillOpen
    case sourceRunNotWrite
    case nothingToContinue
    case inputWorkNotPrepared
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
}

public enum RunRequestKind: Equatable, Sendable {
    case observeLibrary
    case previewFixes(FixPlanConfig)
    case writeFixes(FixPlanWriteInput)

    public var intent: RunIntent {
        switch self {
        case .observeLibrary: .observeLibrary
        case .previewFixes: .previewFixes
        case .writeFixes: .writeFixes
        }
    }

    public var writeTarget: FixPlanWriteTarget? {
        switch self {
        case .observeLibrary, .previewFixes: nil
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

    private init(
        id: RunRequestID = RunRequestID(),
        trigger: RunTrigger,
        kind: RunRequestKind,
        requestedTestArtists: [String],
        knownTrackCount: Int?,
        continuesRunID: RunID? = nil
    ) {
        self.id = id
        self.trigger = trigger
        self.kind = kind
        self.requestedTestArtists = requestedTestArtists
        self.knownTrackCount = knownTrackCount
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
        requestedTestArtists: [String],
        knownTrackCount: Int?
    ) -> Self {
        Self(
            id: id,
            trigger: trigger,
            kind: .previewFixes(configuration),
            requestedTestArtists: requestedTestArtists,
            knownTrackCount: knownTrackCount
        )
    }

    public static func write(
        id: RunRequestID = RunRequestID(),
        trigger: RunTrigger,
        input: FixPlanWriteInput
    ) -> Self {
        Self(
            id: id,
            trigger: trigger,
            kind: .writeFixes(input),
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

    public static func manualWrite(input: FixPlanWriteInput) -> Self {
        write(
            trigger: .manualCheck,
            input: input
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
        return Self(
            trigger: .recovery,
            kind: .writeFixes(input),
            requestedTestArtists: input.scope.normalizedTestArtists,
            knownTrackCount: input.scope.knownTrackCount,
            continuesRunID: record.runID
        )
    }
}
