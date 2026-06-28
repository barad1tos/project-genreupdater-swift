import SwiftUI

struct ActivityView: View {
    @Bindable var model: AppModel
    let pipelineSecondaryAction: (() -> Void)?

    private let summaryColumns = Array(repeating: GridItem(.flexible(minimum: 0), spacing: 14), count: 5)
    private let lowerColumns = [GridItem(.adaptive(minimum: 310), spacing: 14)]

    init(
        model: AppModel,
        pipelineSecondaryAction: (() -> Void)? = nil
    ) {
        self.model = model
        self.pipelineSecondaryAction = pipelineSecondaryAction
    }

    var body: some View {
        let pipeline = model.pipelineActivity
        let snapshot = model.snapshot

        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header(pipeline)
                PipelineLifecycleMasthead(snapshot: pipeline)
                summaryCards(pipeline, snapshot: snapshot)
                fixPlanPreview

                LazyVGrid(columns: lowerColumns, alignment: .leading, spacing: 14) {
                    interventionQueue
                    safetyGates(pipeline, snapshot: snapshot)
                    recentRuns(snapshot)
                }
            }
            .padding(24)
            .frame(maxWidth: 1180, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .background(Ayu.window)
    }

    private func header(_ pipeline: PipelineActivitySnapshot) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: 14) {
                titleBlock(pipeline)
                Spacer(minLength: 18)
                actionButtons(pipeline)
            }

            VStack(alignment: .leading, spacing: 12) {
                titleBlock(pipeline)
                actionButtons(pipeline)
            }
        }
    }

    private func titleBlock(_ pipeline: PipelineActivitySnapshot) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Activity")
                .font(.system(size: 26, weight: .semibold))
                .foregroundStyle(Ayu.fg)
            Text(pipeline.subtitle)
                .font(.system(size: 13.5))
                .foregroundStyle(Ayu.fg2)
        }
    }

    private func actionButtons(_ pipeline: PipelineActivitySnapshot) -> some View {
        HStack(spacing: 10) {
            if let secondaryAction = pipeline.secondaryAction {
                BorderedButton(title: secondaryAction.title, symbol: secondaryAction.symbol) {
                    if let pipelineSecondaryAction {
                        pipelineSecondaryAction()
                    } else {
                        model.navigate(to: .update)
                    }
                }
                .disabled(!secondaryAction.isEnabled)
            }
            PrimaryButton(title: pipeline.primaryAction.title, symbol: pipeline.primaryAction.symbol) {
                model.navigate(to: .update)
            }
            .disabled(!pipeline.primaryAction.isEnabled)
        }
    }

    private func summaryCards(_ pipeline: PipelineActivitySnapshot, snapshot: HealthSnapshot) -> some View {
        LazyVGrid(columns: summaryColumns, alignment: .leading, spacing: 14) {
            ActivitySummaryCard(
                symbol: "waveform.path.ecg",
                tone: .teal,
                label: "Automation",
                value: pipeline.automationState.summaryValue,
                detail: pipeline.detail(for: .watch)
            )
            ActivitySummaryCard(
                symbol: "arrow.triangle.2.circlepath",
                tone: .accent,
                label: "Delta",
                value: "\(pipeline.deltaCount)",
                detail: "candidate fixes"
            )
            ActivitySummaryCard(
                symbol: "eye",
                tone: .purple,
                label: "Intervention",
                value: "\(pipeline.interventionCount)",
                detail: "needs review"
            )
            ActivitySummaryCard(
                symbol: "arrow.uturn.backward.circle",
                tone: pipeline.isUndoReady ? .success : .neutral,
                label: "Undo",
                value: pipeline.isUndoReady ? "Ready" : "Unavailable",
                detail: "pre-write snapshot"
            )
            ActivitySummaryCard(
                symbol: "checkmark.seal",
                tone: healthTone(snapshot.health),
                label: "Quality",
                value: "\(Int((snapshot.health * 100).rounded()))%",
                detail: "reporting context"
            )
        }
    }

    private var fixPlanPreview: some View {
        SectionCard(
            symbol: "checklist",
            tone: .accent,
            title: "Fix plan preview",
            subtitle: "Preview mode: no Music tags are written until the plan is approved."
        ) {
            VStack(spacing: 0) {
                ForEach(Array(model.data.changes.prefix(5))) { change in
                    HStack(spacing: 10) {
                        Image(systemName: change.type.symbol)
                            .foregroundStyle(change.type.tone.color.opacity(0.78))
                            .font(.system(size: 13.5))
                            .frame(width: 18)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(change.track)
                                .font(.system(size: 12.5, weight: .semibold))
                                .foregroundStyle(Ayu.fg)
                                .lineLimit(1)
                            Text(change.artist)
                                .font(.system(size: 11.5))
                                .foregroundStyle(Ayu.fg2)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 8)
                        DiffRow(old: change.old, new: change.new)
                            .font(.system(size: 11.5))
                        ConfidenceBadge(conf: change.conf)
                    }
                    .padding(.vertical, 9)
                    if change.id != model.data.changes.prefix(5).last?.id {
                        Divider().overlay(Ayu.glassBorder)
                    }
                }

                Button { model.navigate(to: .update) } label: {
                    HStack(spacing: 5) {
                        Text("Review all \(model.pipelineActivity.deltaCount)")
                        Image(systemName: "chevron.right")
                            .font(.system(size: 11))
                    }
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(Ayu.accent)
                }
                .buttonStyle(.plain)
                .padding(.top, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var interventionQueue: some View {
        SectionCard(
            symbol: "exclamationmark.triangle",
            tone: .warning,
            title: "Intervention queue",
            subtitle: "Review status and verification summary for this run."
        ) {
            VStack(spacing: 0) {
                ForEach(model.data.issues) { issue in
                    HStack(spacing: 11) {
                        Image(systemName: issue.symbol)
                            .foregroundStyle(issue.tone.color)
                            .font(.system(size: 16))
                            .frame(width: 18)
                        Text(issue.label)
                            .font(.system(size: 13.5))
                            .foregroundStyle(Ayu.fg)
                        Spacer()
                        Text(issue.count)
                            .font(.system(size: 13.5, weight: .semibold).monospacedDigit())
                            .foregroundStyle(issue.tone.color)
                        if let unit = issue.unit {
                            Text(unit)
                                .font(.system(size: 11))
                                .foregroundStyle(Ayu.fg2)
                        }
                    }
                    .padding(.vertical, 11)
                    if issue.id != model.data.issues.last?.id {
                        Divider().overlay(Ayu.glassBorder)
                    }
                }

                if !model.data.issues.isEmpty {
                    Divider().overlay(Ayu.glassBorder)
                }
                pendingVerificationSummary(model.data.pendingVerification)
            }
        }
    }

    private func pendingVerificationSummary(_ pending: PendingVerificationSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Verification summary")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Ayu.fg)

            if let unavailableReason = pending.unavailableReason {
                Text(unavailableReason)
                    .font(.system(size: 12))
                    .foregroundStyle(Ayu.fg2)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                VStack(spacing: 6) {
                    PendingVerificationMetricRow(
                        title: "Pending albums",
                        value: pending.totalAlbums,
                        tone: .purple
                    )
                    PendingVerificationMetricRow(
                        title: "Due now",
                        value: pending.dueAlbums,
                        tone: pending.dueAlbums > 0 ? .warning : .success
                    )
                    PendingVerificationMetricRow(
                        title: "Skipped by interval",
                        value: pending.skippedByInterval,
                        tone: .neutral
                    )
                    PendingVerificationMetricRow(
                        title: "Problematic albums",
                        value: pending.problematicAlbums,
                        tone: pending.problematicAlbums > 0 ? .error : .success
                    )
                    PendingVerificationMetricRow(
                        title: "Verified latest run",
                        value: pending.verifiedAlbums,
                        tone: .success
                    )
                }
            }
        }
        .padding(.top, 10)
    }

    private func safetyGates(_ pipeline: PipelineActivitySnapshot, snapshot: HealthSnapshot) -> some View {
        SectionCard(
            symbol: "lock.shield",
            tone: .teal,
            title: "Safety gates",
            subtitle: "Fix stays gated in Preview mode."
        ) {
            VStack(alignment: .leading, spacing: 10) {
                SafetyGateRow(title: "Preview approval", value: previewApprovalValue(pipeline), tone: .teal)
                SafetyGateRow(title: "Protected files", value: "\(snapshot.protectedFiles) skipped", tone: .warning)
                SafetyGateRow(
                    title: "Write errors",
                    value: "\(pipeline.failedWriteCount)",
                    tone: pipeline.failedWriteCount > 0 ? .error : .success
                )
                SafetyGateRow(
                    title: "Undo readiness",
                    value: pipeline.isUndoReady ? "Snapshot ready" : "Not available",
                    tone: pipeline.isUndoReady ? .success : .neutral
                )
            }
        }
    }

    private func recentRuns(_ snapshot: HealthSnapshot) -> some View {
        SectionCard(
            symbol: "clock.arrow.circlepath",
            tone: .purple,
            title: "Recent runs",
            subtitle: "Most recent run · \(snapshot.lastScan)"
        ) {
            VStack(spacing: 0) {
                ForEach(Array(model.data.activity.enumerated()), id: \.offset) { index, item in
                    HStack(alignment: .top, spacing: 11) {
                        Circle()
                            .fill(Ayu.fgMuted.opacity(0.75))
                            .frame(width: 5.5, height: 5.5)
                            .padding(.top, 5)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(item.title)
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(Ayu.fg)
                            Text(item.detail)
                                .font(.system(size: 12))
                                .foregroundStyle(Ayu.fg2)
                        }
                        Spacer()
                    }
                    .padding(.vertical, 9)
                    if index < model.data.activity.count - 1 {
                        Divider().overlay(Ayu.glassBorder)
                    }
                }
            }
        }
    }

    private func previewApprovalValue(_ pipeline: PipelineActivitySnapshot) -> String {
        switch pipeline.safetyMode {
        case .preview:
            return "Required before write"
        case .autoFix:
            return "Auto-fix enabled"
        }
    }
}

