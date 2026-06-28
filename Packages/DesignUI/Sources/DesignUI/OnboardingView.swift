import SwiftUI

struct OnboardingView: View {
    var onFinish: () -> Void
    @State private var step = 0
    @State private var installing = false

    private struct Step { let title, heading, body, cta, symbol: String; let tone: Tone }
    private let steps: [Step] = [
        .init(title: "Welcome", heading: "Welcome to GenreUpdater",
              body: "Automatically fix genres and release years across your Music library using MusicBrainz, Discogs, and Apple Music — safely, with a preview before every write.",
              cta: "Get started", symbol: "music.note.list", tone: .accent),
        .init(title: "Install scripts", heading: "Install AppleScript components",
              body: "GenreUpdater needs a few AppleScript helpers to write metadata to Music.app. They install into a secure system directory.",
              cta: "Install scripts", symbol: "doc.text", tone: .warning),
        .init(title: "Music access", heading: "Music library access",
              body: "GenreUpdater uses MusicKit to read your library. You’ll be asked to grant access — required to view and update tracks.",
              cta: "Grant access", symbol: "lock.shield", tone: .info),
        .init(title: "Ready", heading: "All set",
              body: "GenreUpdater is ready. Your library will load automatically and the dashboard will show where it needs attention.",
              cta: "Start using GenreUpdater", symbol: "checkmark.seal", tone: .success),
    ]

    private func next() {
        if step == 1 && !installing {
            installing = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.3) { installing = false; step = 2 }
            return
        }
        if step < steps.count - 1 { step += 1 } else { onFinish() }
    }

    var body: some View {
        let s = steps[step]
        VStack(spacing: 0) {
            HStack(spacing: 22) {
                ForEach(Array(steps.enumerated()), id: \.offset) { i, st in
                    HStack(spacing: 8) {
                        Circle().fill(i <= step ? Ayu.accent : Ayu.track).frame(width: 9, height: 9)
                        Text(st.title).font(.system(size: 12, weight: i == step ? .bold : .medium))
                            .foregroundStyle(i <= step ? Ayu.fg : Ayu.fg2)
                    }
                    .opacity(i <= step ? 1 : 0.5)
                }
            }
            .padding(20)
            Divider().overlay(Ayu.glassBorder)

            VStack(spacing: 16) {
                RoundedRectangle(cornerRadius: 24).fill(s.tone.color.opacity(0.15))
                    .frame(width: 84, height: 84)
                    .overlay(Image(systemName: s.symbol).font(.system(size: 40)).foregroundStyle(s.tone.color))
                Text(s.heading).font(.system(size: 22, weight: .bold))
                Text(s.body).font(.system(size: 14)).foregroundStyle(Ayu.fg2)
                    .multilineTextAlignment(.center).frame(maxWidth: 420)
                Spacer()
                if installing {
                    HStack(spacing: 10) { ProgressView().controlSize(.small); Text("Installing scripts…").foregroundStyle(Ayu.fg2) }
                } else {
                    PrimaryButton(title: s.cta, symbol: s.symbol, action: next)
                    if step > 0 {
                        Button("Skip setup") { onFinish() }.buttonStyle(.plain).font(.system(size: 12.5)).foregroundStyle(Ayu.fgMuted)
                    }
                }
            }
            .padding(40)
            .frame(minHeight: 300)
        }
        .frame(width: 560)
        .background(Ayu.card)
        .preferredColorScheme(.dark)
    }
}
