import SwiftUI

public enum FixPlanStatus: String, Equatable, Sendable {
    case empty
    case ready
    case stale
    case unavailable
}

public enum FixPlanVerdict: String, Equatable, Sendable {
    case accepted
    case rejected
}

public struct FixPlanItem: Identifiable, Equatable, Sendable {
    public let id: String
    public let track: String
    public let artist: String
    public let album: String
    public let type: ChangeType
    public let old: String?
    public let new: String
    public let confidence: Double
    public let source: String
    public let verdict: FixPlanVerdict

    public init(
        id: String,
        track: String,
        artist: String,
        album: String,
        type: ChangeType,
        old: String?,
        new: String,
        confidence: Double,
        source: String,
        verdict: FixPlanVerdict
    ) {
        self.id = id
        self.track = track
        self.artist = artist
        self.album = album
        self.type = type
        self.old = old
        self.new = new
        self.confidence = confidence
        self.source = source
        self.verdict = verdict
    }
}

public struct FixPlanSnapshot: Equatable, Sendable {
    public static let empty = Self(
        status: .empty,
        planID: nil,
        planRevision: nil,
        decisionRevision: nil,
        projectionRevision: 0,
        itemCount: 0,
        acceptedCount: 0,
        rejectedCount: 0,
        genreCount: 0,
        yearCount: 0,
        averageConfidence: nil,
        canApply: false,
        issues: [],
        items: []
    )

    public let status: FixPlanStatus
    public let planID: String?
    public let planRevision: Int?
    public let decisionRevision: Int?
    public let projectionRevision: UInt64
    public let itemCount: Int
    public let acceptedCount: Int
    public let rejectedCount: Int
    public let genreCount: Int
    public let yearCount: Int
    public let averageConfidence: Int?
    public let canApply: Bool
    public let issues: [String]
    public let items: [FixPlanItem]

    public init(
        status: FixPlanStatus,
        planID: String?,
        planRevision: Int?,
        decisionRevision: Int?,
        projectionRevision: UInt64,
        itemCount: Int,
        acceptedCount: Int,
        rejectedCount: Int,
        genreCount: Int,
        yearCount: Int,
        averageConfidence: Int?,
        canApply: Bool,
        issues: [String],
        items: [FixPlanItem]
    ) {
        self.status = status
        self.planID = planID
        self.planRevision = planRevision
        self.decisionRevision = decisionRevision
        self.projectionRevision = projectionRevision
        self.itemCount = itemCount
        self.acceptedCount = acceptedCount
        self.rejectedCount = rejectedCount
        self.genreCount = genreCount
        self.yearCount = yearCount
        self.averageConfidence = averageConfidence
        self.canApply = canApply
        self.issues = issues
        self.items = items
    }
}

public struct FixPlanView: View {
    public let snapshot: FixPlanSnapshot
    public let noticeMessage: String?
    public let noticeTone: Tone
    public let isReviewBusy: Bool
    public let onAccept: (() -> Void)?
    public let onApply: (() -> Void)?
    public let onReject: (() -> Void)?
    public let onToggleItem: ((String) -> Void)?

