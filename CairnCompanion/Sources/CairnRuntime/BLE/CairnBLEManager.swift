import CairnCore
import CoreBluetooth
import Foundation
import os

/// CoreBluetooth central for the Cairn dongle. Scans by service UUID, bonds by touching an
/// encrypted characteristic, reconnects on its own (restoration alone is not assumed to), and
/// writes `GNSS_FIX` without response, dropping when the radio is backed up rather than queueing stale fixes.
@MainActor
public final class CairnBLEManager: NSObject {
    public enum SendResult: Sendable { case sent, notReady, backpressure }

    private static let log = Logger(subsystem: "app.cairn.companion", category: "ble")
    private static let restoreID = "app.cairn.companion.central"
    private static let lastPeripheralKey = "cairn.lastPeripheralID"
    private static let streamingTimeout = LinkHealth.liveWindow

    private let state: SessionState
    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var fixCharacteristic: CBCharacteristic?
    /// Phase 2 characteristics; nil when the dongle firmware does not expose them.
    private var baroCharacteristic: CBCharacteristic?
    private var utcCharacteristic: CBCharacteristic?
    private var obdCharacteristic: CBCharacteristic?
    private var deviceStatusCharacteristic: CBCharacteristic?
    private var wantsConnection = false
    private var reconnectTask: Task<Void, Never>?
    private var streamingTask: Task<Void, Never>?
    private var tracedWrites = 0
    /// Consecutive failures of a link that did connect; reset when the link becomes ready or on a new Start.
    private var failureStreak = 0 {
        didSet { state.retryAttempt = failureStreak }
    }
    /// Set before `cancelPeripheralConnection` when cleanup is already done, so `didDisconnect` skips its own.
    private var pendingDisconnect = false
    /// Consecutive ATT authentication failures; triggers stale-bond detection after 2.
    private var consecutiveAuthFailures = 0
    private static let sendDisabled = ProcessInfo.processInfo.environment["CAIRN_DISABLE_SEND"] != nil

    /// The link is bonded and the protocol version is accepted; fixes can be sent.
    public var onReady: (() -> Void)?
    /// The link dropped or failed. Reconnection keeps going on its own unless the link failed for good.
    public var onLinkLost: (() -> Void)?
    /// A `COMPANION_STATUS` notify arrived.
    public var onStatus: ((CompanionStatus) -> Void)?
    /// The streaming state (dongle recently acknowledged) changed.
    public var onStreamingChanged: ((Bool) -> Void)?
    /// An `OBD_LIVE` notification arrived.
    public var onOBDReceived: (() -> Void)?
    /// A `DEVICE_STATUS` notification arrived.
    public var onDeviceStatus: ((DeviceStatus) -> Void)?

    /// Create at launch so state restoration can deliver its callback.
    public init(state: SessionState) {
        self.state = state
        super.init()
        central = CBCentralManager(
            delegate: self, queue: .main,
            options: [CBCentralManagerOptionRestoreIdentifierKey: Self.restoreID]
        )
    }

    private func trace(_ message: String) {
        Self.log.notice("\(message, privacy: .private)")
        #if DEBUG
        print("[ble]", message)
        #endif
        DriveLog.shared.record("ble \(message)")
    }

    // MARK: Control

    public func start() {
        wantsConnection = true
        failureStreak = 0
        consecutiveAuthFailures = 0
        pendingDisconnect = false
        connectIfPossible()
    }

    public func stop() {
        wantsConnection = false
        pendingDisconnect = false
        reconnectTask?.cancel()
        streamingTask?.cancel()
        state.nextRetryAt = nil
        central.stopScan()
        if let peripheral { central.cancelPeripheralConnection(peripheral) }
        peripheral = nil
        clearCharacteristics()
        state.resetDeviceState()
        state.connection = .idle
    }

    /// Clear the stored dongle identity. The user must also forget "Cairn" in Settings → Bluetooth
    /// to remove the stale iOS bond before re-pairing.
    public func forgetDongle() {
        stop()
        UserDefaults.standard.removeObject(forKey: Self.lastPeripheralKey)
        peripheral = nil
        trace("forgot dongle")
    }

    private func clearCharacteristics() {
        fixCharacteristic = nil
        baroCharacteristic = nil
        utcCharacteristic = nil
        obdCharacteristic = nil
        deviceStatusCharacteristic = nil
    }

    public func send(_ payload: GNSSFixPayload) -> SendResult {
        guard state.connection == .ready, let peripheral, let fixCharacteristic else { return .notReady }
        // Flow control says the radio can take it; only COMPANION_STATUS says the firmware did.
        guard peripheral.canSendWriteWithoutResponse else { return .backpressure }
        if Self.sendDisabled { return .notReady } // diagnostics: CAIRN_DISABLE_SEND=1 in the launch environment
        if tracedWrites < 8 {
            tracedWrites += 1
            trace("write seq \(payload.seq) \(payload.data.count) B age \(payload.sampleAgeMs) ms")
        }
        peripheral.writeValue(payload.data, for: fixCharacteristic, type: .withoutResponse)
        return .sent
    }

