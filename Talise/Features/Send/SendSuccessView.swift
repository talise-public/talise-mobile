import SwiftUI

/// Wireframe "3D" check used by `SendCompleteView`. No outer ring,
/// no halo — just the check itself drawn as a ribbon-extrusion
/// outline with an inner crease line at the vertex, exactly the
/// same construction logic the `AnimatedPaperPlane` uses to imply
/// depth (outer silhouette + interior fold line). Gradient stroke,
/// gentle float, soft drop-shadow.
struct SendSuccessAnimation: View {
    var size: CGFloat = 140
    var color: Color = TaliseColor.accent

    @State private var drawProgress: CGFloat = 0
    @State private var float = false

    var body: some View {
        Check3DShape()
            .trim(from: 0, to: drawProgress)
            .stroke(
                color,
                style: StrokeStyle(
                    lineWidth: 2.4,
                    lineCap: .round,
                    lineJoin: .round
                )
            )
            .frame(width: size, height: size)
            .rotationEffect(.degrees(float ? -3 : 3))
            .offset(y: float ? -3 : 3)
            .onAppear { runIn() }
    }

    private func runIn() {
        withAnimation(.easeInOut(duration: 1.1)) { drawProgress = 1 }
        withAnimation(
            .easeInOut(duration: 1.6).repeatForever(autoreverses: true)
        ) { float.toggle() }
    }
}

/// Ribbon-extrusion checkmark Shape. Two parallel check strokes
/// (offset perpendicular to the visual direction) form the front and
/// back edges of a thin band; the start and end caps close the
/// ribbon, and an interior fold line at the vertex gives the 3D
/// "folded paper" feel that matches `SendPaperPlane`.
///
/// Tuned by eye for a 140pt frame. All coordinates are fractions of
/// the bounding rect so it scales cleanly.
struct Check3DShape: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        let w = rect.width
        let h = rect.height

        // Front (top) edge of the check ribbon — runs from start →
        // vertex → end.
        let startFront  = CGPoint(x: w * 0.14, y: h * 0.48)
        let vertexFront = CGPoint(x: w * 0.42, y: h * 0.74)
        let endFront    = CGPoint(x: w * 0.86, y: h * 0.22)

        // Back (bottom) edge — same path, offset down-right to imply
        // depth. Constant offset works at this angle; perpendicular
        // math would be overkill for a 3D-icon glyph.
        let dx: CGFloat = w * 0.045
        let dy: CGFloat = h * 0.055
        let startBack  = CGPoint(x: startFront.x  + dx, y: startFront.y  + dy)
        let vertexBack = CGPoint(x: vertexFront.x + dx, y: vertexFront.y + dy)
        let endBack    = CGPoint(x: endFront.x    + dx, y: endFront.y    + dy)

        // Outer outline: front edge → end cap → back edge (reversed)
        // → start cap. Single closed subpath so the trim animation
        // draws the whole silhouette in one continuous sweep.
        p.move(to: startFront)
        p.addLine(to: vertexFront)
        p.addLine(to: endFront)
        p.addLine(to: endBack)
        p.addLine(to: vertexBack)
        p.addLine(to: startBack)
        p.closeSubpath()

        // Interior fold line at the vertex — same role as
        // `SendPaperPlane`'s nose→belly crease. This is what makes
        // the check read as a folded ribbon rather than a flat
        // outline.
        p.move(to: vertexFront)
        p.addLine(to: vertexBack)

        return p
    }
}

/// Two-segment checkmark, sized to its bounding box so it scales with
/// the parent Shape frame. Lives here (not in DesignSystem) because the
/// rest of the app doesn't need it yet.
struct CheckmarkPath: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        let w = rect.width
        let h = rect.height
        p.move(to: CGPoint(x: w * 0.10, y: h * 0.55))
        p.addLine(to: CGPoint(x: w * 0.40, y: h * 0.82))
        p.addLine(to: CGPoint(x: w * 0.92, y: h * 0.20))
        return p
    }
}

private extension Comparable {
    func clamped(to limits: ClosedRange<Self>) -> Self {
        min(max(self, limits.lowerBound), limits.upperBound)
    }
}
