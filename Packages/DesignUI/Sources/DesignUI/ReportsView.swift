import SwiftUI
import Charts

struct ReportsView: View {
    @Bindable var model: AppModel
    private let cols = [GridItem(.adaptive(minimum: 260), spacing: 14)]

    var body: some View {
        let st = model.data.reportStats
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .lastTextBaseline) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Reports").font(.system(size: 24, weight: .heavy))
                        HStack(spacing: 26) {
                            stat("\(st.processed)", "Processed", .neutral)
                            stat("\(st.genres)", "Genres updated", .purple)
                            stat("\(st.years)", "Years updated", .info)
                        }
                    }
                    Spacer()
                    BorderedButton(title: "Import revert CSV", symbol: "arrow.uturn.backward") {}
                }

                GlassCard(padding: 0) {
                    VStack(spacing: 0) {
                        HStack(spacing: 9) {
                            Image(systemName: "clock.arrow.circlepath").foregroundStyle(Ayu.purple)
                            Text("Change log").font(.system(size: 14.5, weight: .bold))
                            Spacer()
                        }
                        .padding(.horizontal, 18).padding(.vertical, 13)
                        Divider().overlay(Ayu.glassBorder)
                        ForEach(model.data.changeLog) { c in
                            HStack(spacing: 13) {
                                Text(c.time).font(.system(size: 11).monospacedDigit()).foregroundStyle(Ayu.fgMuted).frame(width: 58, alignment: .leading)
                                Image(systemName: c.type.symbol).foregroundStyle(c.type.tone.color).frame(width: 18)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(c.track).font(.system(size: 13)).foregroundStyle(Ayu.fg).lineLimit(1)
                                    Text(c.artist).font(.system(size: 11.5)).foregroundStyle(Ayu.fg2)
                                }
                                Spacer()
                                DiffRow(old: c.old, new: c.new)
                                ConfidenceBadge(conf: c.conf)
                                Button { } label: { Image(systemName: "arrow.uturn.backward") }
                                    .buttonStyle(.plain).foregroundStyle(Ayu.fg2)
                            }
                            .padding(.horizontal, 18).padding(.vertical, 11)
                            Divider().overlay(Ayu.glassBorder)
                        }
                    }
                }

                LazyVGrid(columns: cols, spacing: 14) {
                    chartCard("Genre distribution", "chart.bar", .purple) {
                        Chart(model.data.genreDistribution) { d in
                            BarMark(x: .value("Count", d.count), y: .value("Genre", d.label))
                                .foregroundStyle(Ayu.purple)
                        }
                        .frame(height: 160)
                    }
                    chartCard("Changes over time", "chart.line.uptrend.xyaxis", .accent) {
                        Chart(model.data.updatesOverTime) { d in
                            AreaMark(x: .value("Week", d.label), y: .value("Count", d.count))
                                .foregroundStyle(Ayu.accent.opacity(0.25))
                            LineMark(x: .value("Week", d.label), y: .value("Count", d.count))
                                .foregroundStyle(Ayu.accent)
                        }
                        .frame(height: 160)
                    }
                    chartCard("Year distribution", "calendar", .info) {
                        Chart(model.data.yearDistribution) { d in
                            BarMark(x: .value("Decade", d.label), y: .value("Count", d.count))
                                .foregroundStyle(Ayu.info)
                        }
                        .frame(height: 160)
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: 1320, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .background(Ayu.window)
        .navigationTitle("Reports")
    }

    private func stat(_ v: String, _ l: String, _ tone: Tone) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(v).font(.rounded(26, .heavy)).foregroundStyle(tone == .neutral ? Ayu.fg : tone.color)
            Text(l).font(.system(size: 11.5, weight: .semibold)).foregroundStyle(Ayu.fg2)
        }
    }

    private func chartCard<C: View>(_ title: String, _ symbol: String, _ tone: Tone, @ViewBuilder _ chart: () -> C) -> some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 9) {
                    Image(systemName: symbol).foregroundStyle(tone.color)
                    Text(title).font(.system(size: 14.5, weight: .bold))
                }
                chart()
            }
        }
    }
}
