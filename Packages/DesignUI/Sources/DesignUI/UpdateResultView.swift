import SwiftUI

enum UpdateResultSelection {
    static func resolve(currentID: String?, albums: [UpdateResultAlbum]) -> String? {
        guard let firstAlbumID = albums.first?.id else { return nil }
        guard let currentID, albums.contains(where: { $0.id == currentID }) else {
            return firstAlbumID
        }
        return currentID
    }
}

/// Presents preview decisions and verified write outcomes through one album-centered hierarchy.
///
/// The view owns only album selection. All workflow actions remain with the caller and are exposed
/// through optional callbacks, so rendering a result never grants write authority by itself.
public struct UpdateResultView: View {
    @State private var selectedAlbumID: String?

    public let snapshot: UpdateResultSnapshot
    public let onPrimaryAction: (() -> Void)?
    public let onSecondaryAction: (() -> Void)?
    public let onToggleChange: ((String) -> Void)?
    public let onAcceptAll: (() -> Void)?
    public let onRejectAll: (() -> Void)?

    /// Creates a shared result surface for a preview or a verified write result.
    ///
    /// - Parameters:
    ///   - snapshot: Immutable display data describing the result hierarchy and available content.
    ///   - onPrimaryAction: Handles the snapshot's primary action when available.
    ///   - onSecondaryAction: Handles the optional secondary action.
    ///   - onToggleChange: Toggles the preview verdict for the supplied change identifier.
    ///   - onAcceptAll: Accepts all reviewable preview changes.
    ///   - onRejectAll: Rejects all reviewable preview changes.
    public init(
        snapshot: UpdateResultSnapshot,
        onPrimaryAction: (() -> Void)? = nil,
        onSecondaryAction: (() -> Void)? = nil,
        onToggleChange: ((String) -> Void)? = nil,
        onAcceptAll: (() -> Void)? = nil,
        onRejectAll: (() -> Void)? = nil
    ) {
        self.snapshot = snapshot
        self.onPrimaryAction = onPrimaryAction
        self.onSecondaryAction = onSecondaryAction
        self.onToggleChange = onToggleChange
        self.onAcceptAll = onAcceptAll
        self.onRejectAll = onRejectAll
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ResultStatusStrip(snapshot: snapshot)
            ResultNotices(notices: snapshot.notices, contentAccess: snapshot.contentAccess)

            HSplitView {
                ResultAlbumRail(
                    albums: snapshot.albums,
                    selectedAlbumID: resolvedAlbumID,
                    onSelect: { selectedAlbumID = $0 }
                )
                .frame(idealWidth: 240, maxHeight: .infinity)

                ResultDetailPane(
                    mode: snapshot.mode,
                    album: selectedAlbum,
                    canReview: snapshot.canReview,
                    onToggleChange: onToggleChange
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            ResultActionBar(
                snapshot: snapshot,
                onPrimaryAction: onPrimaryAction,
                onSecondaryAction: onSecondaryAction,
                onAcceptAll: onAcceptAll,
                onRejectAll: onRejectAll
            )
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Ayu.window)
        .navigationTitle("Update")
        .onAppear(perform: reconcileSelection)
        .onChange(of: snapshot.albums) { _, _ in
            reconcileSelection()
        }
    }

    private var resolvedAlbumID: String? {
        UpdateResultSelection.resolve(currentID: selectedAlbumID, albums: snapshot.albums)
    }

    private var selectedAlbum: UpdateResultAlbum? {
        guard let resolvedAlbumID else { return nil }
        return snapshot.albums.first { $0.id == resolvedAlbumID }
    }

    private func reconcileSelection() {
        selectedAlbumID = UpdateResultSelection.resolve(currentID: selectedAlbumID, albums: snapshot.albums)
    }
}

private struct ResultStatusStrip: View {
    let snapshot: UpdateResultSnapshot

    var body: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top, spacing: 14) {
                    Image(systemName: statusSymbol)
                        .font(.system(size: 24, weight: .semibold))
                        .foregroundStyle(statusTone.color)

                    VStack(alignment: .leading, spacing: 7) {
                        HStack(spacing: 8) {
                            Text(snapshot.title)
                                .font(.system(size: 24, weight: .heavy))
                                .foregroundStyle(Ayu.fg)
                            TagPill(text: modeLabel, tone: .accent)
                            TagPill(text: statusLabel, tone: statusTone, dot: true)
                        }

                        Text(snapshot.subtitle)
                            .font(.system(size: 13))
                            .foregroundStyle(Ayu.fg2)
                        Label(snapshot.scope, systemImage: "scope")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Ayu.fgMuted)
                    }