    /// Phase 2 `BARO_ALT`. Returns false when the dongle does not expose it or the radio is backed up.
    @discardableResult
    public func send(_ payload: BaroAltPayload) -> Bool {
        write(payload.data, to: baroCharacteristic)
    }

    /// Phase 2 `UTC_SYNC`. Returns false when the dongle does not expose it or the radio is backed up.
    @discardableResult
    public func send(_ payload: UTCSyncPayload) -> Bool {
        write(payload.data, to: utcCharacteristic)
    }

    /// Whether the connected dongle exposes `BARO_ALT` / `UTC_SYNC`.
    public var supportsBaroAlt: Bool { baroCharacteristic != nil }
    public var supportsUTCSync: Bool { utcCharacteristic != nil }

    /// Uses write-without-response when the characteristic offers it, otherwise a confirmed write.
    private func write(_ data: Data, to characteristic: CBCharacteristic?) -> Bool {
        guard state.connection == .ready, let peripheral, let characteristic else { return false }
        if characteristic.properties.contains(.writeWithoutResponse) {
            guard peripheral.canSendWriteWithoutResponse else { return false }
            peripheral.writeValue(data, for: characteristic, type: .withoutResponse)
        } else {
            peripheral.writeValue(data, for: characteristic, type: .withResponse)
        }
        return true
    }

    // MARK: Connection

    private static let connectOptions: [String: Any] = [
        CBConnectPeripheralOptionNotifyOnDisconnectionKey: true
    ]

    private func connectIfPossible() {
        guard wantsConnection else { return }
        switch central.state {
        case .poweredOn:
            if let peripheral {
                state.connection = .connecting
                central.connect(peripheral, options: Self.connectOptions)
            } else if let known = knownPeripheral() {
                adopt(known)
                state.connection = .connecting
                central.connect(known, options: Self.connectOptions)
            } else {
                state.connection = .scanning
                central.scanForPeripherals(withServices: [CairnGATTProfile.serviceUUID])
            }
        case .unauthorized: bluetoothUnavailable("Bluetooth permission denied")
        case .poweredOff: bluetoothUnavailable("Bluetooth is off")
        case .unsupported: bluetoothUnavailable("Bluetooth LE unsupported")
        default: bluetoothUnavailable("Waiting for Bluetooth")
        }
    }

    private func bluetoothUnavailable(_ reason: String) {
        let next = SessionState.Connection.bluetoothUnavailable(reason)
        if state.connection != next { state.record(.bluetoothUnavailable, reason) }
        state.connection = next
    }

    private func knownPeripheral() -> CBPeripheral? {
        guard let text = UserDefaults.standard.string(forKey: Self.lastPeripheralKey),
              let id = UUID(uuidString: text) else { return nil }
        return central.retrievePeripherals(withIdentifiers: [id]).first
    }

    private func adopt(_ peripheral: CBPeripheral) {
        self.peripheral = peripheral
        peripheral.delegate = self
    }

