import SwiftUI

/// 180° ruler arc (red→amber→teal→green by health band), a heavy composite
/// marker at the net health value, and three true-position % satellites for
/// Genre / Year / Consistency so the weak link reads instantly.
struct LibraryHealthGauge: View {
    let snap: HealthSnapshot
    var onReview: () -> Void = {}

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var draw: CGFloat = 0

    private func polar(_ center: CGPoint, _ radius: CGFloat, _ degrees: Double) -> CGPoint {
        let angle = degrees * .pi / 180
        return CGPoint(
            x: center.x + radius * CGFloat(cos(angle)),
            y: center.y + radius * CGFloat(sin(angle))
        )
    }

    private func arc(_ center: CGPoint, _ radius: CGFloat, _ from: Double, _ to: Double) -> Path {
        var path = Path()
        let steps = 140
        for index in 0 ... steps {
            let point = polar(center, radius, from + (to - from) * Double(index) / Double(steps))
            if index == 0 {
                path.move(to: point)
            } else {
                path.addLine(to: point)
            }
        }
        return path
    }

    var body: some View {
        Color.clear
            .aspectRatio(900.0 / 470.0, contentMode: .fit)
            .overlay { gauge }
            .onAppear {
                guard !reduceMotion else {
                    draw = 1
                    return
                }
                withAnimation(.easeOut(duration: 0.9)) { draw = 1 }
            }
    }

    private var gauge: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let height = geometry.size.height
            let center = CGPoint(x: width / 2, y: height * 0.93)
            let radius = min(width * 0.40, height * 0.80)
            let strokeWidth = radius * 0.12
            let healthDegrees = 180 + 180 * snap.health
            let satellites: [(label: String, ratio: Double)] = [
                ("Consistency", snap.consistency),
                ("Genre", snap.genre),
                ("Year", snap.year),
            ]

            ZStack {
                Canvas { context, _ in
                    // bright gradient ruler — red(low) → green(high)
                    context.stroke(
                        arc(center, radius, 180, 360),
                        with: .linearGradient(
                            Gradient(stops: [
                                .init(color: Ayu.error, location: 0.00),
                                .init(color: Ayu.warning, location: 0.40),
                                .init(color: Ayu.info, location: 0.65),
                                .init(color: Ayu.success, location: 0.85),
                                .init(color: Ayu.success, location: 1.00),
                            ]),
                            startPoint: CGPoint(x: center.x - radius, y: center.y),
                            endPoint: CGPoint(x: center.x + radius, y: center.y)
                        ),
                        style: StrokeStyle(lineWidth: strokeWidth, lineCap: .round)
                    )

                    // component % dots at true positions + short leaders
                    for satellite in satellites {
                        let degrees = 180 + 180 * satellite.ratio
                        let dot = polar(center, radius, degrees)
                        var leader = Path()
                        leader.move(to: dot)
                        leader.addLine(to: polar(center, radius + strokeWidth, degrees))
                        context.stroke(
                            leader,
                            with: .color(Ayu.band(satellite.ratio).opacity(0.5)),
                            lineWidth: 1.5
                        )
                        let box = CGRect(x: dot.x - 6.5, y: dot.y - 6.5, width: 13, height: 13)
                        context.fill(Path(ellipseIn: box), with: .color(Ayu.card))
                        context.stroke(Path(ellipseIn: box), with: .color(Ayu.band(satellite.ratio)), lineWidth: 3.5)
                    }

                    // composite health marker — clean dot with a defining ring + thin tick
                    var notch = Path()
                    notch.move(to: polar(center, radius - strokeWidth / 2 - 3, healthDegrees))
                    notch.addLine(to: polar(center, radius + strokeWidth / 2 + 3, healthDegrees))
                    context.stroke(
                        notch,
                        with: .color(Ayu.fg.opacity(0.85)),
                        style: StrokeStyle(lineWidth: 3, lineCap: .round)
                    )
                    let marker = polar(center, radius, healthDegrees)
                    let ring = CGRect(x: marker.x - 7, y: marker.y - 7, width: 14, height: 14)
                    context.fill(Path(ellipseIn: ring), with: .color(Ayu.fg))
                    context.stroke(Path(ellipseIn: ring), with: .color(Ayu.window), lineWidth: 2.5)
                }
                .opacity(draw)

                // satellite labels (stagger the middle one so 89/92 don't collide)
                ForEach(Array(satellites.enumerated()), id: \.offset) { index, satellite in
                    let labelRadius = radius + strokeWidth + (index == 1 ? 30 : 16)
                    let position = polar(center, labelRadius, 180 + 180 * satellite.ratio)
                    HStack(spacing: 4) {
                        Text(satellite.label)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Ayu.fg2)
                        Text("\(Int((satellite.ratio * 100).rounded()))%")
                            .font(.system(size: 13, weight: .bold).monospacedDigit())
                            .foregroundStyle(Ayu.band(satellite.ratio))
                    }
                    .fixedSize()
                    .position(x: position.x, y: position.y)
                    .opacity(draw)
                }

                // center stack
                VStack(spacing: 4) {
                    Text("\(Int((snap.health * 100).rounded()))%")
                        .font(.rounded(radius * 0.42, .heavy))
                        .foregroundStyle(Ayu.fg)
                        .contentTransition(.numericText())
                    Text("Library Health").font(.system(size: 14, weight: .bold)).foregroundStyle(Ayu.fg2)

                    if snap.protectedFiles > 0 || snap.writeErrors > 0 {
                        let statusText = "\(snap.protectedFiles) protected"
                            + (snap.writeErrors > 0 ? " · \(snap.writeErrors) errors" : "")
                        Label(statusText, systemImage: "exclamationmark.triangle.fill")
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
                .position(x: center.x, y: center.y - radius * 0.34)
            }
        }
    }
}

#Preview {
    LibraryHealthGauge(snap: MockData().snapshot)
        .frame(width: 560).padding(40)
        .background(Ayu.card).preferredColorScheme(.dark)
}
