import Foundation
import Testing
@testable import CairnCore

private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

@Suite struct DriveSessionTests {
    @Test func newSessionIsActive() {
        let s = DriveSession(startedAt: t0)
        #expect(s.lifecycle == .active)
        #expect(s.startedAt == t0)
        #expect(s.closedAt == nil)
        #expect(s.counters.sent == 0)
        #expect(s.track.isEmpty)
        #expect(s.serverState == .unknown)
    }

    @Test func durationUsesClosedAtWhenAvailable() {
        var s = DriveSession(startedAt: t0)
        s.lastObservedAt = t0.addingTimeInterval(300)
        s.closedAt = t0.addingTimeInterval(600)
        #expect(s.duration == 600)
    }

    @Test func durationFallsBackToLastObserved() {
        var s = DriveSession(startedAt: t0)
        s.lastObservedAt = t0.addingTimeInterval(120)
        #expect(s.duration == 120)
    }

    @Test func streamingFractionExcludesUnknownTime() {
        var s = DriveSession(startedAt: t0)
        s.observedSeconds = 100
        s.streamingSeconds = 80
        #expect(s.streamingFraction! == 0.8)
    }

    @Test func streamingFractionNilWhenTooShort() {
        var s = DriveSession(startedAt: t0)
        s.observedSeconds = 3
        s.streamingSeconds = 3
        #expect(s.streamingFraction == nil)
    }

    @Test func counterEpochAccumulation() {
        var counters = DriveSession.Counters()
        let epoch = CounterEpoch(priorAccepted: 10, priorRejected: 2, priorQueueDrops: 1)
        let status = CompanionStatus(lastAcceptedSeq: 0, acceptedCount: 5, rejectedCount: 1, queueDropCount: 0)
        counters.accumulate(from: epoch, status: status)
        #expect(counters.accepted == 15)
        #expect(counters.rejected == 3)
        #expect(counters.queueDrops == 1)
    }

    @Test func counterGapClampsToZero() {
        var c = DriveSession.Counters()
        c.sent = 5
        c.accepted = 8
        c.rejected = 0
        #expect(c.counterGap == 0)
    }

    @Test func trackPointFiltersAccuracy() {
        let good = PhoneGNSSFix(latitude: 37, longitude: -122, ellipsoidalAltitude: 10,
                                horizontalAccuracy: 5, verticalAccuracy: 5, speed: 10, course: 90, timestamp: t0)
        let bad = PhoneGNSSFix(latitude: 37, longitude: -122, ellipsoidalAltitude: 10,
                               horizontalAccuracy: 100, verticalAccuracy: 5, speed: 10, course: 90, timestamp: t0)
        #expect(good.horizontalAccuracy <= TrackPoint.maxAccuracy)
        #expect(bad.horizontalAccuracy > TrackPoint.maxAccuracy)
    }
}

@Suite struct DriveSegmenterTests {
    @Test func gapBelowThresholdDoesNotClose() {
        #expect(!DriveSegmenter.shouldClose(droppedAt: t0, now: t0.addingTimeInterval(300)))
    }

    @Test func gapAtThresholdCloses() {
        #expect(DriveSegmenter.shouldClose(droppedAt: t0, now: t0.addingTimeInterval(600)))
    }

    @Test func reconcileResumesShortGapWithBLE() {
        var s = DriveSession(startedAt: t0)
        s.lifecycle = .active
        s.lastObservedAt = t0.addingTimeInterval(100)
        DriveSegmenter.reconcile(session: &s, bleRestored: true, now: t0.addingTimeInterval(110))
        #expect(s.lifecycle == .active)
    }

    @Test func reconcileClosesLongGap() {
        var s = DriveSession(startedAt: t0)
        s.lifecycle = .active
        s.lastObservedAt = t0.addingTimeInterval(100)
        DriveSegmenter.reconcile(session: &s, bleRestored: false, now: t0.addingTimeInterval(800))
        #expect(s.lifecycle == .closed)
        #expect(s.closeReason == .linkGap)
        #expect(s.closedAt == t0.addingTimeInterval(100))
    }

    @Test func reconcileMarksInterruptedWithoutBLE() {
        var s = DriveSession(startedAt: t0)
        s.lifecycle = .active
        s.lastObservedAt = t0.addingTimeInterval(100)
        DriveSegmenter.reconcile(session: &s, bleRestored: false, now: t0.addingTimeInterval(200))
        #expect(s.lifecycle == .interrupted)
    }
}

@Suite struct HistoryEntryTests {
    @Test func phoneOnlyEntry() {
        let session = DriveSession(startedAt: t0)
        let e = HistoryEntry(phoneSession: session)
        #expect(e.isOnPhoneOnly)
        #expect(!e.isOnServerOnly)
        #expect(!e.isMatched)
    }

    @Test func syncLabelShowsPending() {
        var session = DriveSession(startedAt: t0)
        session.serverState = .pendingSync
        let e = HistoryEntry(phoneSession: session)
        #expect(e.syncLabel == "Waiting to sync")
    }
}
