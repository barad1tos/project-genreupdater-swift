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

    var body: some View {
        let s = model.snapshot
        List(selection: $model.route) {
            // library identity
            Section {
                HStack(spacing: 10) {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(LinearGradient(colors: [Ayu.info, Ayu.purple], startPoint: .topLeading, endPoint: .bottomTrailing))
                        .frame(width: 30, height: 30)
                        .overlay(Image(systemName: "music.note.list").font(.system(size: 15, weight: .semibold)).foregroundStyle(Ayu.onAccent))
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
                navRow(.browse, "Browse", "music.note.list", badge: "42.3K", badgeTone: .neutral)
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

            Section("Automation") {
                statusRow("Watcher", value: "On")
                HStack { Text("Mode"); Spacer(); TagPill(text: "Preview", tone: .warning, dot: true) }
                    .font(.system(size: 12)).foregroundStyle(Ayu.fg2).listRowSeparator(.hidden)
                HStack { Text("Auto-fix"); Spacer(); TagPill(text: "Off", tone: .neutral, dot: true) }
                    .font(.system(size: 12)).foregroundStyle(Ayu.fg2).listRowSeparator(.hidden)
            }

            navRow(.settings, "Settings", "gearshape")
        }
        .listStyle(.sidebar)
        .tint(Ayu.accent)
    }

    private func navRow(_ route: Route, _ title: String, _ symbol: String,
                        badge: String? = nil, badgeTone: Tone = .neutral) -> some View {
        HStack {
            Label(title, systemImage: symbol)
            Spacer()
            if let badge { TagPill(text: badge, tone: badgeTone) }
        }
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
}
