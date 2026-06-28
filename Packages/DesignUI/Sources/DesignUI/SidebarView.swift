import SwiftUI

/// Native macOS vibrancy sidebar (NavigationSplitView provides the glass + traffic
/// lights). Library identity header, nav, smart Views, and a run-status footer.
struct SidebarView: View {
    @Bindable var model: AppModel

    private let smartViews: [(String, String, BrowseFilter)] = [
        ("Missing genre", "tag.slash", .missingGenre),
        ("Missing year", "calendar.badge.exclamationmark", .missingYear),
        ("Low health", "exclamationmark.triangle", .conflicts),
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
        let s = model.snapshot
        List(selection: routeSelection) {
            // library identity
            Section {
                HStack(spacing: 10) {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Ayu.controlFillStrong)
                        .frame(width: 30, height: 30)
                        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Ayu.glassBorderStrong))
                        .overlay(Image(systemName: "music.note.list").font(.system(size: 15, weight: .semibold)).foregroundStyle(Ayu.info))
                    VStack(alignment: .leading, spacing: 1) {
                        Text(s.library).font(.system(size: 13, weight: .bold)).foregroundStyle(Ayu.fg)
                        Text(s.source).font(.system(size: 11)).foregroundStyle(Ayu.fg2).lineLimit(1)
                    }
                }
                .listRowSeparator(.hidden)
                HStack(spacing: 6) {
                    TagPill(text: "42.3K tracks", tone: .info)
                    TagPill(text: "Synced 8m", tone: .neutral)
                }
                .listRowSeparator(.hidden)
            }

            Section("Library") {
                navRow(.activity, "Activity", "waveform.path.ecg.rectangle",
                       badge: model.pipelineActivity.safetyMode.title, badgeTone: .warning)
                navRow(.browse, "Browse", "music.note.list")
                navRow(.reports, "Reports", "chart.bar")
            }
            Section("Intervention") {
                navRow(.update, "Fix plan", "checklist",
                       badge: "\(model.pipelineActivity.deltaCount)", badgeTone: .accent)
            }

            // smart filtered jumps
            Section("Views") {
                ForEach(smartViews, id: \.0) { v in
                    Button { model.openBrowse(filter: v.2) } label: {
                        Label(v.0, systemImage: v.1)
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

    private func navRow(_ route: Route, _ title: String, _ symbol: String,
                        badge: String? = nil, badgeTone: Tone = .neutral) -> some View {
        HStack {
            Label(title, systemImage: symbol)
            Spacer()
            if let badge { TagPill(text: badge, tone: badgeTone) }
        }
        .font(.system(size: 13, weight: .medium))
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
                automationRow("Watcher", value: "On")
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

    private func automationRow(_ label: String, value: String) -> some View {
        HStack {
            Text(label)
                .foregroundStyle(Ayu.fg2)
            Spacer()
            Text(value)
                .fontWeight(.semibold)
                .foregroundStyle(Ayu.fg)
        }
        .font(.system(size: 12))
    }

    private func automationRow<Pill: View>(_ label: String, pill: Pill) -> some View {
        HStack {
            Text(label)
                .foregroundStyle(Ayu.fg2)
            Spacer()
            pill
        }
        .font(.system(size: 12))
    }
}
