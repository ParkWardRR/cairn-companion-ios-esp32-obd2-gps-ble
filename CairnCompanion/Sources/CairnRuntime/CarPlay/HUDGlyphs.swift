#if os(iOS)
import CairnCore
import UIKit

/// Draws the HUD's glyphs and caches them.
///
/// A CarPlay driving-task app cannot draw its own views, so a list row's image is the only place Cairn
/// can put colour, a needle, or a number it controls. That makes `setImage` the hot path, and
/// `setImage` called repeatedly is known to hang the main thread — so every glyph is cached by the
/// small set of values that actually change its pixels (`HUDGaugeKey` plus the caption). A needle that
/// has not moved a whole bucket costs one dictionary lookup and no drawing at all.
///
/// Each glyph is drawn twice, light and dark, and handed back as a single `UIImageAsset`-backed image.
/// The vehicle switches content style at dusk without Cairn re-rendering anything.
@MainActor
final class HUDGlyphRenderer {
    private let format: UIGraphicsImageRendererFormat
    private var cache: [CacheKey: UIImage] = [:]

    /// The car screen's scale, so glyphs are drawn for the display they land on rather than the phone's.
    init(scale: CGFloat) {
        let format = UIGraphicsImageRendererFormat.preferred()
        format.scale = scale > 0 ? scale : 2
        format.opaque = false
        self.format = format
    }

    private struct CacheKey: Hashable {
        let kind: Int
        let gauge: HUDGaugeKey?
        let stones: [Int]
        let caption: String
        let width: Int
        let height: Int
    }

    /// Caches are per CarPlay session and bounded by the number of distinct buckets, but a long drive
    /// with changing captions can still grow them, so they are cleared if they get silly.
    private func store(_ key: CacheKey, _ image: UIImage) -> UIImage {
        if cache.count > 600 { cache.removeAll(keepingCapacity: true) }
        cache[key] = image
        return image
    }

    // MARK: - Gauge

    /// A 270° radial gauge. `caption` is drawn in the middle when there is room for it — the numbers
    /// live in pixels Cairn owns, so nothing depends on CarPlay letting it rewrite a label.
    func gauge(_ gauge: HUDGauge, size: CGSize, showsCaption: Bool) -> UIImage {
        let caption = showsCaption ? gauge.caption : ""
        let key = CacheKey(
            kind: 0, gauge: gauge.imageKey, stones: [], caption: caption,
            width: Int(size.width), height: Int(size.height)
        )
        if let hit = cache[key] { return hit }
        return store(key, draw(size: size) { rect, palette in
            Self.drawArc(
                in: rect, palette: palette, fraction: gauge.fraction,
                band: gauge.band, freshness: gauge.freshness, caption: caption
            )
        })
    }

    /// The small ring beside an ordinary row. No caption: the row's own text carries the number.
    func meter(_ row: HUDRow, size: CGSize) -> UIImage {
        let key = CacheKey(
            kind: 1, gauge: row.imageKey, stones: [], caption: "",
            width: Int(size.width), height: Int(size.height)
        )
        if let hit = cache[key] { return hit }
        return store(key, draw(size: size) { rect, palette in
            Self.drawArc(
                in: rect, palette: palette, fraction: row.meter,
                band: row.band, freshness: row.freshness, caption: ""
            )
        })
    }

    // MARK: - Keystone

    /// Cairn's mark is a stack of stones, so the dongle's four health bits are drawn as four stones.
    /// Bottom to top: SD, IMU, GNSS, OBD. Filled is good, hollow red is a fault, dashed means the
    /// dongle has never said.
    func keystone(_ hero: HUDHero, size: CGSize) -> UIImage {
        let stones = hero.stones.map { stone -> Int in
            switch stone {
            case .ok: 0
            case .fault: 1
            case .unreported: 2
            }
        }
        let key = CacheKey(
            kind: 2,
            gauge: HUDGaugeKey(bucket: nil, band: hero.band, freshness: hero.freshness),
            stones: stones, caption: "",
            width: Int(size.width), height: Int(size.height)
        )
        if let hit = cache[key] { return hit }
        return store(key, draw(size: size) { rect, palette in
            Self.drawStones(hero.stones, in: rect, palette: palette, band: hero.band, freshness: hero.freshness)
        })
    }

