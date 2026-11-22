import CoreBluetooth
import Foundation

/// 通过 CoreBluetooth 读取已连接 BLE 外设的标准 Battery Service (GATT 0x180F / Characteristic 0x2A19)
/// 覆盖 ZMK/QMK 蓝牙分体键盘、蓝牙低功耗鼠标、手写笔、穿戴外设等
public final class CoreBluetoothBASProvider: NSObject, BatteryProvider, @unchecked Sendable, CBCentralManagerDelegate, CBPeripheralDelegate {
    public let name = "CoreBluetooth BAS (0x180F)"

    private static let batteryServiceUUID = CBUUID(string: "180F")
    private static let batteryLevelUUID = CBUUID(string: "2A19")
    private static let userDescriptionUUID = CBUUID(string: "2901")

    private let queue = DispatchQueue(label: "com.peripheralbattery.corebluetooth")
    private let lock = NSLock()
    private var centralManager: CBCentralManager?
    private var trackedPeripherals: [UUID: CBPeripheral] = [:]
    private var readings: [UUID: PeripheralReading] = [:]
    private var onUpdate: (() -> Void)?

    private struct PeripheralReading {
        var name: String
        var mainLevel: Int?
        var charLevels: [String: (label: String, level: Int)] = [:]
        var lastUpdated: Date = Date()
    }

    public static var isSafeToUseCoreBluetooth: Bool {
        Bundle.main.bundleURL.pathExtension == "app"
            && Bundle.main.object(forInfoDictionaryKey: "NSBluetoothAlwaysUsageDescription") != nil
    }

    public init(onUpdate: (() -> Void)? = nil) {
        self.onUpdate = onUpdate
        super.init()
    }

    public func startIfPermitted() {
        guard Self.isSafeToUseCoreBluetooth else { return }
        queue.async { [weak self] in
            guard let self, self.centralManager == nil else { return }
            self.centralManager = CBCentralManager(delegate: self, queue: self.queue)
        }
    }

    public func setOnUpdate(_ callback: @escaping () -> Void) {
        lock.lock()
        onUpdate = callback
        lock.unlock()
    }

    public func triggerRefresh() {
        guard Self.isSafeToUseCoreBluetooth else { return }
        queue.async { [weak self] in
            guard let self else { return }
            if self.centralManager == nil {
                self.centralManager = CBCentralManager(delegate: self, queue: self.queue)
                return
            }
            if self.centralManager?.state == .poweredOn {
                self.pollConnectedPeripherals()
            }
        }
    }

    public func fetch() -> ProviderResult {
        startIfPermitted()
        return snapshot()
    }

    /// Read cached measurements without scheduling Bluetooth work.
    func snapshot() -> ProviderResult {
        lock.lock()
        let snapshot = readings
        lock.unlock()

        var devices: [PeripheralDevice] = []
        var diagnostics: [DiagnosticEntry] = []

        for (uuid, info) in snapshot {
            var subs: [SubBattery] = []
            if info.charLevels.count > 1 {
                let sorted = info.charLevels.sorted { $0.value.label < $1.value.label }
                for (cid, entry) in sorted {
                    subs.append(SubBattery(id: cid, label: entry.label, level: entry.level))
                }
            }
            let mainLevel = info.mainLevel ?? subs.map(\.level).min()
            guard mainLevel != nil || !subs.isEmpty else { continue }

            let id = "ble-\(uuid.uuidString.lowercased())"
            let category = DeviceClassifier.classify(name: info.name)
            devices.append(
                PeripheralDevice(
                    id: id,
                    name: info.name,
                    category: category,
                    transport: .ble,
                    batteryLevel: mainLevel,
                    subBatteries: subs,
                    chargingState: .discharging,
                    source: .coreBluetoothBAS,
                    sourceDetail: "BLE GATT 0x180F",
                    isExternal: true,
                    isConnected: true,
                    lastUpdated: info.lastUpdated
                )
            )
            diagnostics.append(
                DiagnosticEntry(
                    id: "diag-\(id)",
                    name: info.name,
                    transport: "BLE",
                    vendorIDHex: "-",
                    productIDHex: "-",
                    usagePageHex: "0x180F",
                    usageHex: "0x2A19",
                    matchedDriver: "CoreBluetooth BAS",
                    batterySummary: mainLevel.map { "\($0)%" } ?? "-",
                    rawNote: subs.isEmpty ? "Standard BAS" : subs.map { "\($0.label):\($0.level)%" }.joined(separator: ", ")
                )
            )
        }

        return ProviderResult(devices: devices, diagnostics: diagnostics)
    }

    // MARK: - CBCentralManagerDelegate

    public func centralManagerDidUpdateState(_ central: CBCentralManager) {
        if central.state == .poweredOn {
            pollConnectedPeripherals()
        } else {
            trackedPeripherals.removeAll()
            removeReadings(excluding: [])
        }
    }

