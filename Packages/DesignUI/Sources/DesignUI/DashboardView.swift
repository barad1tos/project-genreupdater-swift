import SwiftUI

struct DashboardView: View {
    @Bindable var model: AppModel

    private let cols = [GridItem(.adaptive(minimum: 290), spacing: 14)]
    private let metricCols = [GridItem(.adaptive(minimum: 170), spacing: 14)]

    var body: some View {
        let s = model.snapshot
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header(s)

                GlassCard(padding: 22, glow: true) {
                    LibraryHealthGauge(snap: s) { model.route = .update }
                        .frame(maxWidth: 1120)
                        .frame(maxWidth: .infinity)
                }

                LazyVGrid(columns: metricCols, spacing: 14) {
                    ForEach(model.data.metrics) { m in
                        MetricCardView(m: m) { model.route = .update }
                    }
                }

                LazyVGrid(columns: cols, alignment: .leading, spacing: 14) {
                    stagedCard(s)
                    needsCard
                    lastRunCard(s)
                }
            }
            .padding(24)
            .frame(maxWidth: 1180, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .background(Ayu.window)
    }

    private func header(_ s: HealthSnapshot) -> some View {
        HStack(alignment: .lastTextBaseline) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Library Health").font(.system(size: 27, weight: .heavy))
                Text("\(Int((s.health*100).rounded()))% healthy · \(s.ready) updates staged · \(model.dryRun ? "dry-run preview" : "ready to write")")
                    .font(.system(size: 14)).foregroundStyle(Ayu.fg2)
            }
            Spacer()
            BorderedButton(title: "Scan now", symbol: "arrow.clockwise") {}
        }
    }

    private func stagedCard(_ s: HealthSnapshot) -> some View {
        SectionCard(symbol: "checklist", tone: .accent, title: "What’s staged",
                    subtitle: "Dry-run preview of the next write.") {
            VStack(spacing: 0) {
                ForEach(Array(model.data.changes.prefix(4))) { c in
                    HStack(spacing: 9) {
                        Image(systemName: c.type.symbol).foregroundStyle(c.type.tone.color).font(.system(size: 14))
                        Text(c.track).font(.system(size: 12.5)).foregroundStyle(Ayu.fg).lineLimit(1)
                        Spacer(minLength: 8)
                        DiffRow(old: c.old, new: c.new).font(.system(size: 11.5))
                    }
                    .padding(.vertical, 9)
                    Divider().overlay(Ayu.glassBorder)
                }
                Button { model.route = .update } label: {
                    HStack(spacing: 5) { Text("Review all \(s.ready)"); Image(systemName: "chevron.right").font(.system(size: 11)) }
                        .font(.system(size: 12.5, weight: .semibold)).foregroundStyle(Ayu.accent)
                }
                .buttonStyle(.plain).padding(.top, 8).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var needsCard: some View {
        SectionCard(symbol: "exclamationmark.triangle", tone: .warning, title: "Needs attention",
                    subtitle: "Every gap and review queue, in one place.") {
            VStack(spacing: 0) {
                ForEach(model.data.issues) { it in
                    Button { if let r = it.route { model.route = r } } label: {
                        HStack(spacing: 11) {
                            Image(systemName: it.symbol).foregroundStyle(it.tone.color).font(.system(size: 16))
                            Text(it.label).font(.system(size: 13.5)).foregroundStyle(Ayu.fg)
                            Spacer()
                            if let d = it.trendDown {
                                HStack(spacing: 3) { Image(systemName: "arrow.down.right"); Text(d) }
                                    .font(.system(size: 11, weight: .semibold)).foregroundStyle(Ayu.success)
                            }
                            HStack(spacing: 3) {
                                Text(it.count).font(.system(size: 13.5, weight: .bold).monospacedDigit()).foregroundStyle(it.tone.color)
                                if let u = it.unit { Text(u).font(.system(size: 11)).foregroundStyle(Ayu.fg2) }
                            }
                            if it.route != nil { Image(systemName: "chevron.right").font(.system(size: 12)).foregroundStyle(Ayu.fgMuted) }
                        }
                        .padding(.vertical, 11)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(it.route == nil)
                    if it.id != model.data.issues.last?.id { Divider().overlay(Ayu.glassBorder) }
                }
            }
        }
    }

    private func lastRunCard(_ s: HealthSnapshot) -> some View {
        SectionCard(symbol: "clock.arrow.circlepath", tone: .purple, title: "Last run",
                    subtitle: "Most recent run · \(s.lastScan)") {
            VStack(spacing: 0) {
                ForEach(Array(model.data.activity.enumerated()), id: \.offset) { i, a in
                    HStack(alignment: .top, spacing: 11) {
                        Circle().fill(Ayu.fgMuted).frame(width: 7, height: 7).padding(.top, 5)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(a.title).font(.system(size: 13, weight: .semibold)).foregroundStyle(Ayu.fg)
                            Text(a.detail).font(.system(size: 12)).foregroundStyle(Ayu.fg2)
                        }
                        Spacer()
                    }
                    .padding(.vertical, 9)
                    if i < model.data.activity.count - 1 { Divider().overlay(Ayu.glassBorder) }
                }
            }
        }
    }
}

struct MetricCardView: View {
    let m: MetricTile
    let action: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Image(systemName: m.symbol).foregroundStyle(m.tone.color).font(.system(size: 19))
                    Spacer()
                    if let up = m.trendUp, let d = m.delta {
                        HStack(spacing: 3) {
                            Image(systemName: up ? "arrow.up.right" : "arrow.down.right")
                            Text(d)
                        }
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(up ? Ayu.success : Ayu.info)
                    }
                }
                Text(m.value).font(.rounded(25, .bold)).foregroundStyle(Ayu.fg)
                Text(m.label).font(.system(size: 12)).foregroundStyle(Ayu.fg2)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Ayu.card, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(hover ? Ayu.accent : Ayu.borderL))
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}
