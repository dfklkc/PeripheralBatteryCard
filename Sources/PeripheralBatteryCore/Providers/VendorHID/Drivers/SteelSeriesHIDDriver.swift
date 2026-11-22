import Foundation
import IOKit.hid

/// SteelSeries 赛睿无线鼠标与 Arctis / Nova 系列无线耳机 HID 协议驱动（VID 0x1038）
public final class SteelSeriesHIDDriver: HIDVendorDriver {
    public let driverID = "steelseries-hid"
    public let displayName = "SteelSeries HID (0x1038)"

    public init() {}

    public func matches(descriptor: HIDDeviceDescriptor) -> Bool {
        guard !descriptor.isBuiltIn, descriptor.vendorID == 0x1038 else { return false }
        return descriptor.hasUsagePair(page: 0xFFC0)
            || descriptor.hasUsagePair(page: 0xFF00)
            || descriptor.hasUsagePair(page: 0xFFC2)
    }

    public func query(device: IOHIDDevice, descriptor: HIDDeviceDescriptor) -> [VendorBatteryReading] {
        let lowerName = descriptor.product.lowercased()
        let looksLikeHeadset = lowerName.contains("arctis")
            || lowerName.contains("nova")
            || lowerName.contains("headset")
            || descriptor.hasUsagePair(page: 0xFFC0, usage: 0x0001)

        return HIDDeviceHelper.withOpenDevice(device) { opened in
            if !looksLikeHeadset {
                for cmd: UInt8 in [0x92, 0xD2] {
                    let req = Self.buildMouseRequest(command: cmd, length: max(descriptor.maxOutputReportSize, 2))
                    if let resp = HIDDeviceHelper.exchangeOutputInputReport(
                        device: opened,
                        outputReportID: 0,
                        payload: req,
                        expectedInputSize: max(descriptor.maxInputReportSize, 64),
                        timeout: 0.4,
                        matcher: { _, bytes in
                            bytes.count >= 2 && bytes[0] == cmd
                        }
                    ), let parsed = Self.parseMouseResponse(resp, command: cmd) {
                        return [parsed]
                    }
                }
            }

            let headsetReq = Self.buildHeadsetRequest(length: max(descriptor.maxOutputReportSize, 64))
            if let resp = HIDDeviceHelper.exchangeOutputInputReport(
                device: opened,
                outputReportID: 0,
                payload: headsetReq,
                expectedInputSize: max(descriptor.maxInputReportSize, 64),
                timeout: 0.45,
                matcher: { _, bytes in
                    bytes.count >= 4 && (bytes[0] == 0x06 || bytes[0] == 0xB0 || bytes[1] == 0xB0)
                }
            ), let parsed = Self.parseHeadsetResponse(resp) {
                return [parsed]
            }

            return []
        } ?? []
    }

    public static func buildMouseRequest(command: UInt8 = 0x92, length: Int = 64) -> [UInt8] {
        var req = [UInt8](repeating: 0, count: max(length, 2))
        req[0] = command
        return req
    }

    public static func buildHeadsetRequest(length: Int = 64) -> [UInt8] {
        var req = [UInt8](repeating: 0, count: max(length, 2))
        req[0] = 0x06
        req[1] = 0xB0
        return req
    }

    public static func parseMouseResponse(_ bytes: [UInt8], command: UInt8) -> VendorBatteryReading? {
        guard bytes.count >= 2, bytes[0] == command else { return nil }
        let raw = bytes[1]
        let isCharging = (raw & 0x80) != 0
        let step = Int(raw & 0x7F)
        let level: Int
        if step == 0 {
            level = 0
        } else {
            level = min(max((step - 1) * 5, 0), 100)
        }
        let chargingState: ChargingState = isCharging ? (level >= 100 ? .full : .charging) : .discharging
        return VendorBatteryReading(
            slotKey: "0",
            categoryOverride: .mouse,
            transportOverride: .wireless24G,
            batteryLevel: level,
            chargingState: chargingState
        )
    }

    public static func parseHeadsetResponse(_ bytes: [UInt8]) -> VendorBatteryReading? {
        guard bytes.count >= 4 else { return nil }
        let candidate: Int
        if bytes[0] == 0x06 && bytes[1] == 0xB0 {
            candidate = Int(bytes[2])
        } else if bytes[0] == 0xB0 {
            candidate = Int(bytes[1])
        } else {
            candidate = Int(bytes[3])
        }
        guard (0...100).contains(candidate) else { return nil }
        return VendorBatteryReading(
            slotKey: "0",
            categoryOverride: .headphones,
            transportOverride: .wireless24G,
            batteryLevel: candidate,
            chargingState: .discharging
        )
    }
}
