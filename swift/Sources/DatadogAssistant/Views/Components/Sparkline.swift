import SwiftUI

/// A dithered area sparkline (the "dither-kit" look) with analysis overlays:
/// - **Threshold-breach shading**: when a threshold is present, the dither fill
///   is vivid *above* the line (the severity mass) and faint below.
/// - **Week-over-week ghost**: a faint dashed line of the same metric a week ago.
/// - **Slope projection**: a dashed tail in a reserved right-hand strip.
/// All drawn in one `Canvas` (macOS 12+), tinted with the monitor's color.
struct Sparkline: View {
    let points: [Double]
    let color: Color
    var lineWidth: CGFloat = 1.5
    var fill: Bool = true
    /// Critical threshold in normalized 0…1 y-space; drives the dashed guide
    /// and the two-tone breach shading.
    var threshold: Double? = nil
    /// Deploy timestamps as 0…1 x positions; vertical ticks.
    var markers: [Double] = []
    /// Week-ago series in the same 0…1 space — a faint dashed ghost.
    var ghost: [Double] = []
    /// Projected continuation (already normalized) — dashed, in a reserved
    /// right strip after a "now" divider.
    var projection: [Double] = []

    private static let bayer: [[Double]] = {
        let m = [[0, 8, 2, 10], [12, 4, 14, 6], [3, 11, 1, 9], [15, 7, 13, 5]]
        return m.map { $0.map { (Double($0) + 0.5) / 16.0 } }
    }()
    private let cell: CGFloat = 3.0
    private let dot: CGFloat = 1.6

    var body: some View {
        Canvas { ctx, size in
            guard points.count > 1, size.width > 0, size.height > 0 else { return }
            let h = size.height
            // Reserve a right strip for the projection tail, if any.
            let projFrac: CGFloat = projection.count > 1 ? 0.28 : 0
            let w = size.width * (1 - projFrac)
            guard w > 0 else { return }

            func value(atX x: CGFloat) -> Double {
                let t = Double(max(0, min(1, x / w))) * Double(points.count - 1)
                let i0 = Int(t.rounded(.down)); let i1 = min(i0 + 1, points.count - 1)
                let f = t - Double(i0)
                return max(0, min(1, points[i0] * (1 - f) + points[i1] * f))
            }
            func lineY(atX x: CGFloat) -> CGFloat { h * (1 - CGFloat(value(atX: x))) }

            let thY = threshold.map { h * (1 - CGFloat(max(0, min(1, $0)))) }

            // Dithered area fill — two-tone when a threshold is present.
            if fill {
                var cx = cell / 2
                while cx < w {
                    let ly = lineY(atX: cx); let depth = max(h - ly, 1)
                    var cy = ly
                    while cy < h {
                        let fillFrac = (cy - ly) / depth
                        let intensity = pow(1 - Double(fillFrac), 0.75)
                        let thr = Self.bayer[Int(cy / cell) % 4][Int(cx / cell) % 4]
                        if intensity > thr {
                            let above = thY.map { cy < $0 } ?? true
                            let fillColor = above ? color.opacity(0.9)
                                                  : Color.primary.opacity(0.14)
                            ctx.fill(Path(ellipseIn: CGRect(x: cx - dot / 2, y: cy - dot / 2,
                                                            width: dot, height: dot)),
                                     with: .color(fillColor))
                        }
                        cy += cell
                    }
                    cx += cell
                }
            }

            // Week-ago ghost line.
            if ghost.count > 1 {
                var g = Path()
                let stepX = w / CGFloat(ghost.count - 1)
                for (i, v) in ghost.enumerated() {
                    let pt = CGPoint(x: CGFloat(i) * stepX, y: h * (1 - CGFloat(max(0, min(1, v)))))
                    if i == 0 { g.move(to: pt) } else { g.addLine(to: pt) }
                }
                ctx.stroke(g, with: .color(.primary.opacity(0.28)),
                           style: StrokeStyle(lineWidth: 1, dash: [2, 3]))
            }

            // Threshold guide (across the full width, projection included).
            if let thY {
                var p = Path()
                p.move(to: CGPoint(x: 0, y: thY))
                p.addLine(to: CGPoint(x: size.width, y: thY))
                ctx.stroke(p, with: .color(.primary.opacity(0.35)),
                           style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
            }

            // Deploy markers (historical region only).
            for pos in markers {
                let x = w * CGFloat(max(0, min(1, pos)))
                var p = Path()
                p.move(to: CGPoint(x: x, y: 0)); p.addLine(to: CGPoint(x: x, y: h))
                ctx.stroke(p, with: .color(Theme.info.opacity(0.55)), lineWidth: 1)
                ctx.fill(Path(ellipseIn: CGRect(x: x - 1.75, y: 0.25, width: 3.5, height: 3.5)),
                         with: .color(Theme.info))
            }

            // The line.
            var line = Path()
            let stepX = w / CGFloat(points.count - 1)
            var lastPt = CGPoint.zero
            for (i, v) in points.enumerated() {
                let pt = CGPoint(x: CGFloat(i) * stepX, y: h * (1 - CGFloat(max(0, min(1, v)))))
                if i == 0 { line.move(to: pt) } else { line.addLine(to: pt) }
                lastPt = pt
            }
            ctx.stroke(line, with: .color(color),
                       style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round))

            // Projection tail, in the reserved strip, from "now".
            if projFrac > 0 {
                var divider = Path()
                divider.move(to: CGPoint(x: w, y: 0)); divider.addLine(to: CGPoint(x: w, y: h))
                ctx.stroke(divider, with: .color(.primary.opacity(0.15)), lineWidth: 1)
                var pj = Path()
                pj.move(to: lastPt)
                let pstep = (size.width - w) / CGFloat(projection.count)
                for (i, v) in projection.enumerated() {
                    pj.addLine(to: CGPoint(x: w + pstep * CGFloat(i + 1),
                                           y: h * (1 - CGFloat(max(0, min(1, v))))))
                }
                ctx.stroke(pj, with: .color(color.opacity(0.8)),
                           style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, dash: [3, 3]))
            }
        }
    }
}
