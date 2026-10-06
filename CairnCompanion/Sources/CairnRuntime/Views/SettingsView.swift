import CairnCore
import SwiftUI

public struct SettingsView: View {
    let session: DrivingSession
    let syncClient: TripSyncClient
    @State private var lanURL: String = ""
    @State private var tailnetURL: String = ""
    @State private var showDeleteConfirm = false
    @State private var showServerSetup = false
    @State private var isProbing = false

    public init(session: DrivingSession, syncClient: TripSyncClient) {
        self.session = session
        self.syncClient = syncClient
    }

    public var body: some View {
        NavigationStack {
            Form {
                serverSection
                if syncClient.hasServer {
                    diagnosticsSection
                    syncStatusSection
                }
                aboutSection
                dangerZone
            }
            .navigationTitle("Settings")
            .onAppear {
                lanURL = syncClient.lanURL
                tailnetURL = syncClient.tailnetURL
            }
        }
    }

    // MARK: - Server

    @ViewBuilder
    private var serverSection: some View {
        if syncClient.hasServer || showServerSetup {
            Section {
                VStack(alignment: .leading, spacing: 2) {
                    Text("LAN")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                    TextField("https://cairn.example.lan", text: $lanURL)
                        .textContentType(.URL)
                        .autocorrectionDisabled()
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                        #endif
                        .onSubmit { saveLAN() }
                        .onChange(of: lanURL) { _, _ in saveLAN() }
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text("Tailnet")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                    TextField("https://cairn.ts.net", text: $tailnetURL)
                        .textContentType(.URL)
                        .autocorrectionDisabled()
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                        #endif
                        .onSubmit { saveTailnet() }
                        .onChange(of: tailnetURL) { _, _ in saveTailnet() }
                }

                if syncClient.hasServer {
                    Button {
                        syncClient.sync()
                    } label: {
                        HStack {
                            Text("Sync Now")
                            Spacer()
                            if syncClient.state == .syncing {
                                ProgressView()
                            }
                        }
                    }
                    .disabled(syncClient.state == .syncing)
                }
            } header: {
                Text("Cairn Server")
            } footer: {
                Text("The LAN URL is tried first. If unreachable, the Tailnet URL is used as fallback. Both must point to the same server instance.")
            }
        } else {
            Section {
                HStack(spacing: 12) {
                    Image(systemName: "checkmark.shield.fill")
                        .font(.title2)
                        .foregroundStyle(.green)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Standalone Mode")
                            .font(.subheadline.weight(.semibold))
                        Text("All features work offline. Connect a server to sync trip data.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)

                Button {
                    showServerSetup = true
                } label: {
                    Label("Connect to Server", systemImage: "link")
                }
            } header: {
                Text("Server")
            }
        }
    }

    // MARK: - Diagnostics

    @ViewBuilder
    private var diagnosticsSection: some View {
        Section {
            HStack {
                Text("Active Route")
                Spacer()
                routeBadge(syncClient.activeRoute)
            }

            if let lan = syncClient.lastLANProbe {
                probeRow("LAN", probe: lan)
            }

            if let tailnet = syncClient.lastTailnetProbe {
                probeRow("Tailnet", probe: tailnet)
            }

            Button {
                isProbing = true
                Task {
                    await syncClient.probeEndpoints()
                    isProbing = false
                }
            } label: {
                HStack {
                    Text("Test Connection")
                    Spacer()
                    if isProbing {
                        ProgressView()
                    }
                }
            }
            .disabled(isProbing)
        } header: {
            Text("Diagnostics")
        }
    }

    @ViewBuilder
    private func routeBadge(_ route: TripSyncClient.Route) -> some View {
        HStack(spacing: 5) {
            Circle()
                .fill(routeColor(route))
                .frame(width: 7, height: 7)
            Text(route.rawValue)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(routeColor(route))
        }
    }

    private func routeColor(_ route: TripSyncClient.Route) -> Color {
        switch route {
        case .lan: .green
        case .tailnet: .blue
        case .unreachable: .red
        }
    }

    @ViewBuilder
    private func probeRow(_ label: String, probe: TripSyncClient.ProbeResult) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(.subheadline)
                if let error = probe.error {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .lineLimit(1)
                } else {
                    Text("\(probe.latencyMs) ms")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if probe.error == nil {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            } else {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.red)
            }
        }
    }

    // MARK: - Sync Status

    @ViewBuilder
    private var syncStatusSection: some View {
        Section("Sync Status") {
            if let manifest = syncClient.manifest {
                LabeledContent("Trips", value: "\(manifest.tripCount)")
                LabeledContent("Bundles", value: "\(manifest.bundleCount)")
                LabeledContent("Total rows", value: formattedCount(manifest.totalRows))
                LabeledContent("Server built") {
                    Text(manifest.builtAt, style: .relative)
                        .foregroundStyle(.secondary)
                }
                LabeledContent("Schema", value: "v\(manifest.schemaVersion)")
            }

            if let lastSync = syncClient.lastSyncAt {
                LabeledContent("Last synced") {
                    Text(lastSync, style: .relative)
                        .foregroundStyle(.secondary)
                }
            } else {
                LabeledContent("Last synced", value: "Never")
            }

            switch syncClient.state {
            case .idle: EmptyView()
            case .syncing:
                HStack {
                    ProgressView()
                    Text("Syncing...").foregroundStyle(.secondary)
                }
            case .failed(let msg):
                Label(msg, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
                    .font(.caption)
            }
        }
    }

    // MARK: - About

    @ViewBuilder
    private var aboutSection: some View {
        Section("About") {
            LabeledContent("App", value: "Cairn Companion")
            if let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String {
                LabeledContent("Version", value: version)
            }
            if let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String {
                LabeledContent("Build", value: build)
            }
        }
    }

    // MARK: - Danger Zone

    @ViewBuilder
    private var dangerZone: some View {
        Section {
            Button(role: .destructive) {
                showDeleteConfirm = true
            } label: {
                Label("Delete All History", systemImage: "trash")
            }
            .confirmationDialog("Delete all drive history?", isPresented: $showDeleteConfirm) {
                Button("Delete All", role: .destructive) {
                    Task {
                        try? await session.recorder.deleteAllSessions()
                    }
                }
            } message: {
                Text("This removes all phone-recorded sessions. Server data will re-sync on next download.")
            }

            Button {
                session.forgetDongle()
            } label: {
                Label("Forget Dongle", systemImage: "minus.circle")
                    .foregroundStyle(.red)
            }
        } header: {
            Text("Danger Zone")
        }
    }

    private func saveLAN() {
        syncClient.lanURL = lanURL.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func saveTailnet() {
        syncClient.tailnetURL = tailnetURL.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func formattedCount(_ n: Int) -> String {
        if n < 1000 { return "\(n)" }
        return String(format: "%.1fk", Double(n) / 1000)
    }
}
