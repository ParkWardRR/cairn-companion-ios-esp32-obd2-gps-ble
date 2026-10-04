import CairnCore
import SwiftUI

public struct RootView: View {
    private let session: DrivingSession
    private let syncClient: TripSyncClient

    public init(session: DrivingSession, syncClient: TripSyncClient) {
        self.session = session
        self.syncClient = syncClient
    }

    public var body: some View {
        TabView {
            MainView(session: session)
                .tabItem { Label("Live", systemImage: "location.fill") }
            HistoryView(recorder: session.recorder, syncClient: syncClient)
                .tabItem { Label("History", systemImage: "clock.arrow.circlepath") }
            SettingsView(session: session, syncClient: syncClient)
                .tabItem { Label("Settings", systemImage: "gear") }
        }
    }
}