    // MARK: - Drawing

    private func draw(size: CGSize, _ body: (CGRect, Palette) -> Void) -> UIImage {
        let clamped = CGSize(width: max(12, size.width), height: max(12, size.height))
        let renderer = UIGraphicsImageRenderer(size: clamped, format: format)
        let rect = CGRect(origin: .zero, size: clamped)
        let light = renderer.image { _ in body(rect, .light) }
        let dark = renderer.image { _ in body(rect, .dark) }
        let asset = UIImageAsset()
        asset.register(light, with: UITraitCollection(userInterfaceStyle: .light))
        asset.register(dark, with: UITraitCollection(userInterfaceStyle: .dark))
        return asset.image(with: UITraitCollection(userInterfaceStyle: .dark))
    }

    private static func drawArc(
        in rect: CGRect, palette: Palette, fraction: Double?,
        band: HUDBand, freshness: Freshness, caption: String
    ) {
        let side = min(rect.width, rect.height)
        let width = max(2.5, side * 0.115)
        let radius = side / 2 - width / 2 - 1
        guard radius > 2 else { return }
        let centre = CGPoint(x: rect.midX, y: rect.midY)
        // 270° starting at the bottom-left and sweeping clockwise over the top, the way a
        // dashboard gauge reads. UIBezierPath angles are already in screen orientation.
        let start = CGFloat.pi * 0.75
        let sweep = CGFloat.pi * 1.5
        let alpha = palette.alpha(for: freshness)
        let colour = freshness == .never ? palette.unknown : palette.colour(for: band)

        let track = UIBezierPath(
            arcCenter: centre, radius: radius,
            startAngle: start, endAngle: start + sweep, clockwise: true
        )
        track.lineWidth = width
        track.lineCapStyle = .round
        if fraction == nil {
            // Nothing has ever been read for this metric: an empty dashed track, not a zero needle.
            palette.unknown.withAlphaComponent(0.34).setStroke()
            track.setLineDash([1.5, max(3, width * 0.8)], count: 2, phase: 0)
        } else {
            palette.track.setStroke()
        }
        track.stroke()

        if let fraction {
            // A hair of arc even at zero, so the driver can tell "reading zero" from "not reading".
            let swept = sweep * CGFloat(max(0.012, min(1, fraction)))
            let value = UIBezierPath(
                arcCenter: centre, radius: radius,
                startAngle: start, endAngle: start + swept, clockwise: true
            )
            value.lineWidth = width
            value.lineCapStyle = .round
            colour.withAlphaComponent(alpha).setStroke()
            value.stroke()

            let tipAngle = start + swept
            let tip = CGPoint(
                x: centre.x + radius * cos(tipAngle),
                y: centre.y + radius * sin(tipAngle)
            )
            colour.withAlphaComponent(alpha).setFill()
            UIBezierPath(
                ovalIn: CGRect(
                    x: tip.x - width * 0.62, y: tip.y - width * 0.62,
                    width: width * 1.24, height: width * 1.24
                )
            ).fill()
        }

        guard !caption.isEmpty else { return }
        let available = CGSize(width: side * 0.74, height: side * 0.46)
        guard available.width > 10, let font = fittedFont(caption, in: available, ceiling: side * 0.3) else { return }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: palette.label.withAlphaComponent(freshness == .never ? 0.4 : max(0.45, alpha)),
        ]
        let text = caption as NSString
        let bounds = text.size(withAttributes: attributes)
        text.draw(
            at: CGPoint(x: centre.x - bounds.width / 2, y: centre.y - bounds.height / 2),
            withAttributes: attributes
        )
    }

    /// Shrinks the value until it fits inside the ring. Monospaced digits so a changing number does
    /// not jitter from frame to frame.
    private static func fittedFont(_ text: String, in size: CGSize, ceiling: CGFloat) -> UIFont? {
        var points = ceiling
        while points >= 7 {
            let font = UIFont.monospacedDigitSystemFont(ofSize: points, weight: .semibold)
            let bounds = (text as NSString).size(withAttributes: [.font: font])
            if bounds.width <= size.width && bounds.height <= size.height { return font }
            points -= 0.5
        }
        return nil
    }

    private static func drawStones(
        _ stones: [HUDStone], in rect: CGRect, palette: Palette,
        band: HUDBand, freshness: Freshness
    ) {
        guard !stones.isEmpty else { return }
        let side = min(rect.width, rect.height)
        let widths: [CGFloat] = [0.80, 0.64, 0.48, 0.32]
        let count = min(stones.count, widths.count)
        let height = side * 0.145
        let gap = side * 0.055
        let total = CGFloat(count) * height + CGFloat(count - 1) * gap
        var y = rect.midY + total / 2 - height
        let alpha = palette.alpha(for: freshness)
        let colour = freshness == .never ? palette.unknown : palette.colour(for: band)

        for index in 0..<count {
            let width = side * widths[index]
            let frame = CGRect(x: rect.midX - width / 2, y: y, width: width, height: height)
            let radius = height / 2
            switch stones[index] {
            case .ok:
                colour.withAlphaComponent(alpha).setFill()
                UIBezierPath(roundedRect: frame, cornerRadius: radius).fill()
            case .fault:
                let path = UIBezierPath(roundedRect: frame.insetBy(dx: 0.9, dy: 0.9), cornerRadius: radius)
                path.lineWidth = max(1.2, side * 0.028)
                palette.alarm.withAlphaComponent(max(alpha, 0.55)).setStroke()
                path.stroke()
            case .unreported:
                let path = UIBezierPath(roundedRect: frame.insetBy(dx: 0.9, dy: 0.9), cornerRadius: radius)
                path.lineWidth = max(1, side * 0.024)
                path.setLineDash([2.5, 2.5], count: 2, phase: 0)
                palette.unknown.withAlphaComponent(0.45).setStroke()
                path.stroke()
            }
            y -= height + gap
        }
    }
}

