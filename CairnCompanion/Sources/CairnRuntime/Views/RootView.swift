import CairnCore
import SwiftUI

public struct RootView: View {
    private static let hasSeenWelcomeKey = "cairn.hasSeenWelcome"

    private let session: DrivingSession
    private let vehicleStore: GRDBVehicleStore
    private let maintenanceStore: GRDBMaintenanceStore
    private let syncClient: TripSyncClient
    private let dataPorter: DataPorter
    private let enrolmentService: EnrolmentService?
    @State private var showWelcome: Bool

    public init(session: DrivingSession, vehicleStore: GRDBVehicleStore, maintenanceStore: GRDBMaintenanceStore, syncClient: TripSyncClient, dataPorter: DataPorter, enrolmentService: EnrolmentService? = nil) {
        self.session = session
        self.vehicleStore = vehicleStore
        self.maintenanceStore = maintenanceStore
        self.syncClient = syncClient
        self.dataPorter = dataPorter
        self.enrolmentService = enrolmentService
        _showWelcome = State(initialValue: !UserDefaults.standard.bool(forKey: Self.hasSeenWelcomeKey))
    }

    public var body: some View {
        if showWelcome {
            WelcomeView {
                UserDefaults.standard.set(true, forKey: Self.hasSeenWelcomeKey)
                withAnimation { showWelcome = false }
            }
        } else {
            TabView {
                MainView(session: session)
                    .tabItem { Label("Drive", systemImage: "location.fill") }
                HistoryView(recorder: session.recorder, vehicleStore: vehicleStore, maintenanceStore: maintenanceStore, syncClient: syncClient)
                    .tabItem { Label("History", systemImage: "clock.arrow.circlepath") }
                GarageView(vehicleStore: vehicleStore, maintenanceStore: maintenanceStore, recorder: session.recorder)
                    .tabItem { Label("Garage", systemImage: "building.2") }
                SettingsView(session: session, syncClient: syncClient, dataPorter: dataPorter, enrolmentService: enrolmentService)
                    .tabItem { Label("Settings", systemImage: "gear") }
            }
        }
    }
}
