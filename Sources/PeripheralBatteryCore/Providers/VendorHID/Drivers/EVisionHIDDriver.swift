import Foundation
import IOKit.hid

/// EVision / Telink 方案无线机械键盘协议驱动（如 VXE V87、VGN V87/V98/S99、ATK、Wobkey Rainy75、Akko/Ajazz/CHERRY 等）
public final class EVisionHIDDriver: HIDVendorDriver {
    public let driverID = "evision-ff1c"
    public let displayName = "EVision HID (0xFF1C)"

    private static let knownVendorIDs: Set<Int> = [0x320F, 0x0C45, 0x258A, 0x3151]

    public init() {}

    public func matches(descriptor: HIDDeviceDescriptor) -> Bool {
        guard !descriptor.isBuiltIn, descriptor.vendorID != 0x05AC else { return false }
        guard descriptor.maxOutputReportSize == 64 && descriptor.maxInputReportSize == 64 else {
            return false
        }
        if Self.knownVendorIDs.contains(descriptor.vendorID) && descriptor.hasUsagePair(page: 0xFF1C) {
            return true
        }
        return descriptor.hasUsagePair(page: 0xFF1C, usage: 0x0092)
    }

    public func query(device: IOHIDDevice, descriptor: HIDDeviceDescriptor) -> [VendorBatteryReading] {
        let request = Self.buildBatteryRequest()
        guard let response = HIDDeviceHelper.withOpenDevice(device, body: { opened in
            HIDDeviceHelper.exchangeOutputInputReport(
                device: opened,
                outputReportID: 0x04,
                payload: request,
                expectedInputSize: 64,
                timeout: 0.6
            ) { reportID, bytes in
                (reportID == 4 || bytes.first == 0x04) && bytes.count >= 10 && bytes[3] == 0x1A
            }
        }) else {
            return []
        }

        guard let parsed = Self.parseBatteryResponse(response, descriptor: descriptor) else {
            return []
        }
        return [parsed]
    }

    public static func buildBatteryRequest() -> [UInt8] {
        var req = [UInt8](repeating: 0, count: 64)
        req[0] = 0x04
        req[3] = 0x1A
        var sum: UInt16 = 0
        for i in 3..<64 {
            sum &+= UInt16(req[i])
        }
        req[1] = UInt8(sum & 0xFF)
        req[2] = UInt8((sum >> 8) & 0xFF)
        return req
    }

    public static func parseBatteryResponse(
        _ bytes: [UInt8],
        descriptor: HIDDeviceDescriptor? = nil
    ) -> VendorBatteryReading? {
        guard bytes.count >= 10, bytes[0] == 0x04, bytes[3] == 0x1A else {
            return nil
        }
        let rawLevel = Int(bytes[8])
        guard rawLevel <= 100 else { return nil }
        let isCharging = bytes[9] != 0

        let chargingState: ChargingState
        if isCharging {
            chargingState = rawLevel >= 100 ? .full : .charging
        } else {
            chargingState = .discharging
        }

        let transport: DeviceTransport
        if let desc = descriptor {
            transport = DeviceClassifier.inferTransport(
                rawTransport: desc.transport,
                productName: desc.product,
                productID: desc.productID
            )
        } else {
            transport = .usb
        }

        return VendorBatteryReading(
            slotKey: "0",
            categoryOverride: .keyboard,
            transportOverride: transport,
            batteryLevel: rawLevel,
            chargingState: chargingState
        )
    }
}