    /// A pending `connect` never times out, so a short delay is enough to avoid a tight loop on auth failures.
    private func scheduleReconnect() {
        guard wantsConnection else { return }
        let delay = ReconnectPolicy.delay(afterFailures: failureStreak)
        state.nextRetryAt = Date().addingTimeInterval(delay)
        reconnectTask?.cancel()
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            self?.state.nextRetryAt = nil
            self?.connectIfPossible()
        }
    }

    /// A link that was ready going away is a drop. A connect attempt that never got that far is not.
    private func noteDrop(_ reason: String?) {
        if state.connectedSince != nil { state.record(.dropped, reason) }
    }

    private func linkLost(_ reason: String? = nil) {
        trace("linkLost, reconnect in \(ReconnectPolicy.delay(afterFailures: failureStreak)) s")
        noteDrop(reason)
        streamingTask?.cancel()
        clearCharacteristics()
        state.resetDeviceState()
        if wantsConnection { state.connection = .connecting }
        onLinkLost?()
        scheduleReconnect()
    }

    /// A failure that retrying cannot fix. Stays failed until the user starts again.
    private func fail(_ message: String) {
        trace("FAIL \(message)")
        noteDrop(message)
        state.record(.failed, message)
        state.nextRetryAt = nil
        state.resetDeviceState()
        state.connection = .failed(message)
        if let peripheral {
            pendingDisconnect = true
            central.cancelPeripheralConnection(peripheral)
        }
        streamingTask?.cancel()
        onLinkLost?()
        wantsConnection = false
    }

    /// A failure after the link came up that may be a hiccup (discovery, the first read, pairing).
    /// Drops the link and reconnects with backoff, and only gives up after `ReconnectPolicy.maxConsecutiveFailures`.
    private func retry(_ message: String) {
        failureStreak += 1
        if ReconnectPolicy.shouldGiveUp(afterFailures: failureStreak) {
            return fail("\(message) (gave up after \(failureStreak) attempts)")
        }
        trace("RETRY \(failureStreak)/\(ReconnectPolicy.maxConsecutiveFailures): \(message)")
        noteDrop(message)
        streamingTask?.cancel()
        clearCharacteristics()
        state.resetDeviceState()
        state.connection = .connecting
        onLinkLost?()
        if let peripheral {
            pendingDisconnect = true
            central.cancelPeripheralConnection(peripheral)
        }
        scheduleReconnect()
    }

    private func failAsStaleBond() {
        fail("Stale pairing")
    }

    private func becomeReady() {
        guard let peripheral else { return }
        failureStreak = 0
        consecutiveAuthFailures = 0
        let writable = peripheral.maximumWriteValueLength(for: .withoutResponse)
        guard writable >= CairnGATTProfile.requiredWriteLength else {
            fail("BLE write size \(writable) B is below the 28 B GNSS_FIX")
            return
        }
        tracedWrites = 0
        trace("ready, maxWrite \(writable) B")
        state.clearDeviceReadings()
        state.nextRetryAt = nil
        state.connectedSince = Date()
        state.record(.ready)
        state.connection = .ready
        onReady?()
        streamingTask?.cancel()
        streamingTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                self?.refreshStreaming()
            }
        }
    }

    private func refreshStreaming() {
        let recent = state.lastStatusAt.map { Date().timeIntervalSince($0) < Self.streamingTimeout } ?? false
        let streaming = state.connection == .ready && recent
        guard state.isStreaming != streaming else { return }
        state.isStreaming = streaming
        state.record(streaming ? .streamingResumed : .streamingLost)
        onStreamingChanged?(streaming)
    }
}

// MARK: - CBCentralManagerDelegate

extension CairnBLEManager: @preconcurrency CBCentralManagerDelegate {
    public func centralManagerDidUpdateState(_ central: CBCentralManager) {
        trace("central state \(central.state.rawValue)")
        if central.state == .poweredOn {
            connectIfPossible()
        } else if wantsConnection {
            linkLost("Bluetooth turned off")
            connectIfPossible() // surfaces the reason (off / unauthorized)
        }
    }

    public func centralManager(_ central: CBCentralManager, willRestoreState dict: [String: Any]) {
        guard let restored = (dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral])?.first else { return }
        adopt(restored)
        // Only an armed app has a pending connection, so the system relaunched us for the dongle.
        // `DrivingSession.resumeIfEnabled()` arms at launch; the link coming up starts the session.
        wantsConnection = true
    }

    public func centralManager(
        _ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any], rssi RSSI: NSNumber
    ) {
        trace("discovered \(peripheral.identifier) rssi \(RSSI) name \(peripheral.name ?? "-")")
        central.stopScan()
        adopt(peripheral)
        state.connection = .connecting
        central.connect(peripheral)
    }

    public func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        trace("didConnect \(peripheral.identifier)")
        UserDefaults.standard.set(peripheral.identifier.uuidString, forKey: Self.lastPeripheralKey)
        state.connection = .bonding
        peripheral.discoverServices([CairnGATTProfile.serviceUUID])
    }

    public func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        trace("didFailToConnect \(describe(error))")
        linkLost()
    }

    public func centralManager(
        _ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral,
        timestamp: CFAbsoluteTime, isReconnecting: Bool, error: (any Error)?
    ) {
        trace("didDisconnect \(describe(error)) stage \(state.connection) isReconnecting \(isReconnecting)")
        guard peripheral === self.peripheral else { return }
        if pendingDisconnect {
            pendingDisconnect = false
            return
        }
        if let error, isStaleBondError(error) {
            failAsStaleBond()
            return
        }
        if isReconnecting {
            noteDrop(error.map { _ in describe(error) })
            streamingTask?.cancel()
            clearCharacteristics()
            state.resetDeviceState()
            state.connection = .connecting
            onLinkLost?()
            return
        }
        linkLost(error.map { _ in describe(error) })
    }
}

// MARK: - CBPeripheralDelegate

