import Foundation
import IOKit.hid

/// YJX-CHIP 方案无线鼠标协议驱动（如迈从 MCHOSE G7 / G3 等 0xA8A5:0x2255 系列）
public final class YJXChipHIDDriver: HIDVendorDriver, @unchecked Sendable {
    public let driverID = "yjx-chip-ff01"
    public let displayName = "YJX-CHIP HID (0xFF01)"

    private struct DeviceKey: Hashable {
        let vendorID: Int
        let productID: Int
        let locationID: Int?
        let serialNumber: String?
    }

    private let lock = NSLock()
    private var accepted: [DeviceKey: (reading: VendorBatteryReading, uptime: TimeInterval)] = [:]

    public init() {}

    public func matches(descriptor: HIDDeviceDescriptor) -> Bool {
        !descriptor.isBuiltIn && (descriptor.vendorID == 0xA8A5 || descriptor.vendorID == 0xA8A4)
            && descriptor.productID == 0x2255 && descriptor.maxOutputReportSize == 64
            && descriptor.maxInputReportSize == 64 && descriptor.hasUsagePair(page: 0xFF01, usage: 0x0010)
    }

    public func query(device: IOHIDDevice, descriptor: HIDDeviceDescriptor) -> [VendorBatteryReading] {
        guard matches(descriptor: descriptor) else { return [] }
        let location = descriptor.locationID == 0 ? nil : descriptor.locationID
        let serial = descriptor.serialNumber.flatMap { $0.isEmpty ? nil : $0 }
        let key = location == nil && serial == nil ? nil : DeviceKey(
            vendorID: descriptor.vendorID, productID: descriptor.productID, locationID: location, serialNumber: serial
        )
        let uptime = ProcessInfo.processInfo.systemUptime
        let previous = lock.withLock {
            accepted = accepted.filter { uptime - $0.value.uptime <= 1800 }
            return key.flatMap { accepted[$0]?.reading }
        }

        guard let reading = HIDDeviceHelper.withOpenDevice(device, body: { opened -> VendorBatteryReading? in
            let request = Self.buildBatteryRequest()
            func read() -> VendorBatteryReading? {
                let frame = HIDDeviceHelper.exchangeOutputInputReport(
                    device: opened, outputReportID: 0, payload: request, expectedInputSize: 64, timeout: 0.6
                ) { reportID, bytes in
                    reportID == 0 && Self.isBatteryResponse(bytes)
                }
                return frame.flatMap { Self.parseBatteryResponse($0, descriptor: descriptor) }
            }

            guard let first = read() else { return nil }
            return Self.confirmReading(first, previous: previous) {
                Thread.sleep(forTimeInterval: 0.12)
                return read()
            }
        }) else {
            return []
        }
        if let key, reading.batteryLevel != nil {
            lock.withLock { accepted[key] = (reading, uptime) }
        }
        return [reading]
    }

    static func confirmReading(
        _ first: VendorBatteryReading,
        previous: VendorBatteryReading?,
        reread: () -> VendorBatteryReading?
    ) -> VendorBatteryReading {
        guard let level = first.batteryLevel else { return first }
        if let previous, let prior = previous.batteryLevel,
           abs(prior - level) < 12, first.chargingState == previous.chargingState {
            return first
        }

        if let second = reread(), let secondLevel = second.batteryLevel {
            if abs(secondLevel - level) <= 3, second.chargingState == first.chargingState {
                return second
            }
            if let previous, let prior = previous.batteryLevel,
               abs(secondLevel - prior) <= 3, second.chargingState == previous.chargingState {
                return second
            }
        }
        var uncertain = first
        uncertain.batteryLevel = nil
        uncertain.chargingState = .unknown
        uncertain.statusHint = "电量波动 · 等待复核"
        return uncertain
    }

    private static func isBatteryResponse(_ bytes: [UInt8]) -> Bool {
        // The fourth byte differs between validated cable and receiver responses.
        bytes.count >= 10 && bytes[0] == 0xAA && bytes[1] == 0x30 && bytes[2] == 0xA5
            && bytes[4...7].elementsEqual([0x0A, 0x01, 0x01, 0x01]) && bytes[8] <= 100
    }

    public static func buildBatteryRequest() -> [UInt8] {
        var req = [UInt8](repeating: 0, count: 64)
        let header: [UInt8] = [0x55, 0x30, 0xA5, 0x0B, 0x2E, 0x01, 0x01, 0x01]
        for (idx, byte) in header.enumerated() {
            req[idx] = byte
        }
        return req
    }

    public static func parseBatteryResponse(
        _ bytes: [UInt8],
        descriptor: HIDDeviceDescriptor? = nil
    ) -> VendorBatteryReading? {
        guard isBatteryResponse(bytes) else { return nil }

        let rawLevel = Int(bytes[8])
        let isCharging = bytes[9] != 0

        // 部分 YJX-CHIP 设备在深休眠时返回 0% 且未充电
        if rawLevel == 0 && !isCharging {
            return VendorBatteryReading(
                slotKey: "0",
                categoryOverride: .mouse,
                transportOverride: .wireless24G,
                batteryLevel: nil,
                chargingState: .sleeping,
                statusHint: "休眠中"
            )
        }

        let level = rawLevel
        let chargingState: ChargingState = isCharging
            ? (level >= 100 ? .full : .charging)
            : .discharging

        let transport: DeviceTransport
        if let desc = descriptor {
            transport = DeviceClassifier.inferTransport(
                rawTransport: desc.transport,
                productName: desc.product,
                productID: desc.productID
            )
            // YJX-CHIP 常见 2.4G 无线接收器在 macOS 上未标注 Receiver 字样，默认为 2.4G 或 USB
            let resolvedTransport: DeviceTransport = transport == .usb && !isCharging && desc.vendorID != 0xA8A4
                ? .wireless24G : transport
            return VendorBatteryReading(
                slotKey: "0",
                categoryOverride: .mouse,
                transportOverride: resolvedTransport,
                batteryLevel: level,
                chargingState: chargingState
            )
        }

        return VendorBatteryReading(
            slotKey: "0",
            categoryOverride: .mouse,
            transportOverride: isCharging ? .usb : .wireless24G,
            batteryLevel: level,
            chargingState: chargingState
        )
    }
}
