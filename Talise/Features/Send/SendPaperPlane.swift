import SwiftUI

/// Stylized paper-plane Shape. Two stroked triangles sharing the nose
/// — the larger outer body and a smaller crease line that suggests a
/// folded wing. Built so `.trim(from:to:)` produces a clean draw-on
/// animation from tail to tip.
struct SendPaperPlane: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        let w = rect.width
        let h = rect.height

        // Outer plane silhouette: tail (bottom-left) → nose (top-right)
        // → wing (mid-right) → fuselage (center) → tail.
        let tail = CGPoint(x: w * 0.05, y: h * 0.85)
        let nose = CGPoint(x: w * 0.95, y: h * 0.10)
        let wing = CGPoint(x: w * 0.55, y: h * 0.60)
        let belly = CGPoint(x: w * 0.40, y: h * 0.45)

        p.move(to: tail)
        p.addLine(to: nose)
        p.addLine(to: wing)
        p.addLine(to: belly)
        p.closeSubpath()

        // Inner crease — nose down to the wing-fold, so we get the
        // hint of depth instead of a single flat triangle.
        p.move(to: nose)
        p.addLine(to: belly)

        return p
    }
}

/// Animated paper-plane card. Renders the plane with a slow stroke-draw
/// once on appear, then a perpetual gentle flutter (slight rotation +
/// translate) so the screen reads as "in flight" rather than static.
struct AnimatedPaperPlane: View {
    var size: CGFloat = 120
    var color: Color = TaliseColor.accent

    @State private var drawProgress: CGFloat = 0
    @State private var flutter = false

    var body: some View {
        SendPaperPlane()
            .trim(from: 0, to: drawProgress)
            .stroke(
                LinearGradient(
                    colors: [color.opacity(0.9), color],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                style: StrokeStyle(
                    lineWidth: 2.2,
                    lineCap: .round,
                    lineJoin: .round
                )
            )
            .frame(width: size, height: size)
            .rotationEffect(.degrees(flutter ? -4 : 4))
            .offset(y: flutter ? -4 : 4)
            .shadow(color: color.opacity(0.35), radius: 14, x: 0, y: 6)
            .onAppear {
                withAnimation(.easeInOut(duration: 1.1)) {
                    drawProgress = 1
                }
                withAnimation(
                    .easeInOut(duration: 1.6).repeatForever(autoreverses: true)
                ) {
                    flutter.toggle()
                }
            }
    }
}

/// Vertical bars that shimmer left-to-right beneath the plane. Reads as
/// a soft "transmission" pulse so the screen has rhythm even before the
/// network call comes back.
struct ShimmerBars: View {
    var count: Int = 14
    var color: Color = TaliseColor.accent

    @State private var phase: Double = 0

    var body: some View {
        TimelineView(.animation) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            HStack(alignment: .center, spacing: 6) {
                ForEach(0..<count, id: \.self) { i in
                    let frac = Double(i) / Double(count)
                    let wave = sin((t * 1.6 + frac * 5))
                    let h = 6 + (1 + wave) * 8   // 6 → 22pt range
                    let alpha = 0.25 + (1 + wave) * 0.2
                    Capsule()
                        .fill(color.opacity(alpha))
                        .frame(width: 3, height: CGFloat(h))
                }
            }
            .frame(height: 24)
            .onAppear { phase = 1 }
        }
    }
}
