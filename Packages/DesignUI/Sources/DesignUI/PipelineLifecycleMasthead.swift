import SwiftUI

struct PipelineLifecycleMasthead: View {
    let snapshot: PipelineActivitySnapshot

    var body: some View {
        GlassCard(padding: 16) {
            VStack(alignment: .leading, spacing: 15) {
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
            ForEach(snapshot.stageDescriptors) { descriptor in
                stageCell(descriptor)
                if descriptor.stage != .report {
                    connector(after: descriptor.stage)
                }
            }
        }
    }

    private func stageCell(_ descriptor: PipelineStageDescriptor) -> some View {
        let stage = descriptor.stage
        let status = descriptor.status
        return VStack(spacing: 7) {
            ZStack {
                Circle()
                    .fill(status.backgroundColor)
                    .frame(width: 32, height: 32)
                Circle()
                    .strokeBorder(status.borderColor, lineWidth: status == .current ? 1.5 : 1)
                    .frame(width: 32, height: 32)
                Image(systemName: stage.symbol)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(status.foregroundColor)
            }
            Text(stage.title)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(status.titleColor)
                .lineLimit(1)
            Text(descriptor.detail)
                .font(.system(size: 10.5))
                .foregroundStyle(Ayu.fg2)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(stage.title), \(descriptor.detail)")
    }

    private func connector(after stage: PipelineStage) -> some View {
        Rectangle()
            .fill(snapshot.status(for: stage).connectorColor)
            .frame(width: 26, height: 2)
            .clipShape(Capsule())
            .padding(.top, 15)
    }
}

extension PipelineStageStatus {
    fileprivate var backgroundColor: Color {
        switch self {
        case .completed: Ayu.teal.opacity(0.14)
        case .current: Ayu.accent
        case .gated: Ayu.controlFillStrong
        case .pending: Ayu.track
        case .failed: Ayu.error.opacity(0.78)
        }
    }

    fileprivate var borderColor: Color {
        switch self {
        case .completed: Ayu.teal.opacity(0.36)
        case .current: Ayu.accent2
        case .gated: Ayu.fgMuted.opacity(0.45)
        case .pending: Ayu.glassBorder
        case .failed: Ayu.error
        }
    }

    fileprivate var foregroundColor: Color {
        switch self {
        case .completed: Ayu.teal
        case .current: Ayu.onAccent
        case .gated: Ayu.fg2
        case .pending: Ayu.fgMuted
        case .failed: .white
        }
    }

    fileprivate var titleColor: Color {
        switch self {
        case .completed: Ayu.fg
        case .current: Ayu.accent
        case .gated: Ayu.fg2
        case .pending: Ayu.fgMuted
        case .failed: Ayu.error
        }
    }

    fileprivate var connectorColor: Color {
        switch self {
        case .completed: Ayu.teal.opacity(0.48)
        case .current: Ayu.accent.opacity(0.78)
        case .gated, .pending: Ayu.fgMuted.opacity(0.48)
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
