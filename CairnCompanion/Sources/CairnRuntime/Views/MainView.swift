import CairnCore
import SwiftUI

/// The single Phase 1 screen: auto-connect switch, phone vs internal receiver, acceptance feedback.
public struct MainView: View {
    private let session: DrivingSession
    private let state: SessionState

    public init(session: DrivingSession) {
        self.session = session
        self.state = session.state
    }

    public var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                Header()
                StatusCard(state: state, session: session)
                if let message = state.locationMessage {
                    Banner(text: message)
                }
                PhoneCard(state: state)
                DeviceCard(state: state)
                AcceptanceCard(state: state)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 24)
        }
        .background(Backdrop().ignoresSafeArea())
        .scrollBounceBehavior(.basedOnSize)
        .animation(.smooth, value: state.stage)
    }
}

// MARK: - Header and status

private struct Header: View {
    var body: some View {
        HStack(spacing: 12) {
            CairnMark()
                .frame(width: 44, height: 44)
                .padding(6)
                .background(Color(red: 0.04, green: 0.15, blue: 0.19), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text("Cairn").font(.title.weight(.bold))
                Text("GPS companion").font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.top, 8)
    }
}

private struct StatusCard: View {
    let state: SessionState
    let session: DrivingSession

    private var tone: Tone {
        switch state.connection {
        case .idle: .neutral
        case .bluetoothUnavailable, .failed: .bad
        case .scanning, .connecting, .bonding: .warn
        case .ready: state.isStreaming ? .good : .warn
        }
    }

    private var symbol: String {
        switch state.connection {
        case .idle: "power"
        case .bluetoothUnavailable: "bolt.horizontal.circle"
        case .scanning: "dot.radiowaves.left.and.right"
        case .connecting, .bonding: "link"
        case .ready: state.isStreaming ? "location.fill" : "checkmark.seal.fill"
        case .failed: "exclamationmark.triangle.fill"
        }
    }

    var body: some View {
        Card {
            HStack(spacing: 14) {
                ZStack {
                    Circle().fill(tone.color.opacity(0.16))
                    Image(systemName: symbol)
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(tone.color)
                        .symbolEffect(.pulse, isActive: tone == .warn || tone == .good)
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
                }
                Spacer(minLength: 0)
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
        Card(title: "Device", subtitle: "Internal GNSS", symbol: "antenna.radiowaves.left.and.right") {
            if let q = state.deviceQuality {
                MetricGrid {
                    Metric("Fix type", ["none", "2D", "3D"][safe: Int(q.fixType)] ?? "?")
                    Metric("Satellites", q.satsUsed == 0xFF ? "unknown" : "\(q.satsUsed)")
                    Metric("HDOP", q.hdop.map { String(format: "%.2f", $0) } ?? "unknown")
                }
            } else {
                Placeholder("Not connected")
            }
        }
    }
}

private struct AcceptanceCard: View {
    let state: SessionState

    var body: some View {
        Card(title: "Acceptance", subtitle: "From the device", symbol: "checkmark.shield") {
            if let s = state.companionStatus {
                MetricGrid {
                    Metric("Last seq", "\(s.lastAcceptedSeq)")
                    Metric("Accepted", "\(s.acceptedCount)", tone: .good)
                    Metric("Rejected", "\(s.rejectedCount)", tone: s.rejectedCount > 0 ? .bad : .neutral)
                    Metric("Dropped", "\(s.queueDropCount)", tone: s.queueDropCount > 0 ? .warn : .neutral)
                }
            } else {
                Placeholder("No status from device")
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

private struct Card<Content: View>: View {
    var title: String?
    var subtitle: String?
    var symbol: String?
    @ViewBuilder var content: Content

    init(title: String? = nil, subtitle: String? = nil, symbol: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.subtitle = subtitle
        self.symbol = symbol
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
                }
            }
            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
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
        .background(Color(.tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
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
            Color(.systemGroupedBackground)
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
