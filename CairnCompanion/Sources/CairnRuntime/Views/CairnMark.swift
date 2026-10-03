import SwiftUI

/// The Cairn logo: a navigation arrowhead inside an open "C" ring, with a beacon in the gap.
/// Drawn in SwiftUI so it stays sharp at any size; matches the app icon.
struct CairnMark: View {
    var beacon: Color = .accentColor
    var glow = false

    var body: some View {
        Canvas { context, size in
            let s = min(size.width, size.height)
            let origin = CGPoint(x: (size.width - s) / 2, y: (size.height - s) / 2)
            func point(_ x: Double, _ y: Double) -> CGPoint { CGPoint(x: origin.x + x * s, y: origin.y + y * s) }

            let center = point(0.5, 0.5)
            let radius = 0.315 * s
            let lineWidth = 0.094 * s

            // Open ring, gap on the right.
            var ring = Path()
            ring.addArc(center: center, radius: radius, startAngle: .degrees(38), endAngle: .degrees(322), clockwise: false)
            context.stroke(
                ring,
                with: .linearGradient(
                    Gradient(colors: [Color(red: 0.36, green: 0.95, blue: 0.84), Color(red: 0.18, green: 0.55, blue: 0.96)]),
                    startPoint: point(0.2, 0.1), endPoint: point(0.8, 0.9)
                ),
                style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
            )

            // Beacon in the gap.
            let dotR = 0.049 * s
            context.fill(
                Path(ellipseIn: CGRect(x: center.x + radius - dotR, y: center.y - dotR, width: dotR * 2, height: dotR * 2)),
                with: .color(beacon)
            )

            // Arrowhead, tilted 14 degrees, two facets.
            let tilt = 14.0 * .pi / 180
            func arrow(_ x: Double, _ y: Double) -> CGPoint {
                let k = 0.21
                let xr = x * cos(tilt) - y * sin(tilt)
                let yr = x * sin(tilt) + y * cos(tilt)
                return point(0.494 + xr * k, 0.523 + yr * k)
            }
            let tip = arrow(0, -1), right = arrow(0.72, 0.92), notch = arrow(0, 0.46), left = arrow(-0.72, 0.92)
            let joinStyle = StrokeStyle(lineWidth: 0.018 * s, lineCap: .round, lineJoin: .round)
            for (corner, color) in [(left, Color(red: 0.81, green: 0.91, blue: 0.95)), (right, Color.white)] {
                var facet = Path()
                facet.move(to: tip)
                facet.addLine(to: corner)
                facet.addLine(to: notch)
                facet.closeSubpath()
                context.fill(facet, with: .color(color))
                context.stroke(facet, with: .color(color), style: joinStyle) // rounds the corners slightly
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
