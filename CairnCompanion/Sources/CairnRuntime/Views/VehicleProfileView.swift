import CairnCore
import SwiftUI

struct VehicleProfileView: View {
    let vehicle: Vehicle
    let vehicleStore: GRDBVehicleStore
    let maintenanceStore: GRDBMaintenanceStore
    @State private var maintenanceEntries: [MaintenanceEntry] = []
    @State private var latestOdometer: OdometerCorrection?
    @State private var showAddMaintenance = false
    @State private var showRecordOdometer = false

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                identityCard
                odometerCard
                maintenanceCard
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 24)
        }
        .background(Backdrop().ignoresSafeArea())
        .navigationTitle(vehicle.displayName)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .automatic) {
                Menu {
                    Button { showAddMaintenance = true } label: {
                        Label("Log Service", systemImage: "wrench.and.screwdriver")
                    }
                    Button { showRecordOdometer = true } label: {
                        Label("Record Odometer", systemImage: "gauge.with.dots.needle.67percent")
                    }
                    Button {
                        vehicleStore.selectVehicle(vehicle.id)
                    } label: {
                        Label("Set as Active", systemImage: "checkmark.circle")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .task { await load() }
        .sheet(isPresented: $showAddMaintenance) {
            AddMaintenanceSheet(vehicleID: vehicle.id) { entry in
                Task {
                    try? await maintenanceStore.saveEntry(entry)
                    await load()
                }
            }
        }
        .sheet(isPresented: $showRecordOdometer) {
            RecordOdometerSheet(vehicleID: vehicle.id) { correction in
                Task {
                    try? await maintenanceStore.saveOdometerCorrection(correction)
                    await load()
                }
            }
        }
    }

    // MARK: - Identity

    @ViewBuilder
    private var identityCard: some View {
        Card(title: "Vehicle", symbol: "car.fill") {
            MetricGrid {
                Metric("Year", "\(vehicle.year)")
                Metric("Make", vehicle.make)
                Metric("Model", vehicle.model)
                if let code = vehicle.engineCode {
                    Metric("Engine", code)
                }
            }
        }
    }

    // MARK: - Odometer

    @ViewBuilder
    private var odometerCard: some View {
        Card(title: "Odometer", symbol: "gauge.with.dots.needle.67percent") {
            if let odo = latestOdometer {
                MetricGrid {
                    Metric("Reading", odo.formatted())
                    Metric("Recorded", odo.recordedAt.formatted(date: .abbreviated, time: .omitted))
                }
            } else {
                Placeholder("No odometer readings")
            }

            Button { showRecordOdometer = true } label: {
                Label("Record Reading", systemImage: "plus.circle")
                    .font(.subheadline.weight(.medium))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .tint(.accentColor)
        }
    }

    // MARK: - Maintenance Timeline

    @ViewBuilder
    private var maintenanceCard: some View {
        Card(title: "Maintenance", symbol: "wrench.and.screwdriver") {
            if maintenanceEntries.isEmpty {
                Placeholder("No maintenance logged")
            } else {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(maintenanceEntries) { entry in
                        maintenanceRow(entry)
                        if entry.id != maintenanceEntries.last?.id {
                            Divider().padding(.leading, 34)
                        }
                    }
                }
            }

            Button { showAddMaintenance = true } label: {
                Label("Log Service", systemImage: "plus.circle")
                    .font(.subheadline.weight(.medium))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .tint(.accentColor)
        }
    }

    @ViewBuilder
    private func maintenanceRow(_ entry: MaintenanceEntry) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: entry.category.systemImage)
                .font(.body)
                .foregroundStyle(.secondary)
                .frame(width: 24, height: 24)

            VStack(alignment: .leading, spacing: 2) {
                Text(entry.title)
                    .font(.subheadline.weight(.medium))
                HStack(spacing: 8) {
                    Text(entry.performedAt, style: .date)
                    if let cost = entry.formattedCost {
                        Text(cost).foregroundStyle(Color.accentColor)
                    }
                    if let shop = entry.shop {
                        Text(shop)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                if let notes = entry.notes {
                    Text(notes)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 8)
    }

    private func load() async {
        maintenanceEntries = (try? await maintenanceStore.listEntries(vehicleID: vehicle.id)) ?? []
        latestOdometer = try? await maintenanceStore.latestOdometer(vehicleID: vehicle.id)
    }
}

// MARK: - Add Maintenance Sheet

struct AddMaintenanceSheet: View {
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

struct RecordOdometerSheet: View {
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
