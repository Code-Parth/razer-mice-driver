import CoreBluetooth
import Foundation

enum LinkState: Equatable {
    case bluetoothOff
    case unauthorized
    case searching
    case connecting(name: String)
    case ready(name: String)
    /// A Razer mouse is connected but does not expose the vendor config service.
    case unsupported(name: String)
}

enum LinkError: LocalizedError {
    case notConnected
    case timeout
    case rejected(status: UInt8)
    case transport(String)

    var errorDescription: String? {
        switch self {
        case .notConnected: "The mouse is not connected."
        case .timeout: "The mouse did not answer."
        case .rejected(let status): String(format: "The mouse rejected the request (status 0x%02X).", status)
        case .transport(let message): message
        }
    }
}

/// CoreBluetooth transport for the vendor service. The mouse is already paired
/// and connected by macOS as a HID device; this attaches a second GATT client to it.
final class VendorLink: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    var onStateChange: ((LinkState) -> Void)?
    var onStandardBattery: ((Int) -> Void)?

    private(set) var state: LinkState = .searching {
        didSet {
            guard state != oldValue else { return }
            log.add("link: \(state)")
            onStateChange?(state)
        }
    }

    private let log: DiagnosticsLog
    private var central: CBCentralManager?
    private var peripheral: CBPeripheral?
    private var writeCharacteristic: CBCharacteristic?
    private var retry: Task<Void, Never>?

    private struct Exchange {
        var response: VendorResponse
        let continuation: CheckedContinuation<[UInt8], Error>
        /// Polls are not logged: several a second would bury everything else.
        let quiet: Bool
    }

    private var exchange: Exchange?
    private var watchdog: Task<Void, Never>?
    private var queueTail: Task<Void, Never>?
    private var nextRequestID: UInt8 = 0x30

    private static let vendorService = CBUUID(string: VendorGATT.service)
    private static let vendorWrite = CBUUID(string: VendorGATT.write)
    private static let vendorNotify = CBUUID(string: VendorGATT.notify)
    private static let hidService = CBUUID(string: "1812")
    private static let batteryService = CBUUID(string: "180F")
    private static let batteryLevel = CBUUID(string: "2A19")

    init(log: DiagnosticsLog) {
        self.log = log
    }

    /// Creating the central is what triggers the Bluetooth permission prompt.
    func start() {
        guard central == nil else { return }
        log.add("starting Bluetooth, authorization \(CBCentralManager.authorization.rawValue)")
        central = CBCentralManager(delegate: self, queue: .main)
    }

    // MARK: Exchanges

    /// The only correlation token is a one-byte request ID and replies span several
    /// notifications, so exchanges run strictly one at a time.
    func send(_ key: VendorKey, payload: [UInt8] = [], quiet: Bool = false) async throws -> [UInt8] {
        let previous = queueTail
        let task = Task { () throws -> [UInt8] in
            await previous?.value
            return try await self.perform(key, payload: payload, quiet: quiet)
        }
        queueTail = Task { _ = try? await task.value }
        return try await task.value
    }

    private func perform(_ key: VendorKey, payload: [UInt8], quiet: Bool) async throws -> [UInt8] {
        guard case .ready = state, let peripheral, let writeCharacteristic else { throw LinkError.notConnected }
        let id = nextRequestID
        nextRequestID &+= 1
        let frames = VendorFrame.request(id: id, key: key, payload: payload)
        if !quiet { log.add("→ \(frames.map { $0.hex }.joined(separator: " | "))") }

        return try await withCheckedThrowingContinuation { continuation in
            exchange = Exchange(response: VendorResponse(requestID: id), continuation: continuation, quiet: quiet)
            for frame in frames {
                peripheral.writeValue(frame, for: writeCharacteristic, type: .withResponse)
            }
            armWatchdog(seconds: 2.5)
        }
    }

    private func armWatchdog(seconds: Double) {
        watchdog?.cancel()
        watchdog = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled, let self, let exchange = self.exchange else { return }
            if let payload = exchange.response.embeddedPayload {
                self.finish(.success(payload))
            } else {
                self.finish(.failure(LinkError.timeout))
            }
        }
    }

    private func finish(_ result: Result<[UInt8], Error>) {
        guard let exchange else { return }
        self.exchange = nil
        watchdog?.cancel()
        if case .failure(let error) = result, !exchange.quiet { log.add("✕ \(error.localizedDescription)") }
        exchange.continuation.resume(with: result)
    }

    // MARK: Discovery

    private func search() {
        retry?.cancel()
        guard let central, central.state == .poweredOn, peripheral == nil else { return }

        let razerNames = ["da v2", "deathadder", "razer"]
        let target = central.retrieveConnectedPeripherals(withServices: [Self.vendorService]).first
            ?? central.retrieveConnectedPeripherals(withServices: [Self.hidService]).first { candidate in
                let name = (candidate.name ?? "").lowercased()
                return razerNames.contains { name.contains($0) }
            }

        guard let target else {
            state = .searching
            retry = Task { [weak self] in
                try? await Task.sleep(for: .seconds(3))
                guard !Task.isCancelled else { return }
                self?.search()
            }
            return
        }
        peripheral = target
        target.delegate = self
        state = .connecting(name: target.name ?? "Razer mouse")
        central.connect(target)
    }

    private func drop(_ reason: String) {
        log.add("dropped: \(reason)")
        finish(.failure(LinkError.notConnected))
        if let peripheral { central?.cancelPeripheralConnection(peripheral) }
        peripheral = nil
        writeCharacteristic = nil
        search()
    }

    // MARK: CBCentralManagerDelegate

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        log.add("bluetooth state \(central.state.rawValue), authorization \(CBCentralManager.authorization.rawValue)")
        switch central.state {
        case .poweredOn:
            search()
        case .unauthorized:
            state = .unauthorized
        case .poweredOff, .unsupported, .resetting, .unknown:
            peripheral = nil
            writeCharacteristic = nil
            finish(.failure(LinkError.notConnected))
            state = central.state == .poweredOff ? .bluetoothOff : .searching
        @unknown default:
            state = .searching
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        peripheral.discoverServices(nil)
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        drop("connect failed: \(error?.localizedDescription ?? "unknown")")
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        drop("disconnected: \(error?.localizedDescription ?? "clean")")
    }

    // MARK: CBPeripheralDelegate

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        let services = peripheral.services ?? []
        log.add("services: \(services.map(\.uuid.uuidString).joined(separator: ", "))")
        guard services.contains(where: { $0.uuid == Self.vendorService }) else {
            state = .unsupported(name: peripheral.name ?? "Razer mouse")
            return
        }
        for service in services where service.uuid == Self.vendorService || service.uuid == Self.batteryService {
            peripheral.discoverCharacteristics(nil, for: service)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        let characteristics = service.characteristics ?? []
        let summary = characteristics.map { "\($0.uuid.uuidString)[\(String($0.properties.rawValue, radix: 16))]" }
        log.add("characteristics of \(service.uuid.uuidString): \(summary.joined(separator: ", "))")

        if service.uuid == Self.batteryService {
            if let level = characteristics.first(where: { $0.uuid == Self.batteryLevel }) {
                peripheral.readValue(for: level)
            }
            return
        }
        guard let write = characteristics.first(where: { $0.uuid == Self.vendorWrite }),
              let notify = characteristics.first(where: { $0.uuid == Self.vendorNotify })
        else {
            state = .unsupported(name: peripheral.name ?? "Razer mouse")
            return
        }
        writeCharacteristic = write
        peripheral.setNotifyValue(true, for: notify)
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        guard characteristic.uuid == Self.vendorNotify else { return }
        if let error {
            log.add("notify subscribe failed: \(error.localizedDescription)")
            state = .unsupported(name: peripheral.name ?? "Razer mouse")
        } else if characteristic.isNotifying {
            state = .ready(name: peripheral.name ?? "Razer mouse")
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        if let error { finish(.failure(LinkError.transport(error.localizedDescription))) }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard let value = characteristic.value else { return }
        if characteristic.uuid == Self.batteryLevel {
            if let level = value.first {
                log.add("battery service (2A19): \(level)%")
                onStandardBattery?(Int(level))
            }
            return
        }
        guard characteristic.uuid == Self.vendorNotify else { return }
        let frame = [UInt8](value)
        if exchange?.quiet != true { log.add("← \(frame.hex)") }
        guard var current = exchange else { return }

        switch current.response.consume(frame) {
        case .done(let payload):
            finish(.success(payload))
        case .failed(let status):
            finish(.failure(LinkError.rejected(status: status)))
        case .waiting:
            exchange = current
            // Past the header the remaining frames arrive back to back; a short
            // idle window means the payload was packed into the header itself.
            if current.response.hasHeader { armWatchdog(seconds: 0.5) }
        }
    }
}
