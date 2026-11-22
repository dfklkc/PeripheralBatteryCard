import Foundation
import IOKit.hid

/// 厂商私有 HID 协议单条电量读取结果（支持一个接收器返回多台设备）
public struct VendorBatteryReading: Sendable, Equatable {
    public var slotKey: String
    public var nameOverride: String?
    public var categoryOverride: DeviceCategory?
    public var transportOverride: DeviceTransport?
    public var batteryLevel: Int?
    public var chargingState: ChargingState
    public var voltageMillivolts: Int?
    public var statusHint: String?

    public init(
        slotKey: String = "0",
        nameOverride: String? = nil,
        categoryOverride: DeviceCategory? = nil,
        transportOverride: DeviceTransport? = nil,
        batteryLevel: Int? = nil,
        chargingState: ChargingState = .unknown,
        voltageMillivolts: Int? = nil,
        statusHint: String? = nil
    ) {
        self.slotKey = slotKey
        self.nameOverride = nameOverride
        self.categoryOverride = categoryOverride
        self.transportOverride = transportOverride
        self.batteryLevel = batteryLevel.map { min(max($0, 0), 100) }
        self.chargingState = chargingState
        self.voltageMillivolts = voltageMillivolts
        self.statusHint = statusHint
    }
}

/// 可插拔厂商 HID 协议驱动接口
public protocol HIDVendorDriver: AnyObject, Sendable {
    var driverID: String { get }
    var displayName: String { get }
    func matches(descriptor: HIDDeviceDescriptor) -> Bool
    func query(device: IOHIDDevice, descriptor: HIDDeviceDescriptor) -> [VendorBatteryReading]
}
