import CairnCore
import SwiftUI

public struct RootView: View {
    private let session: DrivingSession
    private let vehicleStore: FileVehicleStore
    private let syncClient: TripSyncClient

    public init(session: DrivingSession, vehicleStore: FileVehicleStore, syncClient: TripSyncClient) {
        self.session = session
        self.vehicleStore = vehicleStore
        self.syncClient = syncClient
    }

    public var body: some View {
        TabView {
            MainView(session: session)
                .tabItem { Label("Live", systemImage: "location.fill") }
            HistoryView(recorder: session.recorder, vehicleStore: vehicleStore, syncClient: syncClient)
                .tabItem { Label("History", systemImage: "clock.arrow.circlepath") }
            SettingsView(session: session, vehicleStore: vehicleStore, syncClient: syncClient)
                .tabItem { Label("Settings", systemImage: "gear") }
        }
    }
}
