import Foundation
import Testing
@testable import CairnCore

private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

/// A straight northbound drive: `count` fixes one second apart, `step` degrees of latitude apart.
private func northbound(count: Int, step: Double = 0.0001, accuracy: Double = 5, speed: Double = 11) -> [TrackPoint] {
    (0..<count).map { i in
        TrackPoint(fix: PhoneGNSSFix(
            latitude: 37.0 + Double(i) * step, longitude: -122.0, ellipsoidalAltitude: 0,
            horizontalAccuracy: accuracy, verticalAccuracy: 5, speed: speed, course: 0,
            timestamp: t0.addingTimeInterval(Double(i))
        ))
    }
}

private func session(track: [TrackPoint], duration: TimeInterval = 120) -> DriveSession {
    var s = DriveSession(startedAt: t0)
    s.track = track
    s.lifecycle = .closed
    s.closedAt = t0.addingTimeInterval(duration)
    s.obdReceived = true
    return s
}

@Suite struct TripSummaryTests {
    @Test func distanceFollowsTheTrack() throws {
        // 100 steps of 0.0001 deg of latitude is about 1.1 km.
        let summary = TripSummary(entry: HistoryEntry(phoneSession: session(track: northbound(count: 101))))
        let metres = try #require(summary.distanceMeters)
        #expect(abs(metres - 1112) < 20)
        #expect(summary.maxSpeedKph == 40)
        #expect(summary.averageSpeedKph == 33)
    }

    @Test func badFixesAreLeftOut() throws {
        var track = northbound(count: 11)
        // one wildly inaccurate fix far from the road and one impossible jump
        track[5] = TrackPoint(fix: PhoneGNSSFix(latitude: 38, longitude: -122, ellipsoidalAltitude: 0, horizontalAccuracy: 500, verticalAccuracy: 5, speed: 11, course: 0, timestamp: track[5].timestamp))
        track[8] = TrackPoint(fix: PhoneGNSSFix(latitude: 37.5, longitude: -122, ellipsoidalAltitude: 0, horizontalAccuracy: 5, verticalAccuracy: 5, speed: 11, course: 0, timestamp: track[8].timestamp))
        let summary = TripSummary(entry: HistoryEntry(phoneSession: session(track: track, duration: 40)))
        let metres = try #require(summary.distanceMeters)
        #expect(metres < 200)
    }

    @Test func nothingIsMeasuredAcrossAGap() throws {
        var s = session(track: northbound(count: 10) + northbound(count: 10, step: 0.0001).map {
            TrackPoint(fix: PhoneGNSSFix(latitude: $0.latitude + 0.5, longitude: $0.longitude, ellipsoidalAltitude: 0, horizontalAccuracy: 5, verticalAccuracy: 5, speed: 11, course: 0, timestamp: $0.timestamp.addingTimeInterval(3600)))
        })
        s.trackSegments.append(TrackSegment(startIndex: 10, startedAt: t0.addingTimeInterval(3600)))
        let summary = TripSummary(entry: HistoryEntry(phoneSession: s))
        let metres = try #require(summary.distanceMeters)
        #expect(metres < 300) // two short runs, not 55 km of crossing the gap
    }

    @Test func theServerTripWinsForDurationAndTopSpeed() {
        let trip = TripSnapshot(id: "boot-1", startedAt: t0, endedAt: t0.addingTimeInterval(600), durationSeconds: 600, maxSpeedKph: 131)
        let summary = TripSummary(entry: HistoryEntry(phoneSession: session(track: northbound(count: 30), duration: 30), serverTrip: trip))
        #expect(summary.durationSeconds == 600)
        #expect(summary.maxSpeedKph == 131)
        #expect(!summary.isBench)
    }

    @Test func aServerOnlyTripHasNoSketchOrDistance() {
        let trip = TripSnapshot(id: "boot-2", startedAt: t0, durationSeconds: 300, maxSpeedKph: 90)
        let summary = TripSummary(entry: HistoryEntry(serverTrip: trip))
        #expect(summary.distanceMeters == nil)
        #expect(summary.routeSketch.isEmpty)
        #expect(summary.averageSpeedKph == nil)
        #expect(summary.maxSpeedKph == 90)
    }

    @Test func benchSessionsAreMarked() {
        var s = DriveSession(startedAt: t0)
        s.lifecycle = .closed
        s.closedAt = t0.addingTimeInterval(20)
        #expect(TripSummary(entry: HistoryEntry(phoneSession: s)).isBench)
    }

    @Test func theSketchStaysInsideTheUnitSquareAndKeepsItsShape() {
        let sketch = TripSummary(entry: HistoryEntry(phoneSession: session(track: northbound(count: 400)))).routeSketch
        #expect(sketch.count <= TripSummary.sketchPointLimit + 1)
        #expect(sketch.allSatisfy { (0...1).contains($0.x) && (0...1).contains($0.y) })
        // a straight line north: x is constant, y runs the full height
        #expect(Set(sketch.map { ($0.x * 1000).rounded() }).count == 1)
        #expect(sketch.first!.y == 0 && abs(sketch.last!.y - 1) < 1e-9)
    }

    @Test func daysAreNewestFirstWithTotals() {
        var day = Calendar(identifier: .gregorian)
        day.timeZone = TimeZone(identifier: "UTC")!
        func entry(_ offset: TimeInterval) -> TripSummary {
            TripSummary(entry: HistoryEntry(phoneSession: DriveSession(startedAt: t0.addingTimeInterval(offset))))
        }
        // t0 is 22:13 UTC: an hour earlier is the same day, three days earlier is another
        let days = TripDay.group([entry(-3600), entry(0), entry(-3 * 86_400)], calendar: day)
        #expect(days.count == 2)
        #expect(days[0].id > days[1].id)
        #expect(days[0].trips.count == 2)
        #expect(days[0].trips[0].startedAt > days[0].trips[1].startedAt)
    }
}