    public init(
        snapshot: FixPlanSnapshot,
        noticeMessage: String? = nil,
        noticeTone: Tone = .info,
        isReviewBusy: Bool = false,
        onAccept: (() -> Void)? = nil,
        onApply: (() -> Void)? = nil,
        onReject: (() -> Void)? = nil,
        onToggleItem: ((String) -> Void)? = nil
    ) {
        self.snapshot = snapshot
        self.noticeMessage = noticeMessage
        self.noticeTone = noticeTone
        self.isReviewBusy = isReviewBusy
        self.onAccept = onAccept
        self.onApply = onApply
        self.onReject = onReject
        self.onToggleItem = onToggleItem
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                header
                notice
                stats
                issues
                itemList
            }
            .padding(24)
            .frame(maxWidth: 1320, alignment: .leading)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .background(Ayu.window)
        .navigationTitle("Update")
    }

    private var header: some View {
        GlassCard {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: statusSymbol)
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(statusTone.color)
                    .frame(width: 34, height: 34)

                VStack(alignment: .leading, spacing: 9) {
                    HStack(spacing: 9) {
                        Text(title)
                            .font(.system(size: 24, weight: .heavy))
                            .foregroundStyle(Ayu.fg)
                        TagPill(text: statusLabel, tone: statusTone, dot: true)
                    }

                    Text(subtitle)
                        .font(.system(size: 13))
                        .foregroundStyle(Ayu.fg2)
                }

                Spacer()

                HStack(spacing: 8) {
                    Button {
                        onReject?()
                    } label: {
                        Label("Reject all", systemImage: "xmark.circle")
                    }
                    .disabled(!canReject)

                    Button {
                        onAccept?()
                    } label: {
                        Label("Accept all", systemImage: "checkmark.circle")
                    }
                    .disabled(!canAccept)

                    Button {
                        onApply?()
                    } label: {
                        Label("Apply \(snapshot.acceptedCount)", systemImage: "square.and.arrow.down")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!canApplyChanges)
                }
            }
        }
    }

    @ViewBuilder
    private var notice: some View {
        if let noticeMessage {
            SectionCard(
                symbol: noticeSymbol,
                tone: noticeTone,
                title: "Review status"
            ) {
                Text(noticeMessage)
                    .font(.system(size: 12.5))
                    .foregroundStyle(Ayu.fg2)
            }
        }
    }

    private var stats: some View {
        GlassCard {
            HStack(spacing: 34) {
                stat(snapshot.itemCount.formatted(), "Changes", .accent)
                stat(snapshot.acceptedCount.formatted(), "Accepted", .success)
                stat(snapshot.rejectedCount.formatted(), "Rejected", .warning)
                stat(snapshot.genreCount.formatted(), "Genre", .purple)
                stat(snapshot.yearCount.formatted(), "Year", .info)
                if let averageConfidence = snapshot.averageConfidence {
                    stat("\(averageConfidence)%", "Avg confidence", .teal)
                }
                Spacer(minLength: 0)
            }
        }
    }

    @ViewBuilder
    private var issues: some View {
        if !snapshot.issues.isEmpty {
            SectionCard(
                symbol: "exclamationmark.triangle",
                tone: .warning,
                title: "Plan notices"
            ) {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(snapshot.issues, id: \.self) { issue in
                        Text(issue)
                            .font(.system(size: 12.5))
                            .foregroundStyle(Ayu.fg2)
                    }
                }
            }
        }
    }

    private var itemList: some View {
        GlassCard(padding: 0) {
            VStack(spacing: 0) {
                HStack {
                    Text("\(snapshot.items.count.formatted()) proposed changes")
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(Ayu.fg2)
                    Spacer()
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 13)

                Divider().overlay(Ayu.glassBorder)

                if snapshot.items.isEmpty {
                    emptyState
                } else {
                    LazyVStack(spacing: 0) {
                        ForEach(snapshot.items) { item in
                            itemRow(item)
                            if item.id != snapshot.items.last?.id {
                                Divider().overlay(Ayu.glassBorder)
                            }
                        }
                    }
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(emptyTitle)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Ayu.fg)
            Text(emptyDetail)
                .font(.system(size: 12.5))
                .foregroundStyle(Ayu.fg2)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func itemRow(_ item: FixPlanItem) -> some View {
        HStack(spacing: 13) {
            Image(systemName: item.type.symbol)
                .foregroundStyle(item.type.tone.color)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 2) {
                Text(item.track)
                    .font(.system(size: 13.5, weight: .medium))
                    .foregroundStyle(Ayu.fg)
                    .lineLimit(1)
                Text("\(item.artist) · \(item.album)")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Ayu.fg2)
                    .lineLimit(1)
            }

            Spacer(minLength: 12)

            TagPill(text: item.source, tone: .neutral)
            TagPill(text: item.verdict.label, tone: item.verdict.tone, dot: true)
            DiffRow(old: item.old, new: item.new)
                .font(.system(size: 11.5))
            ConfidenceBadge(conf: item.confidence)
            Button {
                onToggleItem?(item.id)
            } label: {
                Image(systemName: item.verdict.toggleSymbol)
                    .frame(width: 20, height: 20)
            }
            .buttonStyle(.borderless)
            .disabled(!canToggle)
            .help(item.verdict.toggleHelp)
            .accessibilityLabel(item.verdict.toggleHelp)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 11)
    }

    private func stat(_ value: String, _ label: String, _ tone: Tone) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.rounded(24, .heavy))
                .foregroundStyle(tone == .neutral ? Ayu.fg : tone.color)
                .monospacedDigit()
            Text(label)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(Ayu.fg2)
        }
    }

    private var title: String {
        switch snapshot.status {
        case .ready, .stale:
            "Review changes"
        case .empty:
            "No fix plan"
        case .unavailable:
            "Fix plan unavailable"
        }
    }

    private var subtitle: String {
        switch snapshot.status {
        case .ready:
            "\(snapshot.itemCount.formatted()) candidate fixes · preview mode"
        case .stale:
            "\(snapshot.itemCount.formatted()) candidate fixes · stale plan"
        case .empty:
            "Run manually to generate a preview plan."
        case .unavailable:
            "The latest preview plan could not be loaded."
        }
    }

    private var emptyTitle: String {
        snapshot.status == .unavailable ? "Plan could not be loaded" : "No proposed changes"
    }

    private var emptyDetail: String {
        snapshot.status == .unavailable
            ? "Check the latest run report for the failure reason."
            : "No reviewable changes are available yet."
    }

    private var noticeSymbol: String {
        switch noticeTone {
        case .success:
            "checkmark.circle"
        case .warning:
            "exclamationmark.triangle"
        case .error:
            "exclamationmark.octagon"
        default:
            "info.circle"
        }
    }

    private var statusLabel: String {
        switch snapshot.status {
        case .empty:
            "Empty"
        case .ready:
            "Ready"
        case .stale:
            "Stale"
        case .unavailable:
            "Unavailable"
        }
    }

    private var statusSymbol: String {
        switch snapshot.status {
        case .ready:
            "checkmark.seal"
        case .stale:
            "clock.badge.exclamationmark"
        case .empty:
            "tray"
        case .unavailable:
            "exclamationmark.triangle"
        }
    }

    private var statusTone: Tone {
        switch snapshot.status {
        case .ready:
            .success
        case .stale:
            .warning
        case .empty:
            .neutral
        case .unavailable:
            .error
        }
    }

    private var canReview: Bool {
        !isReviewBusy &&
            snapshot.status == .ready &&
            snapshot.planID != nil &&
            snapshot.planRevision != nil &&
            snapshot.decisionRevision != nil
    }

    private var canAccept: Bool {
        canReview && onAccept != nil && snapshot.acceptedCount < snapshot.itemCount
    }

    private var canReject: Bool {
        canReview && onReject != nil && snapshot.rejectedCount < snapshot.itemCount
    }

    private var canApplyChanges: Bool {
        canReview && onApply != nil && snapshot.canApply
    }

    private var canToggle: Bool {
        canReview && onToggleItem != nil
    }
}

