import Foundation
import IOKit.hid

/// 统一调度所有厂商私有 USB / 2.4GHz / 蓝牙 HID 协议驱动的采集器
public final class VendorHIDBatteryProvider: BatteryProvider {
    public let name = "Vendor HID Protocols"

    private let drivers: [HIDVendorDriver]

    public init(drivers: [HIDVendorDriver]? = nil) {
        self.drivers = drivers ?? [
            CustomJSONRuleDriver(),
            EVisionHIDDriver(),
            YJXChipHIDDriver(),
            CompxHIDDriver(),
            LogitechHIDPPDriver(),
            RazerHIDDriver(),
            SonyPlayStationDriver(),
            SteelSeriesHIDDriver(),
            CorsairBragiHIDDriver()
        ]
    }

    public func fetch() -> ProviderResult {
        HIDDeviceHelper.ioQueue.sync {
            performFetch()
        }
    }

    private func performFetch() -> ProviderResult {
        let rawItems = HIDDeviceHelper.enumerateExternalHIDDevices()
        guard !rawItems.isEmpty else {
            return ProviderResult()
        }

        var devices: [PeripheralDevice] = []
        var diagnostics: [DiagnosticEntry] = []
        var resolvedPhysicalDevices = Set<String>()
        var restrictedPhysicalDevices: [String: (desc: HIDDeviceDescriptor, driverName: String)] = [:]
        var anyNotPermitted = false

        // 先按接口尺寸和厂商 UsagePage 排序，优先测试厂商专用接口
        let sortedItems = rawItems.sorted { lhs, rhs in
            let lVendor = lhs.descriptor.hasVendorUsagePage() ? 1 : 0
            let rVendor = rhs.descriptor.hasVendorUsagePage() ? 1 : 0
            if lVendor != rVendor { return lVendor > rVendor }
            return lhs.descriptor.maxOutputReportSize > rhs.descriptor.maxOutputReportSize
        }

        for (hidDevice, desc) in sortedItems {
            var entryID: UInt64 = 0
            IORegistryEntryGetRegistryEntryID(IOHIDDeviceGetService(hidDevice), &entryID)
            let physicalKey = PeripheralDevice.hardwareGroupKey(vendorID: desc.vendorID, productID: desc.productID,
                serialNumber: desc.serialNumber, physicalLocationID: desc.locationID) ?? "registry-\(entryID)"

            let matchedDrivers = drivers.filter { $0.matches(descriptor: desc) }
            var driverLabel = matchedDrivers.map(\.displayName).joined(separator: ", ")
            if driverLabel.isEmpty {
                driverLabel = "未匹配私有协议"
            }

            if resolvedPhysicalDevices.contains(physicalKey) {
                diagnostics.append(makeDiagnostic(desc: desc, driver: driverLabel, summary: "同设备其他接口（已通过主接口读取）"))
                continue
            }

            if !matchedDrivers.isEmpty {
                let openStatus = HIDDeviceHelper.probeOpenStatus(hidDevice)
                if openStatus == kIOReturnNotPermitted {
                    anyNotPermitted = true
                    if restrictedPhysicalDevices[physicalKey] == nil {
                        restrictedPhysicalDevices[physicalKey] = (desc, matchedDrivers[0].displayName)
                    }
                    diagnostics.append(
                        DiagnosticEntry(
                            id: "hid-\(desc.vendorID)-\(desc.productID)-\(desc.primaryUsagePage)-\(desc.primaryUsage)-\(desc.maxOutputReportSize)-\(desc.locationID ?? 0)",
                            name: desc.product.isEmpty ? "未知 HID 接口" : desc.product,
                            transport: desc.transport.isEmpty ? "HID" : desc.transport,
                            vendorIDHex: DeviceClassifier.formatHex(desc.vendorID),
                            productIDHex: DeviceClassifier.formatHex(desc.productID),
                            usagePageHex: DeviceClassifier.formatHex(desc.primaryUsagePage),
                            usageHex: DeviceClassifier.formatHex(desc.primaryUsage),
                            matchedDriver: driverLabel,
                            batterySummary: "权限受限（需输入监控）",
                            rawNote: String(format: "IOHIDDeviceOpen=0x%08X In=%dB Out=%dB", UInt32(bitPattern: openStatus), desc.maxInputReportSize, desc.maxOutputReportSize),
                            deviceGroupKey: diagnosticGroupKey(desc)
                        )
                    )
                    continue
                }
            }

            var capturedReadings: [VendorBatteryReading] = []
            var usedDriver: HIDVendorDriver?

            for driver in matchedDrivers {
                let readings = driver.query(device: hidDevice, descriptor: desc)
                if !readings.isEmpty {
                    capturedReadings = readings
                    usedDriver = driver
                    break
                }
            }

            if let usedDriver, !capturedReadings.isEmpty {
                resolvedPhysicalDevices.insert(physicalKey)
                restrictedPhysicalDevices.removeValue(forKey: physicalKey)
                for reading in capturedReadings {
                    let devName = reading.nameOverride ?? (desc.product.isEmpty ? "USB 外设" : desc.product)
                    let baseID = String(
                        format: "hid-%04x-%04x-%@",
                        desc.vendorID,
                        desc.productID,
                        desc.serialNumber ?? devName.lowercased()
                    )
                    let canonicalID = reading.slotKey == "0" ? baseID : "\(baseID)-slot\(reading.slotKey)"
                    let category = reading.categoryOverride ?? DeviceClassifier.classify(
                        name: devName,
                        usagePage: desc.primaryUsagePage,
                        usage: desc.primaryUsage,
                        usagePairs: desc.usagePairs
                    )
                    let transport = reading.transportOverride ?? DeviceClassifier.inferTransport(
                        rawTransport: desc.transport,
                        productName: devName,
                        productID: desc.productID
                    )

                    devices.append(
                        PeripheralDevice(
                            id: canonicalID,
                            name: devName,
                            category: category,
                            transport: transport,
                            batteryLevel: reading.batteryLevel,
                            chargingState: reading.chargingState,
                            voltageMillivolts: reading.voltageMillivolts,
                            source: .vendorHID,
                            sourceDetail: usedDriver.displayName,
                            vendorID: desc.vendorID,
                            productID: desc.productID,
                            serialNumber: desc.serialNumber,
                            physicalLocationID: desc.locationID,
                            isExternal: true,
                            isConnected: true,
                            statusHint: reading.statusHint
                        )
                    )
                }

                let summaryText = capturedReadings.map { r in
                    let pct = r.batteryLevel.map { "\($0)%" } ?? (r.statusHint ?? "未知")
                    return r.slotKey == "0" ? pct : "槽位\(r.slotKey): \(pct)"
                }.joined(separator: "; ")

                diagnostics.append(makeDiagnostic(desc: desc, driver: usedDriver.displayName, summary: summaryText))
            } else {
                let summary = matchedDrivers.isEmpty ? "无读取" : "匹配但未返回电量（可能休眠或待机）"
                diagnostics.append(makeDiagnostic(desc: desc, driver: driverLabel, summary: summary))
            }
        }

        // 对于因缺少“输入监控”权限而无法打开的匹配外设，生成带权限提示的设备占位条目
        for (physicalKey, info) in restrictedPhysicalDevices where !resolvedPhysicalDevices.contains(physicalKey) {
            let desc = info.desc
            let devName = desc.product.isEmpty ? "HID 外设" : desc.product
            let canonicalID = String(
                format: "hid-%04x-%04x-%@",
                desc.vendorID,
                desc.productID,
                desc.serialNumber ?? devName.lowercased()
            )
            let category = DeviceClassifier.classify(
                name: devName,
                usagePage: desc.primaryUsagePage,
                usage: desc.primaryUsage,
                usagePairs: desc.usagePairs
            )
            let transport = DeviceClassifier.inferTransport(
                rawTransport: desc.transport,
                productName: devName,
                productID: desc.productID
            )

            devices.append(
                PeripheralDevice(
                    id: canonicalID,
                    name: devName,
                    category: category,
                    transport: transport,
                    batteryLevel: nil,
                    chargingState: .unknown,
                    source: .vendorHID,
                    sourceDetail: "\(info.driverName) · 需权限",
                    vendorID: desc.vendorID,
                    productID: desc.productID,
                    serialNumber: desc.serialNumber,
                    physicalLocationID: desc.locationID,
                    isExternal: true,
                    isConnected: true,
                    statusHint: "需开启「输入监控」",
                    requiresInputMonitoring: true
                )
            )
        }

        return ProviderResult(
            devices: devices,
            diagnostics: diagnostics,
            needsInputMonitoring: anyNotPermitted
        )
    }

