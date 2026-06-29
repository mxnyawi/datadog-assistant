import SwiftUI

struct Sparkline: View {
    let points: [Double]
    let color: Color
    var lineWidth: CGFloat = 1.5
    var fill: Bool = true

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
