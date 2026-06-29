import Foundation
import SwiftUI

/// Native macOS vibrancy sidebar (NavigationSplitView provides the glass + traffic
/// lights). Library identity header, nav, smart Views, and a run-status footer.
struct SidebarView: View {
    @Bindable var model: AppModel

    private let smartViews = [
        SmartSidebarView(title: "Missing genre", symbol: "tag.slash", filter: .missingGenre),
        SmartSidebarView(title: "Missing year", symbol: "calendar.badge.exclamationmark", filter: .missingYear),
        SmartSidebarView(title: "Low health", symbol: "exclamationmark.triangle", filter: .conflicts)
    ]

    private var routeSelection: Binding<Route?> {
        Binding {
            model.route
        } set: { route in
            guard let route else { return }
            model.navigate(to: route)
        }
    }

    var body: some View {
        let snapshot = model.snapshot
        List(selection: routeSelection) {
            // library identity
            Section {
                HStack(spacing: 10) {
                    libraryIcon
                    VStack(alignment: .leading, spacing: 1) {
                        Text(snapshot.library).font(.system(size: 13, weight: .bold)).foregroundStyle(Ayu.fg)
                        Text(snapshot.source).font(.system(size: 11)).foregroundStyle(Ayu.fg2).lineLimit(1)
                    }
                }
                .listRowSeparator(.hidden)
                libraryCounterPills(snapshot)
                    .listRowSeparator(.hidden)
            }

            Section("Library") {
                navRow(.activity, "Activity", "waveform.path.ecg.rectangle")
                navRow(.browse, "Browse", "music.note.list")
                navRow(.reports, "Reports", "chart.bar")
            }
            Section("Intervention") {
                navRow(
                    .update,
                    "Fix plan",
                    "checklist",
                    badge: "\(model.pipelineActivity.deltaCount)",
                    badgeTone: .accent
                )
            }

            // smart filtered jumps
            Section("Views") {
                ForEach(smartViews) { view in
                    Button { model.openBrowse(filter: view.filter) } label: {
                        Label(view.title, systemImage: view.symbol)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .listStyle(.sidebar)
        .tint(Ayu.selectionFill)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            footer
        }
    }

    private var libraryIcon: some View {
        RoundedRectangle(cornerRadius: 8)
            .fill(Ayu.controlFillStrong)
            .frame(width: 30, height: 30)
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Ayu.glassBorderStrong))
            .overlay {
                Image(systemName: "music.note.list")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Ayu.info)
            }
    }

    private func navRow(
        _ route: Route,
        _ title: String,
        _ symbol: String,
        badge: String? = nil,
        badgeTone: Tone = .neutral
    ) -> some View {
        SidebarNavigationRow(
            title: title,
            symbol: symbol,
            badge: badge,
            badgeTone: badgeTone
        )
        .tag(route)
    }

    private func statusRow(_ label: String, value: String) -> some View {
        HStack {
            Text(label).foregroundStyle(Ayu.fg2)
            Spacer()
            Text(value).fontWeight(.semibold).foregroundStyle(Ayu.fg)
        }
        .font(.system(size: 12))
        .listRowSeparator(.hidden)
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 12) {
            Divider().overlay(Ayu.glassBorder)

            VStack(alignment: .leading, spacing: 10) {
                Text("Automation")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Ayu.fgMuted)
                automationRow(
                    "Status",
                    pill: TagPill(text: model.pipelineActivity.automationState.summaryValue, tone: .neutral)
                )
                automationRow("Mode", pill: TagPill(text: "Preview", tone: .warning, dot: true))
                automationRow("Auto-fix", pill: TagPill(text: "Off", tone: .neutral, dot: true))
            }

