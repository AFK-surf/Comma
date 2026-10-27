import Foundation
@preconcurrency import CoreBluetooth

/// One foreground setup. Peripheral identifiers last only for this scan session.
@MainActor
final class DeviceBluetooth: NSObject, @preconcurrency CBCentralManagerDelegate, @preconcurrency CBPeripheralDelegate {
    typealias Reply = (Any?, String?) -> Void
    private var central: CBCentralManager?
    private var session = ""
    private var scanning = false
    private var found: [String: CBPeripheral] = [:]
    private var peripheral: CBPeripheral?
    private var characteristics: [String: CBCharacteristic] = [:]
    private var connectReply: Reply?
    private var pending: [String: Reply] = [:]
    private var events: [[String: Any]] = []
    private var nextReply: Reply?
    private let service = CBUUID(string: "f2d20001-eb8e-4a64-9ec7-ab0cbb8107c8")

    func perform(_ op: String, _ input: [String: Any], reply: @escaping Reply) {
        let requested = input["session"] as? String ?? ""
        if op == "start" {
            close()
            session = requested
            scanning = true
            if central == nil { central = CBCentralManager(delegate: self, queue: .main) }
            if let central { centralManagerDidUpdateState(central) }
            reply(nil, nil)
            return
        }
        guard !session.isEmpty, session == requested else { reply(nil, "Setup session ended"); return }
        switch op {
        case "next":
            guard nextReply == nil else { reply(nil, "Event reader is busy"); return }
            if events.isEmpty { nextReply = reply } else { reply(events.removeFirst(), nil) }
        case "stopScan": scanning = false; central?.stopScan(); reply(nil, nil)
        case "connect":
            guard connectReply == nil, peripheral == nil, let id = input["peripheral"] as? String,
                  let selected = found[id], central?.state == .poweredOn else { reply(nil, "Device is unavailable"); return }
            peripheral = selected; selected.delegate = self; connectReply = reply
            central?.connect(selected)
        case "read", "notify", "write":
            guard let peripheral, peripheral.state == .connected,
                  let uuid = input["characteristic"] as? String, let characteristic = characteristics[uuid.lowercased()] else { reply(nil, "Device is disconnected"); return }
            let key = "\(op):\(uuid.lowercased())"
            guard pending[key] == nil else { reply(nil, "Bluetooth operation is busy"); return }
            if op == "write" {
                guard let value = input["value"] as? String else { reply(nil, "Missing write value"); return }
                let bytes = Data(value.utf8)
                // CoreBluetooth performs prepared writes when needed. Never split JSON into independent writes.
                guard bytes.count <= 512, bytes.count <= peripheral.maximumWriteValueLength(for: .withResponse) else { reply(nil, "Write exceeds Bluetooth limit"); return }
                pending[key] = reply; peripheral.writeValue(bytes, for: characteristic, type: .withResponse)
            } else if op == "read" {
                pending[key] = reply; peripheral.readValue(for: characteristic)
            } else {
                pending[key] = reply; peripheral.setNotifyValue(true, for: characteristic)
            }
        case "disconnect", "close": close(); reply(nil, nil)
        default: reply(nil, "Unknown Bluetooth operation")
        }
    }

    func close() {
        scanning = false; central?.stopScan()
        if let peripheral { peripheral.delegate = nil; central?.cancelPeripheralConnection(peripheral) }
        peripheral = nil; found.removeAll(); characteristics.removeAll()
        let waiting = Array(pending.values); pending.removeAll()
        let connect = connectReply; connectReply = nil
        let next = nextReply; nextReply = nil
        events.removeAll(); session = ""
        connect?(nil, "Device is disconnected")
        for reply in waiting { reply(nil, "Device is disconnected") }
        next?(nil, "Setup session ended")
    }