// MARK: - Palette

/// Fixed colours rather than semantic ones: these are baked into images, so they cannot resolve
/// against the car's trait collection later. Light and dark are drawn separately instead.
struct Palette {
    let nominal: UIColor
    let caution: UIColor
    let alarm: UIColor
    let unknown: UIColor
    let track: UIColor
    let label: UIColor

    static let dark = Palette(
        nominal: UIColor(red: 0.196, green: 0.835, blue: 0.514, alpha: 1),
        caution: UIColor(red: 0.992, green: 0.690, blue: 0.133, alpha: 1),
        alarm: UIColor(red: 0.976, green: 0.439, blue: 0.400, alpha: 1),
        unknown: UIColor(red: 0.412, green: 0.459, blue: 0.525, alpha: 1),
        track: UIColor(white: 1, alpha: 0.16),
        label: UIColor(white: 0.96, alpha: 1)
    )

    static let light = Palette(
        nominal: UIColor(red: 0.035, green: 0.573, blue: 0.314, alpha: 1),
        caution: UIColor(red: 0.710, green: 0.278, blue: 0.027, alpha: 1),
        alarm: UIColor(red: 0.851, green: 0.176, blue: 0.125, alpha: 1),
        unknown: UIColor(red: 0.412, green: 0.459, blue: 0.525, alpha: 1),
        track: UIColor(white: 0, alpha: 0.13),
        label: UIColor(white: 0.06, alpha: 1)
    )

    func colour(for band: HUDBand) -> UIColor {
        switch band {
        case .nominal: nominal
        case .caution: caution
        case .alarm: alarm
        case .unknown: unknown
        }
    }

    /// The whole point of the HUD: a reading the dongle has stopped sending fades instead of vanishing.
    func alpha(for freshness: Freshness) -> CGFloat {
        switch freshness {
        case .live: 1
        case .stale: 0.62
        case .silent: 0.32
        case .never: 0.24
        }
    }
}
#endif
