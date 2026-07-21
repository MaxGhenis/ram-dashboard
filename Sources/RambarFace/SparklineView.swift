import SwiftUI

/// Sixty minutes of used-memory fraction as a quiet line with a soft fill.
/// The y-axis is the full 0–1 range of physical memory, so the line's height
/// is literally the machine's fullness — no dramatized scaling.
struct SparklineView: View {
    let points: [(time: Double, fraction: Double)]
    let tint: Color

    var body: some View {
        Canvas { context, size in
            guard points.count >= 2 else { return }
            let start = points.first!.time
            let span = max(points.last!.time - start, 1)

            func position(_ point: (time: Double, fraction: Double)) -> CGPoint {
                CGPoint(
                    x: (point.time - start) / span * size.width,
                    y: size.height * (1 - min(max(point.fraction, 0), 1))
                )
            }

            var line = Path()
            line.move(to: position(points[0]))
            for point in points.dropFirst() {
                line.addLine(to: position(point))
            }

            var fill = line
            fill.addLine(to: CGPoint(x: size.width, y: size.height))
            fill.addLine(to: CGPoint(x: 0, y: size.height))
            fill.closeSubpath()

            context.fill(fill, with: .linearGradient(
                Gradient(colors: [tint.opacity(0.18), tint.opacity(0.02)]),
                startPoint: .zero,
                endPoint: CGPoint(x: 0, y: size.height)
            ))
            context.stroke(line, with: .color(tint.opacity(0.85)), lineWidth: 1.2)
        }
        .accessibilityLabel("Memory used over the last hour")
    }
}