extension FixPlanVerdict {
    fileprivate var label: String {
        switch self {
        case .accepted:
            "Accepted"
        case .rejected:
            "Rejected"
        }
    }

    fileprivate var tone: Tone {
        switch self {
        case .accepted:
            .success
        case .rejected:
            .warning
        }
    }

    fileprivate var toggleSymbol: String {
        switch self {
        case .accepted:
            "xmark.circle"
        case .rejected:
            "checkmark.circle"
        }
    }

    fileprivate var toggleHelp: String {
        switch self {
        case .accepted:
            "Reject this change"
        case .rejected:
            "Accept this change"
        }
    }
}

#Preview {
    FixPlanView(snapshot: FixPlanSnapshot(
        status: .ready,
        planID: "preview",
        planRevision: 1,
        decisionRevision: 1,
        projectionRevision: 1,
        itemCount: 2,
        acceptedCount: 1,
        rejectedCount: 1,
        genreCount: 1,
        yearCount: 1,
        averageConfidence: 88,
        canApply: true,
        issues: [],
        items: [
            FixPlanItem(
                id: "1",
                track: "Idioteque",
                artist: "Radiohead",
                album: "Kid A",
                type: .year,
                old: nil,
                new: "2000",
                confidence: 0.91,
                source: "MusicBrainz",
                verdict: .accepted
            )
        ]
    ))
}
