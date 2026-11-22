import Foundation
import IOKit.hid

/// 用户可扩展的自定义 HID 协议规则（JSON 配置）
public struct CustomHIDRule: Codable, Equatable, Sendable {
    public var name: String
    public var vendorID: String
    public var productID: String?
    public var usagePage: String?
    public var usage: String?
    public var reportType: String
    public var reportID: Int
    public var reportLength: Int
    public var requestHex: String
    public var responsePrefixHex: String?
    public var batteryByteIndex: Int
    public var batteryMaxValue: Int?
    public var chargingByteIndex: Int?
    public var chargingMask: Int?
    public var category: DeviceCategory?

    public init(
        name: String,
        vendorID: String,
        productID: String? = nil,
        usagePage: String? = nil,
        usage: String? = nil,
        reportType: String = "output",
        reportID: Int = 0,
        reportLength: Int = 64,
        requestHex: String,
        responsePrefixHex: String? = nil,
        batteryByteIndex: Int,
        batteryMaxValue: Int? = 100,
        chargingByteIndex: Int? = nil,
        chargingMask: Int? = nil,
        category: DeviceCategory? = nil
    ) {
        self.name = name
        self.vendorID = vendorID
        self.productID = productID
        self.usagePage = usagePage
        self.usage = usage
        self.reportType = reportType
        self.reportID = reportID
        self.reportLength = reportLength
        self.requestHex = requestHex
        self.responsePrefixHex = responsePrefixHex
        self.batteryByteIndex = batteryByteIndex
        self.batteryMaxValue = batteryMaxValue
        self.chargingByteIndex = chargingByteIndex
        self.chargingMask = chargingMask
        self.category = category
    }

    public func matches(descriptor: HIDDeviceDescriptor) -> Bool {
        guard !descriptor.isBuiltIn else { return false }
        guard let vid = Self.parseHexOrDec(vendorID), descriptor.vendorID == vid else {
            return false
        }
        if let pidStr = productID, !pidStr.isEmpty {
            guard let pid = Self.parseHexOrDec(pidStr), descriptor.productID == pid else {
                return false
            }
        }
        if let upStr = usagePage, !upStr.isEmpty {
            guard let up = Self.parseHexOrDec(upStr) else { return false }
            if let uStr = usage, !uStr.isEmpty {
                guard let u = Self.parseHexOrDec(uStr), descriptor.hasUsagePair(page: up, usage: u) else {
                    return false
                }
            } else if !descriptor.hasUsagePair(page: up) {
                return false
            }
        }
        return true
    }

    public func buildRequestBytes() -> [UInt8] {
        let raw = Self.parseHexBytes(requestHex)
        let targetLen = max(reportLength, raw.count)
        var padded = [UInt8](repeating: 0, count: targetLen)
        for (i, b) in raw.enumerated() where i < targetLen {
            padded[i] = b
        }
        return padded
    }

    public func parseResponse(_ bytes: [UInt8]) -> VendorBatteryReading? {
        let prefix = Self.parseHexBytes(responsePrefixHex ?? "")
        if !prefix.isEmpty {
            guard bytes.count >= prefix.count else { return nil }
            for (i, expected) in prefix.enumerated() where bytes[i] != expected {
                return nil
            }
        }

        guard batteryByteIndex >= 0 && batteryByteIndex < bytes.count else {
            return nil
        }

        let rawBat = Int(bytes[batteryByteIndex])
        let maxVal = max(batteryMaxValue ?? 100, 1)
        let level = min(max(Int((Double(rawBat) / Double(maxVal) * 100.0).rounded()), 0), 100)

        var chargingState: ChargingState = .discharging
        if let chIdx = chargingByteIndex, chIdx >= 0 && chIdx < bytes.count {
            let mask = chargingMask ?? 0xFF
            let isCharging = (Int(bytes[chIdx]) & mask) != 0
            chargingState = isCharging ? (level >= 100 ? .full : .charging) : .discharging
        }

        return VendorBatteryReading(
            slotKey: "0",
            categoryOverride: category,
            batteryLevel: level,
            chargingState: chargingState
        )
    }

    static func parseHexOrDec(_ str: String) -> Int? {
        let trimmed = str.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if trimmed.hasPrefix("0x") {
            return Int(trimmed.dropFirst(2), radix: 16)
        }
        return Int(trimmed, radix: 10)
    }

