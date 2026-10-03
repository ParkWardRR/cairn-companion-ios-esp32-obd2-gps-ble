import CairnCore
import CoreBluetooth
import Foundation

/// CoreBluetooth central for the Cairn dongle. Scans by service UUID, bonds by touching an
/// encrypted characteristic, reconnects on its own (restoration alone is not assumed to), and
/// writes `GNSS_FIX` without response, dropping when the radio is backed up rather than queueing stale fixes.
@MainActor
public final class CairnBLEManager: NSObject {
    public enum SendResult: Sendable { case sent, notReady, backpressure }

    private static let restoreID = "app.cairn.companion.central"
    private static let lastPeripheralKey = "cairn.lastPeripheralID"
    /// Matches the firmware's phone-GNSS staleness window.
    private static let streamingTimeout: TimeInterval = 3
    private static let reconnectDelay: Duration = .seconds(1)

    private let state: SessionState
    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var fixCharacteristic: CBCharacteristic?
    private var wantsConnection = false
    private var reconnectTask: Task<Void, Never>?
    private var streamingTask: Task<Void, Never>?

    /// Create at launch so state restoration can deliver its callback.
    public init(state: SessionState) {
        self.state = state
        super.init()
        central = CBCentralManager(
            delegate: self, queue: .main,
            options: [CBCentralManagerOptionRestoreIdentifierKey: Self.restoreID]
        )
    }

    // MARK: Control

    public func start() {
        wantsConnection = true
        connectIfPossible()
    }

    public func stop() {
        wantsConnection = false
        reconnectTask?.cancel()
        streamingTask?.cancel()
        central.stopScan()
        if let peripheral { central.cancelPeripheralConnection(peripheral) }
        peripheral = nil
        fixCharacteristic = nil
        state.resetDeviceState()
        state.connection = .idle
    }

    public func send(_ payload: GNSSFixPayload) -> SendResult {
        guard state.connection == .ready, let peripheral, let fixCharacteristic else { return .notReady }
        // Flow control says the radio can take it; only COMPANION_STATUS says the firmware did.
        guard peripheral.canSendWriteWithoutResponse else { return .backpressure }
        peripheral.writeValue(payload.data, for: fixCharacteristic, type: .withoutResponse)
        return .sent
    }

    // MARK: Connection

    private func connectIfPossible() {
        guard wantsConnection else { return }
        switch central.state {
        case .poweredOn:
            if let peripheral {
                state.connection = .connecting
                central.connect(peripheral)
            } else if let known = knownPeripheral() {
                adopt(known)
                state.connection = .connecting
                central.connect(known)
            } else {
                state.connection = .scanning
                central.scanForPeripherals(withServices: [CairnGATTProfile.serviceUUID])
            }
        case .unauthorized:
            state.connection = .bluetoothUnavailable("Bluetooth permission denied")
        case .poweredOff:
            state.connection = .bluetoothUnavailable("Bluetooth is off")
        case .unsupported:
            state.connection = .bluetoothUnavailable("Bluetooth LE unsupported")
        default:
            state.connection = .bluetoothUnavailable("Waiting for Bluetooth")
        }
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
        reconnectTask?.cancel()
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(for: Self.reconnectDelay)
            guard !Task.isCancelled else { return }
            self?.connectIfPossible()
        }
    }

    private func linkLost() {
        streamingTask?.cancel()
        fixCharacteristic = nil
        state.resetDeviceState()
        if wantsConnection { state.connection = .connecting }
        scheduleReconnect()
    }

    private func fail(_ message: String) {
        state.connection = .failed(message)
        if let peripheral { central.cancelPeripheralConnection(peripheral) }
        streamingTask?.cancel()
        // Stay failed: retrying would repeat the same refusal. A new Start clears it.
        wantsConnection = false
    }

    private func becomeReady() {
        guard let peripheral else { return }
        let writable = peripheral.maximumWriteValueLength(for: .withoutResponse)
        guard writable >= CairnGATTProfile.requiredWriteLength else {
            fail("BLE write size \(writable) B is below the 28 B GNSS_FIX")
            return
        }
        state.connection = .ready
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
        if state.isStreaming != streaming { state.isStreaming = streaming }
    }
}