    private func pollConnectedPeripherals() {
        guard let central = centralManager, central.state == .poweredOn else { return }
        let connected = central.retrieveConnectedPeripherals(withServices: [Self.batteryServiceUUID])
        let activeUUIDs = Set(connected.map(\.identifier))

        for key in trackedPeripherals.keys where !activeUUIDs.contains(key) {
            trackedPeripherals.removeValue(forKey: key)
        }
        removeReadings(excluding: activeUUIDs)

        for peripheral in connected {
            trackedPeripherals[peripheral.identifier] = peripheral
            peripheral.delegate = self
            if peripheral.state == .connected {
                peripheral.discoverServices([Self.batteryServiceUUID])
            } else if peripheral.state == .disconnected {
                central.connect(peripheral, options: nil)
            }
        }
    }

    public func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        guard isActive(peripheral) else { return }
        peripheral.delegate = self
        peripheral.discoverServices([Self.batteryServiceUUID])
    }

    public func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        discard(peripheral)
    }

    public func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        discard(peripheral)
    }

    private func isActive(_ peripheral: CBPeripheral) -> Bool {
        centralManager?.state == .poweredOn && peripheral.state == .connected
            && trackedPeripherals[peripheral.identifier] === peripheral
    }

    private func discard(_ peripheral: CBPeripheral) {
        let id = peripheral.identifier
        guard trackedPeripherals[id] === peripheral else { return }
        trackedPeripherals.removeValue(forKey: id)
        lock.lock()
        let removed = readings.removeValue(forKey: id) != nil
        lock.unlock()
        if removed { notifyUpdate() }
    }

    private func removeReadings(excluding active: Set<UUID>) {
        lock.lock()
        let removed = readings.keys.filter { !active.contains($0) }
        for key in removed { readings.removeValue(forKey: key) }
        lock.unlock()
        if !removed.isEmpty { notifyUpdate() }
    }

    // MARK: - CBPeripheralDelegate

    public func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard error == nil, isActive(peripheral), let services = peripheral.services else { return }
        for service in services where service.uuid == Self.batteryServiceUUID {
            peripheral.discoverCharacteristics([Self.batteryLevelUUID], for: service)
        }
    }

    public func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard error == nil, isActive(peripheral), let chars = service.characteristics else { return }
        for ch in chars where ch.uuid == Self.batteryLevelUUID {
            peripheral.readValue(for: ch)
            if ch.descriptors == nil {
                peripheral.discoverDescriptors(for: ch)
            }
            if ch.properties.contains(.notify), !ch.isNotifying {
                peripheral.setNotifyValue(true, for: ch)
            }
        }
    }

    public func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard error == nil,
              isActive(peripheral),
              characteristic.uuid == Self.batteryLevelUUID,
              let data = characteristic.value,
              let byte = data.first,
              byte <= 100
        else {
            return
        }

        let level = Int(byte)
        let devName = peripheral.name?.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedName = (devName?.isEmpty == false) ? devName! : "BLE 外设"
        let charKey = characteristic.uuid.uuidString + "-" + String(describing: characteristic.hash)
        let description = characteristic.descriptors?.first { $0.uuid == Self.userDescriptionUUID }
        let describedLabel = localizeSubBatteryLabel(description?.value)

        lock.lock()
        var entry = readings[peripheral.identifier] ?? PeripheralReading(name: resolvedName)
        entry.name = resolvedName
        entry.lastUpdated = Date()

        let existingLabel = entry.charLevels[charKey]?.label
        let defaultLabel = entry.charLevels.isEmpty ? "主电池" : "部件 \(entry.charLevels.count + 1)"
        entry.charLevels[charKey] = (label: describedLabel ?? existingLabel ?? defaultLabel, level: level)
        if entry.charLevels.count == 1 {
            entry.mainLevel = level
        } else {
            entry.mainLevel = entry.charLevels.values.map(\.level).min()
        }
        readings[peripheral.identifier] = entry
        lock.unlock()

        notifyUpdate()
    }

    public func peripheral(_ peripheral: CBPeripheral, didDiscoverDescriptorsFor characteristic: CBCharacteristic, error: Error?) {
        guard error == nil, isActive(peripheral), let descriptors = characteristic.descriptors else { return }
        for desc in descriptors where desc.uuid == Self.userDescriptionUUID {
            peripheral.readValue(for: desc)
        }
    }

    public func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor descriptor: CBDescriptor, error: Error?) {
        guard error == nil,
              isActive(peripheral),
              descriptor.uuid == Self.userDescriptionUUID,
              let ch = descriptor.characteristic,
              let label = localizeSubBatteryLabel(descriptor.value)
        else {
            return
        }
        let charKey = ch.uuid.uuidString + "-" + String(describing: ch.hash)
        lock.lock()
        guard var entry = readings[peripheral.identifier], let existing = entry.charLevels[charKey], existing.label != label else {
            lock.unlock()
            return
        }
        entry.charLevels[charKey] = (label: label, level: existing.level)
        readings[peripheral.identifier] = entry
        lock.unlock()
        notifyUpdate()
    }

    private func localizeSubBatteryLabel(_ value: Any?) -> String? {
        guard let raw = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
        let lower = raw.lowercased()
        if lower.contains("left") || lower == "l" { return "左手" }
        if lower.contains("right") || lower == "r" { return "右手" }
        if lower.contains("central") || lower.contains("main") { return "主控" }
        if lower.contains("peripheral") { return "副手" }
        return raw
    }

    private func notifyUpdate() {
        lock.lock()
        let cb = onUpdate
        lock.unlock()
        cb?()
    }
}
