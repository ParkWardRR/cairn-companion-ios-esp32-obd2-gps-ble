import CairnCore
import CoreLocation
import Foundation

/// One explicit driving session: keeps location and BLE alive with the screen locked, throttles
/// to ~1 Hz, encodes, and hands fixes to the BLE manager. Start and Stop are user actions.
@MainActor
public final class DrivingSession {
    public let state: SessionState
    private let ble: CairnBLEManager
    private let authorization = CLLocationManager()

    #if os(iOS)
    private var backgroundSession: CLBackgroundActivitySession?
    #endif
    private var locationTask: Task<Void, Never>?
    private var throttle = TransmitThrottle()
    private var seq: UInt16 = 0

    public init(state: SessionState, ble: CairnBLEManager) {
        self.state = state
        self.ble = ble
    }

    public func start() {
        guard !state.isSessionActive else { return }
        state.resetAll()
        state.isSessionActive = true

        // While In Use is enough for an explicitly started session with a background activity session.
        if authorization.authorizationStatus == .notDetermined {
            authorization.requestWhenInUseAuthorization()
        }
        #if os(iOS)
        backgroundSession = CLBackgroundActivitySession()
        #endif
        throttle.reset()
        seq = 0

        ble.start()
        locationTask = Task { [weak self] in
            for await event in LocationStream.events() {
                self?.handle(event)
            }
        }
    }

    public func stop() {
        locationTask?.cancel()
        locationTask = nil
        #if os(iOS)
        backgroundSession?.invalidate()
        backgroundSession = nil
        #endif
        ble.stop()
        state.resetAll()
        state.isSessionActive = false
    }

    private func handle(_ event: LocationEvent) {
        switch event {
        case .unavailable(let message):
            state.locationMessage = message
        case .fix(let fix):
            state.locationMessage = nil
            state.phoneFix = fix
            transmit(fix)
        }
    }

    private func transmit(_ fix: PhoneGNSSFix) {
        guard throttle.shouldSend(fix) else { return }
        guard let payload = PayloadEncoder.encode(fix, now: Date(), seq: seq) else {
            state.droppedCount += 1
            return
        }
        switch ble.send(payload) {
        case .sent:
            seq &+= 1
            state.sentCount += 1
            state.lastSent = payload
        case .backpressure:
            state.droppedCount += 1
        case .notReady:
            break // not connected yet; fixes are not queued
        }
    }
}
