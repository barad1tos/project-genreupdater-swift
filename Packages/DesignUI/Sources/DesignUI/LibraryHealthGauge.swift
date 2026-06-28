import SwiftUI

/// 180° ruler arc (red→amber→teal→green by health band), a heavy composite
/// marker at the net health value, and three true-position % satellites for
/// Genre / Year / Consistency so the weak link reads instantly.
struct LibraryHealthGauge: View {
    let snap: HealthSnapshot
    var onReview: () -> Void = {}

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var draw: CGFloat = 0

    private func polar(_ c: CGPoint, _ r: CGFloat, _ deg: Double) -> CGPoint {
        let a = deg * .pi / 180
        return CGPoint(x: c.x + r * CGFloat(cos(a)), y: c.y + r * CGFloat(sin(a)))
    }
    private func arc(_ c: CGPoint, _ r: CGFloat, _ from: Double, _ to: Double) -> Path {
        var p = Path()
        let steps = 140
        for i in 0...steps {
            let pt = polar(c, r, from + (to - from) * Double(i) / Double(steps))
            i == 0 ? p.move(to: pt) : p.addLine(to: pt)
        }
        return p
    }

    var body: some View {
        Color.clear
            .aspectRatio(900.0 / 470.0, contentMode: .fit)
            .overlay { gauge }
            .onAppear {
                guard !reduceMotion else { draw = 1; return }
                withAnimation(.easeOut(duration: 0.9)) { draw = 1 }
            }
    }

    private var gauge: some View {
        GeometryReader { geo in
            let W = geo.size.width, H = geo.size.height
            let c = CGPoint(x: W / 2, y: H * 0.93)
            let R = min(W * 0.40, H * 0.80)
            let sw = R * 0.12
            let healthDeg = 180 + 180 * snap.health
            let sats: [(String, Double)] = [
                ("Consistency", snap.consistency), ("Genre", snap.genre), ("Year", snap.year)
            ]

            ZStack {
                Canvas { ctx, _ in
                    // bright gradient ruler — red(low) → green(high)
                    ctx.stroke(
                        arc(c, R, 180, 360),
                        with: .linearGradient(
                            Gradient(stops: [
                                .init(color: Ayu.error,   location: 0.00),
                                .init(color: Ayu.warning, location: 0.40),
                                .init(color: Ayu.info,    location: 0.65),
                                .init(color: Ayu.success, location: 0.85),
                                .init(color: Ayu.success, location: 1.00),
                            ]),
                            startPoint: CGPoint(x: c.x - R, y: c.y),
                            endPoint:   CGPoint(x: c.x + R, y: c.y)),
                        style: StrokeStyle(lineWidth: sw, lineCap: .round))

                    // component % dots at true positions + short leaders
                    for (_, v) in sats {
                        let deg = 180 + 180 * v
                        let dot = polar(c, R, deg)
                        var leader = Path()
                        leader.move(to: dot); leader.addLine(to: polar(c, R + sw, deg))
                        ctx.stroke(leader, with: .color(Ayu.band(v).opacity(0.5)), lineWidth: 1.5)
                        let box = CGRect(x: dot.x - 6.5, y: dot.y - 6.5, width: 13, height: 13)
                        ctx.fill(Path(ellipseIn: box), with: .color(Ayu.card))
                        ctx.stroke(Path(ellipseIn: box), with: .color(Ayu.band(v)), lineWidth: 3.5)
                    }

                    // composite health marker — heavier, spans the ring
                    var notch = Path()
                    notch.move(to: polar(c, R - sw / 2 - 6, healthDeg))
                    notch.addLine(to: polar(c, R + sw / 2 + 6, healthDeg))
                    ctx.stroke(notch, with: .color(Ayu.fg), style: StrokeStyle(lineWidth: 5, lineCap: .round))
                    let m = polar(c, R, healthDeg)
                    ctx.fill(Path(ellipseIn: CGRect(x: m.x - 6.5, y: m.y - 6.5, width: 13, height: 13)),
                             with: .color(Ayu.fg))
                }
                .opacity(draw)

                // satellite labels (stagger the middle one so 89/92 don't collide)
                ForEach(Array(sats.enumerated()), id: \.offset) { i, s in
                    let p = polar(c, R + sw + (i == 1 ? 30 : 16), 180 + 180 * s.1)
                    HStack(spacing: 4) {
                        Text(s.0).font(.system(size: 12, weight: .semibold)).foregroundStyle(Ayu.fg2)
                        Text("\(Int((s.1 * 100).rounded()))%")
                            .font(.system(size: 13, weight: .bold).monospacedDigit())
                            .foregroundStyle(Ayu.band(s.1))
                    }
                    .fixedSize()
                    .position(x: p.x, y: p.y)
                    .opacity(draw)
                }

                // center stack
                VStack(spacing: 4) {
                    Text("\(Int((snap.health * 100).rounded()))%")
                        .font(.rounded(R * 0.42, .heavy))
                        .foregroundStyle(Ayu.fg)
                        .contentTransition(.numericText())
                    Text("Library Health").font(.system(size: 14, weight: .bold)).foregroundStyle(Ayu.fg2)

                    if snap.protectedFiles > 0 || snap.writeErrors > 0 {
                        let txt = "\(snap.protectedFiles) protected"
                            + (snap.writeErrors > 0 ? " · \(snap.writeErrors) errors" : "")
                        Label(txt, systemImage: "exclamationmark.triangle.fill")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Ayu.warning)
                            .padding(.horizontal, 10).padding(.vertical, 4)
                            .background(Ayu.warning.opacity(0.13), in: Capsule())
                            .overlay(Capsule().strokeBorder(Ayu.warning.opacity(0.28)))
                    }

                    Button(action: onReview) {
                        Text(snap.ready > 0 ? "Review changes" : "Up to date")
                            .font(.system(size: 13, weight: .bold))
                            .padding(.horizontal, 18).padding(.vertical, 9)
                            .background(snap.ready > 0 ? Ayu.accent : Ayu.success.opacity(0.16), in: Capsule())
                            .foregroundStyle(snap.ready > 0 ? Ayu.onAccent : Ayu.success)
                    }
                    .buttonStyle(.plain)
                    .disabled(snap.ready == 0)
                    .padding(.top, 4)
                }
                .position(x: c.x, y: c.y - R * 0.34)
            }
        }
    }
}

#Preview {
    LibraryHealthGauge(snap: MockData().snapshot)
        .frame(width: 560).padding(40)
        .background(Ayu.card).preferredColorScheme(.dark)
}