private struct ActivitySummaryCard: View {
    let symbol: String
    let tone: Tone
    let label: String
    let value: String
    let detail: String

    var body: some View {
        GlassCard(padding: 14) {
            VStack(alignment: .leading, spacing: 7) {
                Image(systemName: symbol)
                    .foregroundStyle(tone.color.opacity(tone == .neutral ? 0.72 : 0.84))
                    .font(.system(size: 16, weight: .semibold))
                Spacer(minLength: 2)
                Text(value)
                    .font(.rounded(22, .semibold))
                    .foregroundStyle(Ayu.fg)
                    .lineLimit(1)
                VStack(alignment: .leading, spacing: 2) {
                    Text(label)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Ayu.fg)
                    Text(detail)
                        .font(.system(size: 11.5))
                        .foregroundStyle(Ayu.fg2)
                        .lineLimit(1)
                }
            }
            .frame(minHeight: 88, alignment: .topLeading)
        }
    }
}

private struct SafetyGateRow: View {
    let title: String
    let value: String
    let tone: Tone

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(tone.color)
                .frame(width: 6, height: 6)
            Text(title)
                .font(.system(size: 12.5))
                .foregroundStyle(Ayu.fg)
            Spacer()
            Text(value)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(tone.color)
        }
    }
}

private struct PendingVerificationMetricRow: View {
    let title: String
    let value: Int
    let tone: Tone

    var body: some View {
        HStack(spacing: 10) {
            Text(title)
                .font(.system(size: 12))
                .foregroundStyle(Ayu.fg2)
            Spacer()
            Text(value.formatted())
                .font(.system(size: 12, weight: .semibold).monospacedDigit())
                .foregroundStyle(tone.color)
        }
    }
}

#Preview {
    ActivityView(model: AppModel())
        .frame(width: 1180, height: 760)
        .background(Ayu.window)
        .preferredColorScheme(.dark)
}
