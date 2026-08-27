import SwiftUI

public struct AnalyticsView: View {
    public let snapshot: DesignAnalyticsSnapshot
    private let selectWindow: (DesignAnalyticsWindow) -> Void
    private let retry: () -> Void
    private let openSettings: () -> Void
    private let columns = [GridItem(.adaptive(minimum: 150), spacing: 12)]

    public init(
        snapshot: DesignAnalyticsSnapshot,
        selectWindow: @escaping (DesignAnalyticsWindow) -> Void,
        retry: @escaping () -> Void,
        openSettings: @escaping () -> Void
    ) {
        self.snapshot = snapshot
        self.selectWindow = selectWindow
        self.retry = retry
        self.openSettings = openSettings
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                header
                content
            }
            .padding(24)
            .frame(maxWidth: 1320, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .background(Ayu.window)
        .navigationTitle("Analytics")
    }

    private var header: some View {
        HStack(alignment: .lastTextBaseline) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Analytics")
                    .font(.system(size: 24, weight: .heavy))
                Text("Local performance measurements from this Mac")
                    .font(.system(size: 12.5))
                    .foregroundStyle(Ayu.fg2)
            }
            Spacer()
            Picker("Window", selection: windowBinding) {
                ForEach(snapshot.availableWindows) { window in
                    Text(window.label).tag(window)
                }
            }
            .pickerStyle(.segmented)
            .fixedSize()
        }
    }

    @ViewBuilder private var content: some View {
        switch snapshot.state {
        case .disabled:
            stateCard(
                symbol: "chart.bar.xaxis",
                title: "Analytics recording is off",
                message: "Enable local analytics in Advanced Settings to start collecting performance measurements.",
                actionTitle: "Open Settings",
                action: openSettings
            )
        case .empty:
            stateCard(
                symbol: "chart.bar",
                title: "No measurements yet",
                message: "Run a library scan or preview to populate this report."
            )
        case .unavailable:
            stateCard(
                symbol: "exclamationmark.triangle",
                title: "Analytics are temporarily unavailable",
                message: "The local analytics store could not be read.",
                actionTitle: "Try Again",
                action: retry
            )
        case .populated:
            summaryGrid
            durationCard
            operationsCard
            recentEventsCard
        }
    }

    private var windowBinding: Binding<DesignAnalyticsWindow> {
        Binding(
            get: { snapshot.selectedWindow },
            set: { window in selectWindow(window) }
        )
    }

    private var summaryGrid: some View {
        LazyVGrid(columns: columns, spacing: 12) {
            summaryCard("Calls", snapshot.summary.calls.formatted(), .accent)
            summaryCard("Succeeded", snapshot.summary.succeeded.formatted(), .success)
            summaryCard("Degraded", snapshot.summary.degraded.formatted(), .warning)
            summaryCard("Failed", snapshot.summary.failed.formatted(), .error)
            summaryCard("Cancelled", snapshot.summary.cancelled.formatted(), .warning)
            summaryCard(
                "Success rate",
                snapshot.summary.successRate.formatted(.percent.precision(.fractionLength(0))),
                .success
            )
            summaryCard("Total time", snapshot.summary.totalDuration, .purple)
            summaryCard("Average", snapshot.summary.averageDuration, .info)
            summaryCard("P95", snapshot.summary.p95Duration, .warning)
        }
    }

    private var durationCard: some View {
        SectionCard(symbol: "chart.bar.fill", tone: .purple, title: "Duration distribution") {
            VStack(spacing: 10) {
                ForEach(snapshot.distribution) { bucket in
                    HStack {
                        Circle().fill(bucket.tone.color).frame(width: 7, height: 7)
                        Text(bucket.label).foregroundStyle(Ayu.fg2)
                        Spacer()
                        Text(bucket.count.formatted()).fontWeight(.semibold).foregroundStyle(Ayu.fg)
                    }
                    .font(.system(size: 12.5))
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }

    private var operationsCard: some View {
        SectionCard(symbol: "gauge.with.dots.needle.50percent", tone: .accent, title: "Operations") {
            Grid(horizontalSpacing: 12, verticalSpacing: 0) {
                operationHeader
                ForEach(snapshot.operations) { operation in
                    Divider()
                        .overlay(Ayu.glassBorder)
                        .gridCellColumns(6)
                    operationRow(operation)
                }
            }
        }
    }

    private var operationHeader: some View {
        operationColumns(OperationCells(
            name: "Operation",
            calls: "Calls",
            success: "Success",
            total: "Total",
            average: "Average",
            p95: "P95"
        ))
        .font(.system(size: 11, weight: .semibold))
        .foregroundStyle(Ayu.fgMuted)
    }

    private func operationRow(_ operation: DesignAnalyticsOperation) -> some View {
        operationColumns(OperationCells(
            name: "\(operation.name)\n\(operation.category)",
            calls: operation.calls.formatted(),
            success: operation.successRate,
            total: operation.totalDuration,
            average: operation.averageDuration,
            p95: operation.p95Duration
        ))
        .font(.system(size: 12.5))
        .foregroundStyle(Ayu.fg)
        .accessibilityElement(children: .combine)
    }

    private func operationColumns(_ cells: OperationCells) -> some View {
        GridRow {
            Text(cells.name).frame(maxWidth: .infinity, alignment: .leading)
            Text(cells.calls).frame(minWidth: 50, alignment: .trailing)
            Text(cells.success).frame(minWidth: 65, alignment: .trailing)
            Text(cells.total).frame(minWidth: 70, alignment: .trailing)
            Text(cells.average).frame(minWidth: 70, alignment: .trailing)
            Text(cells.p95).frame(minWidth: 70, alignment: .trailing)
        }
        .padding(.vertical, 8)
    }

    private var recentEventsCard: some View {
        SectionCard(symbol: "clock.arrow.circlepath", tone: .info, title: "Recent slow or unsuccessful events") {
            if snapshot.recentEvents.isEmpty {
                Text("No slow, failed, or cancelled events in this window")
                    .font(.system(size: 12.5))
                    .foregroundStyle(Ayu.fg2)
            } else {
                VStack(spacing: 0) {
                    ForEach(snapshot.recentEvents) { event in
                        HStack(spacing: 10) {
                            Circle().fill(event.outcome.tone.color).frame(width: 7, height: 7)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(event.operation).fontWeight(.medium)
                                Text(event.startedAt).font(.system(size: 11)).foregroundStyle(Ayu.fg2)
                            }
                            Spacer()
                            Text(event.duration).monospacedDigit()
                            TagPill(text: event.outcome.rawValue.capitalized, tone: event.outcome.tone)
                        }
                        .font(.system(size: 12.5))
                        .padding(.vertical, 9)
                        .accessibilityElement(children: .combine)
                    }
                }
            }
        }
    }

    private func summaryCard(_ label: String, _ value: String, _ tone: Tone) -> some View {
        GlassCard(padding: 16) {
            VStack(alignment: .leading, spacing: 5) {
                Text(label).font(.system(size: 11.5)).foregroundStyle(Ayu.fg2)
                Text(value).font(.system(size: 20, weight: .bold)).foregroundStyle(tone.color)
            }
            .accessibilityElement(children: .combine)
        }
    }

    private func stateCard(
        symbol: String,
        title: String,
        message: String,
        actionTitle: String? = nil,
        action: (() -> Void)? = nil
    ) -> some View {
        SectionCard(symbol: symbol, tone: .info, title: title) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(message).font(.system(size: 12.5)).foregroundStyle(Ayu.fg2)
                Spacer()
                if let actionTitle, let action {
                    Button(actionTitle, action: action)
                }
            }
        }
    }
}

private struct OperationCells {
    let name: String
    let calls: String
    let success: String
    let total: String
    let average: String
    let p95: String
}
