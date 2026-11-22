import Foundation
import Testing
@testable import PeripheralBatteryCore

@Suite("HID 协议驱动单元测试")
struct ProtocolDriversTests {

    @Test("EVision 0xFF1C 请求构造与电量解析")
    func eVisionRequestAndResponses() {
        let req = EVisionHIDDriver.buildBatteryRequest()
        #expect(req.count == 64)
        #expect(req[0] == 0x04)
        #expect(req[3] == 0x1A)
        #expect(req[1] == 0x1A)
        #expect(req[2] == 0x00)

        var fullResp = [UInt8](repeating: 0, count: 64)
        fullResp[0] = 0x04
        fullResp[3] = 0x1A
        fullResp[8] = 0x64 // 100%
        fullResp[9] = 0x01 // charging
        let parsedFull = EVisionHIDDriver.parseBatteryResponse(fullResp)
        #expect(parsedFull?.batteryLevel == 100)
        #expect(parsedFull?.chargingState == .full)

        var dischResp = [UInt8](repeating: 0, count: 64)
        dischResp[0] = 0x04
        dischResp[3] = 0x1A
        dischResp[8] = 72
        dischResp[9] = 0x00
        let parsedDisch = EVisionHIDDriver.parseBatteryResponse(dischResp)
        #expect(parsedDisch?.batteryLevel == 72)
        #expect(parsedDisch?.chargingState == .discharging)
    }

    @Test("YJX-CHIP 0xFF01 请求构造与电量/休眠解析")
    func yjxChipRequestAndResponses() {
        let req = YJXChipHIDDriver.buildBatteryRequest()
        #expect(req.count == 64)
        #expect(Array(req.prefix(8)) == [0x55, 0x30, 0xA5, 0x0B, 0x2E, 0x01, 0x01, 0x01])

        let activeResp = yjxFrame(level: 64)
        let active = YJXChipHIDDriver.parseBatteryResponse(activeResp)
        #expect(active?.batteryLevel == 64)
        #expect(active?.chargingState == .discharging)

        let sleepingResp = yjxFrame(level: 0)
        let sleeping = YJXChipHIDDriver.parseBatteryResponse(sleepingResp)
        #expect(sleeping?.batteryLevel == nil)
        #expect(sleeping?.chargingState == .sleeping)

        let chargingResp = yjxFrame(level: 85, charging: true)
        let charging = YJXChipHIDDriver.parseBatteryResponse(chargingResp)
        #expect(charging?.batteryLevel == 85)
        #expect(charging?.chargingState == .charging)
    }

    @Test("YJX-CHIP 拒绝异常回包和超范围电量")
    func yjxChipRejectsInvalidFrames() {
        var unrelated = yjxFrame(level: 80)
        unrelated[5] = 0xFF
        #expect(YJXChipHIDDriver.parseBatteryResponse(unrelated) == nil)
        #expect(YJXChipHIDDriver.parseBatteryResponse(yjxFrame(level: 255)) == nil)
        #expect(YJXChipHIDDriver.parseBatteryResponse(Array(yjxFrame(level: 64).prefix(9))) == nil)
    }

    @Test("YJX-CHIP 复读确认跳变和首次读数")
    func yjxChipConfirmsLargeChanges() {
        let previous = VendorBatteryReading(batteryLevel: 64, chargingState: .discharging)
        let normal = VendorBatteryReading(batteryLevel: 63, chargingState: .discharging)
        let spike = VendorBatteryReading(batteryLevel: 80, chargingState: .discharging)
        let confirmedChange = VendorBatteryReading(batteryLevel: 79, chargingState: .discharging)

        let reverted = YJXChipHIDDriver.confirmReading(spike, previous: previous) { normal }
        #expect(reverted == normal)
        let confirmed = YJXChipHIDDriver.confirmReading(spike, previous: previous) { confirmedChange }
        #expect(confirmed == confirmedChange)
        let unresolved = YJXChipHIDDriver.confirmReading(spike, previous: previous) { nil }
        #expect(unresolved.batteryLevel == nil)
        #expect(unresolved.chargingState == .unknown)

        var rereadCount = 0
        let ordinary = YJXChipHIDDriver.confirmReading(normal, previous: previous) {
            rereadCount += 1
            return normal
        }
        #expect(ordinary == normal)
        #expect(rereadCount == 0)
        let initial = YJXChipHIDDriver.confirmReading(spike, previous: nil) { normal }
        #expect(initial.batteryLevel == nil)
    }

