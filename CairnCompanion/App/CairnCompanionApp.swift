import CairnRuntime
import SwiftUI

@main
struct CairnCompanionApp: App {
    private let session: DrivingSession
    private let syncClient: TripSyncClient
    @Environment(\.scenePhase) private var scenePhase

    init() {
        let state = SessionState()
        let store = FileDriveStore()
        let recorder = DriveRecorder(store: store)
        let ble = CairnBLEManager(state: state)
        session = DrivingSession(state: state, ble: ble, recorder: recorder)
        syncClient = TripSyncClient()
        #if DEBUG
        if let scenario = DemoMode.scenario {
            DemoMode.apply(scenario, to: state)
            return
        }
        #endif
        session.resumeIfEnabled()
        Task { await syncClient.loadCachedSnapshot() }
        if syncClient.isStale { syncClient.sync() }
    }

    var body: some Scene {
        WindowGroup {
            #if DEBUG
            if let scale = DemoMode.scale {
                GeometryReader { proxy in
                    RootView(session: session, syncClient: syncClient)
                        .frame(width: proxy.size.width / scale, height: proxy.size.height / scale)
                        .scaleEffect(scale, anchor: .top)
                        .frame(width: proxy.size.width, height: proxy.size.height, alignment: .top)
                }
                .ignoresSafeArea(edges: .bottom)
            } else {
                RootView(session: session, syncClient: syncClient)
            }
            #else
            RootView(session: session, syncClient: syncClient)
            #endif
        }
        .onChange(of: scenePhase) { _, phase in
            session.log("scene \(phase)")
        }
    }
}
