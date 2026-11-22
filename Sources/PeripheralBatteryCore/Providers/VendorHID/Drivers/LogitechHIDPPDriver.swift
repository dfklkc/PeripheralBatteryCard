import Foundation
import IOKit.hid

/// Logitech HID++ 2.0 协议驱动（支持 Unifying / Logi Bolt / Lightspeed 接收器多槽位及蓝牙/USB 直连设备）
/// 覆盖特性：0x1004 (Unified Battery)、0x1000 (Battery Status)、0x1001 (Battery Voltage) 以及 0x0005 (Device Name)
public final class LogitechHIDPPDriver: HIDVendorDriver {
    public let driverID = "logitech-hidpp"
    public let displayName = "Logitech HID++ 2.0"

    private static let receiverPIDs: Set<Int> = [
        0xC52B, 0xC548, 0xC539, 0xC53F, 0xC545, 0xC547, 0xC54D, 0xC534, 0xC52F, 0xC532
    ]

    public init() {}

    public func matches(descriptor: HIDDeviceDescriptor) -> Bool {
        guard !descriptor.isBuiltIn, descriptor.vendorID == 0x046D else { return false }
        return descriptor.hasUsagePair(page: 0xFF00) || descriptor.hasUsagePair(page: 0xFF43)
    }

    public func query(device: IOHIDDevice, descriptor: HIDDeviceDescriptor) -> [VendorBatteryReading] {
        let isReceiver = Self.isReceiverDevice(descriptor: descriptor)
        let useLong = descriptor.maxOutputReportSize >= 20 || descriptor.maxInputReportSize >= 20
        let slots: [UInt8] = isReceiver ? [1, 2, 3, 4, 5, 6] : [0xFF]

        return HIDDeviceHelper.withOpenDevice(device) { opened in
            var results: [VendorBatteryReading] = []
            for slot in slots {
                if let reading = querySlot(opened, deviceIndex: slot, useLong: useLong, isReceiver: isReceiver, descriptor: descriptor) {
                    results.append(reading)
                }
            }
            return results
        } ?? []
    }

    private func querySlot(
        _ device: IOHIDDevice,
        deviceIndex: UInt8,
        useLong: Bool,
        isReceiver: Bool,
        descriptor: HIDDeviceDescriptor
    ) -> VendorBatteryReading? {
        let swID: UInt8 = 0x0A
        var level: Int?
        var charging: ChargingState = .unknown
        var voltageMV: Int?

        // 1. 尝试 0x1004 (Unified Battery)
        if let featIdx = resolveFeatureIndex(device, deviceIndex: deviceIndex, featureID: 0x1004, swID: swID, useLong: useLong) {
            let req = Self.buildFeatureQueryRequest(deviceIndex: deviceIndex, featureIndex: featIdx, functionID: 1, swID: swID, long: useLong)
            if let resp = sendHIDPP(device, request: req, expectedDeviceIndex: deviceIndex, expectedFeatureIndex: featIdx, swID: swID),
               let parsed = Self.parseUnifiedBatteryResponse(resp) {
                level = parsed.level
                charging = parsed.charging
            }
        }

        // 2. 回退 0x1000 (Battery Level Status)
        if level == nil,
           let featIdx = resolveFeatureIndex(device, deviceIndex: deviceIndex, featureID: 0x1000, swID: swID, useLong: useLong) {
            let req = Self.buildFeatureQueryRequest(deviceIndex: deviceIndex, featureIndex: featIdx, functionID: 0, swID: swID, long: useLong)
            if let resp = sendHIDPP(device, request: req, expectedDeviceIndex: deviceIndex, expectedFeatureIndex: featIdx, swID: swID),
               let parsed = Self.parseBatteryStatusResponse(resp) {
                level = parsed.level
                charging = parsed.charging
            }
        }

        // 3. 回退 0x1001 (Battery Voltage)
        if level == nil,
           let featIdx = resolveFeatureIndex(device, deviceIndex: deviceIndex, featureID: 0x1001, swID: swID, useLong: useLong) {
            let req = Self.buildFeatureQueryRequest(deviceIndex: deviceIndex, featureIndex: featIdx, functionID: 0, swID: swID, long: useLong)
            if let resp = sendHIDPP(device, request: req, expectedDeviceIndex: deviceIndex, expectedFeatureIndex: featIdx, swID: swID),
               let parsed = Self.parseBatteryVoltageResponse(resp) {
                level = parsed.level
                charging = parsed.charging
                voltageMV = parsed.voltageMV
            }
        }

        guard let resolvedLevel = level else {
            return nil
        }

        var slotName: String?
        if isReceiver {
            slotName = resolveDeviceName(device, deviceIndex: deviceIndex, swID: swID, useLong: useLong)
        }

        let transport: DeviceTransport = isReceiver
            ? .wireless24G
            : DeviceClassifier.inferTransport(rawTransport: descriptor.transport, productName: slotName ?? descriptor.product, productID: descriptor.productID)

        let category = slotName.map { DeviceClassifier.classify(name: $0) }

        return VendorBatteryReading(
            slotKey: isReceiver ? "slot-\(deviceIndex)" : "0",
            nameOverride: slotName,
            categoryOverride: category,
            transportOverride: transport,
            batteryLevel: resolvedLevel,
            chargingState: charging,
            voltageMillivolts: voltageMV
        )
    }

