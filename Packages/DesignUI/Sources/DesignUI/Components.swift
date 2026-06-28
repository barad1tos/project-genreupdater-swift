import SwiftUI

// MARK: - Tag / pill
struct TagPill: View {
    let text: String
    var tone: Tone = .neutral
    var dot: Bool = false
    var body: some View {
        HStack(spacing: 5) {
            if dot { Circle().fill(tone.color).frame(width: 6, height: 6) }
            Text(text).font(.system(size: 11, weight: .bold))
        }
        .foregroundStyle(tone.color)
        .padding(.horizontal, 9).padding(.vertical, 3)
        .background(tone.color.opacity(0.14), in: Capsule())
        .overlay(Capsule().strokeBorder(tone.color.opacity(0.30)))
    }
}

// MARK: - Buttons
struct PrimaryButton: View {
    let title: String
    var symbol: String? = nil
    var enabled: Bool = true
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                if let symbol { Image(systemName: symbol) }
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
    var symbol: String? = nil
    var enabled: Bool = true
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                if let symbol { Image(systemName: symbol) }
                Text(title)
            }
            .font(.system(size: 13, weight: .medium))
            .padding(.horizontal, 14).padding(.vertical, 8)
            .background(Ayu.glassHi, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Ayu.glassBorder))
            .foregroundStyle(Ayu.fg)
        }
        .buttonStyle(.plain)
        .opacity(enabled ? 1 : 0.55)
        .disabled(!enabled)
    }
}

// MARK: - Card container
struct GlassCard<Content: View>: View {
    var padding: CGFloat = 22
    var glow: Bool = false
    @ViewBuilder var content: Content
    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Ayu.card, in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Ayu.glassBorder))
            .shadow(color: glow ? Ayu.accent.opacity(0.10) : .black.opacity(0.18),
                    radius: glow ? 22 : 8, y: glow ? 0 : 2)
    }
}

// MARK: - Section card (icon + title + subtitle header)
struct SectionCard<Content: View>: View {
    let symbol: String
    let tone: Tone
    let title: String
    var subtitle: String? = nil
    @ViewBuilder var content: Content
    var body: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 9) {
                        Image(systemName: symbol).foregroundStyle(tone.color).font(.system(size: 16))
                        Text(title).font(.system(size: 16, weight: .bold)).foregroundStyle(Ayu.fg)
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
        .frame(height: 9)
    }
}

// MARK: - Diff row (old → new)
struct DiffRow: View {
    let old: String?
    let new: String
    var body: some View {
        HStack(spacing: 8) {
            Text(old ?? "none").strikethrough().foregroundStyle(Ayu.fg2)
            Image(systemName: "arrow.right").font(.system(size: 11)).foregroundStyle(Ayu.fgMuted)
            Text(new).fontWeight(.bold).foregroundStyle(Ayu.fg)
        }
        .font(.system(size: 12.5))
    }
}
