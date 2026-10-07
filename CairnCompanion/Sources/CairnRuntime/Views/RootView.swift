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
    private let offload: OffloadController?
    @State private var showWelcome: Bool
    @State private var pendingLink: PendingLink?
    @State private var linkError: String?

    private struct PendingLink: Identifiable {
        let id = UUID()
        let link: ConfigureLink
    }

    public init(session: DrivingSession, vehicleStore: GRDBVehicleStore, maintenanceStore: GRDBMaintenanceStore, syncClient: TripSyncClient, dataPorter: DataPorter, enrolmentService: EnrolmentService? = nil, offload: OffloadController? = nil) {
        self.offload = offload
        self.session = session
        self.vehicleStore = vehicleStore
        self.maintenanceStore = maintenanceStore
        self.syncClient = syncClient
        self.dataPorter = dataPorter
        self.enrolmentService = enrolmentService
        _showWelcome = State(initialValue: !UserDefaults.standard.bool(forKey: Self.hasSeenWelcomeKey))
    }

    public var body: some View {
        content
            #if DEBUG
            .task {
                // Simulator has no camera and iOS asks "Open in Cairn?" for simctl openurl, so
                // let a test launch hand the link over directly: CAIRN_TEST_LINK=cairn://configure?...
                if let raw = ProcessInfo.processInfo.environment["CAIRN_TEST_LINK"], let url = URL(string: raw) {
                    pendingLink = (try? ConfigureLink.parse(url)).map(PendingLink.init)
                }
            }
            #endif
            .onOpenURL { url in
                do {
                    pendingLink = PendingLink(link: try ConfigureLink.parse(url))
                } catch {
                    linkError = "That link isn't a valid Cairn setup code. Ask for a new QR code."
                }
            }
            .sheet(item: $pendingLink) { pending in
                ConfigureLinkSheet(link: pending.link, syncClient: syncClient, enrolmentService: enrolmentService) {
                    pendingLink = nil
                }
            }
            .alert("Can't use this code", isPresented: .init(get: { linkError != nil }, set: { if !$0 { linkError = nil } })) {
                Button("OK") { linkError = nil }
            } message: {
                Text(linkError ?? "")
            }
    }

    @ViewBuilder
    private var content: some View {
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
                SettingsView(session: session, syncClient: syncClient, dataPorter: dataPorter, enrolmentService: enrolmentService, offload: offload)
                    .tabItem { Label("Settings", systemImage: "gear") }
            }
        }
    }
}
