import CairnCore
import SwiftUI

/// The single Phase 1 screen: auto-connect switch, phone vs internal receiver, acceptance feedback.
public struct MainView: View {
    private let session: DrivingSession
    private let state: SessionState
    @State private var showingGuide = false

    public init(session: DrivingSession) {
        self.session = session
        self.state = session.state
    }

    public var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                Header(showingGuide: $showingGuide)
                StatusCard(state: state, session: session)
                if case .failed = state.connection {
                    PairingCard(state: state, session: session)
                }
                if let message = state.locationMessage {
                    Banner(text: message)
                }
                PhoneCard(state: state)
                DeviceCard(state: state)
                if state.obdLive != nil { TelemetryCard(state: state) }
                if state.deviceStatus != nil { DeviceHealthCard(state: state) }
                AcceptanceCard(state: state)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 24)
        }
        .background(Backdrop().ignoresSafeArea())
        .scrollBounceBehavior(.basedOnSize)
        .animation(.smooth, value: state.stage)
        .sheet(isPresented: $showingGuide) { ConnectionGuideView() }
    }
}

// MARK: - Header and status

private struct Header: View {
    @Binding var showingGuide: Bool

    var body: some View {
        HStack(spacing: 12) {
            CairnMark()
                .frame(width: 44, height: 44)
                .padding(6)
                .background(CairnMark.tile, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text("Cairn").font(.title.weight(.bold))
                Text("GPS companion").font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer()
            Button { showingGuide = true } label: {
                Image(systemName: "questionmark.circle")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.top, 8)
    }
}

private struct StatusCard: View {
    let state: SessionState
    let session: DrivingSession

    private func tone(now: Date) -> Tone {
        switch state.connection {
        case .idle: .neutral
        case .bluetoothUnavailable, .failed: .bad
        case .scanning, .connecting, .bonding: .warn
        case .ready:
            if state.isStreaming { .good }
            else if LinkHealth.freshness(lastHeard: state.lastStatusAt, now: now) == .silent { .bad }
            else { .warn }
        }
    }

    private var connectionHint: String? {
        switch state.connection {
        case .idle where !state.isArmed:
            return "Toggle auto-connect to begin"
        case .scanning:
            return "Make sure the dongle is powered on and nearby"
        case .bonding:
            return "Enter the 6-digit passkey if prompted"
        default:
            return nil
        }
    }

    private func symbol(now: Date) -> String {
        switch state.connection {
        case .idle: "power"
        case .bluetoothUnavailable: "bolt.horizontal.circle"
        case .scanning: "dot.radiowaves.left.and.right"
        case .connecting, .bonding: "link"
        case .ready:
            if state.isStreaming { "location.fill" }
            else if tone(now: now) == .bad { "wifi.exclamationmark" }
            else { "checkmark.seal.fill" }
        case .failed: "exclamationmark.triangle.fill"
        }
    }

    var body: some View {
        Card {
            TimelineView(.periodic(from: .now, by: 1)) { timeline in
                let now = timeline.date
                let tone = tone(now: now)
                HStack(spacing: 14) {
                    ZStack {
                        Circle().fill(tone.color.opacity(0.16))
                        HealthRing(state: state, tone: tone)
                        Image(systemName: symbol(now: now))
                            .font(.title2.weight(.semibold))
                            .foregroundStyle(tone.color)
                            .symbolEffect(.pulse, isActive: tone == .warn)
                            .symbolEffect(.bounce, value: state.lastStatusAt)
                            .contentTransition(.symbolEffect(.replace))
                    }
                    .frame(width: 52, height: 52)

                    VStack(alignment: .leading, spacing: 2) {
                        Text("CONNECTION")
                            .font(.caption2.weight(.semibold)).tracking(0.8)
                            .foregroundStyle(.secondary)
                        Text(state.stage)
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(tone == .bad ? tone.color : .primary)
                            .lineLimit(2)
                        if let detail = state.linkDetail(now: now) {
                            Text(detail)
                                .font(.footnote.monospacedDigit())
                                .foregroundStyle(.secondary)
                                .contentTransition(.numericText())
                        }
                        if let drops = state.dropSummary(now: now) {
                            Text(drops)
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(Tone.warn.color)
                        }
                        if let hint = connectionHint {
                            Text(hint)
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                    }
                    Spacer(minLength: 0)
                }
            }

            Divider()

            Toggle(isOn: Binding(
                get: { state.isArmed },
                set: { $0 ? session.arm() : session.disarm() }
            )) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Auto-connect to Cairn").font(.body.weight(.medium))
                    Text("Starts when the dongle powers up, stops when it drops.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .tint(.accentColor)
            .sensoryFeedback(.selection, trigger: state.isArmed)
        }
    }
}

private struct PairingCard: View {
    let state: SessionState
    let session: DrivingSession

    private var isStaleBond: Bool {
        if case .failed(let msg) = state.connection { return msg.hasPrefix("Stale pairing") }
        return false
    }

    var body: some View {
        Card(title: "Pairing", symbol: "lock.shield") {
            if isStaleBond {
                VStack(alignment: .leading, spacing: 10) {
                    Label("The dongle's pairing keys changed.", systemImage: "exclamationmark.triangle.fill")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(Tone.warn.color)
                    Text("To re-pair:")
                        .font(.footnote.weight(.medium))
                    VStack(alignment: .leading, spacing: 4) {
                        Label("Tap Forget Dongle below", systemImage: "1.circle.fill")
                        Label("Settings → Bluetooth → Cairn → Forget This Device", systemImage: "2.circle.fill")
                        Label("Toggle auto-connect back on", systemImage: "3.circle.fill")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    Button(role: .destructive) {
                        session.forgetDongle()
                    } label: {
                        Label("Forget Dongle", systemImage: "minus.circle")
                            .font(.body.weight(.medium))
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                }
            } else if case .failed(let msg) = state.connection {
                VStack(alignment: .leading, spacing: 8) {
                    Label(msg, systemImage: "exclamationmark.triangle.fill")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(Tone.bad.color)
                    Text("Toggle auto-connect off and back on to retry.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

/// Drains over the streaming window after each `COMPANION_STATUS`, so a link going quiet is visible
/// before "Streaming" flips. Refills on the next status.
private struct HealthRing: View {
    let state: SessionState
    let tone: Tone

    var body: some View {
        if state.connection == .ready, let last = state.lastStatusAt {
            TimelineView(.animation(minimumInterval: 0.1)) { timeline in
                let remaining = max(0, 1 - timeline.date.timeIntervalSince(last) / LinkHealth.liveWindow)
                Circle()
                    .trim(from: 0, to: remaining)
                    .stroke(tone.color, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .padding(2)
            }
        }
    }
}

private struct Banner: View {
    let text: String

    var body: some View {
        Label(text, systemImage: "location.slash.fill")
            .font(.subheadline.weight(.medium))
            .foregroundStyle(Tone.warn.color)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(Tone.warn.color.opacity(0.14), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

// MARK: - Data cards
// Satellite count and constellation are deliberately absent from the phone card: Core Location does not expose them.

private struct PhoneCard: View {
    let state: SessionState

    var body: some View {
        Card(title: "Phone", subtitle: "Core Location", symbol: "iphone") {
            if let fix = state.phoneFix {
                TimelineView(.periodic(from: .now, by: 0.5)) { timeline in
                    let age = max(0, timeline.date.timeIntervalSince(fix.timestamp))
                    MetricGrid {
                        Metric("Accuracy", fix.horizontalAccuracy >= 0 ? "\(Int(fix.horizontalAccuracy.rounded()))" : "invalid",
                               unit: fix.horizontalAccuracy >= 0 ? "m" : nil)
                        Metric("Fix age", String(format: "%.1f", age), unit: "s")
                        Metric("Speed", fix.speed >= 0 ? String(format: "%.1f", fix.speed) : "n/a",
                               unit: fix.speed >= 0 ? "m/s" : nil)
                        Metric("Sent / dropped", "\(state.sentCount) / \(state.droppedCount)")
                    }
                }
            } else {
                Placeholder("No fix yet")
            }
        }
    }
}

private struct DeviceCard: View {
    let state: SessionState

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { timeline in
            let now = timeline.date
            Card(title: "Device", subtitle: "Internal GNSS", symbol: "antenna.radiowaves.left.and.right",
                 badge: Badge.heard(state.lastQualityAt, connected: state.connection == .ready, now: now)) {
                if let q = state.deviceQuality {
                    MetricGrid {
                        Metric("Fix type", ["none", "2D", "3D"][safe: Int(q.fixType)] ?? "?")
                        Metric("Satellites", q.satsUsed == 0xFF ? "unknown" : "\(q.satsUsed)")
                        Metric("HDOP", q.hdop.map { String(format: "%.2f", $0) } ?? "unknown")
                        Metric("Fix age", q.fixAgeMs < 0xFFFF_FFFF ? "\(q.fixAgeMs)" : "—", unit: q.fixAgeMs < 0xFFFF_FFFF ? "ms" : nil)
                    }
                    .opacity(state.isLive(lastHeard: state.lastQualityAt, now: now) ? 1 : 0.45)
                } else {
                    Placeholder("Not connected")
                }
            }
        }
    }
}

private struct TelemetryCard: View {
    let state: SessionState

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { timeline in
            let now = timeline.date
            Card(title: "Live Telemetry", subtitle: "OBD-II", symbol: "gauge.open.with.lines.needle.33percent",
                 badge: Badge.heard(state.lastOBDAt, connected: state.connection == .ready, now: now)) {
                if let obd = state.obdLive {
                    let live = state.isLive(lastHeard: state.lastOBDAt, now: now)
                    MetricGrid {
                        Metric("RPM", obd.hasRPM ? "\(obd.rpm)" : "—")
                        Metric("Speed", obd.speedKph.map { String(format: "%.0f", $0) } ?? "—", unit: obd.hasSpeed ? "km/h" : nil)
                        Metric("Throttle", obd.hasThrottle ? "\(obd.throttlePct)" : "—", unit: obd.hasThrottle ? "%" : nil)
                        Metric("Coolant", obd.hasCoolant ? "\(obd.coolantTempC)" : "—", unit: obd.hasCoolant ? "°C" : nil)
                        Metric("Intake", obd.hasIntakeTemp ? "\(obd.intakeTempC)" : "—", unit: obd.hasIntakeTemp ? "°C" : nil)
                        Metric("Boost", obd.boostKpa.map { String(format: "%.1f", $0) } ?? "—", unit: obd.hasBoost ? "kPa" : nil)
                    }
                    .opacity(live ? 1 : 0.45)
                    if obd.stft1 != nil || obd.ltft1 != nil {
                        Divider()
                        MetricGrid {
                            if let v = obd.stft1 { Metric("STFT B1", String(format: "%+.1f", v), unit: "%",
                                                          tone: abs(v) > 10 ? .warn : .neutral) }
                            if let v = obd.ltft1 { Metric("LTFT B1", String(format: "%+.1f", v), unit: "%",
                                                          tone: abs(v) > 10 ? .warn : .neutral) }
                            if let v = obd.stft2 { Metric("STFT B2", String(format: "%+.1f", v), unit: "%",
                                                          tone: abs(v) > 10 ? .warn : .neutral) }
                            if let v = obd.ltft2 { Metric("LTFT B2", String(format: "%+.1f", v), unit: "%",
                                                          tone: abs(v) > 10 ? .warn : .neutral) }
                        }
                        .opacity(live ? 1 : 0.45)
                    }
                } else {
                    Placeholder("No OBD data")
                }
            }
        }
    }
}

private struct DeviceHealthCard: View {
    let state: SessionState

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { timeline in
            let now = timeline.date
            Card(title: "Device", subtitle: "Health", symbol: "cpu",
                 badge: Badge.heard(state.lastDeviceStatusAt, connected: state.connection == .ready, now: now)) {
                if let ds = state.deviceStatus {
                    let live = state.isLive(lastHeard: state.lastDeviceStatusAt, now: now)
                    MetricGrid {
                        Metric("Trip", ds.tripPhase.label)
                        Metric("Battery", ds.batteryV.map { String(format: "%.1f", $0) } ?? "—", unit: ds.batteryV != nil ? "V" : nil,
                               tone: ds.batteryMv != 0xFFFF && ds.batteryMv < 11500 ? .warn : .neutral)
                        Metric("SD free", ds.sdFree.map { "\($0)" } ?? "—", unit: ds.sdFree != nil ? "MB" : nil,
                               tone: ds.sdFree.map { $0 < 100 } == true ? .warn : .neutral)
                        Metric("Uptime", formatUptime(ds.uptimeS))
                    }
                    .opacity(live ? 1 : 0.45)
                } else {
                    Placeholder("No device status")
                }
            }
        }
    }

    private func formatUptime(_ seconds: UInt32) -> String {
        if seconds >= 3600 {
            return "\(seconds / 3600)h \((seconds % 3600) / 60)m"
        } else if seconds >= 60 {
            return "\(seconds / 60)m \(seconds % 60)s"
        }
        return "\(seconds)s"
    }
}

private extension DeviceStatus.TripPhase {
    var label: String {
        switch self {
        case .idle: "Idle"
        case .driving: "Driving"
        case .paused: "Paused"
        case .unknown: "Unknown"
        }
    }
}

private struct AcceptanceCard: View {
    let state: SessionState

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { timeline in
            let now = timeline.date
            Card(title: "Acceptance", subtitle: "From the device", symbol: "checkmark.shield",
                 badge: Badge.heard(state.lastStatusAt, connected: state.connection == .ready, now: now)) {
                if let s = state.companionStatus {
                    let live = state.isLive(lastHeard: state.lastStatusAt, now: now)
                    let unacked = LinkHealth.unacked(sent: state.sentCount, status: s)
                    MetricGrid {
                        Metric("Last seq", "\(s.lastAcceptedSeq)")
                        Metric("Accepted", "\(s.acceptedCount)", tone: .good)
                        Metric("Rejected", "\(s.rejectedCount)", tone: s.rejectedCount > 0 ? .bad : .neutral)
                        Metric("Dropped", "\(s.queueDropCount)", tone: s.queueDropCount > 0 ? .warn : .neutral)
                        if live {
                            Metric("Unacked", "\(unacked)", tone: unacked >= LinkHealth.unackedWarning ? .warn : .neutral)
                        }
                    }
                    .opacity(live ? 1 : 0.45)
                } else {
                    Placeholder("No status from device")
                }
            }
        }
    }
}

// MARK: - Building blocks

private enum Tone {
    case neutral, good, warn, bad

    var color: Color {
        switch self {
        case .neutral: .secondary
        case .good: .green
        case .warn: .orange
        case .bad: .red
        }
    }
}

/// Freshness chip in a card header: a dot and how long ago the channel was last heard.
private struct Badge: View {
    let text: String
    let tone: Tone

    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(tone.color).frame(width: 7, height: 7)
            Text(text).font(.caption.weight(.medium).monospacedDigit())
        }
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(tone.color.opacity(0.14), in: Capsule())
        .foregroundStyle(tone == .neutral ? Color.secondary : tone.color)
        .accessibilityElement(children: .combine)
    }

    /// Nil until the channel has been heard at all. Once the link is down the text reads "as of", not "heard".
    static func heard(_ lastHeard: Date?, connected: Bool, now: Date) -> Badge? {
        guard let lastHeard else { return nil }
        let age = LinkHealth.ageLabel(now.timeIntervalSince(lastHeard))
        if !connected { return Badge(text: "As of \(age) ago", tone: .bad) }
        switch LinkHealth.freshness(lastHeard: lastHeard, now: now) {
        case .live: return Badge(text: "Live", tone: .good)
        case .stale: return Badge(text: "Heard \(age) ago", tone: .warn)
        case .silent: return Badge(text: "Silent \(age)", tone: .bad)
        case .never: return nil
        }
    }
}

private struct Card<Content: View>: View {
    var title: String?
    var subtitle: String?
    var symbol: String?
    var badge: Badge?
    @ViewBuilder var content: Content

    init(
        title: String? = nil, subtitle: String? = nil, symbol: String? = nil, badge: Badge? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.subtitle = subtitle
        self.symbol = symbol
        self.badge = badge
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let title {
                HStack(spacing: 10) {
                    if let symbol {
                        Image(systemName: symbol)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Color.accentColor)
                            .frame(width: 30, height: 30)
                            .background(Color.accentColor.opacity(0.14), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                    }
                    Text(title).font(.headline)
                    if let subtitle {
                        Text(subtitle).font(.subheadline).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    if let badge { badge }
                }
            }
            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.cardSurface, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(Color.primary.opacity(0.06)))
        .shadow(color: .black.opacity(0.06), radius: 10, y: 4)
    }
}

private struct MetricGrid<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
            content
        }
    }
}

private struct Metric: View {
    let label: String
    let value: String
    var unit: String?
    var tone: Tone = .neutral

    init(_ label: String, _ value: String, unit: String? = nil, tone: Tone = .neutral) {
        self.label = label
        self.value = value
        self.unit = unit
        self.tone = tone
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(value)
                    .font(.title3.weight(.semibold).monospacedDigit())
                    .foregroundStyle(tone == .neutral ? Color.primary : tone.color)
                    .contentTransition(.numericText())
                    .minimumScaleFactor(0.7)
                    .lineLimit(1)
                if let unit {
                    Text(unit).font(.caption.weight(.medium)).foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color.tileSurface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

private struct Placeholder: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .center)
    }
}

/// Grouped-background wash with a faint accent glow at the top, matching the icon.
private struct Backdrop: View {
    var body: some View {
        ZStack(alignment: .top) {
            Color.pageSurface
            RadialGradient(
                colors: [Color.accentColor.opacity(0.18), .clear],
                center: .top, startRadius: 0, endRadius: 360
            )
        }
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}

/// Grouped-list surfaces on iOS; the macOS equivalents only keep the package building for `swift test`.
private extension Color {
    #if canImport(UIKit)
    static let pageSurface = Color(.systemGroupedBackground)
    static let cardSurface = Color(.secondarySystemGroupedBackground)
    static let tileSurface = Color(.tertiarySystemGroupedBackground)
    #else
    static let pageSurface = Color(nsColor: .windowBackgroundColor)
    static let cardSurface = Color(nsColor: .controlBackgroundColor)
    static let tileSurface = Color(nsColor: .underPageBackgroundColor)
    #endif
}
