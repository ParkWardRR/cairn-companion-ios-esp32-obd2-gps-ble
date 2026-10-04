import CairnCore
import SwiftUI

public struct HistoryView: View {
    let recorder: DriveRecorder
    let syncClient: TripSyncClient
    @State private var sessions: [DriveSession] = []
    @State private var serverTrips: [TripSnapshot] = []
    @State private var isLoading = true

    public init(recorder: DriveRecorder, syncClient: TripSyncClient) {
        self.recorder = recorder
        self.syncClient = syncClient
    }

    private var entries: [HistoryEntry] {
        HistoryMerger.merge(sessions: sessions, trips: serverTrips)
    }

    public var body: some View {
        NavigationStack {
            Group {
                if isLoading {
                    ProgressView()
                } else if entries.isEmpty {
                    ContentUnavailableView(
                        "No drives yet",
                        systemImage: "car.side",
                        description: Text("Drives are recorded automatically when the Cairn dongle connects.")
                    )
                } else {
                    driveList
                }
            }
            .navigationTitle("History")
            .toolbar {
                ToolbarItem(placement: .automatic) {
                    syncButton
                }
            }
            .task { await load() }
            .refreshable { await load() }
        }
    }

    private var driveList: some View {
        List {
            ForEach(entries) { entry in
                NavigationLink(value: entry.id) {
                    HistoryRow(entry: entry)
                }
            }
            .onDelete { indexSet in
                Task {
                    for i in indexSet {
                        if let id = entries[i].phoneSession?.id {
                            try? await recorder.deleteSession(id)
                        }
                    }
                    await load()
                }
            }
        }
        #if os(iOS)
        .listStyle(.insetGrouped)
        #endif
        .navigationDestination(for: String.self) { id in
            if let entry = entries.first(where: { $0.id == id }) {
                DriveDetailView(entry: entry)
            }
        }
    }

    @ViewBuilder
    private var syncButton: some View {
        Button {
            syncClient.sync()
            Task {
                try? await Task.sleep(for: .seconds(2))
                await load()
            }
        } label: {
            if syncClient.state == .syncing {
                ProgressView()
            } else {
                Image(systemName: "arrow.triangle.2.circlepath")
            }
        }
        .disabled(syncClient.state == .syncing)
    }

    private func load() async {
        isLoading = true
        sessions = (try? await recorder.allSessions()) ?? []
        serverTrips = syncClient.cachedTrips()
        isLoading = false
    }
}

// MARK: - Row

