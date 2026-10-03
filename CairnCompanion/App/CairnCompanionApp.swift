import CairnRuntime
import SwiftUI

@main
struct CairnCompanionApp: App {
    private let session: DrivingSession

    init() {
        let state = SessionState()
        session = DrivingSession(state: state, ble: CairnBLEManager(state: state))
        #if DEBUG
        if let scenario = DemoMode.scenario {
            DemoMode.apply(scenario, to: state)
            return
        }
        #endif
        session.resumeIfEnabled()
    }

    var body: some Scene {
        WindowGroup {
            #if DEBUG
            if let scale = DemoMode.scale {
                // Fits the whole page on one screenshot: lay out on a taller canvas, then shrink it.
                GeometryReader { proxy in
                    MainView(session: session)
                        .frame(width: proxy.size.width / scale, height: proxy.size.height / scale)
                        .scaleEffect(scale, anchor: .top)
                        .frame(width: proxy.size.width, height: proxy.size.height, alignment: .top)
                }
                .ignoresSafeArea(edges: .bottom)
            } else {
                MainView(session: session)
            }
            #else
            MainView(session: session)
            #endif
        }
    }
}
