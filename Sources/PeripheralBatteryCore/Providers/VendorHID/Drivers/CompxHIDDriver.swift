import Foundation
import IOKit.hid

/// Compx / 博通常见国产轻量化无线鼠标方案协议驱动（如 VXE R1、蜻蜓 F1/F1 Pro、ATK、Pulsar、Lamzu、Ninjutso、Darmoshark、MCHOSE 旧版等）
public final class CompxHIDDriver: HIDVendorDriver {
    public let driverID = "compx-ff02"
    public let displayName = "Compx HID (0xFF02)"

    private static let knownVendorIDs: Set<Int> = [
        0x373B, 0x3554, 0x248A, 0x1915, 0x3553, 0x3837
    ]

    public init() {}

    public func matches(descriptor: HIDDeviceDescriptor) -> Bool {
        guard !descriptor.isBuiltIn, descriptor.vendorID != 0x05AC else { return false }
        guard descriptor.maxOutputReportSize >= 17 && descriptor.maxInputReportSize >= 17 else {
            return false
        }
        if Self.knownVendorIDs.contains(descriptor.vendorID) &&
            (descriptor.hasUsagePair(page: 0xFF02) || descriptor.hasVendorUsagePage()) {
            return true
        }
        return descriptor.primaryUsagePage == 0xFF02
            && descriptor.maxOutputReportSize == 17
            && descriptor.maxInputReportSize == 17
    }

    public func query(device: IOHIDDevice, descriptor: HIDDeviceDescriptor) -> [VendorBatteryReading] {
        let request = Self.buildBatteryRequest()
        guard let response = HIDDeviceHelper.withOpenDevice(device, body: { opened in
            HIDDeviceHelper.exchangeOutputInputReport(
                device: opened,
                outputReportID: 0x08,
                payload: request,
                expectedInputSize: max(descriptor.maxInputReportSize, 17),
                timeout: 0.6
            ) { reportID, bytes in
                (reportID == 8 || bytes.first == 0x08) && bytes.count >= 10 && bytes[1] == 0x04
            }
        }) else {
            return []
        }

        guard let parsed = Self.parseBatteryResponse(response, descriptor: descriptor) else {
            return []
        }
        return [parsed]
    }

    public static func buildBatteryRequest(command: UInt8 = 0x04) -> [UInt8] {
        var req = [UInt8](repeating: 0, count: 17)
        req[0] = 0x08
        req[1] = command
        req[16] = 0x4D &- command
        return req
    }

    public static func parseBatteryResponse(
        _ bytes: [UInt8],
        descriptor: HIDDeviceDescriptor? = nil
    ) -> VendorBatteryReading? {
        guard bytes.count >= 10, bytes[0] == 0x08, bytes[1] == 0x04 else {
            return nil
        }

        let rawLevel = Int(bytes[6])
        guard rawLevel <= 100 else { return nil }
        let isCharging = bytes[7] != 0

        let rawVoltage = (Int(bytes[8]) << 8) | Int(bytes[9])
        let validVoltage = (2500...4500).contains(rawVoltage) ? rawVoltage : nil

        if rawLevel == 0 && !isCharging && validVoltage == nil {
            return VendorBatteryReading(
                slotKey: "0",
                categoryOverride: .mouse,
                transportOverride: .wireless24G,
                batteryLevel: nil,
                chargingState: .sleeping,
                statusHint: "休眠中"
            )
        }

        let chargingState: ChargingState = isCharging
            ? (rawLevel >= 100 ? .full : .charging)
            : .discharging

        let transport: DeviceTransport
        if let desc = descriptor {
            transport = DeviceClassifier.inferTransport(
                rawTransport: desc.transport,
                productName: desc.product,
                productID: desc.productID
            )
        } else {
            transport = isCharging ? .usb : .wireless24G
        }

        return VendorBatteryReading(
            slotKey: "0",
            categoryOverride: .mouse,
            transportOverride: transport,
            batteryLevel: rawLevel,
            chargingState: chargingState,
            voltageMillivolts: validVoltage
        )
    }
}
