import Foundation

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
    case previewFixes(FixPlanConfigurationSnapshot)
    case writeFixes(FixPlanWriteTarget)

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
        case let .writeFixes(target): target
        }
    }

    public var previewConfiguration: FixPlanConfigurationSnapshot? {
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

    public var intent: RunIntent {
        kind.intent
    }

    public var writeTarget: FixPlanWriteTarget? {
        kind.writeTarget
    }

    public var previewConfiguration: FixPlanConfigurationSnapshot? {
        kind.previewConfiguration
    }

    private init(
        id: RunRequestID = RunRequestID(),
        trigger: RunTrigger,
        kind: RunRequestKind,
        requestedTestArtists: [String],
        knownTrackCount: Int?
    ) {
        self.id = id
        self.trigger = trigger
        self.kind = kind
        self.requestedTestArtists = requestedTestArtists
        self.knownTrackCount = knownTrackCount
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
        configuration: FixPlanConfigurationSnapshot,
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
        target: FixPlanWriteTarget,
        requestedTestArtists: [String],
        knownTrackCount: Int?
    ) -> Self {
        Self(
            id: id,
            trigger: trigger,
            kind: .writeFixes(target),
            requestedTestArtists: requestedTestArtists,
            knownTrackCount: knownTrackCount
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
        configuration: FixPlanConfigurationSnapshot,
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

    public static func manualWrite(
        target: FixPlanWriteTarget,
        requestedTestArtists: [String],
        knownTrackCount: Int?
    ) -> Self {
        write(
            trigger: .manualCheck,
            target: target,
            requestedTestArtists: requestedTestArtists,
            knownTrackCount: knownTrackCount
        )
    }
}
