import CairnCore
import CoreLocation
import Foundation

/// Follows the Cairn dongle. While auto-connect is on, the app keeps a pending BLE connection to the
/// paired dongle; location streaming starts when the link is bonded and stops when it drops. It keeps
/// location and BLE alive with the screen locked, throttles to ~1 Hz, encodes, and hands fixes to the BLE manager.
@MainActor
public final class DrivingSession {
    public let state: SessionState
    private let ble: CairnBLEManager
    private let authorization = CLLocationManager()

    private static let autoConnectKey = "cairn.autoConnectEnabled"

    #if os(iOS)
    private var backgroundSession: CLBackgroundActivitySession?
    #endif
    private var locationTask: Task<Void, Never>?
    private var utcTask: Task<Void, Never>?
    private var baroTask: Task<Void, Never>?
    private static let utcSyncInterval: Duration = .seconds(60)
    private var throttle = TransmitThrottle()
    private var seq: UInt16 = 0

    public init(state: SessionState, ble: CairnBLEManager) {
        self.state = state
        self.ble = ble
        ble.onReady = { [weak self] in self?.beginDriving() }
        ble.onLinkLost = { [weak self] in self?.endDriving() }
    }

    /// Call at launch, including background relaunches. Auto-connect is on unless the user turned it off.
    public func resumeIfEnabled() {
        let enabled = UserDefaults.standard.object(forKey: Self.autoConnectKey) as? Bool ?? true
        if enabled { arm() }
    }

    /// Start waiting for the dongle. Location is not used until the link is up.
    public func arm() {
        guard !state.isArmed else { return }
        UserDefaults.standard.set(true, forKey: Self.autoConnectKey)
        state.resetAll()
        state.isArmed = true
        seq = 0

        // A link that comes up while the app is in the background has to start location there, which
        // needs Always authorization. While In Use is enough only when the app is foregrounded.
        switch authorization.authorizationStatus {
        case .notDetermined, .authorizedWhenInUse: authorization.requestAlwaysAuthorization()
        default: break
        }
        ble.start()
    }

    /// Stop following the dongle and release BLE and location.
    public func disarm() {
        UserDefaults.standard.set(false, forKey: Self.autoConnectKey)
        endDriving()
        ble.stop()
        state.resetAll()
        state.isArmed = false
    }

    private func beginDriving() {
        guard state.isArmed, !state.isDriving else { return }
        state.isDriving = true
        // The dongle's COMPANION_STATUS counters restart on every connection, so ours do too.
        state.sentCount = 0
        state.droppedCount = 0
        throttle.reset()
        #if os(iOS)
        backgroundSession = CLBackgroundActivitySession()
        #endif
        locationTask = Task { [weak self] in
            for await event in LocationStream.events() {
                self?.handle(event)
            }
        }
        startEnrichment()
    }

    /// Phase 2 writes, sent only if the dongle exposes the characteristic.
    private func startEnrichment() {
        if ble.supportsUTCSync {
            utcTask = Task { [weak self] in
                while !Task.isCancelled {
                    self?.ble.send(UTCSyncPayload(date: Date()))
                    try? await Task.sleep(for: Self.utcSyncInterval)
                }
            }
        }
        if ble.supportsBaroAlt, BaroStream.isAvailable {
            baroTask = Task { [weak self] in
                for await reading in BaroStream.readings() {
                    self?.ble.send(reading)
                }
            }
        }
    }

    private func endDriving() {
        guard state.isDriving else { return }
        locationTask?.cancel()
        locationTask = nil
        utcTask?.cancel()
        utcTask = nil
        baroTask?.cancel()
        baroTask = nil
        #if os(iOS)
        backgroundSession?.invalidate()
        backgroundSession = nil
        #endif
        state.isDriving = false
        state.phoneFix = nil
        state.locationMessage = nil
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
