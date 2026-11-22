import Foundation
import IOKit

/// 从 IOKit 注册表读取由苹果 HID/蓝牙驱动上报的标准化 BatteryPercent 设备（如 Magic Mouse/Keyboard/Trackpad、部分蓝牙外设与手柄）
public final class IOKitHIDBatteryProvider: BatteryProvider {
    public let name = "IOKit HID Battery"

    private static let candidateClasses = [
        "AppleDeviceManagementHIDEventService",
        "AppleHSBluetoothDevice",
        "BNBMouseDevice",
        "BNBTrackpadDevice",
        "AppleBluetoothHIDKeyboard",
        "IOHIDDevice"
    ]

    public init() {}

    public func fetch() -> ProviderResult {
        var devices: [PeripheralDevice] = []
        var diagnostics: [DiagnosticEntry] = []
        var seenEntries = Set<String>()

        for className in Self.candidateClasses {
            guard let matching = IOServiceMatching(className) else { continue }
            var iterator: io_iterator_t = 0
            let kr = IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator)
            guard kr == KERN_SUCCESS else { continue }
            defer { IOObjectRelease(iterator) }

            while case let service = IOIteratorNext(iterator), service != 0 {
                defer { IOObjectRelease(service) }

                var propsRef: Unmanaged<CFMutableDictionary>?
                let pkr = IORegistryEntryCreateCFProperties(service, &propsRef, kCFAllocatorDefault, 0)
                guard pkr == KERN_SUCCESS, let props = propsRef?.takeRetainedValue() as? [String: Any] else {
                    continue
                }

                if let builtIn = props["Built-In"] as? Bool, builtIn {
                    continue
                }
                let transportRaw = props["Transport"] as? String
                if let t = transportRaw?.lowercased(), t == "spi" || t == "spu" || t == "audio" {
                    continue
                }

                guard let batteryPercent = intValue(props["BatteryPercent"]) else {
                    continue
                }

                let product = (props["Product"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
                    ?? (props["Name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
                    ?? "蓝牙/HID 外设"
                let vendorID = intValue(props["VendorID"])
                let productID = intValue(props["ProductID"])
                let serial = (props["SerialNumber"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
                let locationID = intValue(props["LocationID"] ?? props["locationID"])
                let btAddr = normalizeBTAddress(props["DeviceAddress"] as? String ?? props["BD_ADDR"] as? String)
                let usagePage = intValue(props["PrimaryUsagePage"])
                let usage = intValue(props["PrimaryUsage"])

                var entryID: UInt64 = 0
                IORegistryEntryGetRegistryEntryID(service, &entryID)
                let dedupKey = PeripheralDevice.hardwareGroupKey(vendorID: vendorID, productID: productID,
                    serialNumber: serial, bluetoothAddress: btAddr, physicalLocationID: locationID)
                    ?? "registry-\(entryID)"
                if seenEntries.contains(dedupKey) {
                    continue
                }
                seenEntries.insert(dedupKey)

                let charging = inferChargingState(from: props)
                let transport = DeviceClassifier.inferTransport(
                    rawTransport: transportRaw,
                    productName: product,
                    productID: productID,
                    isBluetooth: className.contains("Bluetooth") || className.hasPrefix("BNB")
                )
                let category = DeviceClassifier.classify(
                    name: product,
                    usagePage: usagePage,
                    usage: usage
                )

                let canonicalID = makeID(btAddr: btAddr, vendorID: vendorID, productID: productID, serial: serial, name: product)

                let device = PeripheralDevice(
                    id: canonicalID,
                    name: product,
                    category: category,
                    transport: transport,
                    batteryLevel: batteryPercent,
                    chargingState: charging,
                    source: .iokitHID,
                    sourceDetail: className,
                    vendorID: vendorID,
                    productID: productID,
                    serialNumber: serial,
                    bluetoothAddress: btAddr,
                    physicalLocationID: locationID,
                    isExternal: true,
                    isConnected: true
                )
                devices.append(device)

                diagnostics.append(
                    DiagnosticEntry(
                        id: "iokit-\(canonicalID)",
                        name: product,
                        transport: transport.badgeText,
                        vendorIDHex: DeviceClassifier.formatHex(vendorID),
                        productIDHex: DeviceClassifier.formatHex(productID),
                        usagePageHex: DeviceClassifier.formatHex(usagePage),
                        usageHex: DeviceClassifier.formatHex(usage),
                        matchedDriver: "IOKit (\(className))",
                        batterySummary: "\(batteryPercent)%",
                        rawNote: "BatteryPercent=\(batteryPercent)",
                        deviceGroupKey: device.diagnosticGroupKey
                    )
                )
            }
        }

        return ProviderResult(devices: devices, diagnostics: diagnostics)
    }

    private func inferChargingState(from props: [String: Any]) -> ChargingState {
        if let isCharging = props["BatteryCharging"] as? Bool {
            return isCharging ? .charging : .discharging
        }
        if let isCharging = props["Charging"] as? Bool {
            return isCharging ? .charging : .discharging
        }
        if let flags = intValue(props["BatteryStatusFlags"]) {
            // Apple HID BatteryStatusFlags: bit 0/1 常用于表示充电中
            if (flags & 0x01) != 0 || (flags & 0x02) != 0 {
                return .charging
            }
        }
        if let state = (props["BatteryState"] as? String)?.lowercased() {
            if state.contains("charg") { return .charging }
            if state.contains("full") { return .full }
        }
        return .discharging
    }

    private func intValue(_ raw: Any?) -> Int? {
        if let v = raw as? Int { return v }
        if let v = raw as? NSNumber { return v.intValue }
        return nil
    }

    private func normalizeBTAddress(_ addr: String?) -> String? {
        guard let addr = addr?.trimmingCharacters(in: .whitespacesAndNewlines), !addr.isEmpty else {
            return nil
        }
        return addr.uppercased().replacingOccurrences(of: "-", with: ":")
    }

    private func makeID(btAddr: String?, vendorID: Int?, productID: Int?, serial: String?, name: String) -> String {
        if let btAddr { return "bt-\(btAddr)" }
        if let vid = vendorID, let pid = productID {
            if let serial, !serial.isEmpty {
                return String(format: "hid-%04x-%04x-%@", vid, pid, serial)
            }
            return String(format: "hid-%04x-%04x-%@", vid, pid, name.lowercased())
        }
        return "iokit-\(name.lowercased())"
    }
}