    private func emit(_ event: [String: Any]) {
        guard !session.isEmpty else { return }
        if let reply = nextReply { nextReply = nil; reply(event, nil); return }
        if event["type"] as? String == "found", let id = event["peripheral"] as? String {
            events.removeAll { $0["peripheral"] as? String == id }
        }
        if events.count >= 100 {
            if let first = events.firstIndex(where: { $0["type"] as? String == "found" }) { events.remove(at: first) }
            else { close(); return }
        }
        events.append(event)
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        let state: String
        switch central.state {
        case .poweredOn: state = "on"
        case .poweredOff: state = "off"
        case .unauthorized: state = "denied"
        case .unsupported: state = "unsupported"
        default: state = "pending"
        }
        emit(["type": "state", "state": state])
        if scanning && central.state == .poweredOn {
            central.scanForPeripherals(withServices: [service], options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
        }
        if central.state != .poweredOn && peripheral != nil { emit(["type": "lost"]) }
    }
    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String: Any], rssi RSSI: NSNumber) {
        guard scanning else { return }
        let id = peripheral.identifier.uuidString
        guard found[id] != nil || found.count < 50 else { return }
        found[id] = peripheral
        let manufacturer = advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data ?? Data()
        emit(["type": "found", "peripheral": id, "name": advertisementData[CBAdvertisementDataLocalNameKey] as? String ?? "",
              "manufacturer": Array(manufacturer), "rssi": RSSI.intValue])
    }
    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        guard peripheral === self.peripheral else { return }
        peripheral.discoverServices([service])
    }
    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: (any Error)?) {
        guard peripheral === self.peripheral else { return }
        let reply = connectReply; connectReply = nil; reply?(nil, "Bluetooth connection failed")
        emit(["type": "lost"])
    }
    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: (any Error)?) {
        guard peripheral === self.peripheral else { return }
        let replies = Array(pending.values); pending.removeAll()
        let reply = connectReply; connectReply = nil
        reply?(nil, "Device is disconnected")
        for reply in replies { reply(nil, "Device is disconnected") }
        emit(["type": "lost"])
    }
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: (any Error)?) {
        guard peripheral === self.peripheral else { return }
        guard error == nil, let service = peripheral.services?.first(where: { $0.uuid == self.service }) else {
            let reply = connectReply; connectReply = nil; reply?(nil, "Setup service is unavailable"); return
        }
        peripheral.discoverCharacteristics(nil, for: service)
    }
    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: (any Error)?) {
        guard peripheral === self.peripheral else { return }
        let reply = connectReply; connectReply = nil
        guard error == nil else { reply?(nil, "Setup characteristics are unavailable"); return }
        for characteristic in service.characteristics ?? [] { characteristics[characteristic.uuid.uuidString.lowercased()] = characteristic }
        guard (2...6).allSatisfy({ characteristics[String(format: "f2d2000%d-eb8e-4a64-9ec7-ab0cbb8107c8", $0)] != nil }) else { reply?(nil, "Setup characteristics are unavailable"); return }
        reply?(nil, nil)
    }
    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: (any Error)?) {
        guard peripheral === self.peripheral else { return }
        let uuid = characteristic.uuid.uuidString.lowercased()
        let value = characteristic.value.flatMap { String(data: $0, encoding: .utf8) }
        if let reply = pending.removeValue(forKey: "read:\(uuid)") { reply(value, error == nil && value != nil ? nil : "Bluetooth read failed") }
        else if error == nil, let value { emit(["type": "value", "characteristic": uuid, "value": value]) }
    }
    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: (any Error)?) {
        guard peripheral === self.peripheral else { return }
        pending.removeValue(forKey: "write:\(characteristic.uuid.uuidString.lowercased())")?(nil, error == nil ? nil : "Bluetooth write rejected")
    }
    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: (any Error)?) {
        guard peripheral === self.peripheral else { return }
        pending.removeValue(forKey: "notify:\(characteristic.uuid.uuidString.lowercased())")?(nil, error == nil && characteristic.isNotifying ? nil : "Bluetooth notifications unavailable")
    }
}

#if os(macOS)
public typealias NativeReply = @Sendable @convention(c) (Int32, UnsafePointer<CChar>?, UnsafePointer<CChar>?) -> Void
@MainActor private let macBluetooth = DeviceBluetooth()
@_cdecl("comma_ble_request")
public func commaBleRequest(_ id: Int32, _ op: UnsafePointer<CChar>, _ json: UnsafePointer<CChar>, _ reply: NativeReply) {
    let operation = String(cString: op)
    let text = String(cString: json)
    Task { @MainActor in
        guard let data = text.data(using: .utf8), let input = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { "Invalid Bluetooth input".withCString { reply(id, nil, $0) }; return }
        macBluetooth.perform(operation, input) { value, error in
            if let error { error.withCString { reply(id, nil, $0) }; return }
            let data = try? JSONSerialization.data(withJSONObject: value ?? NSNull(), options: [.fragmentsAllowed])
            let answer = data.flatMap { String(data: $0, encoding: .utf8) } ?? "null"
            answer.withCString { reply(id, $0, nil) }
        }
    }
}
#endif