                    Spacer(minLength: 0)
                }

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 24) {
                        ForEach(snapshot.metrics) { metric in
                            ResultMetric(metric: metric)
                        }
                    }
                }
            }
        }
    }

    private var modeLabel: String {
        switch snapshot.mode {
        case .preview: "Preview"
        case .write: "Write result"
        }
    }

    private var statusLabel: String {
        switch snapshot.status {
        case .empty: "No changes"
        case .ready: "Ready"
        case .stale: "Needs refresh"
        case .unavailable: "Unavailable"
        case .completed: "Completed"
        case .completedWithFailures: "Completed with failures"
        }
    }

    private var statusTone: Tone {
        switch snapshot.status {
        case .empty: .neutral
        case .ready: .accent
        case .stale: .warning
        case .unavailable: .error
        case .completed: .success
        case .completedWithFailures: .warning
        }
    }

    private var statusSymbol: String {
        switch snapshot.status {
        case .empty: "tray"
        case .ready: "checkmark.circle"
        case .stale: "arrow.clockwise.circle"
        case .unavailable: "exclamationmark.octagon"
        case .completed: "checkmark.seal"
        case .completedWithFailures: "exclamationmark.triangle"
        }
    }
}

private struct ResultMetric: View {
    let metric: UpdateResultMetric

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(metric.value)
                .font(.system(size: 20, weight: .bold).monospacedDigit())
                .foregroundStyle(metric.tone.color)
            Text(metric.label)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(Ayu.fg2)
        }
    }
}

private struct ResultNotices: View {
    let notices: [UpdateResultNotice]
    let contentAccess: ContentAccess

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if case let .locked(message) = contentAccess {
                SectionCard(symbol: "lock.fill", tone: .warning, title: "Access required") {
                    Text(message)
                        .font(.system(size: 12.5))
                        .foregroundStyle(Ayu.fg2)
                }
            }

            ForEach(notices) { notice in
                SectionCard(symbol: noticeSymbol(for: notice.tone), tone: notice.tone, title: notice.title) {
                    Text(notice.message)
                        .font(.system(size: 12.5))
                        .foregroundStyle(Ayu.fg2)
                }
            }
        }
    }

    private func noticeSymbol(for tone: Tone) -> String {
        switch tone {
        case .success: "checkmark.circle"
        case .warning: "exclamationmark.triangle"
        case .error: "xmark.octagon"
        case .accent, .info, .neutral, .purple, .teal: "info.circle"
        }
    }
}

private struct ResultAlbumRail: View {
    let albums: [UpdateResultAlbum]
    let selectedAlbumID: String?
    let onSelect: (String) -> Void

    var body: some View {
        GlassCard(padding: 0) {
            VStack(alignment: .leading, spacing: 0) {
                Text("\(albums.count.formatted()) albums")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(Ayu.fg2)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 13)

                Divider().overlay(Ayu.glassBorder)

                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        ForEach(albums) { album in
                            Button {
                                onSelect(album.id)
                            } label: {
                                HStack(spacing: 10) {
                                    Image(systemName: "rectangle.stack")
                                        .foregroundStyle(album.id == selectedAlbumID ? Ayu.accent : Ayu.fgMuted)
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(album.title)
                                            .font(.system(size: 13, weight: .semibold))
                                            .foregroundStyle(Ayu.fg)
                                            .lineLimit(2)
                                        Text("\(album.tracks.count.formatted()) tracks")
                                            .font(.system(size: 11.5))
                                            .foregroundStyle(Ayu.fg2)
                                    }
                                    Spacer(minLength: 0)
                                }
                                .padding(.horizontal, 12)
                                .padding(.vertical, 10)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(
                                    album.id == selectedAlbumID ? Ayu.selectionFill : Color.clear,
                                    in: RoundedRectangle(cornerRadius: 7, style: .continuous)
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(8)
                }
            }
        }
    }
}

private struct ResultDetailPane: View {
    let mode: UpdateResultMode
    let album: UpdateResultAlbum?
    let canReview: Bool
    let onToggleChange: ((String) -> Void)?

    var body: some View {
        GlassCard(padding: 0) {
            ScrollView {
                if let album {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        HStack(alignment: .firstTextBaseline) {
                            Text(album.title)
                                .font(.system(size: 18, weight: .bold))
                                .foregroundStyle(Ayu.fg)
                            Spacer(minLength: 0)
                            TagPill(text: "\(album.tracks.count.formatted()) tracks", tone: .neutral)
                        }
                        .padding(18)

                        Divider().overlay(Ayu.glassBorder)

                        ForEach(album.tracks) { track in
                            ResultTrackRow(
                                mode: mode,
                                track: track,
                                canReview: canReview,
                                onToggleChange: onToggleChange
                            )
                            if track.id != album.tracks.last?.id {
                                Divider().overlay(Ayu.glassBorder)
                            }
                        }
                    }
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("No album results")
                            .font(.system(size: 16, weight: .bold))
                            .foregroundStyle(Ayu.fg)
                        Text("Result details will appear here when an album is available.")
                            .font(.system(size: 12.5))
                            .foregroundStyle(Ayu.fg2)
                    }
                    .padding(22)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }
}

private struct ResultTrackRow: View {
    let mode: UpdateResultMode
    let track: UpdateResultTrack
    let canReview: Bool
    let onToggleChange: ((String) -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "music.note")
                    .foregroundStyle(trackTone.color)
                    .frame(width: 20)
                VStack(alignment: .leading, spacing: 3) {
                    Text(track.title)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Ayu.fg)
                    Text(track.artist)
                        .font(.system(size: 12))
                        .foregroundStyle(Ayu.fg2)
                }
                Spacer(minLength: 0)
                TagPill(text: trackLabel, tone: trackTone)
            }

            if case let .failed(message) = track.state {
                Text(message)
                    .font(.system(size: 12))
                    .foregroundStyle(Ayu.error)
            }

            VStack(alignment: .leading, spacing: 8) {
                ForEach(track.changes) { change in
                    ResultChangeRow(
                        mode: mode,
                        change: change,
                        canReview: canReview,
                        onToggleChange: onToggleChange
                    )
                }
            }
        }
        .padding(18)
    }

    private var trackLabel: String {
        switch track.state {
        case .ready: "Ready"
        case .applied: "Applied"
        case .noChange: "No change"
        case .skipped: "Skipped"
        case .failed: "Failed"
        }
    }

    private var trackTone: Tone {
        switch track.state {
        case .ready: .accent
        case .applied: .success
        case .noChange: .neutral
        case .skipped: .warning
        case .failed: .error
        }
    }
}

