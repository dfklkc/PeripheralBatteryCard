import Foundation
import IOKit.hid

/// Sony PlayStation 手柄被动 Input Report 解析驱动（DualSense / DualSense Edge / DualShock 4，支持 USB 与蓝牙）
public final class SonyPlayStationDriver: HIDVendorDriver {
    public let driverID = "sony-playstation"
    public let displayName = "Sony DualSense / DS4"

    private static let dualSensePIDs: Set<Int> = [0x0CE6, 0x0DF2]
    private static let dualShock4PIDs: Set<Int> = [0x05C4, 0x09CC, 0x0BA0]

    public init() {}

    public func matches(descriptor: HIDDeviceDescriptor) -> Bool {
        guard !descriptor.isBuiltIn, descriptor.vendorID == 0x054C else { return false }
        return Self.dualSensePIDs.contains(descriptor.productID)
            || Self.dualShock4PIDs.contains(descriptor.productID)
    }

    public func query(device: IOHIDDevice, descriptor: HIDDeviceDescriptor) -> [VendorBatteryReading] {
        guard let report = HIDDeviceHelper.withOpenDevice(device, body: { opened in
            HIDDeviceHelper.listenInputReport(
                device: opened,
                expectedInputSize: 128,
                timeout: 0.35
            ) { reportID, bytes in
                Self.parseInputReport(
                    reportID: reportID,
                    bytes: bytes,
                    productID: descriptor.productID,
                    transportHint: descriptor.transport
                ) != nil
            }
        }) else {
            return []
        }

        let reportID = UInt32(report.first ?? 0)
        guard let parsed = Self.parseInputReport(
            reportID: reportID,
            bytes: report,
            productID: descriptor.productID,
            transportHint: descriptor.transport
        ) else {
            return []
        }
        return [parsed]
    }

    public static func parseInputReport(
        reportID: UInt32,
        bytes: [UInt8],
        productID: Int,
        transportHint: String = ""
    ) -> VendorBatteryReading? {
        if dualSensePIDs.contains(productID) {
            let statusByte: UInt8
            let transport: DeviceTransport
            if (reportID == 0x01 || bytes.first == 0x01) && bytes.count >= 54 {
                statusByte = bytes[53]
                transport = .usb
            } else if (reportID == 0x31 || bytes.first == 0x31) && bytes.count >= 55 {
                statusByte = bytes[54]
                transport = .bluetooth
            } else {
                return nil
            }

            let rawLevel = Int(statusByte & 0x0F)
            let chargeNibble = (statusByte >> 4) & 0x0F

            let chargingState: ChargingState
            var level = min(rawLevel * 10 + 5, 100)
            switch chargeNibble {
            case 0x0:
                chargingState = .discharging
            case 0x1:
                chargingState = .charging
            case 0x2:
                chargingState = .full
                level = 100
            default:
                chargingState = transport == .usb ? .wiredPower : .unknown
            }

            return VendorBatteryReading(
                slotKey: "0",
                categoryOverride: .gamepad,
                transportOverride: transportHint.lowercased().contains("bluetooth") ? .bluetooth : transport,
                batteryLevel: level,
                chargingState: chargingState
            )
        }

        if dualShock4PIDs.contains(productID) {
            let val: UInt8
            let transport: DeviceTransport
            if (reportID == 0x01 || bytes.first == 0x01) && bytes.count >= 31 {
                val = bytes[30]
                transport = .usb
            } else if (reportID == 0x11 || bytes.first == 0x11) && bytes.count >= 33 {
                val = bytes[32]
                transport = .bluetooth
            } else {
                return nil
            }

            let cable = (val & 0x10) != 0
            let rawLevel = Int(val & 0x0F)
            let level = min(rawLevel * 10, 100)
            let chargingState: ChargingState
            if cable {
                chargingState = rawLevel >= 10 ? .full : .charging
            } else {
                chargingState = .discharging
            }

            return VendorBatteryReading(
                slotKey: "0",
                categoryOverride: .gamepad,
                transportOverride: transportHint.lowercased().contains("bluetooth") ? .bluetooth : transport,
                batteryLevel: level,
                chargingState: chargingState
            )
        }

        return nil
    }
}
