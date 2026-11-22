import Foundation

public struct DiagnosticDeviceGroup: Identifiable {
    public let id: String
    public var devices: [PeripheralDevice] = []
    public var interfaces: [DiagnosticEntry] = []

    public var name: String {
        if devices.count == 1, let device = devices.first { return device.name }
        return interfaces.first?.name ?? devices.first?.name ?? "外设"
    }

    public var transport: String {
        if devices.count == 1, let device = devices.first { return device.transport.badgeText }
        return interfaces.first?.transport ?? devices.first?.transport.badgeText ?? "外设"
    }

    public var hasCurrentReading: Bool {
        devices.contains { $0.isConnected && $0.effectiveBatteryLevel != nil && !$0.hasStaleBatteryReading }
    }

    public var summary: String {
        if devices.count > 1 { return "\(devices.count) 台设备" }
        if let device = devices.first {
            if let level = device.effectiveBatteryLevel {
                return device.hasStaleBatteryReading ? "上次读数 \(level)%" : "\(level)%"
            }
            if device.requiresInputMonitoring { return "需开启输入监控" }
            if device.batteryReadingAt != nil { return "上次读数已过期" }
            if device.chargingState == .sleeping { return "休眠中" }
        }
        if interfaces.contains(where: { $0.batterySummary == "未连接" }) { return "未连接" }
        return "未读取到电量"
    }
}

public enum DiagnosticReport {
    public static func group(devices: [PeripheralDevice], entries: [DiagnosticEntry]) -> [DiagnosticDeviceGroup] {
        var groups: [String: DiagnosticDeviceGroup] = [:]
        var exactMatches: [String: String] = [:]

        for device in devices {
            let key = device.diagnosticGroupKey.map { "hardware:\($0)" } ?? "device:\(device.id)"
            groups[key, default: DiagnosticDeviceGroup(id: key)].devices.append(device)
            exactMatches[device.id] = key
        }

        var unmatchedEntries: [String: Int] = [:]
        for entry in entries {
            let deviceID = ["diag-", "usb-inv-", "stdhid-", "iokit-", "bt-"]
                .first { entry.id.hasPrefix($0) }
                .map { String(entry.id.dropFirst($0.count)) }
            let knownKey = entry.deviceGroupKey.map { "hardware:\($0)" }
                ?? deviceID.flatMap { exactMatches[$0] }
            let key: String
            if let knownKey {
                key = knownKey
            } else {
                unmatchedEntries[entry.id, default: 0] += 1
                key = "interface:\(entry.id):\(unmatchedEntries[entry.id] ?? 1)"
            }
            groups[key, default: DiagnosticDeviceGroup(id: key)].interfaces.append(entry)
        }

        return groups.values.sorted { lhs, rhs in
            if lhs.devices.isEmpty != rhs.devices.isEmpty { return !lhs.devices.isEmpty }
            let nameOrder = lhs.name.localizedStandardCompare(rhs.name)
            return nameOrder == .orderedSame ? lhs.id < rhs.id : nameOrder == .orderedAscending
        }
    }

    public static func redactedJSON(groups: [DiagnosticDeviceGroup], generatedAt: Date?) throws -> Data {
        let export = Export(generatedAt: generatedAt, groups: groups.enumerated().map { index, group in
            Export.Group(
                number: index + 1,
                devices: group.devices.map { device in
                    Export.Reading(
                        category: device.category,
                        transport: device.transport,
                        source: device.source,
                        batteryPercent: device.effectiveBatteryLevel,
                        subBatteryPercentages: device.subBatteries.map(\.level),
                        readingAt: device.batteryReadingAt,
                        stale: device.hasStaleBatteryReading,
                        chargingState: device.chargingState,
                        requiresInputMonitoring: device.requiresInputMonitoring
                    )
                },
                interfaces: group.interfaces.map { entry in
                    let reportedPercent = reportedPercent(entry.batterySummary)
                    return Export.Interface(
                        vendorID: hexCode(entry.vendorIDHex),
                        productID: hexCode(entry.productIDHex),
                        usagePage: hexCode(entry.usagePageHex),
                        usage: hexCode(entry.usageHex),
                        drivers: knownDrivers(entry.matchedDriver),
                        status: reportedPercent == nil ? interfaceStatus(entry.batterySummary) : .reported,
                        reportedPercent: reportedPercent
                    )
                }
            )
        })
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(export)
    }

    private static func hexCode(_ value: String) -> String? {
        guard value.hasPrefix("0x"), value.count <= 6,
              let code = UInt16(value.dropFirst(2), radix: 16) else { return nil }
        return String(format: "0x%04X", code)
    }

    private static func knownDrivers(_ value: String) -> [String] {
        let builtIn: Set<String> = [
            "USB Inventory", "CoreBluetooth BAS", "SPBluetoothDataType", "Standard HID Power (0x06/0x85)",
            "YJX-CHIP HID (0xFF01)", "EVision HID (0xFF1C)", "Compx HID (0xFF02)", "Logitech HID++ 2.0",
            "Razer HID (90B)", "Sony DualSense / DS4", "SteelSeries HID (0x1038)", "Corsair Bragi HID", "自定义 JSON HID 规则"
        ]
        return value.components(separatedBy: ", ").compactMap { driver in
            if builtIn.contains(driver) { return driver }
            if driver.hasPrefix("IOKit (") { return "IOKit" }
            if driver.hasPrefix("IOPowerSources (") { return "IOPowerSources" }
            return nil
        }
    }

    private static func interfaceStatus(_ value: String) -> Export.Interface.Status {
        if value == "未连接" { return .disconnected }
        if value == "权限受限（需输入监控）" { return .permissionRequired }
        if value == "同设备其他接口（已通过主接口读取）" { return .secondaryInterface }
        if value == "休眠中" { return .sleeping }
        return .unavailable
    }

    private static func reportedPercent(_ value: String) -> Int? {
        guard value.hasSuffix("%"), let percent = Int(value.dropLast()), (0...100).contains(percent) else { return nil }
        return percent
    }

    // These types intentionally omit device names, hardware identifiers, and all unstructured text.
    private struct Export: Encodable {
        let schemaVersion = 1
        let generatedAt: Date?
        let groups: [Group]

        struct Group: Encodable {
            let number: Int
            let devices: [Reading]
            let interfaces: [Interface]
        }

        struct Reading: Encodable {
            let category: DeviceCategory
            let transport: DeviceTransport
            let source: BatterySourceKind
            let batteryPercent: Int?
            let subBatteryPercentages: [Int]
            let readingAt: Date?
            let stale: Bool
            let chargingState: ChargingState
            let requiresInputMonitoring: Bool
        }

        struct Interface: Encodable {
            enum Status: String, Encodable {
                case reported, unavailable, disconnected, permissionRequired, secondaryInterface, sleeping
            }

            let vendorID: String?
            let productID: String?
            let usagePage: String?
            let usage: String?
            let drivers: [String]
            let status: Status
            let reportedPercent: Int?
        }
    }
}
