import CairnCore
import CairnRuntime
import SwiftUI

@main
struct CairnCompanionApp: App {
    private let session: DrivingSession
    private let vehicleStore: GRDBVehicleStore
    private let maintenanceStore: GRDBMaintenanceStore
    private let syncClient: TripSyncClient
    private let dataPorter: DataPorter
    private let enrolmentService: EnrolmentService
    private let outboxStore: GRDBOutboxStore
    private let syncStateStore: GRDBSyncStateStore
    @Environment(\.scenePhase) private var scenePhase

    init() {
        let state = SessionState()
        let db = try! CairnDatabase()
        let driveStore = GRDBDriveStore(db: db)
        let vehicleStore = GRDBVehicleStore(db: db)
        let maintenanceStore = GRDBMaintenanceStore(db: db)
        let recorder = DriveRecorder(store: driveStore, vehicleStore: vehicleStore)
        let ble = CairnBLEManager(state: state)
        session = DrivingSession(state: state, ble: ble, recorder: recorder)
        self.vehicleStore = vehicleStore
        self.maintenanceStore = maintenanceStore
        self.dataPorter = DataPorter(db: db, vehicleStore: vehicleStore, maintenanceStore: maintenanceStore)
        syncClient = TripSyncClient()

        let keyProvider: any KeyProvider
        do {
            keyProvider = try SecureEnclaveKeyProvider()
        } catch {
            keyProvider = SoftwareKeyProvider()
        }
        let identityStore = KeychainIdentityStore()
        enrolmentService = EnrolmentService(keyProvider: keyProvider, identityStore: identityStore)
        outboxStore = GRDBOutboxStore(db: db)
        syncStateStore = GRDBSyncStateStore(db: db)

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
                    RootView(session: session, vehicleStore: vehicleStore, maintenanceStore: maintenanceStore, syncClient: syncClient, dataPorter: dataPorter, enrolmentService: enrolmentService)
                        .frame(width: proxy.size.width / scale, height: proxy.size.height / scale)
                        .scaleEffect(scale, anchor: .top)
                        .frame(width: proxy.size.width, height: proxy.size.height, alignment: .top)
                }
                .ignoresSafeArea(edges: .bottom)
            } else {
                RootView(session: session, vehicleStore: vehicleStore, maintenanceStore: maintenanceStore, syncClient: syncClient, dataPorter: dataPorter, enrolmentService: enrolmentService)
            }
            #else
            RootView(session: session, vehicleStore: vehicleStore, maintenanceStore: maintenanceStore, syncClient: syncClient, dataPorter: dataPorter, enrolmentService: enrolmentService)
            #endif
        }
        .onChange(of: scenePhase) { _, phase in
            session.log("scene \(phase)")
        }
    }
}