    private func makeDiagnostic(desc: HIDDeviceDescriptor, driver: String, summary: String) -> DiagnosticEntry {
        let name = desc.product.isEmpty ? "未知 HID 接口" : desc.product
        return DiagnosticEntry(
            id: "hid-\(desc.vendorID)-\(desc.productID)-\(desc.primaryUsagePage)-\(desc.primaryUsage)-\(desc.maxOutputReportSize)-\(desc.locationID ?? 0)",
            name: name,
            transport: desc.transport.isEmpty ? "HID" : desc.transport,
            vendorIDHex: DeviceClassifier.formatHex(desc.vendorID),
            productIDHex: DeviceClassifier.formatHex(desc.productID),
            usagePageHex: DeviceClassifier.formatHex(desc.primaryUsagePage),
            usageHex: DeviceClassifier.formatHex(desc.primaryUsage),
            matchedDriver: driver,
            batterySummary: summary,
            rawNote: "In=\(desc.maxInputReportSize)B Out=\(desc.maxOutputReportSize)B Feat=\(desc.maxFeatureReportSize)B",
            deviceGroupKey: diagnosticGroupKey(desc)
        )
    }

    private func diagnosticGroupKey(_ desc: HIDDeviceDescriptor) -> String? {
        PeripheralDevice.hardwareGroupKey(vendorID: desc.vendorID, productID: desc.productID,
            serialNumber: desc.serialNumber, physicalLocationID: desc.locationID)
    }
}