    private func resolveFeatureIndex(
        _ device: IOHIDDevice,
        deviceIndex: UInt8,
        featureID: UInt16,
        swID: UInt8,
        useLong: Bool
    ) -> UInt8? {
        let req = Self.buildRootGetFeatureRequest(deviceIndex: deviceIndex, featureID: featureID, swID: swID, long: useLong)
        guard let resp = sendHIDPP(device, request: req, expectedDeviceIndex: deviceIndex, expectedFeatureIndex: 0x00, swID: swID) else {
            return nil
        }
        return Self.parseRootGetFeatureResponse(resp)
    }

    private func resolveDeviceName(
        _ device: IOHIDDevice,
        deviceIndex: UInt8,
        swID: UInt8,
        useLong: Bool
    ) -> String? {
        guard let nameFeat = resolveFeatureIndex(device, deviceIndex: deviceIndex, featureID: 0x0005, swID: swID, useLong: useLong) else {
            return nil
        }
        let lenReq = Self.buildFeatureQueryRequest(deviceIndex: deviceIndex, featureIndex: nameFeat, functionID: 0, swID: swID, long: useLong)
        guard let lenResp = sendHIDPP(device, request: lenReq, expectedDeviceIndex: deviceIndex, expectedFeatureIndex: nameFeat, swID: swID),
              lenResp.count >= 5
        else {
            return nil
        }
        let totalLen = Int(lenResp[4])
        guard totalLen > 0 && totalLen <= 64 else { return nil }

        var nameBytes: [UInt8] = []
        var offset = 0
        while offset < totalLen {
            var chunkReq = Self.buildFeatureQueryRequest(deviceIndex: deviceIndex, featureIndex: nameFeat, functionID: 1, swID: swID, long: useLong)
            chunkReq[4] = UInt8(offset)
            guard let chunkResp = sendHIDPP(device, request: chunkReq, expectedDeviceIndex: deviceIndex, expectedFeatureIndex: nameFeat, swID: swID),
                  chunkResp.count > 4
            else {
                break
            }
            let payloadSlice = Array(chunkResp.dropFirst(4))
            let take = min(totalLen - offset, payloadSlice.count)
            nameBytes.append(contentsOf: payloadSlice.prefix(take))
            offset += take
            if take == 0 { break }
        }
        let cleaned = nameBytes.prefix { $0 != 0 }
        guard let decoded = String(bytes: cleaned, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !decoded.isEmpty
        else {
            return nil
        }
        return decoded
    }

    private func sendHIDPP(
        _ device: IOHIDDevice,
        request: [UInt8],
        expectedDeviceIndex: UInt8,
        expectedFeatureIndex: UInt8,
        swID: UInt8
    ) -> [UInt8]? {
        let outID = Int(request[0])
        return HIDDeviceHelper.exchangeOutputInputReport(
            device: device,
            outputReportID: outID,
            payload: request,
            expectedInputSize: 20,
            timeout: 0.25
        ) { _, bytes in
            guard bytes.count >= 7 else { return false }
            guard bytes[0] == 0x10 || bytes[0] == 0x11 else { return false }
            guard bytes[1] == expectedDeviceIndex else { return false }
            // 错误响应 (0x8F / 0xFF) 也立刻结束等待，避免无意义超时
            if bytes[2] == 0x8F || bytes[2] == 0xFF {
                return true
            }
            return bytes[2] == expectedFeatureIndex && (bytes[3] & 0x0F) == (swID & 0x0F)
        }
    }

    public static func isReceiverDevice(descriptor: HIDDeviceDescriptor) -> Bool {
        if receiverPIDs.contains(descriptor.productID) { return true }
        return DeviceClassifier.looksLikeWirelessReceiver(name: descriptor.product, productID: descriptor.productID)
    }

    public static func buildRootGetFeatureRequest(
        deviceIndex: UInt8,
        featureID: UInt16,
        swID: UInt8 = 0x0A,
        long: Bool = true
    ) -> [UInt8] {
        let size = long ? 20 : 7
        var req = [UInt8](repeating: 0, count: size)
        req[0] = long ? 0x11 : 0x10
        req[1] = deviceIndex
        req[2] = 0x00 // IRoot
        req[3] = swID & 0x0F
        req[4] = UInt8((featureID >> 8) & 0xFF)
        req[5] = UInt8(featureID & 0xFF)
        return req
    }

    public static func buildFeatureQueryRequest(
        deviceIndex: UInt8,
        featureIndex: UInt8,
        functionID: UInt8,
        swID: UInt8 = 0x0A,
        long: Bool = true
    ) -> [UInt8] {
        let size = long ? 20 : 7
        var req = [UInt8](repeating: 0, count: size)
        req[0] = long ? 0x11 : 0x10
        req[1] = deviceIndex
        req[2] = featureIndex
        req[3] = ((functionID & 0x0F) << 4) | (swID & 0x0F)
        return req
    }

    public static func parseRootGetFeatureResponse(_ bytes: [UInt8]) -> UInt8? {
        guard bytes.count >= 5 else { return nil }
        if bytes[2] == 0x8F || bytes[2] == 0xFF { return nil }
        let idx = bytes[4]
        return idx == 0 ? nil : idx
    }

    public static func parseUnifiedBatteryResponse(_ bytes: [UInt8]) -> (level: Int, charging: ChargingState)? {
        guard bytes.count >= 7, bytes[2] != 0x8F, bytes[2] != 0xFF else { return nil }
        let level = Int(bytes[4])
        guard (0...100).contains(level) else { return nil }
        let status = bytes[6]
        let charging: ChargingState
        switch status {
        case 0: charging = .discharging
        case 1, 2, 4: charging = .charging
        case 3: charging = .full
        default: charging = .unknown
        }
        return (level, charging)
    }

    public static func parseBatteryStatusResponse(_ bytes: [UInt8]) -> (level: Int, charging: ChargingState)? {
        guard bytes.count >= 7, bytes[2] != 0x8F, bytes[2] != 0xFF else { return nil }
        let level = Int(bytes[4])
        guard (0...100).contains(level) else { return nil }
        let status = bytes[6]
        let charging: ChargingState
        switch status {
        case 0: charging = .discharging
        case 1, 2: charging = .charging
        case 3: charging = .full
        default: charging = .unknown
        }
        return (level, charging)
    }

    public static func parseBatteryVoltageResponse(_ bytes: [UInt8]) -> (level: Int, charging: ChargingState, voltageMV: Int)? {
        guard bytes.count >= 7, bytes[2] != 0x8F, bytes[2] != 0xFF else { return nil }
        let mv = (Int(bytes[4]) << 8) | Int(bytes[5])
        guard (2500...4500).contains(mv) else { return nil }
        let flags = bytes[6]
        let isCharging = (flags & 0x80) != 0 || (flags & 0x07) == 1 || (flags & 0x07) == 2
        let isFull = (flags & 0x07) == 3

        let level = lithiumVoltageToPercent(mv)
        let charging: ChargingState = isFull ? .full : (isCharging ? .charging : .discharging)
        return (level, charging, mv)
    }

    private static func lithiumVoltageToPercent(_ mv: Int) -> Int {
        let clamped = min(max(mv, 3500), 4200)
        return Int((Double(clamped - 3500) / 700.0 * 100.0).rounded())
    }
}
