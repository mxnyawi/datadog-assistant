import SwiftUI

/// A dithered area sparkline (the tripwire.sh "dither-kit" look): the fill
/// under the line is an ordered Bayer-dither dot pattern — dense right under
/// the line, fading downward — instead of a smooth alpha gradient, for a crisp
/// retro/print aesthetic. Everything is drawn in one `Canvas` (macOS 12+, so
/// it works on our macOS 13 target without Metal shaders) using the monitor's
/// tint, so it adapts to light/dark automatically.
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

    /// 4×4 ordered-dither matrix, normalized to 0…1 thresholds. A cell draws a
    /// dot when the local fill intensity exceeds its threshold — the classic
    /// ordered-dithering gradient.
    private static let bayer: [[Double]] = {
        let m = [[0, 8, 2, 10], [12, 4, 14, 6], [3, 11, 1, 9], [15, 7, 13, 5]]
        return m.map { $0.map { (Double($0) + 0.5) / 16.0 } }
    }()
    private let cell: CGFloat = 3.0    // dither grid pitch (points)
    private let dot: CGFloat = 1.6     // dot diameter (points)

    var body: some View {
        Canvas { ctx, size in
            guard points.count > 1 else { return }
            let w = size.width, h = size.height
            guard w > 0, h > 0 else { return }

            // Interpolated normalized value (0…1) at a fractional x.
            func value(atX x: CGFloat) -> Double {
                let t = Double(max(0, min(1, x / w))) * Double(points.count - 1)
                let i0 = Int(t.rounded(.down))
                let i1 = min(i0 + 1, points.count - 1)
                let f = t - Double(i0)
                return max(0, min(1, points[i0] * (1 - f) + points[i1] * f))
            }
            func lineY(atX x: CGFloat) -> CGFloat { h * (1 - CGFloat(value(atX: x))) }

            // Dithered area fill: walk a grid, draw a dot where the fill
            // intensity (highest at the line, fading to the baseline) beats the
            // Bayer threshold for that cell.
            if fill {
                var cx = cell / 2
                while cx < w {
                    let ly = lineY(atX: cx)
                    let depth = max(h - ly, 1)
                    var cy = ly
                    while cy < h {
                        let fillFrac = (cy - ly) / depth               // 0 at line → 1 at bottom
                        let intensity = pow(1 - Double(fillFrac), 0.75) // dense near the line
                        let thr = Self.bayer[Int(cy / cell) % 4][Int(cx / cell) % 4]
                        if intensity > thr {
                            ctx.fill(
                                Path(ellipseIn: CGRect(x: cx - dot / 2, y: cy - dot / 2,
                                                       width: dot, height: dot)),
                                with: .color(color.opacity(0.9)))
                        }
                        cy += cell
                    }
                    cx += cell
                }
            }

            // Threshold guide (dashed).
            if let threshold {
                let y = h * (1 - CGFloat(max(0, min(1, threshold))))
                var p = Path()
                p.move(to: CGPoint(x: 0, y: y))
                p.addLine(to: CGPoint(x: w, y: y))
                ctx.stroke(p, with: .color(.primary.opacity(0.35)),
                           style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
            }

            // Deploy markers.
            for pos in markers {
                let x = w * CGFloat(max(0, min(1, pos)))
                var p = Path()
                p.move(to: CGPoint(x: x, y: 0))
                p.addLine(to: CGPoint(x: x, y: h))
                ctx.stroke(p, with: .color(Theme.info.opacity(0.55)), lineWidth: 1)
                ctx.fill(Path(ellipseIn: CGRect(x: x - 1.75, y: 0.25, width: 3.5, height: 3.5)),
                         with: .color(Theme.info))
            }

            // The line itself, crisp on top of the dither.
            var line = Path()
            let stepX = w / CGFloat(points.count - 1)
            for (i, v) in points.enumerated() {
                let pt = CGPoint(x: CGFloat(i) * stepX,
                                 y: h * (1 - CGFloat(max(0, min(1, v)))))
                if i == 0 { line.move(to: pt) } else { line.addLine(to: pt) }
            }
            ctx.stroke(line, with: .color(color),
                       style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round))
        }
    }
}