            Button { model.navigate(to: .settings) } label: {
                HStack(spacing: 8) {
                    Label("Settings", systemImage: "gearshape")
                    Spacer()
                }
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Ayu.fg)
                .padding(.horizontal, 9)
                .padding(.vertical, 7)
                .background {
                    if model.route == .settings {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Ayu.selectionFill)
                    }
                }
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    private func abbreviatedTrackCount(_ count: Int) -> String {
        if count >= 1_000_000 {
            let millions = Double(count) / 1_000_000
            return "\(millions.formatted(.number.precision(.fractionLength(1))))M"
        }

        if count >= 1000 {
            let thousands = Double(count) / 1000
            return "\(thousands.formatted(.number.precision(.fractionLength(1))))K"
        }

        return count.formatted()
    }

    private func libraryCounterPills(_ snapshot: HealthSnapshot) -> some View {
        WrappingPillRow {
            TagPill(text: "\(abbreviatedTrackCount(snapshot.totalTracks)) tracks", tone: .info)
            if let totalAlbums = snapshot.totalAlbums {
                TagPill(text: "\(abbreviatedTrackCount(totalAlbums)) albums", tone: .purple)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func automationRow(_ label: String, pill: some View) -> some View {
        HStack {
            Text(label)
                .foregroundStyle(Ayu.fg2)
            Spacer()
            pill
        }
        .font(.system(size: 12))
    }
}

private struct SmartSidebarView: Identifiable {
    let title: String
    let symbol: String
    let filter: BrowseFilter

    var id: BrowseFilter {
        filter
    }
}

private struct SidebarNavigationRow: View {
    let title: String
    let symbol: String
    let badge: String?
    let badgeTone: Tone

    var body: some View {
        HStack {
            Label(title, systemImage: symbol)
            Spacer()
            if let badge {
                SidebarNavigationBadge(text: badge, tone: badgeTone)
            }
        }
        .font(.system(size: 13, weight: .medium))
    }
}

private struct SidebarNavigationBadge: View {
    let text: String
    let tone: Tone

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .bold))
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .foregroundStyle(foregroundColor)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(backgroundColor, in: Capsule())
            .overlay(Capsule().strokeBorder(borderColor))
            .fixedSize(horizontal: true, vertical: false)
    }

    private var foregroundColor: Color {
        switch tone {
        case .accent, .warning:
            Ayu.onAccent
        default:
            tone.color
        }
    }

    private var backgroundColor: Color {
        switch tone {
        case .accent, .warning:
            tone.color.opacity(0.88)
        default:
            tone.pillFill
        }
    }

    private var borderColor: Color {
        switch tone {
        case .accent, .warning:
            tone.color.opacity(0.95)
        default:
            tone.pillBorder
        }
    }
}

private struct WrappingPillRow: Layout {
    var horizontalSpacing: CGFloat = 6
    var verticalSpacing: CGFloat = 5

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache _: inout ()
    ) -> CGSize {
        let proposedWidth = proposal.width ?? idealWidth(for: subviews)
        let layout = makeLayout(in: proposedWidth, subviews: subviews)
        return CGSize(width: proposal.width ?? layout.width, height: layout.height)
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal _: ProposedViewSize,
        subviews: Subviews,
        cache _: inout ()
    ) {
        var cursor = CGPoint(x: bounds.minX, y: bounds.minY)
        var lineHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            let shouldWrap = cursor.x > bounds.minX && cursor.x + horizontalSpacing + size.width > bounds.maxX

            if shouldWrap {
                cursor.x = bounds.minX
                cursor.y += lineHeight + verticalSpacing
                lineHeight = 0
            } else if cursor.x > bounds.minX {
                cursor.x += horizontalSpacing
            }

            subview.place(at: cursor, proposal: ProposedViewSize(size))
            cursor.x += size.width
            lineHeight = max(lineHeight, size.height)
        }
    }

    private func idealWidth(for subviews: Subviews) -> CGFloat {
        subviews.reduce(CGFloat.zero) { width, subview in
            let spacing = width == 0 ? 0 : horizontalSpacing
            return width + spacing + subview.sizeThatFits(.unspecified).width
        }
    }

    private func makeLayout(in proposedWidth: CGFloat, subviews: Subviews) -> CGSize {
        var currentLineWidth: CGFloat = 0
        var currentLineHeight: CGFloat = 0
        var totalWidth: CGFloat = 0
        var totalHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            let spacing = currentLineWidth == 0 ? 0 : horizontalSpacing
            let shouldWrap = currentLineWidth > 0 && currentLineWidth + spacing + size.width > proposedWidth

            if shouldWrap {
                totalWidth = max(totalWidth, currentLineWidth)
                totalHeight += currentLineHeight + verticalSpacing
                currentLineWidth = size.width
                currentLineHeight = size.height
            } else {
                currentLineWidth += spacing + size.width
                currentLineHeight = max(currentLineHeight, size.height)
            }
        }

        totalWidth = max(totalWidth, currentLineWidth)
        totalHeight += currentLineHeight
        return CGSize(width: totalWidth, height: totalHeight)
    }
}
