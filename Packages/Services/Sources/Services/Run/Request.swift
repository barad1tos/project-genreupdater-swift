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

public struct RunRequest: Equatable, Sendable {
    public let id: RunRequestID
    public let trigger: RunTrigger
    public let intent: RunIntent
    public let requestedTestArtists: [String]
    public let knownTrackCount: Int?
    public let applyTarget: FixPlanApplyTarget?

    public init(
        id: RunRequestID = RunRequestID(),
        trigger: RunTrigger,
        intent: RunIntent,
        requestedTestArtists: [String],
        knownTrackCount: Int?,
        applyTarget: FixPlanApplyTarget? = nil
    ) {
        self.id = id
        self.trigger = trigger
        self.intent = intent
        self.requestedTestArtists = requestedTestArtists
        self.knownTrackCount = knownTrackCount
        self.applyTarget = applyTarget
    }

    public static func manualObservation(
        requestedTestArtists: [String],
        knownTrackCount: Int?
    ) -> Self {
        Self(
            trigger: .manualCheck,
            intent: .observeLibrary,
            requestedTestArtists: requestedTestArtists,
            knownTrackCount: knownTrackCount
        )
    }

    public static func manualPreview(
        requestedTestArtists: [String],
        knownTrackCount: Int?
    ) -> Self {
        Self(
            trigger: .manualCheck,
            intent: .previewFixes,
            requestedTestArtists: requestedTestArtists,
            knownTrackCount: knownTrackCount
        )
    }

    public static func manualWrite(
        target: FixPlanApplyTarget,
        requestedTestArtists: [String],
        knownTrackCount: Int?
    ) -> Self {
        Self(
            trigger: .manualCheck,
            intent: .writeFixes,
            requestedTestArtists: requestedTestArtists,
            knownTrackCount: knownTrackCount,
            applyTarget: target
        )
    }
}
