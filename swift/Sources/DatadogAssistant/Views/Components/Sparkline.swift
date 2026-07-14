import SwiftUI

struct Sparkline: View {
    let points: [Double]
    let color: Color
    var lineWidth: CGFloat = 1.5
    var fill: Bool = true
    /// Critical threshold in the same normalized 0…1 y-space; drawn as a
    /// dashed guide so "how far past the line are we?" is visible at a glance.
    var threshold: Double? = nil
    /// Deploy timestamps as 0…1 x positions; drawn as vertical ticks so a
    /// deploy sitting right before an inflection is visually undeniable.
    var markers: [Double] = []

    var body: some View {
        GeometryReader { geo in
            let path = makePath(in: geo.size)
            ZStack {
                if fill {
                    fillPath(in: geo.size)
                        .fill(LinearGradient(
                            colors: [color.opacity(0.35), color.opacity(0.0)],
                            startPoint: .top, endPoint: .bottom))
                }
                if let threshold {
                    let y = geo.size.height * (1.0 - CGFloat(max(0.0, min(1.0, threshold))))
                    Path { p in
                        p.move(to: CGPoint(x: 0, y: y))
                        p.addLine(to: CGPoint(x: geo.size.width, y: y))
                    }
                    .stroke(Color.primary.opacity(0.35),
                            style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                }
                ForEach(Array(markers.enumerated()), id: \.offset) { _, position in
                    let x = geo.size.width * CGFloat(max(0.0, min(1.0, position)))
                    Path { p in
                        p.move(to: CGPoint(x: x, y: 0))
                        p.addLine(to: CGPoint(x: x, y: geo.size.height))
                    }
                    .stroke(Theme.info.opacity(0.55), lineWidth: 1)
                    Circle()
                        .fill(Theme.info)
                        .frame(width: 3.5, height: 3.5)
                        .position(x: x, y: 2)
                }
                path.stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round))
            }
        }
    }

    private func makePath(in size: CGSize) -> Path {
        var path = Path()
        guard points.count > 1 else { return path }
        let stepX = size.width / CGFloat(points.count - 1)
        for (i, v) in points.enumerated() {
            let x = CGFloat(i) * stepX
            let y = size.height * (1.0 - CGFloat(max(0.0, min(1.0, v))))
            if i == 0 { path.move(to: CGPoint(x: x, y: y)) }
            else { path.addLine(to: CGPoint(x: x, y: y)) }
        }
        return path
    }

    private func fillPath(in size: CGSize) -> Path {
        var path = makePath(in: size)
        guard !points.isEmpty else { return path }
        path.addLine(to: CGPoint(x: size.width, y: size.height))
        path.addLine(to: CGPoint(x: 0, y: size.height))
        path.closeSubpath()
        return path
    }
}
