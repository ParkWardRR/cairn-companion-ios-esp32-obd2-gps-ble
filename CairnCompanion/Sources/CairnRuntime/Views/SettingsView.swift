import CairnCore
import SwiftUI

public struct SettingsView: View {
    let session: DrivingSession
    let syncClient: TripSyncClient
    @State private var serverURL: String = ""
    @State private var showDeleteConfirm = false

    public init(session: DrivingSession, syncClient: TripSyncClient) {
        self.session = session
        self.syncClient = syncClient
    }

    public var body: some View {
        NavigationStack {
            Form {
                serverSection
                syncStatusSection
                dangerZone
            }
            .navigationTitle("Settings")
            .onAppear { serverURL = syncClient.serverURL }
        }
    }

    @ViewBuilder
    private var serverSection: some View {
        Section {
            TextField("https://your-cairn-server", text: $serverURL)
                .textContentType(.URL)
                .autocorrectionDisabled()
                #if os(iOS)
                .textInputAutocapitalization(.never)
                .keyboardType(.URL)
                #endif
                .onSubmit { saveURL() }
                .onChange(of: serverURL) { _, _ in saveURL() }

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
            .disabled(serverURL.isEmpty || syncClient.state == .syncing)
        } header: {
            Text("Cairn Server")
        } footer: {
            Text("The URL of your Cairn server. The app downloads a snapshot of your trip data for offline browsing.")
        }
    }

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

    private func saveURL() {
        let trimmed = serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
        syncClient.serverURL = trimmed
    }

    private func formattedCount(_ n: Int) -> String {
        if n < 1000 { return "\(n)" }
        return String(format: "%.1fk", Double(n) / 1000)
    }
}
