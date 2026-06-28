import SwiftUI

struct PipelineLifecycleMasthead: View {
    let snapshot: PipelineActivitySnapshot

    var body: some View {
        GlassCard(padding: 18, glow: true) {
            VStack(alignment: .leading, spacing: 16) {
                header
                stages
            }
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 10) {
            Label("Autonomous pipeline", systemImage: "point.3.connected.trianglepath.dotted")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Ayu.fg)
            TagPill(text: snapshot.safetyMode.title, tone: .warning, dot: true)
            Spacer()
            Text("Fix is gated until preview is approved")
                .font(.system(size: 12))
                .foregroundStyle(Ayu.fg2)
        }
    }

    private var stages: some View {
        HStack(alignment: .top, spacing: 6) {
            ForEach(PipelineStage.allCases) { stage in
                stageCell(stage)
                if stage != .report {
                    connector(after: stage)
                }
            }
        }
    }

    private func stageCell(_ stage: PipelineStage) -> some View {
        let status = snapshot.status(for: stage)
        return VStack(spacing: 7) {
            ZStack {
                Circle()
                    .fill(status.backgroundColor)
                    .frame(width: 34, height: 34)
                Circle()
                    .strokeBorder(status.borderColor, lineWidth: status == .current ? 2 : 1)
                    .frame(width: 34, height: 34)
                Image(systemName: stage.symbol)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(status.foregroundColor)
            }
            Text(stage.title)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(status.titleColor)
                .lineLimit(1)
            Text(stage.detail)
                .font(.system(size: 10.5))
                .foregroundStyle(Ayu.fg2)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(stage.title), \(stage.detail)")
    }

    private func connector(after stage: PipelineStage) -> some View {
        Rectangle()
            .fill(snapshot.status(for: stage).connectorColor)
            .frame(width: 28, height: 3)
            .clipShape(Capsule())
            .padding(.top, 16)
    }
}

private extension PipelineStageStatus {
    var backgroundColor: Color {
        switch self {
        case .completed: Ayu.teal
        case .current: Ayu.accent
        case .gated: Ayu.hover
        case .pending: Ayu.track
        case .failed: Ayu.error
        }
    }

    var borderColor: Color {
        switch self {
        case .completed: Ayu.teal.opacity(0.8)
        case .current: Ayu.accent2
        case .gated: Ayu.fg2
        case .pending: Ayu.glassBorder
        case .failed: Ayu.error
        }
    }

    var foregroundColor: Color {
        switch self {
        case .completed, .current: Ayu.onAccent
        case .gated, .pending: Ayu.fg
        case .failed: .white
        }
    }

    var titleColor: Color {
        switch self {
        case .completed: Ayu.teal
        case .current: Ayu.accent
        case .gated: Ayu.fg
        case .pending: Ayu.fg2
        case .failed: Ayu.error
        }
    }

    var connectorColor: Color {
        switch self {
        case .completed: Ayu.teal
        case .current: Ayu.accent
        case .gated, .pending: Ayu.fgMuted
        case .failed: Ayu.error
        }
    }
}

#Preview {
    PipelineLifecycleMasthead(
        snapshot: .previewDefault(
            deltaCount: 211,
            interventionCount: 142,
            protectedCount: 18,
            failedWriteCount: 0
        )
    )
    .padding(32)
    .background(Ayu.window)
    .preferredColorScheme(.dark)
}
