import Foundation
import Testing
@testable import PeripheralBatteryCore

@Suite("蓝牙解析、设备分类与聚合去重测试")
struct AggregatorAndParsersTests {

    @Test("SPBluetoothDataType JSON 解析 AirPods 多电量与未连接设备")
    func bluetoothProfilerParsingAirPodsAndHeadset() throws {
        let sampleJSON = """
        {
          "SPBluetoothDataType": [
            {
              "device_connected": [
                {
                  "AirPods Pro": {
                    "device_address": "02:00:00:00:01:01",
                    "device_minorType": "Headphones",
                    "device_vendorID": "0x004C",
                    "device_productID": "0x2014",
                    "device_batteryLevelLeft": "90%",
                    "device_batteryLevelRight": "85%",
                    "device_batteryLevelCase": "60%"
                  }
                },
                {
                  "Sony WH-1000XM5": {
                    "device_address": "02:00:00:00:01:02",
                    "device_minorType": "Headphones",
                    "device_batteryLevelMain": "75%"
                  }
                }
              ],
              "device_not_connected": [
                {
                  "Xbox Wireless Controller": {
                    "device_address": "02:00:00:00:01:03",
                    "device_minorType": "Gamepad",
                    "device_vendorID": "0x045E",
                    "device_productID": "0x02E0"
                  }
                }
              ]
            }
          ]
        }
        """.data(using: .utf8)!

        let parsed = BluetoothProfilerProvider.parseBluetoothProfilerJSON(sampleJSON)
        #expect(parsed.devices.count == 2)

        let airpods = try #require(parsed.devices.first { $0.name == "AirPods Pro" })
        #expect(airpods.category == .earbuds)
        #expect(airpods.subBatteries.count == 3)
        #expect(airpods.effectiveBatteryLevel == 85)

        let sony = try #require(parsed.devices.first { $0.name == "Sony WH-1000XM5" })
        #expect(sony.category == .headphones)
        #expect(sony.effectiveBatteryLevel == 75)

        #expect(parsed.diagnostics.count == 3)
        #expect(parsed.diagnostics.contains { $0.name == "Xbox Wireless Controller" && $0.batterySummary == "未连接" })
    }

