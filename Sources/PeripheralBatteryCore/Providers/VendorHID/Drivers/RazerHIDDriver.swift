import Foundation
import IOKit.hid

/// Razer 雷蛇 90 字节 Feature Report 协议驱动（Viper、DeathAdder、Basilisk、Naga、BlackWidow 等 0x1532 设备/接收器）
public final class RazerHIDDriver: HIDVendorDriver {
    public let driverID = "razer-feature90"
    public let displayName = "Razer HID (90B)"

    private static let candidateTxIDs: [UInt8] = [0x1F, 0x3F, 0xFF]

    public init() {}

    public func matches(descriptor: HIDDeviceDescriptor) -> Bool {
        guard !descriptor.isBuiltIn, descriptor.vendorID == 0x1532 else { return false }
        return descriptor.maxFeatureReportSize >= 90 || descriptor.hasVendorUsagePage()
    }

    public func query(device: IOHIDDevice, descriptor: HIDDeviceDescriptor) -> [VendorBatteryReading] {
        return HIDDeviceHelper.withOpenDevice(device) { opened in
            var sawSleep = false

            for txID in Self.candidateTxIDs {
                let batReq = Self.buildRequest(transactionID: txID, commandID: 0x80)
                guard let batResp = HIDDeviceHelper.exchangeFeatureReport(
                    device: opened,
                    reportID: 0,
                    request: batReq,
                    responseLength: 90,
                    delayMs: 40
                ) else {
                    continue
                }

                if let first = batResp.first, first == 0x04 {
                    sawSleep = true
                    continue
                }

                guard let level = Self.parseBatteryResponse(batResp) else {
                    continue
                }

                var chargingState: ChargingState = .discharging
                let chReq = Self.buildRequest(transactionID: txID, commandID: 0x84)
                if let chResp = HIDDeviceHelper.exchangeFeatureReport(
                    device: opened,
                    reportID: 0,
                    request: chReq,
                    responseLength: 90,
                    delayMs: 35
                ), let isCharging = Self.parseChargingResponse(chResp) {
                    chargingState = isCharging ? (level >= 100 ? .full : .charging) : .discharging
                }

                let transport = DeviceClassifier.inferTransport(
                    rawTransport: descriptor.transport,
                    productName: descriptor.product,
                    productID: descriptor.productID
                )
                return [
                    VendorBatteryReading(
                        slotKey: "0",
                        transportOverride: transport,
                        batteryLevel: level,
                        chargingState: chargingState
                    )
                ]
            }

            if sawSleep {
                return [
                    VendorBatteryReading(
                        slotKey: "0",
                        transportOverride: .wireless24G,
                        batteryLevel: nil,
                        chargingState: .sleeping,
                        statusHint: "休眠中"
                    )
                ]
            }
            return []
        } ?? []
    }

    public static func buildRequest(transactionID: UInt8 = 0x1F, commandID: UInt8) -> [UInt8] {
        var msg = [UInt8](repeating: 0, count: 90)
        msg[0] = 0x00 // Status: New command
        msg[1] = transactionID
        msg[5] = 0x02 // Data size
        msg[6] = 0x07 // Command class: Power
        msg[7] = commandID
        var crc: UInt8 = 0
        for i in 2..<88 {
            crc ^= msg[i]
        }
        msg[88] = crc
        return msg
    }

    public static func parseBatteryResponse(_ bytes: [UInt8]) -> Int? {
        guard bytes.count >= 12, bytes[0] == 0x02, bytes[6] == 0x07, bytes[7] == 0x80 else {
            return nil
        }
        let raw = Int(bytes[9])
        return min(max(Int((Double(raw) / 255.0 * 100.0).rounded()), 0), 100)
    }

    public static func parseChargingResponse(_ bytes: [UInt8]) -> Bool? {
        guard bytes.count >= 12, bytes[0] == 0x02, bytes[6] == 0x07, bytes[7] == 0x84 else {
            return nil
        }
        return bytes[9] != 0
    }
}