    private func yjxFrame(level: UInt8, charging: Bool = false) -> [UInt8] {
        let route: UInt8 = charging ? 0x3C : 0x0B
        let chargingFlag: UInt8 = charging ? 0x01 : 0x00
        return [0xAA, 0x30, 0xA5, route, 0x0A, 0x01, 0x01, 0x01, level, chargingFlag]
            + Array(repeating: 0, count: 54)
    }

    @Test("Compx 17 字节协议校验与电压解析")
    func compxRequestAndResponses() {
        let req = CompxHIDDriver.buildBatteryRequest()
        #expect(req.count == 17)
        #expect(req[0] == 0x08)
        #expect(req[1] == 0x04)
        #expect(req[16] == 0x49)

        var resp = [UInt8](repeating: 0, count: 17)
        resp[0] = 0x08
        resp[1] = 0x04
        resp[6] = 78
        resp[7] = 0x00
        resp[8] = 0x0F // 0x0F6E = 3950 mV
        resp[9] = 0x6E
        let parsed = CompxHIDDriver.parseBatteryResponse(resp)
        #expect(parsed?.batteryLevel == 78)
        #expect(parsed?.chargingState == .discharging)
        #expect(parsed?.voltageMillivolts == 3950)
    }

    @Test("Logitech HID++ 2.0 特性查找与 0x1004/0x1000/0x1001 解析")
    func logitechHIDPPParsing() {
        let rootReq = LogitechHIDPPDriver.buildRootGetFeatureRequest(deviceIndex: 0x01, featureID: 0x1004)
        #expect(rootReq.count == 20)
        #expect(rootReq[0] == 0x11)
        #expect(rootReq[1] == 0x01)
        #expect(rootReq[2] == 0x00)
        #expect(rootReq[4] == 0x10)
        #expect(rootReq[5] == 0x04)

        let rootResp: [UInt8] = [0x11, 0x01, 0x00, 0x0A, 0x07, 0x00, 0x00]
        #expect(LogitechHIDPPDriver.parseRootGetFeatureResponse(rootResp) == 0x07)

        let errResp: [UInt8] = [0x11, 0x01, 0xFF, 0x0A, 0x05, 0x00, 0x00]
        #expect(LogitechHIDPPDriver.parseRootGetFeatureResponse(errResp) == nil)

        // 0x1004 Unified Battery
        let unified = LogitechHIDPPDriver.parseUnifiedBatteryResponse([0x11, 0x01, 0x07, 0x1A, 85, 0x00, 0x01])
        #expect(unified?.level == 85)
        #expect(unified?.charging == .charging)

        // 0x1000 Battery Status
        let status = LogitechHIDPPDriver.parseBatteryStatusResponse([0x11, 0x01, 0x06, 0x0A, 40, 20, 0x00])
        #expect(status?.level == 40)
        #expect(status?.charging == .discharging)

        // 0x1001 Battery Voltage (3850 mV -> 50%)
        let mv = UInt16(3850)
        let voltageResp: [UInt8] = [0x11, 0x01, 0x05, 0x0A, UInt8(mv >> 8), UInt8(mv & 0xFF), 0x00]
        let voltage = LogitechHIDPPDriver.parseBatteryVoltageResponse(voltageResp)
        #expect(voltage?.level == 50)
        #expect(voltage?.voltageMV == 3850)
        #expect(voltage?.charging == .discharging)
    }

    @Test("Razer 90 字节 XOR 校验与电量/充电解析")
    func razer90ByteProtocol() {
        let req = RazerHIDDriver.buildRequest(transactionID: 0x1F, commandID: 0x80)
        #expect(req.count == 90)
        #expect(req[1] == 0x1F)
        #expect(req[6] == 0x07)
        #expect(req[7] == 0x80)
        #expect(req[88] == 0x85)

        var batResp = [UInt8](repeating: 0, count: 90)
        batResp[0] = 0x02
        batResp[6] = 0x07
        batResp[7] = 0x80
        batResp[9] = 0xFF
        #expect(RazerHIDDriver.parseBatteryResponse(batResp) == 100)

        var chResp = [UInt8](repeating: 0, count: 90)
        chResp[0] = 0x02
        chResp[6] = 0x07
        chResp[7] = 0x84
        chResp[9] = 0x01
        #expect(RazerHIDDriver.parseChargingResponse(chResp) == true)
    }