// MARK: - CBCentralManagerDelegate

extension CairnBLEManager: @preconcurrency CBCentralManagerDelegate {
    public func centralManagerDidUpdateState(_ central: CBCentralManager) {
        if central.state == .poweredOn {
            connectIfPossible()
        } else if wantsConnection {
            linkLost()
            connectIfPossible() // surfaces the reason (off / unauthorized)
        }
    }

    public func centralManager(_ central: CBCentralManager, willRestoreState dict: [String: Any]) {
        guard let restored = (dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral])?.first else { return }
        adopt(restored)
        // The session was running when the system relaunched us; resume it.
        wantsConnection = true
        state.isSessionActive = true
    }

    public func centralManager(
        _ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any], rssi RSSI: NSNumber
    ) {
        central.stopScan()
        adopt(peripheral)
        state.connection = .connecting
        central.connect(peripheral)
    }

    public func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        UserDefaults.standard.set(peripheral.identifier.uuidString, forKey: Self.lastPeripheralKey)
        state.connection = .bonding
        peripheral.discoverServices([CairnGATTProfile.serviceUUID])
    }

    public func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        linkLost()
    }

    public func centralManager(
        _ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?
    ) {
        guard peripheral === self.peripheral else { return }
        linkLost()
    }
}

// MARK: - CBPeripheralDelegate

extension CairnBLEManager: @preconcurrency CBPeripheralDelegate {
    public func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard error == nil,
              let service = peripheral.services?.first(where: { $0.uuid == CairnGATTProfile.serviceUUID })
        else { return fail("Cairn service not found") }
        peripheral.discoverCharacteristics(
            [CairnGATTProfile.gnssFix, CairnGATTProfile.gnssQuality,
             CairnGATTProfile.companionStatus, CairnGATTProfile.protocolVersion],
            for: service
        )
    }

    public func peripheral(
        _ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?
    ) {
        guard error == nil, let characteristics = service.characteristics else {
            return fail("Characteristic discovery failed")
        }
        var found: [CBUUID: CBCharacteristic] = [:]
        for c in characteristics { found[c.uuid] = c }
        guard let fix = found[CairnGATTProfile.gnssFix],
              let version = found[CairnGATTProfile.protocolVersion] else {
            return fail("Device is missing required characteristics")
        }
        fixCharacteristic = fix
        // Every characteristic needs an encrypted, authenticated link; the first access prompts for the passkey.
        peripheral.readValue(for: version)
        for uuid in [CairnGATTProfile.gnssQuality, CairnGATTProfile.companionStatus] {
            if let c = found[uuid] { peripheral.setNotifyValue(true, for: c) }
        }
    }

    public func peripheral(
        _ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?
    ) {
        if let error {
            // Bonding failures (wrong passkey, cancelled pairing) arrive here as ATT or CBError codes.
            if characteristic.uuid == CairnGATTProfile.protocolVersion {
                fail("Pairing failed: \(error.localizedDescription)")
            }
            return
        }
        guard let data = characteristic.value else { return }
        switch characteristic.uuid {
        case CairnGATTProfile.protocolVersion:
            guard let version = PayloadDecoder.protocolVersion(data) else { return fail("Bad protocol version payload") }
            guard version.isSupported else { return fail("Unsupported protocol v\(version.version)") }
            becomeReady()
        case CairnGATTProfile.gnssQuality:
            if let quality = PayloadDecoder.gnssQuality(data) { state.deviceQuality = quality }
        case CairnGATTProfile.companionStatus:
            if let status = PayloadDecoder.companionStatus(data) {
                state.companionStatus = status
                state.lastStatusAt = Date()
                refreshStreaming()
            }
        default:
            break
        }
    }
}
