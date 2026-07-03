import Foundation

public enum RunTrigger: String, Codable, Equatable, Sendable {
    case manualCheck
    case backgroundSync
    case fileSystemEvent
    case recovery
}

public enum RunIntent: String, Codable, Equatable, Sendable {
    case observeLibrary
}

public struct RunRequest: Equatable, Sendable {
    public let id: RunRequestID
    public let trigger: RunTrigger
    public let intent: RunIntent
    public let requestedTestArtists: [String]
    public let knownTrackCount: Int?

    public init(
        id: RunRequestID = RunRequestID(),
        trigger: RunTrigger,
        intent: RunIntent,
        requestedTestArtists: [String],
        knownTrackCount: Int?
    ) {
        self.id = id
        self.trigger = trigger
        self.intent = intent
        self.requestedTestArtists = requestedTestArtists
        self.knownTrackCount = knownTrackCount
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
}
