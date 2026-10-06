import CairnCore
import SwiftUI

public struct RootView: View {
    private let session: DrivingSession
    private let vehicleStore: GRDBVehicleStore
    private let maintenanceStore: GRDBMaintenanceStore
    private let syncClient: TripSyncClient

    public init(session: DrivingSession, vehicleStore: GRDBVehicleStore, maintenanceStore: GRDBMaintenanceStore, syncClient: TripSyncClient) {
        self.session = session
        self.vehicleStore = vehicleStore
        self.maintenanceStore = maintenanceStore
        self.syncClient = syncClient
    }

    public var body: some View {
        TabView {
            MainView(session: session)
                .tabItem { Label("Drive", systemImage: "location.fill") }
            HistoryView(recorder: session.recorder, vehicleStore: vehicleStore, maintenanceStore: maintenanceStore, syncClient: syncClient)
                .tabItem { Label("History", systemImage: "clock.arrow.circlepath") }
            GarageView(vehicleStore: vehicleStore, maintenanceStore: maintenanceStore, recorder: session.recorder)
                .tabItem { Label("Garage", systemImage: "building.2") }
            SettingsView(session: session, syncClient: syncClient)
                .tabItem { Label("Settings", systemImage: "gear") }
        }
    }
}
