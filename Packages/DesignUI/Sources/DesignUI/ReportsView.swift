import Charts
import SwiftUI

struct ReportsView: View {
    @Bindable var model: AppModel
    var runSelectionAction: ((String?) -> Void)?
    private let cols = [GridItem(.adaptive(minimum: 260), spacing: 14)]

    var body: some View {
        let st = model.data.reportStats
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .lastTextBaseline) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Reports").font(.system(size: 24, weight: .heavy))
                        HStack(spacing: 26) {
                            stat("\(st.processed)", "Changes", .neutral)
                            stat("\(st.genres)", "Genres updated", .purple)
                            stat("\(st.years)", "Years updated", .info)
                        }
                    }
                    Spacer()
                    TagPill(text: "Read-only", tone: .neutral)
                }

                runHistorySection

                if let selectedRunReport = model.data.selectedRunReport {
                    runDetailCard(selectedRunReport)
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

                        if model.data.changeLog.isEmpty {
                            Text("No persisted audit entries yet")
                                .font(.system(size: 13))
                                .foregroundStyle(Ayu.fg2)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 18)
                                .padding(.vertical, 14)
                        } else {
                            ForEach(model.data.changeLog) { change in
                                HStack(spacing: 13) {
                                    Text(change.time)
                                        .font(.system(size: 11).monospacedDigit())
                                        .foregroundStyle(Ayu.fgMuted)
                                        .frame(width: 58, alignment: .leading)
                                    Image(systemName: change.type.symbol)
                                        .foregroundStyle(change.type.tone.color)
                                        .frame(width: 18)
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(change.track)
                                            .font(.system(size: 13))
                                            .foregroundStyle(Ayu.fg)
                                            .lineLimit(1)
                                        Text(change.artist)
                                            .font(.system(size: 11.5))
                                            .foregroundStyle(Ayu.fg2)
                                    }
                                    Spacer()
                                    DiffRow(old: change.old, new: change.new)
                                    if let confidence = change.conf {
                                        ConfidenceBadge(conf: confidence)
                                    }
                                }
                                .padding(.horizontal, 18).padding(.vertical, 11)
                                Divider().overlay(Ayu.glassBorder)
                            }
                        }
                    }
                }

                LazyVGrid(columns: cols, spacing: 14) {
                    chartCard("Genre distribution", "chart.bar", .purple) {
                        Chart(model.data.genreDistribution) { datum in
                            BarMark(x: .value("Count", datum.count), y: .value("Genre", datum.label))
                                .foregroundStyle(Ayu.purple)
                        }
                        .frame(height: 160)
                    }
                    chartCard("Changes over time", "chart.line.uptrend.xyaxis", .accent) {
                        Chart(model.data.updatesOverTime) { datum in
                            AreaMark(x: .value("Week", datum.label), y: .value("Count", datum.count))
                                .foregroundStyle(Ayu.accent.opacity(0.25))
                            LineMark(x: .value("Week", datum.label), y: .value("Count", datum.count))
                                .foregroundStyle(Ayu.accent)
                        }
                        .frame(height: 160)
                    }
                    chartCard("Year distribution", "calendar", .info) {
                        Chart(model.data.yearDistribution) { datum in
                            BarMark(x: .value("Decade", datum.label), y: .value("Count", datum.count))
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

    private var runHistorySection: some View {
        SectionCard(
            symbol: "clock.arrow.2.circlepath",
            tone: .accent,
            title: "Run history",
            subtitle: "Sync runs · newest first"
        ) {
            VStack(spacing: 0) {
                if model.data.runHistory.isEmpty {
                    Text("No runs recorded yet")
                        .font(.system(size: 13))
                        .foregroundStyle(Ayu.fg2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 14)
                } else {
                    ForEach(model.data.runHistory) { run in
                        runRow(run)
                        if run.id != model.data.runHistory.last?.id {
                            Divider().overlay(Ayu.glassBorder)
                        }
                    }
                }

                if model.data.runHistorySkippedCount > 0 {
                    if !model.data.runHistory.isEmpty {
                        Divider().overlay(Ayu.glassBorder)
                    }
                    skippedRunLabel(model.data.runHistorySkippedCount)
                }
            }
        }
    }

    private func runRow(_ run: RunReportRow) -> some View {
        let isSelected = model.data.selectedRunReport?.runID == run.id
        let metadataLabel = [run.modeLabel, run.scopeLabel]
            .compactMap(\.self)
            .joined(separator: " · ")
        return Button {
            runSelectionAction?(run.id)
        } label: {
            HStack(spacing: 13) {
                Text(run.startedLabel)
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(Ayu.fgMuted)
                    .frame(width: 70, alignment: .leading)
                TagPill(text: run.stateLabel, tone: run.tone)
                VStack(alignment: .leading, spacing: 1) {
                    Text(run.triggerLabel)
                        .font(.system(size: 13))
                        .foregroundStyle(Ayu.fg)
                    if !metadataLabel.isEmpty {
                        Text(metadataLabel)
                            .font(.system(size: 11.5))
                            .foregroundStyle(Ayu.fgMuted)
                            .lineLimit(1)
                    }
                    if let failureSummary = run.failureSummary {
                        Text(failureSummary)
                            .font(.system(size: 11.5))
                            .foregroundStyle(Ayu.error)
                    }
                }
                Spacer()
                if let changeCountLabel = run.changeCountLabel {
                    Text(changeCountLabel)
                        .font(.system(size: 12.5))
                        .foregroundStyle(Ayu.fg2)
                }
                if let durationLabel = run.durationLabel {
                    Text(durationLabel)
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(Ayu.fgMuted)
                }
            }
            .padding(.vertical, 11)
            .background(isSelected ? Ayu.controlFill : Color.clear)
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func runDetailCard(_ detail: RunReportDetailSnapshot) -> some View {
        SectionCard(symbol: "doc.text.magnifyingglass", tone: detail.tone, title: "Run report") {
            VStack(alignment: .leading, spacing: 14) {
                runDetailHeader(detail)
                if let unavailableReason = detail.unavailableReason {
                    Text(unavailableReason)
                        .font(.system(size: 13))
                        .foregroundStyle(Ayu.fg2)
                } else {
                    runDetailBody(detail)
                }
            }
        }
    }

    private func runDetailHeader(_ detail: RunReportDetailSnapshot) -> some View {
        HStack(spacing: 10) {
            if detail.unavailableReason == nil {
                TagPill(text: detail.stateLabel, tone: detail.tone)
            }
            Text(detail.triggerLabel)
                .font(.system(size: 13))
                .foregroundStyle(Ayu.fg)
            Text(detail.startedLabel)
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(Ayu.fgMuted)
            if let durationLabel = detail.durationLabel {
                Text(durationLabel)
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(Ayu.fgMuted)
            }
            Spacer()
            Button {
                runSelectionAction?(nil)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 22, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(Ayu.fgMuted)
            .accessibilityLabel("Close run report")
        }
    }

    private func runDetailBody(_ detail: RunReportDetailSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(detail.scopeLines, id: \.self) { line in
                Text(line)
                    .font(.system(size: 13))
                    .foregroundStyle(Ayu.fg2)
            }
            ForEach(detail.transitions) { transition in
                HStack(spacing: 10) {
                    Text(transition.timeLabel)
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(Ayu.fgMuted)
                        .frame(width: 60, alignment: .leading)
                    Text(transition.stageLabel)
                        .font(.system(size: 13))
                        .foregroundStyle(Ayu.fg)
                }
            }
            ForEach(detail.summaryItems) { item in
                HStack {
                    Text(item.label)
                        .font(.system(size: 13))
                        .foregroundStyle(Ayu.fg2)
                    Spacer()
                    Text(item.value)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Ayu.fg)
                }
            }
            if let detailMessage = detail.detailMessage {
                Text(detailMessage)
                    .font(.system(size: 13))
                    .foregroundStyle(detail.tone == .success || detail.tone == .neutral ? Ayu.info : Ayu.error)
            }
        }
    }

    private func skippedRunLabel(_ count: Int) -> some View {
        Text(
            count == 1
                ? "1 corrupted run record skipped"
                : "\(count.formatted()) corrupted run records skipped"
        )
        .font(.system(size: 11.5))
        .foregroundStyle(Ayu.fg2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 10)
    }

    private func stat(_ value: String, _ label: String, _ tone: Tone) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.rounded(26, .heavy)).foregroundStyle(tone == .neutral ? Ayu.fg : tone.color)
            Text(label).font(.system(size: 11.5, weight: .semibold)).foregroundStyle(Ayu.fg2)
        }
    }

    private func chartCard(
        _ title: String,
        _ symbol: String,
        _ tone: Tone,
        @ViewBuilder _ chart: () -> some View
    ) -> some View {
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