private struct HistoryRow: View {
    let entry: HistoryEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(entry.startedAt, style: .date)
                    .font(.headline)
                Spacer()
                sourceIcon(entry)
                if let session = entry.phoneSession {
                    lifecycleBadge(session)
                }
            }
            HStack(spacing: 12) {
                Text(entry.startedAt, style: .time)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                if let session = entry.phoneSession {
                    Label(formatDuration(session.duration), systemImage: "timer")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if let frac = session.streamingFraction {
                        Label("\(Int(frac * 100))%", systemImage: "antenna.radiowaves.left.and.right")
                            .font(.caption)
                            .foregroundStyle(frac > 0.9 ? .green : frac > 0.5 ? .orange : .red)
                    }
                    if session.reconnects > 0 {
                        Label("\(session.reconnects)", systemImage: "arrow.triangle.2.circlepath")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                } else if let trip = entry.serverTrip {
                    Label(formatDuration(trip.durationSeconds), systemImage: "timer")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            if let sync = entry.syncLabel {
                Text(sync)
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            if let trip = entry.serverTrip {
                HStack(spacing: 8) {
                    if let speed = trip.maxSpeedKph {
                        Label("\(speed) km/h", systemImage: "speedometer")
                            .font(.caption)
                    }
                    if trip.obdSamples > 0 {
                        Label("\(trip.obdSamples) OBD", systemImage: "engine.combustion")
                            .font(.caption)
                    }
                    Label("\(trip.gnssSamples) GPS", systemImage: "antenna.radiowaves.left.and.right")
                        .font(.caption)
                }
                .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
        .opacity(entry.phoneSession?.quality == .bench ? 0.55 : 1)
    }

    @ViewBuilder
    private func lifecycleBadge(_ session: DriveSession) -> some View {
        switch session.lifecycle {
        case .active:
            badgePill("LIVE", color: .green)
        case .gapPending:
            badgePill("RECONNECTING", color: .orange)
        case .interrupted:
            badgePill("INTERRUPTED", color: .red)
        case .closed:
            if session.quality == .bench {
                badgePill("BENCH", color: .secondary)
            }
        }
    }

    @ViewBuilder
    private func sourceIcon(_ entry: HistoryEntry) -> some View {
        if entry.isMatched {
            Image(systemName: "checkmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.green)
        } else if entry.isOnServerOnly {
            Image(systemName: "cloud.fill")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else if entry.isOnPhoneOnly {
            Image(systemName: "iphone")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func badgePill(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.caption2.weight(.bold))
            .foregroundStyle(.white)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(color, in: Capsule())
    }
}

// MARK: - Detail

private struct DriveDetailView: View {
    let entry: HistoryEntry

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                if let session = entry.phoneSession {
                    phoneSection(session)
                }
                if let trip = entry.serverTrip {
                    serverSection(trip)
                }
                if let session = entry.phoneSession, !session.events.isEmpty {
                    eventTimeline(session)
                }
            }
            .padding()
        }
        .navigationTitle(entry.startedAt.formatted(date: .abbreviated, time: .shortened))
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }

    @ViewBuilder
    private func phoneSection(_ session: DriveSession) -> some View {
        GroupBox("Phone-Observed Session") {
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                tile("Duration", formatDuration(session.duration))
                tile("Streaming", session.streamingFraction.map { "\(Int($0 * 100))%" } ?? "—")
                tile("Sent", "\(session.counters.sent)")
                tile("Accepted", "\(session.counters.accepted)")
                tile("Rejected", "\(session.counters.rejected)")
                tile("Queue drops", "\(session.counters.queueDrops)")
                tile("Write failures", "\(session.counters.writeFailures)")
                tile("Reconnects", "\(session.reconnects)")
                tile("Track points", "\(session.track.count)")
                tile("OBD data", session.obdReceived ? "Yes" : "No")
                tile("Device driving", session.deviceReportedDriving ? "Yes" : "No")
                tile("Classification", session.quality.rawValue.capitalized)
            }
            .padding(.top, 4)
        }

        if session.lifecycle != .closed {
            GroupBox {
                HStack {
                    Image(systemName: "info.circle")
                    Text("This session is \(session.lifecycle.rawValue). Statistics are provisional.")
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func serverSection(_ trip: TripSnapshot) -> some View {
        GroupBox("Server Trip") {
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                tile("Duration", formatDuration(trip.durationSeconds))
                if let speed = trip.maxSpeedKph { tile("Max speed", "\(speed) km/h") }
                if let rpm = trip.maxRpm { tile("Max RPM", "\(rpm)") }
                tile("OBD samples", "\(trip.obdSamples)")
                tile("GNSS samples", "\(trip.gnssSamples)")
                tile("Fix samples", "\(trip.fixSamples)")
                tile("Phone samples", "\(trip.phoneSamples)")
                tile("GNSS gaps", "\(trip.gapCount) (\(formatDuration(trip.gnssGapSeconds)))")
            }
            .padding(.top, 4)
        }
    }

    @ViewBuilder
    private func eventTimeline(_ session: DriveSession) -> some View {
        GroupBox("Link Events") {
            LazyVStack(alignment: .leading, spacing: 8) {
                ForEach(Array(session.events.enumerated()), id: \.offset) { _, event in
                    HStack(spacing: 10) {
                        Circle()
                            .fill(eventColor(event.kind))
                            .frame(width: 8, height: 8)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(event.kind.rawValue.replacingOccurrences(of: "bluetooth", with: "BT "))
                                .font(.caption.weight(.medium))
                            if let detail = event.detail {
                                Text(detail)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        Text(event.at, style: .time)
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.top, 4)
        }
    }

    private func tile(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.callout.weight(.semibold).monospacedDigit())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func eventColor(_ kind: LinkEventKind) -> Color {
        switch kind {
        case .ready, .armed, .streamingResumed: .green
        case .dropped, .streamingLost, .bluetoothUnavailable: .orange
        case .failed: .red
        case .disarmed: .secondary
        }
    }
}

// MARK: - Merge

enum HistoryMerger {
    static func merge(sessions: [DriveSession], trips: [TripSnapshot]) -> [HistoryEntry] {
        var entries: [HistoryEntry] = sessions.map { HistoryEntry(phoneSession: $0) }
        var matchedTrips: Set<String> = []
        for i in entries.indices {
            guard let session = entries[i].phoneSession else { continue }
            if let trip = trips.first(where: { matchesTime(session: session, trip: $0) && !matchedTrips.contains($0.id) }) {
                entries[i] = HistoryEntry(phoneSession: session, serverTrip: trip)
                matchedTrips.insert(trip.id)
            }
        }
        for trip in trips where !matchedTrips.contains(trip.id) {
            entries.append(HistoryEntry(serverTrip: trip))
        }
        entries.sort { $0.startedAt > $1.startedAt }
        return entries
    }

    private static func matchesTime(session: DriveSession, trip: TripSnapshot) -> Bool {
        guard let tripEnd = trip.endedAt else { return false }
        let sessionEnd = session.closedAt ?? session.lastObservedAt
        let overlapStart = max(session.startedAt, trip.startedAt)
        let overlapEnd = min(sessionEnd, tripEnd)
        let overlap = overlapEnd.timeIntervalSince(overlapStart)
        let sessionDuration = sessionEnd.timeIntervalSince(session.startedAt)
        guard sessionDuration > 0 else { return false }
        return overlap / sessionDuration > 0.5
    }
}

// MARK: - Formatting

private func formatDuration(_ seconds: TimeInterval) -> String {
    let s = Int(max(0, seconds).rounded())
    if s < 60 { return "\(s)s" }
    if s < 3600 { return "\(s / 60)m \(s % 60)s" }
    return "\(s / 3600)h \(String(format: "%02d", (s % 3600) / 60))m"
}

private func formatDistance(_ meters: Double) -> String {
    if meters < 1000 { return "\(Int(meters))m" }
    return String(format: "%.1f km", meters / 1000)
}
