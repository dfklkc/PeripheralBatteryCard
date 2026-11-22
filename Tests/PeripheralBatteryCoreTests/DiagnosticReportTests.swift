import Foundation
import Testing
@testable import PeripheralBatteryCore

@Suite("按设备诊断和脱敏导出")
struct DiagnosticReportTests {
    @Test("同一 USB 设备的接口归组，两台同型号设备保持独立")
    func interfacesGroupByPhysicalIdentity() throws {
        let first = device(id: "first", location: 1)
        let second = device(id: "second", location: 2)
        let firstKey = try #require(first.diagnosticGroupKey)
        let secondKey = try #require(second.diagnosticGroupKey)
        #expect(firstKey != secondKey)

        let groups = DiagnosticReport.group(devices: [first, second], entries: [
            entry(id: "inventory", group: firstKey, driver: "USB Inventory", summary: "未读取到电量"),
            entry(id: "primary", group: firstKey, driver: "YJX-CHIP HID (0xFF01)", summary: "63%"),
            entry(id: "other-physical-device", group: secondKey, driver: "YJX-CHIP HID (0xFF01)", summary: "63%")
        ])

        #expect(groups.count == 2)
        let firstGroup = try #require(groups.first { $0.devices.first?.id == first.id })
        #expect(firstGroup.interfaces.count == 2)
        #expect(firstGroup.summary == "63%")
        #expect(firstGroup.hasCurrentReading)
        #expect(groups.first { $0.devices.first?.id == second.id }?.interfaces.count == 1)
    }

    @Test("诊断摘要区别旧读数和当前读数")
    func staleReadingIsLabelledAsPrevious() throws {
        var unit = device(id: "sleeping-unit", location: 3)
        unit.batteryReadingIsStale = true
        let group = try #require(DiagnosticReport.group(devices: [unit], entries: []).first)
        #expect(!group.hasCurrentReading)
        #expect(group.summary == "上次读数 63%")
    }

    @Test("缺少硬件关联信息时使用来源 ID，避免把同名外设串在一起")
    func separateIdenticallyNamedEntriesWithoutEvidence() {
        let ble = PeripheralDevice(id: "ble-unit", name: "同型号", transport: .ble, batteryLevel: 71,
                                   source: .coreBluetoothBAS, sourceDetail: "CoreBluetooth BAS")
        let entries = [
            entry(id: "diag-ble-unit", driver: "CoreBluetooth BAS", summary: "71%"),
            entry(id: "bt-disc-unrelated-unit", driver: "SPBluetoothDataType", summary: "未连接")
        ]

        let groups = DiagnosticReport.group(devices: [ble], entries: entries)

        #expect(groups.count == 2)
        #expect(groups.first?.interfaces.map(\.id) == [entries[0].id])
        #expect(groups.last?.summary == "未连接")
    }

    @Test("分享的 JSON 保留类型化读数和协议，省略所有设备自由文本和标识")
    func exportIsAllowlisted() throws {
        var unit = device(id: "private-device-id", location: 0x123456)
        unit.name = "private-name"
        unit.sourceDetail = "private-provider-text"
        unit.serialNumber = "private-serial"
        unit.bluetoothAddress = "AA:BB:CC:DD:EE:FF"
        unit.statusHint = "private-status"
        let key = try #require(unit.diagnosticGroupKey)
        var primary = entry(id: "private-interface-id", group: key,
                            driver: "YJX-CHIP HID (0xFF01), IOKit (private-driver-text)", summary: "63%")
        primary.name = "private-interface-name"
        primary.rawNote = "private-serial AA:BB:CC:DD:EE:FF"
        primary.usageHex = "private-usage"
        let groups = DiagnosticReport.group(devices: [unit], entries: [primary])

        let data = try DiagnosticReport.redactedJSON(groups: groups, generatedAt: unit.batteryReadingAt)
        let json = String(decoding: data, as: UTF8.self)

        #expect(!json.contains("private-"))
        #expect(!json.contains("AA:BB:CC:DD:EE:FF"))
        #expect(!json.contains("1193046"))
        #expect(json.contains("YJX-CHIP HID (0xFF01)"))
        #expect(json.contains("0xA8A5"))
        #expect(json.contains("\"batteryPercent\" : 63"))
        #expect(json.contains("\"status\" : \"reported\""))
    }

    private func device(id: String, location: Int) -> PeripheralDevice {
        var value = PeripheralDevice(id: id, name: "同型号", category: .mouse,
                                     transport: .wireless24G, batteryLevel: 63, chargingState: .discharging,
                                     source: .vendorHID, sourceDetail: "YJX-CHIP HID (0xFF01)",
                                     vendorID: 0xA8A5, productID: 0x2255, serialNumber: "model-code")
        value.physicalLocationID = location
        return value
    }

    private func entry(id: String, group: String? = nil, driver: String, summary: String) -> DiagnosticEntry {
        var value = DiagnosticEntry(id: id, name: "同型号", transport: "USB", vendorIDHex: "0xA8A5", productIDHex: "0x2255",
                                    usagePageHex: "0xFF01", usageHex: "0x0010", matchedDriver: driver,
                                    batterySummary: summary, rawNote: "")
        value.deviceGroupKey = group
        return value
    }
}
