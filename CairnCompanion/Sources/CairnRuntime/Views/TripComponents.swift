import CairnCore
import MapKit
import SwiftUI

// MARK: - Formatting

func formatDuration(_ seconds: TimeInterval) -> String {
    let s = Int(max(0, seconds).rounded())
    if s < 60 { return "\(s)s" }
    if s < 3600 { return "\(s / 60)m \(s % 60)s" }
    return "\(s / 3600)h \(String(format: "%02d", (s % 3600) / 60))m"
}

/// The duration as a trip card reads it: no seconds once it is minutes long.
func formatTripDuration(_ seconds: TimeInterval) -> String {
    let s = Int(max(0, seconds).rounded())
    if s < 60 { return "\(s) s" }
    if s < 3600 { return "\(max(1, (s + 30) / 60)) min" }
    return "\(s / 3600) h \(String(format: "%02d", (s % 3600) / 60)) m"
}

func formatDistance(_ meters: Double) -> String {
    meters < 1000 ? "\(Int(meters)) m" : String(format: "%.1f km", meters / 1000)
}

// MARK: - Route sketch

/// The route drawn from its own points, with no map tiles, so a long list stays cheap to scroll.
struct RouteSketchShape: Shape {
    let points: [TripSummary.SketchPoint]

    func path(in rect: CGRect) -> Path {
        var path = Path()
        guard points.count >= 2 else { return path }
        let side = min(rect.width, rect.height)
        let origin = CGPoint(x: rect.midX - side / 2, y: rect.midY - side / 2)
        func map(_ p: TripSummary.SketchPoint) -> CGPoint {
            CGPoint(x: origin.x + p.x * side, y: origin.y + (1 - p.y) * side)
        }
        path.move(to: map(points[0]))
        for p in points.dropFirst() { path.addLine(to: map(p)) }
        return path
    }
}

struct RouteSketch: View {
    let summary: TripSummary

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.tileSurface)
            if summary.routeSketch.count >= 2 {
                RouteSketchShape(points: summary.routeSketch)
                    .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
                    .padding(10)
            } else {
                Image(systemName: summary.isBench ? "wrench.and.screwdriver" : "point.topleft.down.to.point.bottomright.curvepath")
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(width: 64, height: 64)
        .accessibilityHidden(true)
    }
}

// MARK: - Trip card

/// One trip in the list: when, how long, how far, how fast, at a glance.
struct TripCard: View {
    let summary: TripSummary
    let entry: HistoryEntry
    let annotations: [CairnCore.Annotation]

    private var isFavorite: Bool { annotations.contains { $0.kind == .favorite } }
    private var firstNote: String? { annotations.first { $0.kind == .note }?.text }

    var body: some View {
        HStack(spacing: 12) {
            RouteSketch(summary: summary)
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Text(summary.startedAt, style: .time).font(.headline)
                    if isFavorite { Image(systemName: "star.fill").font(.caption).foregroundStyle(.yellow) }
                    Spacer(minLength: 4)
                    badges
                }
                HStack(spacing: 12) {
                    stat(summary.distanceMeters.map(formatDistance) ?? "\u{2014}", "road")
                    stat(formatTripDuration(summary.durationSeconds), "timer")
                    if let top = summary.maxSpeedKph { stat("\(top) km/h", "speedometer") }
                }
                if let sync = entry.syncLabel {
                    Text(sync).font(.caption).foregroundStyle(.orange)
                }
                if let firstNote {
                    Text(firstNote).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
        }
        .padding(.vertical, 4)
        .opacity(summary.isBench ? 0.55 : 1)
        .accessibilityElement(children: .combine)
    }

    private func stat(_ text: String, _ symbol: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: symbol).imageScale(.small)
            Text(text).lineLimit(1)
        }
        .font(.caption.monospacedDigit())
        .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private var badges: some View {
        if summary.isLive {
            BadgePill(text: "LIVE", color: .green)
        } else if summary.isBench {
            BadgePill(text: "BENCH", color: .secondary)
        } else if entry.isOnPhoneOnly {
            Image(systemName: "iphone").font(.caption).foregroundStyle(.secondary)
        } else if entry.isOnServerOnly {
            Image(systemName: "cloud.fill").font(.caption).foregroundStyle(.secondary)
        }
    }
}

/// The heading above a day's trips: the day, and what it added up to.
struct TripDayHeader: View {
    let day: TripDay

    private var title: String {
        let calendar = Calendar.current
        if calendar.isDateInToday(day.id) { return "Today" }
        if calendar.isDateInYesterday(day.id) { return "Yesterday" }
        return day.id.formatted(.dateTime.weekday(.wide).month(.abbreviated).day())
    }

    var body: some View {
        HStack {
            Text(title).font(.subheadline.weight(.semibold))
            Spacer()
            Text(totals).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
        }
        .textCase(nil)
    }

    private var totals: String {
        var parts = ["\(day.trips.count) \(day.trips.count == 1 ? "trip" : "trips")"]
        if day.totalDistanceMeters > 0 { parts.append(formatDistance(day.totalDistanceMeters)) }
        return parts.joined(separator: " \u{00B7} ")
    }
}

// MARK: - Route map

/// The phone's track on a real map with its start and end marked.
struct TripRouteMap: View {
    let session: DriveSession

    private var runs: [[CLLocationCoordinate2D]] {
        TripSummary.usableTrack(session).map { run in
            run.map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) }
        }.filter { $0.count >= 2 }
    }

    var body: some View {
        let runs = runs
        if let first = runs.first?.first, let last = runs.last?.last {
            Map(initialPosition: .automatic, interactionModes: [.pan, .zoom]) {
                ForEach(Array(runs.enumerated()), id: \.offset) { _, run in
                    MapPolyline(coordinates: run)
                        .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 5, lineCap: .round, lineJoin: .round))
                }
                Marker("Start", systemImage: "flag.fill", coordinate: first).tint(.green)
                Marker("End", systemImage: "flag.checkered", coordinate: last).tint(.red)
            }
            .frame(height: 220)
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        }
    }
}
