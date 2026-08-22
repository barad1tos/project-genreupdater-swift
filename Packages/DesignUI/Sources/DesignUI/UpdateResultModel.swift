/// Availability of gated content or an action.
public enum ContentAccess: Equatable, Sendable {
    case available
    case locked(message: String)

    /// Whether the gated content or action is currently available.
    public var isAvailable: Bool {
        self == .available
    }
}

/// Identifies the result authority so the shared surface can expose only valid interactions.
public enum UpdateResultMode: Equatable, Sendable {
    case preview
    case write
}

/// Describes preview availability or the terminal state of a verified write result.
public enum UpdateResultStatus: Equatable, Sendable {
    case empty
    case ready
    case stale
    case unavailable
    case completed
    case completedWithFailures

    /// Whether this status permits changing preview decisions.
    public var isReviewable: Bool {
        self == .ready
    }
}

/// Defines the invariant top-level structure shared by preview and write results.
public enum UpdateResultSection: Equatable, Sendable {
    case status
    case metrics
    case albums
    case details
    case actions
}

/// Captures the user's decision for a proposed preview change.
public enum UpdateResultVerdict: Equatable, Sendable {
    case accepted
    case rejected
}

/// Separates preview decisions from verified outcomes for one metadata change.
public enum UpdateResultChangeState: Equatable, Sendable {
    case proposed(UpdateResultVerdict)
    case applied
    case noChange
    case skipped
    case failed(message: String)

    /// The preview decision when this state represents a proposal.
    public var verdict: UpdateResultVerdict? {
        guard case let .proposed(verdict) = self else { return nil }
        return verdict
    }
}

/// Describes a track's presentation outcome without becoming write authority.
public enum UpdateResultTrackState: Equatable, Sendable {
    case ready
    case applied
    case noChange
    case skipped
    case failed(message: String)
}

/// Carries display data for one proposed or verified metadata transition.
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

/// Groups presentation changes under one stable track identity and outcome.
public struct UpdateResultTrack: Identifiable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let artist: String
    public let state: UpdateResultTrackState
    public let changes: [UpdateResultChange]
    /// Optional technical and operational facts associated with this track result.
    public let details: [UpdateResultDetail]

    public init(
        id: String,
        title: String,
        artist: String,
        state: UpdateResultTrackState,
        changes: [UpdateResultChange],
        details: [UpdateResultDetail] = []
    ) {
        self.id = id
        self.title = title
        self.artist = artist
        self.state = state
        self.changes = changes
        self.details = details
    }
}

/// Groups result tracks under one display album for the shared result hierarchy.
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

/// Provides preformatted summary data and semantic tone for the result header.
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

/// Preserves operational or access context that must remain visible with results.
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

/// Carries one preformatted presentation fact without granting workflow authority.
public struct UpdateResultDetail: Identifiable, Equatable, Sendable {
    /// Stable presentation identity within its enclosing result.
    public let id: String
    /// Human-readable name for the fact.
    public let label: String
    /// Preformatted value displayed to the user.
    public let value: String

    /// Creates one immutable presentation fact.
    public init(id: String, label: String, value: String) {
        self.id = id
        self.label = label
        self.value = value
    }
}

/// Presents preview and verified write authorities through one immutable, action-free hierarchy.
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
    /// SF Symbol name displayed by the optional secondary action.
    public let secondaryActionIcon: String
    /// Optional operational facts associated with the complete result.
    public let details: [UpdateResultDetail]

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
        secondaryActionLabel: String? = nil,
        secondaryActionIcon: String = "arrow.counterclockwise",
        details: [UpdateResultDetail] = []
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
        self.secondaryActionIcon = secondaryActionIcon
        self.details = details
    }

    /// The invariant section order rendered in both result modes.
    public var sections: [UpdateResultSection] {
        [.status, .metrics, .albums, .details, .actions]
    }

    /// Whether preview decision controls may be exposed for this snapshot.
    public var canReview: Bool {
        mode == .preview && status.isReviewable
    }

    /// The number of track rows represented across all albums.
    public var affectedTrackCount: Int {
        albums.reduce(into: 0) { count, album in
            count += album.tracks.count
        }
    }
}