private struct ResultChangeRow: View {
    let mode: UpdateResultMode
    let change: UpdateResultChange
    let canReview: Bool
    let onToggleChange: ((String) -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 10) {
                if mode == .preview {
                    Toggle(isOn: verdictBinding) {
                        Text("Accept \(change.type.rawValue) change")
                    }
                    .toggleStyle(.checkbox)
                    .labelsHidden()
                    .disabled(!canReview || onToggleChange == nil || change.state.verdict == nil)
                }

                Label(change.type.rawValue.capitalized, systemImage: change.type.symbol)
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(change.type.tone.color)

                DiffRow(old: change.oldValue, new: change.newValue)
                Spacer(minLength: 0)

                if mode == .write {
                    TagPill(text: outcomeLabel, tone: outcomeTone)
                }
            }

            if mode == .preview, change.source != nil || change.confidence != nil {
                HStack(spacing: 8) {
                    if let source = change.source {
                        TagPill(text: source, tone: .neutral)
                    }
                    if let confidence = change.confidence {
                        ConfidenceBadge(conf: confidence)
                    }
                }
            }

            if mode == .write, case let .failed(message) = change.state {
                Text(message)
                    .font(.system(size: 12))
                    .foregroundStyle(Ayu.error)
            }
        }
        .padding(12)
        .background(Ayu.controlFill, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
    }

    private var verdictBinding: Binding<Bool> {
        Binding {
            change.state.verdict == .accepted
        } set: { isAccepted in
            guard isAccepted != (change.state.verdict == .accepted) else { return }
            onToggleChange?(change.id)
        }
    }

    private var outcomeLabel: String {
        switch change.state {
        case .proposed: "Proposed"
        case .applied: "Applied"
        case .noChange: "No change"
        case .skipped: "Skipped"
        case .failed: "Failed"
        }
    }

    private var outcomeTone: Tone {
        switch change.state {
        case .proposed: .neutral
        case .applied: .success
        case .noChange: .neutral
        case .skipped: .warning
        case .failed: .error
        }
    }
}

private struct ResultActionBar: View {
    let snapshot: UpdateResultSnapshot
    let onPrimaryAction: (() -> Void)?
    let onSecondaryAction: (() -> Void)?
    let onAcceptAll: (() -> Void)?
    let onRejectAll: (() -> Void)?

    var body: some View {
        GlassCard(padding: 16) {
            HStack(spacing: 8) {
                Text(actionSummary)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(Ayu.fg2)
                Spacer(minLength: 12)

                if snapshot.mode == .preview {
                    BorderedButton(
                        title: "Reject all",
                        symbol: "xmark.circle",
                        enabled: snapshot.canReview,
                        action: onRejectAll
                    )
                    BorderedButton(
                        title: "Accept all",
                        symbol: "checkmark.circle",
                        enabled: snapshot.canReview,
                        action: onAcceptAll
                    )
                }

                if let secondaryActionLabel = snapshot.secondaryActionLabel {
                    BorderedButton(
                        title: secondaryActionLabel,
                        symbol: "arrow.counterclockwise",
                        action: onSecondaryAction
                    )
                }

                PrimaryButton(
                    title: snapshot.primaryActionLabel,
                    symbol: primarySymbol,
                    enabled: isPrimaryEnabled
                ) {
                    onPrimaryAction?()
                }
            }
        }
    }

    private var actionSummary: String {
        switch snapshot.mode {
        case .preview: "Review decisions before applying changes."
        case .write: "These outcomes are verified results from the completed write."
        }
    }

    private var primarySymbol: String {
        switch snapshot.mode {
        case .preview: "checkmark.seal"
        case .write: "arrow.clockwise"
        }
    }

    private var isPrimaryEnabled: Bool {
        guard onPrimaryAction != nil, snapshot.contentAccess.isAvailable else { return false }
        return snapshot.mode == .write || snapshot.canReview
    }
}