    @Test("Sony DualSense / DualShock 4 USB 与蓝牙 Report 解析")
    func sonyPlayStationParsing() {
        var dsUSB = [UInt8](repeating: 0, count: 64)
        dsUSB[0] = 0x01
        dsUSB[53] = 0x17
        let parsedDS = SonyPlayStationDriver.parseInputReport(reportID: 1, bytes: dsUSB, productID: 0x0CE6)
        #expect(parsedDS?.batteryLevel == 75)
        #expect(parsedDS?.chargingState == .charging)
        #expect(parsedDS?.transportOverride == .usb)

        var dsBT = [UInt8](repeating: 0, count: 78)
        dsBT[0] = 0x31
        dsBT[54] = 0x06
        let parsedDSBT = SonyPlayStationDriver.parseInputReport(reportID: 0x31, bytes: dsBT, productID: 0x0CE6)
        #expect(parsedDSBT?.batteryLevel == 65)
        #expect(parsedDSBT?.chargingState == .discharging)
        #expect(parsedDSBT?.transportOverride == .bluetooth)

        var ds4USB = [UInt8](repeating: 0, count: 64)
        ds4USB[0] = 0x01
        ds4USB[30] = 0x18
        let parsedDS4 = SonyPlayStationDriver.parseInputReport(reportID: 1, bytes: ds4USB, productID: 0x09CC)
        #expect(parsedDS4?.batteryLevel == 80)
        #expect(parsedDS4?.chargingState == .charging)
    }

    @Test("SteelSeries 与 Corsair Bragi 协议解析")
    func steelSeriesAndCorsairParsing() {
        let mouse = SteelSeriesHIDDriver.parseMouseResponse([0x92, 0x80 | 17], command: 0x92)
        #expect(mouse?.batteryLevel == 80)
        #expect(mouse?.chargingState == .charging)

        let headset = SteelSeriesHIDDriver.parseHeadsetResponse([0x06, 0xB0, 62, 0x00])
        #expect(headset?.batteryLevel == 62)
        #expect(headset?.categoryOverride == .headphones)

        let bragiBat = CorsairBragiHIDDriver.parseBatteryLevelResponse([0x08, 0x02, 0x00, 0x0F, 0x00, 0x57, 0x03])
        #expect(bragiBat == 86)
        let bragiCh = CorsairBragiHIDDriver.parseChargingResponse([0x08, 0x02, 0x00, 0x10, 0x00, 0x01], level: 86)
        #expect(bragiCh == .charging)
    }

    @Test("自定义 JSON 规则匹配与响应解析")
    func customJSONRuleMatchingAndParsing() {
        let rule = CustomHIDRule(
            name: "Custom Mouse",
            vendorID: "0x1234",
            productID: "0x5678",
            usagePage: "0xFF00",
            reportType: "output",
            reportID: 0,
            reportLength: 16,
            requestHex: "AA 55 01",
            responsePrefixHex: "BB 55",
            batteryByteIndex: 4,
            batteryMaxValue: 200,
            chargingByteIndex: 5,
            chargingMask: 0x01,
            category: .mouse
        )

        let desc = HIDDeviceDescriptor(
            vendorID: 0x1234,
            productID: 0x5678,
            product: "My Custom Mouse",
            manufacturer: "Custom",
            serialNumber: nil,
            transport: "USB",
            locationID: 1,
            primaryUsagePage: 0xFF00,
            primaryUsage: 0x0001,
            usagePairs: [(0xFF00, 0x0001)],
            maxInputReportSize: 16,
            maxOutputReportSize: 16,
            maxFeatureReportSize: 0,
            isBuiltIn: false
        )

        #expect(rule.matches(descriptor: desc))
        let req = rule.buildRequestBytes()
        #expect(req.count == 16)
        #expect(Array(req.prefix(3)) == [0xAA, 0x55, 0x01])

        let reading = rule.parseResponse([0xBB, 0x55, 0x00, 0x00, 150, 0x01])
        #expect(reading?.batteryLevel == 75)
        #expect(reading?.chargingState == .charging)
        #expect(reading?.categoryOverride == .mouse)
    }
}
