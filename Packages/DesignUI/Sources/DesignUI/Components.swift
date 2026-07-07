import SwiftUI

// MARK: - Tag / pill

struct TagPill: View {
    let text: String
    var tone: Tone = .neutral
    var dot: Bool = false
    var body: some View {
        HStack(spacing: 5) {
            if dot {
                Circle().fill(tone.color).frame(width: 5.5, height: 5.5)
            }
            Text(text)
                .font(.system(size: 11, weight: .semibold))
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
        }
        .foregroundStyle(tone.color)
        .padding(.horizontal, 8).padding(.vertical, 3)
        .background(tone.pillFill, in: Capsule())
        .overlay(Capsule().strokeBorder(tone.pillBorder))
        .fixedSize(horizontal: true, vertical: false)
    }
}

// MARK: - Buttons

struct PrimaryButton: View {
    let title: String
    var symbol: String?
    var enabled: Bool = true
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                if let symbol {
                    Image(systemName: symbol)
                }
                Text(title)
            }
            .font(.system(size: 13, weight: .semibold))
            .padding(.horizontal, 14).padding(.vertical, 8)
            .background(Ayu.accent, in: RoundedRectangle(cornerRadius: 8))
            .foregroundStyle(Ayu.onAccent)
        }
        .buttonStyle(.plain)
        .opacity(enabled ? 1 : 0.55)
        .disabled(!enabled)
    }
}

struct BorderedButton: View {
    let title: String
    var symbol: String?
    var enabled: Bool = true
    var action: (() -> Void)?
    var body: some View {
        Button(
            action: {
                action?()
            },
            label: {
                HStack(spacing: 7) {
                    if let symbol {
                        Image(systemName: symbol)
                    }
                    Text(title)
                }
                .font(.system(size: 13, weight: .medium))
                .padding(.horizontal, 14).padding(.vertical, 8)
                .background(Ayu.controlFillStrong, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Ayu.glassBorderStrong))
                .foregroundStyle(Ayu.fg)
            }
        )
        .buttonStyle(.plain)
        .opacity(isEnabled ? 1 : 0.55)
        .disabled(!isEnabled)
    }

    private var isEnabled: Bool {
        enabled && action != nil
    }
}

// MARK: - Card container

struct GlassCard<Content: View>: View {
    var padding: CGFloat = 22
    var glow: Bool = false
    @ViewBuilder var content: Content
    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
        return content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                ZStack {
                    shape.fill(Ayu.surfaceRaised)
                    shape.fill(LinearGradient(
                        colors: [.white.opacity(0.035), .white.opacity(0.0)],
                        startPoint: .top, endPoint: .center
                    ))
                    if glow {
                        shape.fill(RadialGradient(
                            colors: [Ayu.accent.opacity(0.045), .clear],
                            center: .top, startRadius: 0, endRadius: 560
                        ))
                    }
                }
            }
            .overlay(
                shape.strokeBorder(LinearGradient(
                    colors: [Ayu.glassBorderStrong, Ayu.glassBorder],
                    startPoint: .top, endPoint: .bottom
                ), lineWidth: 1)
            )
            .shadow(color: .black.opacity(glow ? 0.22 : 0.16), radius: glow ? 14 : 8, y: glow ? 8 : 5)
    }
}

// MARK: - Section card (icon + title + subtitle header)

struct SectionCard<Content: View>: View {
    let symbol: String
    let tone: Tone
    let title: String
    var subtitle: String?
    @ViewBuilder var content: Content
    var body: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 9) {
                        Image(systemName: symbol).foregroundStyle(tone.color).font(.system(size: 14))
                        Text(title).font(.system(size: 15, weight: .semibold)).foregroundStyle(Ayu.fg)
                    }
                    if let subtitle {
                        Text(subtitle).font(.system(size: 12)).foregroundStyle(Ayu.fg2)
                    }
                }
                content
            }
        }
    }
}

// MARK: - Confidence badge

struct ConfidenceBadge: View {
    let conf: Double
    var body: some View {
        let tone = confidenceTone(conf)
        Text("\(Int((conf * 100).rounded()))%")
            .font(.system(size: 11, weight: .bold).monospacedDigit())
            .foregroundStyle(tone == .error ? .white : Ayu.onAccent)
            .padding(.horizontal, 8).padding(.vertical, 2)
            .background(tone.color, in: Capsule())
    }
}

// MARK: - Coverage bar

struct CoverageBar: View {
    let ratio: Double
    let tone: Tone
    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Ayu.track)
                Capsule().fill(tone.color).frame(width: geo.size.width * ratio)
            }
        }
        .frame(height: 7)
    }
}

// MARK: - Diff row (old → new)

struct DiffRow: View {
    let old: String?
    let new: String
    var body: some View {
        HStack(spacing: 8) {
            Text(old ?? "none").strikethrough().foregroundStyle(Ayu.fgMuted)
            Image(systemName: "arrow.right").font(.system(size: 11)).foregroundStyle(Ayu.fgMuted)
            Text(new).fontWeight(.semibold).foregroundStyle(Ayu.fg)
        }
        .font(.system(size: 12.5))
    }
}
