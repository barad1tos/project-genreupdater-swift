/// Availability of gated content or an action.
public enum ContentAccess: Equatable, Sendable {
    case available
    case locked(message: String)

    /// Whether the gated content or action is currently available.
    public var isAvailable: Bool {
        self == .available
    }
}

public enum UpdateResultMode: Equatable, Sendable {
    case preview
    case write
}

public enum UpdateResultStatus: Equatable, Sendable {
    case empty
    case ready
    case stale
    case unavailable
    case completed
    case completedWithFailures

    public var isReviewable: Bool {
        self == .ready
    }
}

public enum UpdateResultSection: Equatable, Sendable {
    case status
    case metrics
    case albums
    case details
    case actions
}

public enum UpdateResultVerdict: Equatable, Sendable {
    case accepted
    case rejected
}

public enum UpdateResultChangeState: Equatable, Sendable {
    case proposed(UpdateResultVerdict)
    case applied
    case noChange
    case skipped
    case failed(message: String)

    public var verdict: UpdateResultVerdict? {
        guard case let .proposed(verdict) = self else { return nil }
        return verdict
    }
}

public enum UpdateResultTrackState: Equatable, Sendable {
    case ready
    case applied
    case noChange
    case skipped
    case failed(message: String)

    public var isFailure: Bool {
        if case .failed = self {
            return true
        }
        return false
    }
}

public struct UpdateResultChange: Identifiable, Equatable, Sendable {
    public let id: String
    public let type: ChangeType
    public let oldValue: String?
    public let newValue: String
    public let source: String?
    public let confidence: Double?
    public let state: UpdateResultChangeState

    public init(
        id: String,
        type: ChangeType,
        oldValue: String?,
        newValue: String,
        source: String? = nil,
        confidence: Double? = nil,
        state: UpdateResultChangeState
    ) {
        self.id = id
        self.type = type
        self.oldValue = oldValue
        self.newValue = newValue
        self.source = source
        self.confidence = confidence
        self.state = state
    }
}

public struct UpdateResultTrack: Identifiable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let artist: String
    public let state: UpdateResultTrackState
    public let changes: [UpdateResultChange]

    public init(
        id: String,
        title: String,
        artist: String,
        state: UpdateResultTrackState,
        changes: [UpdateResultChange]
    ) {
        self.id = id
        self.title = title
        self.artist = artist
        self.state = state
        self.changes = changes
    }
}

public struct UpdateResultAlbum: Identifiable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let tracks: [UpdateResultTrack]

    public init(id: String, title: String, tracks: [UpdateResultTrack]) {
        self.id = id
        self.title = title
        self.tracks = tracks
    }
}

public struct UpdateResultMetric: Identifiable, Equatable, Sendable {
    public let id: String
    public let label: String
    public let value: String
    public let tone: Tone

    public init(id: String, label: String, value: String, tone: Tone) {
        self.id = id
        self.label = label
        self.value = value
        self.tone = tone
    }
}

public struct UpdateResultNotice: Identifiable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let message: String
    public let tone: Tone

    public init(id: String, title: String, message: String, tone: Tone) {
        self.id = id
        self.title = title
        self.message = message
        self.tone = tone
    }
}

public struct UpdateResultSnapshot: Equatable, Sendable {
    public let mode: UpdateResultMode
    public let status: UpdateResultStatus
    public let title: String
    public let subtitle: String
    public let scope: String
    public let metrics: [UpdateResultMetric]
    public let albums: [UpdateResultAlbum]
    public let notices: [UpdateResultNotice]
    public let contentAccess: ContentAccess
    public let primaryActionLabel: String
    public let secondaryActionLabel: String?

    public init(
        mode: UpdateResultMode,
        status: UpdateResultStatus,
        title: String,
        subtitle: String,
        scope: String,
        metrics: [UpdateResultMetric],
        albums: [UpdateResultAlbum],
        notices: [UpdateResultNotice],
        contentAccess: ContentAccess,
        primaryActionLabel: String,
        secondaryActionLabel: String? = nil
    ) {
        self.mode = mode
        self.status = status
        self.title = title
        self.subtitle = subtitle
        self.scope = scope
        self.metrics = metrics
        self.albums = albums
        self.notices = notices
        self.contentAccess = contentAccess
        self.primaryActionLabel = primaryActionLabel
        self.secondaryActionLabel = secondaryActionLabel
    }

    public var sections: [UpdateResultSection] {
        [.status, .metrics, .albums, .details, .actions]
    }

    public var canReview: Bool {
        mode == .preview && status.isReviewable
    }

    public var affectedTrackCount: Int {
        albums.reduce(into: 0) { count, album in
            count += album.tracks.count
        }
    }

    public var changedTrackCount: Int {
        albums.reduce(into: 0) { count, album in
            count += album.tracks.count { $0.state == .applied }
        }
    }

    public var failedCount: Int {
        albums.reduce(into: 0) { count, album in
            count += album.tracks.count { $0.state.isFailure }
        }
    }
}
