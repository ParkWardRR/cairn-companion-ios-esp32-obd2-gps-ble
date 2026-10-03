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
        List {
            Section {
                Toggle("Auto-connect to Cairn", isOn: Binding(
                    get: { state.isArmed },
                    set: { $0 ? session.arm() : session.disarm() }
                ))
                LabeledContent("Connection", value: state.stage)
                if let message = state.locationMessage {
                    Text(message).foregroundStyle(.orange)
                }
            }
            Section("Phone (Core Location)") { GPSComparisonView.phone(state: state) }
            Section("Device (internal GNSS)") { GPSComparisonView.device(state: state) }
            Section("Device acceptance") { GPSComparisonView.acceptance(state: state) }
        }
    }
}

/// Row groups for the phone-versus-internal comparison. Satellite count and constellation are
/// deliberately absent: Core Location does not expose them.
@MainActor
enum GPSComparisonView {
    @ViewBuilder
    static func phone(state: SessionState) -> some View {
        if let fix = state.phoneFix {
            let age = max(0, Date().timeIntervalSince(fix.timestamp))
            LabeledContent("Accuracy", value: fix.horizontalAccuracy >= 0 ? "\(Int(fix.horizontalAccuracy.rounded())) m" : "invalid")
            LabeledContent("Fix age", value: String(format: "%.1f s", age))
            LabeledContent("Speed", value: fix.speed >= 0 ? String(format: "%.1f m/s", fix.speed) : "unavailable")
            LabeledContent("Sent / dropped", value: "\(state.sentCount) / \(state.droppedCount)")
        } else {
            Text("No fix yet").foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    static func device(state: SessionState) -> some View {
        if let q = state.deviceQuality {
            LabeledContent("Fix type", value: ["none", "2D", "3D"][safe: Int(q.fixType)] ?? "?")
            LabeledContent("Satellites used", value: q.satsUsed == 0xFF ? "unknown" : "\(q.satsUsed)")
            LabeledContent("HDOP", value: q.hdop.map { String(format: "%.2f", $0) } ?? "unknown")
        } else {
            Text("Not connected").foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    static func acceptance(state: SessionState) -> some View {
        if let s = state.companionStatus {
            LabeledContent("Last accepted seq", value: "\(s.lastAcceptedSeq)")
            LabeledContent("Accepted", value: "\(s.acceptedCount)")
            LabeledContent("Rejected", value: "\(s.rejectedCount)")
            LabeledContent("Dropped", value: "\(s.queueDropCount)")
        } else {
            Text("No status from device").foregroundStyle(.secondary)
        }
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
