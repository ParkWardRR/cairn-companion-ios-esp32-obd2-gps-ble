import CairnRuntime
import SwiftUI

@main
struct CairnCompanionApp: App {
    private let session: DrivingSession

    init() {
        let state = SessionState()
        session = DrivingSession(state: state, ble: CairnBLEManager(state: state))
        session.resumeIfEnabled()
    }

    var body: some Scene {
        WindowGroup { MainView(session: session) }
    }
}
