import SwiftUI

/// The Cairn logo: three stacked stones under a beacon with signal arcs. Drawn in SwiftUI so it
/// stays sharp at any size and follows the accent color.
struct CairnMark: View {
    var beacon: Color = .accentColor
    var glow = false

    var body: some View {
        Canvas { context, size in
            let s = min(size.width, size.height)
            let origin = CGPoint(x: (size.width - s) / 2, y: (size.height - s) / 2)
            func rect(_ cx: Double, _ cy: Double, _ w: Double, _ h: Double) -> CGRect {
                CGRect(x: origin.x + (cx - w / 2) * s, y: origin.y + (cy - h / 2) * s, width: w * s, height: h * s)
            }

            // Stones, bottom to top.
            let stones: [CGRect] = [
                rect(0.50, 0.86, 0.60, 0.19),
                rect(0.52, 0.68, 0.44, 0.16),
                rect(0.49, 0.52, 0.30, 0.14),
            ]
            for r in stones {
                context.fill(Path(roundedRect: r, cornerRadius: r.height / 2), with: .linearGradient(
                    Gradient(colors: [Color(red: 0.97, green: 0.95, blue: 0.90), Color(red: 0.70, green: 0.67, blue: 0.59)]),
                    startPoint: CGPoint(x: r.minX, y: r.minY), endPoint: CGPoint(x: r.maxX, y: r.maxY)
                ))
            }

            // Beacon and arcs.
            let center = CGPoint(x: origin.x + 0.49 * s, y: origin.y + 0.34 * s)
            let dot = Path(ellipseIn: CGRect(x: center.x - 0.035 * s, y: center.y - 0.035 * s, width: 0.07 * s, height: 0.07 * s))
            context.fill(dot, with: .color(beacon))
            for (i, radius) in [0.10, 0.18, 0.26].enumerated() {
                var arc = Path()
                arc.addArc(center: center, radius: radius * s, startAngle: .degrees(222), endAngle: .degrees(318), clockwise: false)
                context.stroke(arc, with: .color(beacon.opacity(1 - Double(i) * 0.22)),
                               style: StrokeStyle(lineWidth: 0.028 * s, lineCap: .round))
            }
        }
        .shadow(color: glow ? beacon.opacity(0.45) : .clear, radius: 12)
        .aspectRatio(1, contentMode: .fit)
        .accessibilityHidden(true)
    }
}

#Preview {
    CairnMark().frame(width: 160, height: 160).padding().background(Color(red: 0.04, green: 0.15, blue: 0.19))
}