extension CairnBLEManager: @preconcurrency CBPeripheralDelegate {
    public func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        trace("services \(peripheral.services?.map { $0.uuid.uuidString } ?? []) \(describe(error))")
        guard error == nil,
              let service = peripheral.services?.first(where: { $0.uuid == CairnGATTProfile.serviceUUID })
        else { return retry("Cairn service not found \(describe(error))") }
        peripheral.discoverCharacteristics(
            [CairnGATTProfile.gnssFix, CairnGATTProfile.gnssQuality,
             CairnGATTProfile.companionStatus, CairnGATTProfile.protocolVersion,
             CairnGATTProfile.baroAlt, CairnGATTProfile.utcSync,
             CairnGATTProfile.obdLive, CairnGATTProfile.deviceStatus],
            for: service
        )
    }

    public func peripheral(
        _ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?
    ) {
        trace("characteristics \(service.characteristics?.map { $0.uuid.uuidString } ?? []) \(describe(error))")
        guard error == nil, let characteristics = service.characteristics else {
            return retry("Characteristic discovery failed \(describe(error))")
        }
        var found: [CBUUID: CBCharacteristic] = [:]
        for c in characteristics { found[c.uuid] = c }
        guard let fix = found[CairnGATTProfile.gnssFix],
              let version = found[CairnGATTProfile.protocolVersion] else {
            return fail("Device is missing required characteristics")
        }
        fixCharacteristic = fix
        baroCharacteristic = found[CairnGATTProfile.baroAlt]
        utcCharacteristic = found[CairnGATTProfile.utcSync]
        obdCharacteristic = found[CairnGATTProfile.obdLive]
        deviceStatusCharacteristic = found[CairnGATTProfile.deviceStatus]
        // Every characteristic needs an encrypted, authenticated link; the first access prompts for the passkey.
        peripheral.readValue(for: version)
        for uuid in [CairnGATTProfile.gnssQuality, CairnGATTProfile.companionStatus,
                     CairnGATTProfile.obdLive, CairnGATTProfile.deviceStatus] {
            if let c = found[uuid] { peripheral.setNotifyValue(true, for: c) }
        }
    }

    public func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) {
        // Radio cleared after backpressure; the next 1 Hz write will go through.
    }

    public func peripheral(_ peripheral: CBPeripheral, didModifyServices invalidatedServices: [CBService]) {
        trace("services invalidated: \(invalidatedServices.map { $0.uuid.uuidString })")
        if invalidatedServices.contains(where: { $0.uuid == CairnGATTProfile.serviceUUID }) {
            retry("Cairn service changed")
        }
    }

    public func peripheral(
        _ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?
    ) {
        trace("value \(characteristic.uuid.uuidString) \(characteristic.value?.count ?? -1) B \(describe(error))")
        if let error {
            if characteristic.uuid == CairnGATTProfile.protocolVersion {
                if isAuthenticationError(error) {
                    consecutiveAuthFailures += 1
                    trace("auth failure \(consecutiveAuthFailures) on PROTOCOL_VERSION read")
                    if consecutiveAuthFailures >= 2 {
                        failAsStaleBond()
                    } else {
                        retry("Pairing: \(error.localizedDescription)")
                    }
                } else {
                    retry("Pairing: \(error.localizedDescription)")
                }
            }
            return
        }
        guard let data = characteristic.value else { return }
        switch characteristic.uuid {
        case CairnGATTProfile.protocolVersion:
            guard let version = PayloadDecoder.protocolVersion(data) else { return retry("Bad protocol version payload") }
            guard version.isSupported else { return fail("Unsupported protocol v\(version.version)") }
            becomeReady()
        case CairnGATTProfile.gnssQuality:
            if let quality = PayloadDecoder.gnssQuality(data) {
                state.deviceQuality = quality
                state.lastQualityAt = Date()
            }
        case CairnGATTProfile.companionStatus:
            if let status = PayloadDecoder.companionStatus(data) {
                state.companionStatus = status
                state.lastStatusAt = Date()
                onStatus?(status)
                refreshStreaming()
            }
        case CairnGATTProfile.obdLive:
            if let snapshot = PayloadDecoder.obdLive(data) {
                state.obdLive = snapshot
                state.lastOBDAt = Date()
                onOBDReceived?()
            }
        case CairnGATTProfile.deviceStatus:
            if let status = PayloadDecoder.deviceStatus(data) {
                state.deviceStatus = status
                state.lastDeviceStatusAt = Date()
                onDeviceStatus?(status)
            }
        default:
            break
        }
    }
}

private func describe(_ error: Error?) -> String {
    guard let error else { return "ok" }
    let e = error as NSError
    return "\(e.domain)#\(e.code) \(e.localizedDescription)"
}

private func isAuthenticationError(_ error: Error) -> Bool {
    let e = error as NSError
    guard e.domain == CBATTErrorDomain else { return false }
    return e.code == CBATTError.insufficientAuthentication.rawValue
        || e.code == CBATTError.insufficientEncryption.rawValue
}

/// `peerRemovedPairingInformation` — iOS detected the remote device no longer recognises our bond keys.
private func isStaleBondError(_ error: Error) -> Bool {
    let e = error as NSError
    return e.domain == CBErrorDomain && e.code == 14
}
