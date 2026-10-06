import CairnCore
import SwiftUI

public struct SettingsView: View {
    let session: DrivingSession
    let syncClient: TripSyncClient
    @State private var serverURL: String = ""
    @State private var showDeleteConfirm = false
    @State private var showServerSetup = false

    public init(session: DrivingSession, syncClient: TripSyncClient) {
        self.session = session
        self.syncClient = syncClient
    }

    public var body: some View {
        NavigationStack {
            Form {
                serverSection
                if syncClient.hasServer {
                    syncStatusSection
                }
                aboutSection
                dangerZone
            }
            .navigationTitle("Settings")
            .onAppear {
                serverURL = syncClient.serverURL
            }
        }
    }

    // MARK: - Server

    @ViewBuilder
    private var serverSection: some View {
        if syncClient.hasServer || showServerSetup {
            Section {
                TextField("https://cairn.example.lan", text: $serverURL)
                    .textContentType(.URL)
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.URL)
                    #endif
                    .onSubmit { saveURL() }
                    .onChange(of: serverURL) { _, _ in saveURL() }

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
                Text("Optional. Connect to your Cairn server to sync trip data. The app works fully offline without a server.")
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

    private func saveURL() {
        let trimmed = serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
        syncClient.serverURL = trimmed
    }

    private func formattedCount(_ n: Int) -> String {
        if n < 1000 { return "\(n)" }
        return String(format: "%.1fk", Double(n) / 1000)
    }
}
