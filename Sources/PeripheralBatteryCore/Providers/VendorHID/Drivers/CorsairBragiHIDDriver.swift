import Foundation
import IOKit.hid

/// Corsair 美商海盗船 Bragi / Slipstream 协议驱动（HS80、Virtuoso、Dark Core、Sabre 等 0x1B1C 设备）
public final class CorsairBragiHIDDriver: HIDVendorDriver {
    public let driverID = "corsair-bragi"
    public let displayName = "Corsair Bragi HID"

    public init() {}

    public func matches(descriptor: HIDDeviceDescriptor) -> Bool {
        guard !descriptor.isBuiltIn, descriptor.vendorID == 0x1B1C else { return false }
        guard descriptor.maxOutputReportSize == 64 else { return false }
        return descriptor.hasUsagePair(page: 0xFF42) || descriptor.hasUsagePair(page: 0xFFC5)
    }

    public func query(device: IOHIDDevice, descriptor: HIDDeviceDescriptor) -> [VendorBatteryReading] {
        return HIDDeviceHelper.withOpenDevice(device) { opened in
            let batReq = Self.buildGetPropertyRequest(reportID: 0x08, propertyID: 0x0F)
            guard let batResp = HIDDeviceHelper.exchangeOutputInputReport(
                device: opened,
                outputReportID: 0x08,
                payload: batReq,
                expectedInputSize: 64,
                timeout: 0.5,
                matcher: { _, bytes in
                    bytes.count >= 7 && (bytes[2] == 0x0F || bytes[3] == 0x0F)
                }
            ), let level = Self.parseBatteryLevelResponse(batResp) else {
                return []
            }

            var chargingState: ChargingState = .discharging
            let chReq = Self.buildGetPropertyRequest(reportID: 0x08, propertyID: 0x10)
            if let chResp = HIDDeviceHelper.exchangeOutputInputReport(
                device: opened,
                outputReportID: 0x08,
                payload: chReq,
                expectedInputSize: 64,
                timeout: 0.35,
                matcher: { _, bytes in
                    bytes.count >= 6 && (bytes[2] == 0x10 || bytes[3] == 0x10)
                }
            ), let parsedState = Self.parseChargingResponse(chResp, level: level) {
                chargingState = parsedState
            }

            return [
                VendorBatteryReading(
                    slotKey: "0",
                    transportOverride: .wireless24G,
                    batteryLevel: level,
                    chargingState: chargingState
                )
            ]
        } ?? []
    }

    public static func buildGetPropertyRequest(reportID: UInt8 = 0x08, propertyID: UInt8) -> [UInt8] {
        var req = [UInt8](repeating: 0, count: 64)
        req[0] = reportID
        req[1] = 0x02 // GET
        req[2] = propertyID
        return req
    }

    /// 解析千分比电量（如 1000 = 100.0%）
    public static func parseBatteryLevelResponse(_ bytes: [UInt8]) -> Int? {
        guard bytes.count >= 7 else { return nil }
        let tenths: Int
        if bytes[3] == 0x0F {
            tenths = Int(bytes[5]) | (Int(bytes[6]) << 8)
        } else if bytes[2] == 0x0F {
            tenths = Int(bytes[4]) | (Int(bytes[5]) << 8)
        } else {
            return nil
        }
        guard (0...1000).contains(tenths) else { return nil }
        return min(max(Int((Double(tenths) / 10.0).rounded()), 0), 100)
    }

    public static func parseChargingResponse(_ bytes: [UInt8], level: Int) -> ChargingState? {
        guard bytes.count >= 6 else { return nil }
        let status: UInt8
        if bytes[3] == 0x10 {
            status = bytes[5]
        } else if bytes[2] == 0x10 {
            status = bytes[4]
        } else {
            return nil
        }
        switch status {
        case 1: return level >= 100 ? .full : .charging
        case 2: return .full
        default: return .discharging
        }
    }
}