    @Test("设备类型与连接方式自动分类")
    func deviceClassification() {
        #expect(DeviceClassifier.classify(name: "MCHOSE G7", usagePage: 1, usage: 2) == .mouse)
        #expect(DeviceClassifier.classify(name: "VXE V87", usagePage: 1, usage: 6) == .keyboard)
        #expect(DeviceClassifier.classify(name: "Magic Trackpad") == .trackpad)
        #expect(DeviceClassifier.classify(name: "DualSense Wireless Controller") == .gamepad)
        #expect(DeviceClassifier.classify(name: "APC Back-UPS 650", isUPS: true) == .ups)
        #expect(
            DeviceClassifier.inferTransport(rawTransport: "USB", productName: "Logi Bolt Receiver", productID: 0xC548) == .wireless24G
        )
    }

    @Test("跨来源去重合并与 30 分钟休眠电量缓存")
    func aggregatorDeduplicationAndSleepCache() {
        let agg = BatteryAggregator(cacheTTL: 1800)
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)

        let mouseVendor = PeripheralDevice(
            id: "hid-a8a5-2255-sn1",
            name: "MCHOSE G7",
            category: .mouse,
            transport: .wireless24G,
            batteryLevel: 64,
            chargingState: .discharging,
            source: .vendorHID,
            sourceDetail: "YJX-CHIP",
            vendorID: 0xA8A5,
            productID: 0x2255,
            serialNumber: "sn1",
            lastUpdated: t0
        )
        let mouseUSBInv = PeripheralDevice(
            id: "hid-a8a5-2255-sn1",
            name: "MCHOSE G7",
            category: .mouse,
            transport: .usb,
            batteryLevel: nil,
            chargingState: .unknown,
            source: .usbInventory,
            sourceDetail: "USB Inventory",
            vendorID: 0xA8A5,
            productID: 0x2255,
            serialNumber: "sn1",
            statusHint: "未识别电量协议"
        )
        let macBattery = PeripheralDevice(
            id: "internal-battery",
            name: "Mac 本机电池",
            category: .laptop,
            transport: .builtIn,
            batteryLevel: 80,
            chargingState: .wiredPower,
            source: .ioPowerSources,
            sourceDetail: "本机电池",
            isExternal: false,
            lastUpdated: t0
        )

        let first = agg.aggregate(
            results: [ProviderResult(devices: [macBattery, mouseUSBInv, mouseVendor])],
            now: t0
        )
        #expect(first.devices.count == 2)
        #expect(first.devices[0].name == "MCHOSE G7")
        #expect(first.devices[0].batteryLevel == 64)
        #expect(first.devices[0].source == .vendorHID)
        #expect(first.devices[0].statusHint == nil)
        #expect(first.devices[1].id == "internal-battery")

        // 10 分钟后鼠标进入深休眠，命中 30 分钟休眠缓存
        let mouseSleeping = PeripheralDevice(
            id: "hid-a8a5-2255-sn1",
            name: "MCHOSE G7",
            category: .mouse,
            transport: .wireless24G,
            batteryLevel: nil,
            chargingState: .sleeping,
            source: .vendorHID,
            sourceDetail: "YJX-CHIP",
            vendorID: 0xA8A5,
            productID: 0x2255,
            serialNumber: "sn1"
        )
        let t1 = t0.addingTimeInterval(600)
        let second = agg.aggregate(results: [ProviderResult(devices: [mouseSleeping])], now: t1)
        #expect(second.devices[0].batteryLevel == 64)
        #expect(second.devices[0].chargingState == .sleeping)
        #expect(second.devices[0].statusHint == "休眠中 · 上次电量")
        #expect(second.devices[0].hasStaleBatteryReading)
        #expect(second.devices[0].batteryReadingAt == t0)

        // 超过 30 分钟后缓存失效
        let t2 = t0.addingTimeInterval(1900)
        let third = agg.aggregate(results: [ProviderResult(devices: [mouseSleeping])], now: t2)
        #expect(third.devices[0].batteryLevel == nil)
    }

    @Test("受权限限制设备去重抑制 USB 清单并排在有电量设备之后")
    func restrictedDeviceDeduplicationAndSorting() {
        let agg = BatteryAggregator()
        let activeMouse = PeripheralDevice(
            id: "hid-a8a5-2255-sn1",
            name: "MCHOSE G7",
            category: .mouse,
            transport: .wireless24G,
            batteryLevel: 63,
            chargingState: .discharging,
            source: .vendorHID,
            sourceDetail: "YJX-CHIP HID (0xFF01)",
            vendorID: 0xA8A5,
            productID: 0x2255,
            serialNumber: "sn1"
        )
        let restrictedKeyboard = PeripheralDevice(
            id: "hid-320f-5055-sn2",
            name: "VXE V87",
            category: .keyboard,
            transport: .usb,
            batteryLevel: nil,
            chargingState: .unknown,
            source: .vendorHID,
            sourceDetail: "EVision HID (0xFF1C) · 需权限",
            vendorID: 0x320F,
            productID: 0x5055,
            serialNumber: "sn2",
            statusHint: "需开启「输入监控」",
            requiresInputMonitoring: true
        )
        let duplicateKeyboardUSB = PeripheralDevice(
            id: "hid-320f-5055-sn2",
            name: "VXE V87",
            category: .keyboard,
            transport: .usb,
            batteryLevel: nil,
            chargingState: .unknown,
            source: .usbInventory,
            sourceDetail: "USB 设备清单",
            vendorID: 0x320F,
            productID: 0x5055,
            serialNumber: "sn2",
            statusHint: "未识别电量协议"
        )
        let unknownDevice = PeripheralDevice(
            id: "usb-other",
            name: "A Generic USB Device",
            category: .other,
            transport: .usb,
            batteryLevel: nil,
            chargingState: .unknown,
            source: .usbInventory,
            sourceDetail: "USB 设备清单",
            vendorID: 0x1111,
            productID: 0x2222
        )

        let res = agg.aggregate(
            results: [ProviderResult(devices: [unknownDevice, duplicateKeyboardUSB, restrictedKeyboard, activeMouse])]
        )
        #expect(res.devices.count == 3)
        #expect(res.devices[0].name == "MCHOSE G7")
        #expect(res.devices[1].name == "VXE V87")
        #expect(res.devices[1].requiresInputMonitoring == true)
        #expect(res.devices[2].name == "A Generic USB Device")
    }

    @Test("不同蓝牙地址、不同序列号或缺少共同硬件标识时不合并")
    func distinctHardwareIsNotMergedByModelOrName() {
        let first = reading(id: "a", address: "02:00:00:00:02:01")
        let second = reading(id: "b", address: "02:00:00:00:02:02")
        let third = reading(id: "c", serial: "SN-1")
        let fourth = reading(id: "d", serial: "SN-2")
        let firstUnnamed = reading(id: "unverified")
        let secondUnnamed = reading(id: "unverified", source: .hidStandardPower)
        let snapshot = BatteryAggregator().aggregate(results: [ProviderResult(devices: [
            first, second, third, fourth, firstUnnamed, secondUnnamed,
        ])])
        #expect(snapshot.devices.count == 6)
        #expect(Set(snapshot.devices.map(\.id)).count == 6)
        #expect(snapshot.devices.allSatisfy { $0.legacyIDs == nil })
    }

    @Test("同一接口位置跨来源合并，同型号不同接口各自保留")
    func hardwareLocationDeduplicationAndLegacyIDs() throws {
        let aggregator = BatteryAggregator()
        let first = reading(id: "old-one", location: 10)
        let inventory = reading(id: "usb-model", location: 10, source: .usbInventory, level: nil)
        let alone = aggregator.aggregate(results: [ProviderResult(devices: [first, inventory])])
        let one = try #require(alone.devices.first)
        #expect(alone.devices.count == 1)
        #expect(one.legacyIDs == ["old-one", "usb-model"])

        let second = reading(id: "old-one", location: 11)
        let two = aggregator.aggregate(results: [ProviderResult(devices: [second, inventory, first])])
        #expect(two.devices.count == 2)
        #expect(two.devices.first { $0.physicalLocationID == 10 }?.id == one.id)
        #expect(two.devices.allSatisfy { $0.legacyIDs?.contains("old-one") != true })
        let afterDisconnect = aggregator.aggregate(results: [ProviderResult(devices: [second])])
        #expect(afterDisconnect.devices.first?.legacyIDs == nil)
    }

    @Test("同一异步读数的重复快照不会续期，过期后保留设备与上次确认时间")
    func repeatedReadingRetainsTimestampAndExpires() throws {
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        let aggregator = BatteryAggregator()
        let sample = reading(id: "a", serial: "SN-1", level: 0, observedAt: t0)
        let result = [ProviderResult(devices: [sample])]
        let current = try #require(aggregator.aggregate(results: result, now: t0).devices.first)
        #expect(current.effectiveBatteryLevel == 0)
        #expect(!current.hasStaleBatteryReading)
        let old = try #require(aggregator.aggregate(results: result, now: t0.addingTimeInterval(300)).devices.first)
        #expect(old.effectiveBatteryLevel == 0)
        #expect(old.hasStaleBatteryReading)
        #expect(old.batteryReadingAt == t0)
        #expect(old.statusHint == "上次电量")
        let expired = try #require(aggregator.aggregate(results: result, now: t0.addingTimeInterval(1801)).devices.first)
        #expect(expired.effectiveBatteryLevel == nil)
        #expect(expired.batteryReadingAt == t0)
    }

    @Test("复核期间仅展示上次确认值，同位置更换序列号不沿用")
    func staleFallbackPreservesUncertainStatusOnlyForSameDevice() throws {
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        let aggregator = BatteryAggregator()
        let initial = reading(id: "a", serial: "SN-1", location: 10, observedAt: t0)
        _ = aggregator.aggregate(results: [ProviderResult(devices: [initial])], now: t0)

        var uncertain = reading(id: "a", serial: "SN-1", location: 10, level: nil)
        uncertain.statusHint = "电量波动 · 等待复核"
        let t1 = t0.addingTimeInterval(30)
        let fallback = try #require(aggregator.aggregate(results: [ProviderResult(devices: [uncertain])], now: t1).devices.first)
        #expect(fallback.effectiveBatteryLevel == 53)
        #expect(fallback.batteryReadingAt == t0)
        #expect(fallback.hasStaleBatteryReading)
        #expect(fallback.statusHint == "电量波动 · 等待复核")
        #expect(fallback.chargingState == .unknown)

        uncertain.serialNumber = "SN-2"
        let replaced = try #require(aggregator.aggregate(results: [ProviderResult(devices: [uncertain])], now: t1).devices.first)
        #expect(replaced.effectiveBatteryLevel == nil)
    }

    @Test("低优先级来源的实际新读数优先于旧快照")
    func freshLowerPriorityReadingWins() throws {
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        let t1 = t0.addingTimeInterval(200)
        let old = reading(id: "a", serial: "SN-1", level: 20, observedAt: t0)
        let new = reading(id: "b", serial: "SN-1", source: .hidStandardPower, level: 80, observedAt: t1)
        let result = BatteryAggregator().aggregate(results: [ProviderResult(devices: [old, new])], now: t1)
        let actual = try #require(result.devices.first)
        #expect(result.devices.count == 1)
        #expect(actual.effectiveBatteryLevel == 80)
        #expect(actual.batteryReadingAt == t1)
        #expect(!actual.hasStaleBatteryReading)
    }

    private func reading(
        id: String, address: String? = nil, serial: String? = nil, location: Int? = nil,
        source: BatterySourceKind = .vendorHID, level: Int? = 53, observedAt: Date = Date()
    ) -> PeripheralDevice {
        PeripheralDevice(id: id, name: "Same Model", batteryLevel: level, source: source, sourceDetail: "Fixture",
                         vendorID: 0x1234, productID: 0x5678, serialNumber: serial, bluetoothAddress: address,
                         physicalLocationID: location, lastUpdated: observedAt)
    }
}
