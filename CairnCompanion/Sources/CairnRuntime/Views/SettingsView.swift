import CairnCore
import SwiftUI
import UniformTypeIdentifiers

public struct SettingsView: View {
    let session: DrivingSession
    let syncClient: TripSyncClient
    let dataPorter: DataPorter
    @State private var lanURL: String = ""
    @State private var tailnetURL: String = ""
    @State private var showDeleteConfirm = false
    @State private var showServerSetup = false
    @State private var isProbing = false
    @State private var showExportSheet = false
    @State private var showImportPicker = false
    @State private var exportPassphrase = ""
    @State private var importPassphrase = ""
    @State private var exportedFileURL: URL?
    @State private var showShareSheet = false
    @State private var importFileURL: URL?
    @State private var showImportPassphrase = false
    @State private var dataMessage: String?
    @State private var dataError: String?
    @State private var isExporting = false
    @State private var isImporting = false

    public init(session: DrivingSession, syncClient: TripSyncClient, dataPorter: DataPorter) {
        self.session = session
        self.syncClient = syncClient
        self.dataPorter = dataPorter
    }

    public var body: some View {
        NavigationStack {
            Form {
                bluetoothSection
                serverSection
                if syncClient.hasServer {
                    diagnosticsSection
                    syncStatusSection
                }
                dataSection
                aboutSection
                dangerZone
            }
            .navigationTitle("Settings")
            .onAppear {
                lanURL = syncClient.lanURL
                tailnetURL = syncClient.tailnetURL
            }
            .alert("Export", isPresented: $showExportSheet) {
                SecureField("Passphrase", text: $exportPassphrase)
                Button("Export") { performExport() }
                Button("Cancel", role: .cancel) { exportPassphrase = "" }
            } message: {
                Text("Enter a passphrase to encrypt the backup. You'll need it to restore.")
            }
            .alert("Import", isPresented: $showImportPassphrase) {
                SecureField("Passphrase", text: $importPassphrase)
                Button("Import") { performImport() }
                Button("Cancel", role: .cancel) { importPassphrase = ""; importFileURL = nil }
            } message: {
                Text("Enter the passphrase used when this backup was created.")
            }
            .alert("Done", isPresented: .init(get: { dataMessage != nil }, set: { if !$0 { dataMessage = nil } })) {
                Button("OK") { dataMessage = nil }
            } message: {
                Text(dataMessage ?? "")
            }
            .alert("Error", isPresented: .init(get: { dataError != nil }, set: { if !$0 { dataError = nil } })) {
                Button("OK") { dataError = nil }
            } message: {
                Text(dataError ?? "")
            }
            .fileImporter(isPresented: $showImportPicker, allowedContentTypes: [.data], allowsMultipleSelection: false) { result in
                switch result {
                case .success(let urls):
                    if let url = urls.first {
                        importFileURL = url
                        showImportPassphrase = true
                    }
                case .failure(let error):
                    dataError = error.localizedDescription
                }
            }
            #if os(iOS)
            .sheet(isPresented: $showShareSheet) {
                if let url = exportedFileURL {
                    ShareSheet(url: url)
                }
            }
            #endif
        }
    }

    // MARK: - Bluetooth

    @ViewBuilder
    private var bluetoothSection: some View {
        Section {
            NavigationLink {
                BluetoothSettingsView(session: session)
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "antenna.radiowaves.left.and.right")
                        .font(.body)
                        .foregroundStyle(.blue)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Bluetooth")
                            .font(.body)
                        Text(session.state.stage)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
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

    // MARK: - Data

    @ViewBuilder
    private var dataSection: some View {
        Section {
            Button {
                showExportSheet = true
            } label: {
                HStack {
                    Label("Export Data", systemImage: "square.and.arrow.up")
                    Spacer()
                    if isExporting { ProgressView() }
                }
            }
            .disabled(isExporting)

            Button {
                showImportPicker = true
            } label: {
                HStack {
                    Label("Import Data", systemImage: "square.and.arrow.down")
                    Spacer()
                    if isImporting { ProgressView() }
                }
            }
            .disabled(isImporting)
        } header: {
            Text("Data")
        } footer: {
            Text("Export creates an encrypted .cairnbackup file containing vehicles, maintenance, odometer readings, and annotations. Drive sessions are not included — they re-sync from the server.")
        }
    }

    private func performExport() {
        guard !exportPassphrase.isEmpty else {
            dataError = "Passphrase cannot be empty"
            return
        }
        isExporting = true
        let passphrase = exportPassphrase
        exportPassphrase = ""
        Task {
            do {
                let data = try await dataPorter.exportData(passphrase: passphrase)
                let fileName = "cairn-backup-\(Self.dateStamp()).cairnbackup"
                let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(fileName)
                try data.write(to: tempURL)
                exportedFileURL = tempURL
                isExporting = false
                #if os(iOS)
                showShareSheet = true
                #else
                dataMessage = "Exported to \(tempURL.lastPathComponent)"
                #endif
            } catch {
                isExporting = false
                dataError = error.localizedDescription
            }
        }
    }

    private func performImport() {
        guard let url = importFileURL else { return }
        guard !importPassphrase.isEmpty else {
            dataError = "Passphrase cannot be empty"
            return
        }
        isImporting = true
        let passphrase = importPassphrase
        importPassphrase = ""
        Task {
            do {
                let accessing = url.startAccessingSecurityScopedResource()
                defer { if accessing { url.stopAccessingSecurityScopedResource() } }
                let data = try Data(contentsOf: url)
                let summary = try await dataPorter.importData(data, passphrase: passphrase)
                isImporting = false
                importFileURL = nil
                dataMessage = "Imported \(summary.vehicles) vehicles, \(summary.maintenance) maintenance entries, \(summary.odometer) odometer readings, \(summary.annotations) annotations"
            } catch {
                isImporting = false
                importFileURL = nil
                dataError = error.localizedDescription
            }
        }
    }

    private static func dateStamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: Date())
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

#if os(iOS)
private struct ShareSheet: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
#endif