    static func parseHexBytes(_ hex: String) -> [UInt8] {
        let cleaned = hex
            .replacingOccurrences(of: "0x", with: "")
            .replacingOccurrences(of: ",", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.isEmpty { return [] }

        let tokens = cleaned.split { $0.isWhitespace }
        if tokens.count > 1 {
            return tokens.compactMap { UInt8($0, radix: 16) }
        }
        // 连续十六进制字符串
        var result: [UInt8] = []
        var idx = cleaned.startIndex
        while idx < cleaned.endIndex {
            guard let next = cleaned.index(idx, offsetBy: 2, limitedBy: cleaned.endIndex) else { break }
            if let byte = UInt8(cleaned[idx..<next], radix: 16) {
                result.append(byte)
            }
            idx = next
        }
        return result
    }
}

/// 从 `~/Library/Application Support/PeripheralBatteryCard/custom_protocols.json` 加载自定义外设 HID 协议规则
public final class CustomJSONRuleDriver: HIDVendorDriver, @unchecked Sendable {
    public let driverID = "custom-json-rules"
    public let displayName = "自定义 JSON HID 规则"

    private let lock = NSLock()
    private var cachedRules: [CustomHIDRule]
    private let usesDiskConfig: Bool

    public static var configFileURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return appSupport
            .appendingPathComponent("PeripheralBatteryCard", isDirectory: true)
            .appendingPathComponent("custom_protocols.json")
    }

    public init(rules: [CustomHIDRule]? = nil) {
        if let rules {
            self.cachedRules = rules
            self.usesDiskConfig = false
        } else {
            self.cachedRules = Self.loadRulesFromDisk()
            self.usesDiskConfig = true
        }
    }

    public func reloadIfNeeded() {
        guard usesDiskConfig else { return }
        let loaded = Self.loadRulesFromDisk()
        lock.lock()
        cachedRules = loaded
        lock.unlock()
    }

    private func currentRules() -> [CustomHIDRule] {
        reloadIfNeeded()
        lock.lock()
        let copy = cachedRules
        lock.unlock()
        return copy
    }

    public static func loadRulesFromDisk() -> [CustomHIDRule] {
        let url = configFileURL
        guard FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([CustomHIDRule].self, from: data)
        else {
            return []
        }
        return decoded
    }

    @discardableResult
    public static func ensureSampleTemplateFile() -> URL {
        let url = configFileURL
        let dir = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        if !FileManager.default.fileExists(atPath: url.path) {
            let sample = [
                CustomHIDRule(
                    name: "示例设备（按需修改后启用）",
                    vendorID: "0xFFFF",
                    productID: "0x0001",
                    usagePage: "0xFF00",
                    usage: nil,
                    reportType: "output",
                    reportID: 0,
                    reportLength: 64,
                    requestHex: "55 30 A5 0B 2E 01 01 01",
                    responsePrefixHex: "AA 30",
                    batteryByteIndex: 8,
                    batteryMaxValue: 100,
                    chargingByteIndex: 9,
                    chargingMask: 1,
                    category: .mouse
                )
            ]
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            if let data = try? encoder.encode(sample) {
                try? data.write(to: url)
            }
        }
        return url
    }

    public func matches(descriptor: HIDDeviceDescriptor) -> Bool {
        currentRules().contains { $0.matches(descriptor: descriptor) }
    }

    public func query(device: IOHIDDevice, descriptor: HIDDeviceDescriptor) -> [VendorBatteryReading] {
        let matchingRules = currentRules().filter { $0.matches(descriptor: descriptor) }
        guard !matchingRules.isEmpty else { return [] }

        return HIDDeviceHelper.withOpenDevice(device) { opened in
            for rule in matchingRules {
                let req = rule.buildRequestBytes()
                let response: [UInt8]?
                if rule.reportType.lowercased() == "feature" {
                    response = HIDDeviceHelper.exchangeFeatureReport(
                        device: opened,
                        reportID: rule.reportID,
                        request: req,
                        responseLength: max(rule.reportLength, 64),
                        delayMs: 35
                    )
                } else {
                    let prefix = CustomHIDRule.parseHexBytes(rule.responsePrefixHex ?? "")
                    response = HIDDeviceHelper.exchangeOutputInputReport(
                        device: opened,
                        outputReportID: rule.reportID,
                        payload: req,
                        expectedInputSize: max(rule.reportLength, 64),
                        timeout: 0.6
                    ) { _, bytes in
                        guard bytes.count > rule.batteryByteIndex else { return false }
                        if prefix.isEmpty { return true }
                        guard bytes.count >= prefix.count else { return false }
                        return zip(prefix, bytes).allSatisfy { $0 == $1 }
                    }
                }

                if let response, let reading = rule.parseResponse(response) {
                    return [reading]
                }
            }
            return []
        } ?? []
    }
}
