import CairnCore
import SwiftUI

public struct SettingsView: View {
    let session: DrivingSession
    let vehicleStore: GRDBVehicleStore
    let maintenanceStore: GRDBMaintenanceStore
    let syncClient: TripSyncClient
    @State private var serverURL: String = ""
    @State private var showDeleteConfirm = false
    @State private var vehicles: [Vehicle] = []
    @State private var selectedVehicleID: String?
    @State private var showAddVehicle = false
    @State private var showAddMaintenance = false
    @State private var showRecordOdometer = false
    @State private var maintenanceEntries: [MaintenanceEntry] = []
    @State private var latestOdometer: OdometerCorrection?

    public init(session: DrivingSession, vehicleStore: GRDBVehicleStore, maintenanceStore: GRDBMaintenanceStore, syncClient: TripSyncClient) {
        self.session = session
        self.vehicleStore = vehicleStore
        self.maintenanceStore = maintenanceStore
        self.syncClient = syncClient
    }

    public var body: some View {
        NavigationStack {
            Form {
                vehicleSection
                maintenanceSection
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
            .task { await loadMaintenance() }
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
            .sheet(isPresented: $showAddMaintenance) {
                if let vid = selectedVehicleID {
                    AddMaintenanceSheet(vehicleID: vid) { entry in
                        Task {
                            try? await maintenanceStore.saveEntry(entry)
                            await loadMaintenance()
                        }
                    }
                }
            }
            .sheet(isPresented: $showRecordOdometer) {
                if let vid = selectedVehicleID {
                    RecordOdometerSheet(vehicleID: vid) { correction in
                        Task {
                            try? await maintenanceStore.saveOdometerCorrection(correction)
                            await loadMaintenance()
                        }
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

    // MARK: - Maintenance

    @ViewBuilder
    private var maintenanceSection: some View {
        Section {
            if let odo = latestOdometer {
                LabeledContent("Odometer", value: odo.formatted())
            }

            if maintenanceEntries.isEmpty {
                Text("No maintenance logged")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(maintenanceEntries.prefix(5)) { entry in
                    HStack {
                        Image(systemName: entry.category.systemImage)
                            .foregroundStyle(.secondary)
                            .frame(width: 24)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.title)
                            HStack(spacing: 8) {
                                Text(entry.performedAt, style: .date)
                                if let cost = entry.formattedCost {
                                    Text(cost)
                                }
                            }
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                    }
                }
                .onDelete { indexSet in
                    Task {
                        for i in indexSet {
                            let limited = Array(maintenanceEntries.prefix(5))
                            guard i < limited.count else { continue }
                            try? await maintenanceStore.deleteEntry(limited[i].id)
                        }
                        await loadMaintenance()
                    }
                }
            }

            Button {
                showAddMaintenance = true
            } label: {
                Label("Log Service", systemImage: "wrench.and.screwdriver")
            }
            .disabled(selectedVehicleID == nil)

            Button {
                showRecordOdometer = true
            } label: {
                Label("Record Odometer", systemImage: "gauge.with.dots.needle.67percent")
            }
            .disabled(selectedVehicleID == nil)
        } header: {
            Text("Maintenance")
        } footer: {
            if selectedVehicleID == nil {
                Text("Select a vehicle to log maintenance.")
            }
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

    private func loadMaintenance() async {
        guard let vid = selectedVehicleID else {
            maintenanceEntries = []
            latestOdometer = nil
            return
        }
        maintenanceEntries = (try? await maintenanceStore.listEntries(vehicleID: vid)) ?? []
        latestOdometer = try? await maintenanceStore.latestOdometer(vehicleID: vid)
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

// MARK: - Add Maintenance Sheet

private struct AddMaintenanceSheet: View {
    let vehicleID: String
    let onSave: (MaintenanceEntry) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var category: MaintenanceCategory = .oilChange
    @State private var title: String = ""
    @State private var notes: String = ""
    @State private var costString: String = ""
    @State private var shop: String = ""
    @State private var odometerString: String = ""
    @State private var performedAt: Date = Date()

    var body: some View {
        NavigationStack {
            Form {
                Section("Service") {
                    Picker("Category", selection: $category) {
                        ForEach(MaintenanceCategory.allCases, id: \.self) { cat in
                            Label(cat.displayName, systemImage: cat.systemImage)
                                .tag(cat)
                        }
                    }
                    TextField("Title", text: $title)
                    DatePicker("Date", selection: $performedAt, displayedComponents: .date)
                }
                Section("Details") {
                    TextField("Cost", text: $costString)
                        #if os(iOS)
                        .keyboardType(.decimalPad)
                        #endif
                    TextField("Shop / location", text: $shop)
                    TextField("Odometer (km)", text: $odometerString)
                        #if os(iOS)
                        .keyboardType(.numberPad)
                        #endif
                }
                Section("Notes") {
                    TextField("Notes", text: $notes, axis: .vertical)
                        .lineLimit(3...6)
                }
            }
            .navigationTitle("Log Service")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        let entry = MaintenanceEntry(
                            vehicleID: vehicleID,
                            category: category,
                            performedAt: performedAt,
                            title: title.isEmpty ? category.displayName : title,
                            notes: notes.isEmpty ? nil : notes,
                            cost: Decimal(string: costString),
                            shop: shop.isEmpty ? nil : shop,
                            odometerKm: Int(odometerString)
                        )
                        onSave(entry)
                        dismiss()
                    }
                }
            }
            .onChange(of: category) { _, newCat in
                if title.isEmpty || MaintenanceCategory.allCases.map(\.displayName).contains(title) {
                    title = newCat.displayName
                }
            }
            .onAppear { title = category.displayName }
        }
    }
}

// MARK: - Record Odometer Sheet

private struct RecordOdometerSheet: View {
    let vehicleID: String
    let onSave: (OdometerCorrection) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var odometerString: String = ""
    @State private var recordedAt: Date = Date()

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Odometer (km)", text: $odometerString)
                        #if os(iOS)
                        .keyboardType(.numberPad)
                        #endif
                    DatePicker("Date", selection: $recordedAt, displayedComponents: .date)
                } footer: {
                    if let km = Int(odometerString) {
                        let miles = Int(Double(km) * 0.621371)
                        Text("\(miles.formatted()) miles")
                    }
                }
            }
            .navigationTitle("Record Odometer")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        guard let km = Int(odometerString) else { return }
                        let correction = OdometerCorrection(
                            vehicleID: vehicleID,
                            odometerKm: km,
                            recordedAt: recordedAt
                        )
                        onSave(correction)
                        dismiss()
                    }
                    .disabled(Int(odometerString) == nil)
                }
            }
        }
    }
}
