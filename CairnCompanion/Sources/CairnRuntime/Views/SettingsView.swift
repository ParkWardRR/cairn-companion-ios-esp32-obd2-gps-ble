import CairnCore
import SwiftUI

public struct SettingsView: View {
    let session: DrivingSession
    let vehicleStore: GRDBVehicleStore
    let syncClient: TripSyncClient
    @State private var serverURL: String = ""
    @State private var showDeleteConfirm = false
    @State private var vehicles: [Vehicle] = []
    @State private var selectedVehicleID: String?
    @State private var showAddVehicle = false

    public init(session: DrivingSession, vehicleStore: GRDBVehicleStore, syncClient: TripSyncClient) {
        self.session = session
        self.vehicleStore = vehicleStore
        self.syncClient = syncClient
    }

    public var body: some View {
        NavigationStack {
            Form {
                vehicleSection
                serverSection
                syncStatusSection
                dangerZone
            }
            .navigationTitle("Settings")
            .onAppear {
                serverURL = syncClient.serverURL
                selectedVehicleID = vehicleStore.selectedVehicleID()
            }
            .task { await loadVehicles() }
            .sheet(isPresented: $showAddVehicle) {
                AddVehicleSheet { vehicle in
                    Task {
                        try? await vehicleStore.saveVehicle(vehicle)
                        vehicleStore.selectVehicle(vehicle.id)
                        selectedVehicleID = vehicle.id
                        await loadVehicles()
                    }
                }
            }
        }
    }

    // MARK: - Vehicles

    @ViewBuilder
    private var vehicleSection: some View {
        Section {
            if vehicles.isEmpty {
                Text("No vehicles configured")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(vehicles.filter { !$0.isArchived }) { vehicle in
                    Button {
                        selectedVehicleID = vehicle.id
                        vehicleStore.selectVehicle(vehicle.id)
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(vehicle.displayName)
                                    .foregroundStyle(.primary)
                            }
                            Spacer()
                            if selectedVehicleID == vehicle.id {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(Color.accentColor)
                            }
                        }
                    }
                    .swipeActions(edge: .trailing) {
                        Button {
                            Task {
                                var archived = vehicle
                                archived.isArchived = true
                                try? await vehicleStore.saveVehicle(archived)
                                await loadVehicles()
                            }
                        } label: {
                            Label("Archive", systemImage: "archivebox")
                        }
                        .tint(.orange)
                    }
                }

                let archived = vehicles.filter { $0.isArchived }
                if !archived.isEmpty {
                    DisclosureGroup("Archived") {
                        ForEach(archived) { vehicle in
                            HStack {
                                Text(vehicle.displayName)
                                    .foregroundStyle(.secondary)
                                Spacer()
                                Button {
                                    Task {
                                        var restored = vehicle
                                        restored.isArchived = false
                                        try? await vehicleStore.saveVehicle(restored)
                                        await loadVehicles()
                                    }
                                } label: {
                                    Text("Restore")
                                        .font(.caption)
                                }
                            }
                        }
                    }
                }
            }

            Button {
                showAddVehicle = true
            } label: {
                Label("Add Vehicle", systemImage: "plus.circle")
            }
        } header: {
            Text("Vehicles")
        } footer: {
            Text("Select the active vehicle. Drive sessions are recorded against the selected vehicle.")
        }
    }

    // MARK: - Server

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

    private func loadVehicles() async {
        vehicles = (try? await vehicleStore.listVehicles()) ?? []
    }
}

// MARK: - Add Vehicle Sheet

private struct AddVehicleSheet: View {
    let onSave: (Vehicle) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var year: String = ""
    @State private var make: String = ""
    @State private var model: String = ""
    @State private var engineCode: String = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Year", text: $year)
                        #if os(iOS)
                        .keyboardType(.numberPad)
                        #endif
                    TextField("Make", text: $make)
                    TextField("Model", text: $model)
                    TextField("Engine code (optional)", text: $engineCode)
                }
                Section {
                    if let preview = previewName {
                        Text(preview)
                            .font(.headline)
                    }
                }
            }
            .navigationTitle("Add Vehicle")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        guard let y = Int(year), !make.isEmpty, !model.isEmpty else { return }
                        let vehicle = Vehicle(
                            year: y, make: make, model: model,
                            engineCode: engineCode.isEmpty ? nil : engineCode
                        )
                        onSave(vehicle)
                        dismiss()
                    }
                    .disabled(Int(year) == nil || make.isEmpty || model.isEmpty)
                }
            }
        }
    }

    private var previewName: String? {
        guard let y = Int(year), !make.isEmpty, !model.isEmpty else { return nil }
        var parts = ["\(y)", make, model]
        if !engineCode.isEmpty { parts.append("— \(engineCode)") }
        return parts.joined(separator: " ")
    }
}
