import Foundation
import IOKit
import IOKit.hid

/// 通过标准 USB/BT HID 电源页（UsagePage 0x06 Usage 0x20 BatteryStrength；UsagePage 0x85 BatterySystem RemainingCapacity/Charging）读取支持标准协议的外设
public final class StandardHIDBatteryProvider: BatteryProvider {
    public let name = "Standard HID Power"

    public init() {}

    public func fetch() -> ProviderResult {
        HIDDeviceHelper.ioQueue.sync {
            performFetch()
        }
    }

    private func performFetch() -> ProviderResult {
        let externalItems = HIDDeviceHelper.enumerateExternalHIDDevices()
        guard !externalItems.isEmpty else {
            return ProviderResult()
        }

        var devices: [PeripheralDevice] = []
        var diagnostics: [DiagnosticEntry] = []
        var seenIDs = Set<String>()

        for (device, desc) in externalItems {
            let transportRaw = desc.transport

            guard let elements = IOHIDDeviceCopyMatchingElements(device, nil, IOOptionBits(kIOHIDOptionsTypeNone)) as? [IOHIDElement] else {
                continue
            }

            var batteryElement: IOHIDElement?
            var chargingElement: IOHIDElement?

            for element in elements {
                let page = Int(IOHIDElementGetUsagePage(element))
                let usage = Int(IOHIDElementGetUsage(element))
                if page == 0x06 && usage == 0x20 { // Generic Device Controls -> Battery Strength
                    batteryElement = element
                } else if page == 0x85 && (usage == 0x66 || usage == 0x65 || usage == 0x67) { // Battery System -> RemainingCapacity
                    batteryElement = element
                } else if page == 0x85 && (usage == 0x44 || usage == 0xD0) { // Charging / ACPresent
                    chargingElement = element
                }
            }

            guard let batElem = batteryElement else { continue }
            guard IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess else {
                continue
            }
            defer { IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone)) }

            var valueRef = Unmanaged<IOHIDValue>.fromOpaque(UnsafeRawPointer(bitPattern: 1)!)
            guard IOHIDDeviceGetValue(device, batElem, &valueRef) == kIOReturnSuccess else {
                continue
            }
            let val = valueRef.takeUnretainedValue()

            let rawInt = IOHIDValueGetIntegerValue(val)
            let logicalMin = IOHIDElementGetLogicalMin(batElem)
            let logicalMax = IOHIDElementGetLogicalMax(batElem)
            let percent: Int
            if logicalMax > logicalMin {
                let ratio = Double(rawInt - logicalMin) / Double(logicalMax - logicalMin)
                percent = min(max(Int((ratio * 100.0).rounded()), 0), 100)
            } else {
                percent = min(max(Int(rawInt), 0), 100)
            }

            var chargingState: ChargingState = .discharging
            if let chElem = chargingElement {
                var chRef = Unmanaged<IOHIDValue>.fromOpaque(UnsafeRawPointer(bitPattern: 1)!)
                if IOHIDDeviceGetValue(device, chElem, &chRef) == kIOReturnSuccess {
                    let chVal = chRef.takeUnretainedValue()
                    if IOHIDValueGetIntegerValue(chVal) != 0 {
                        chargingState = percent == 100 ? .full : .charging
                    }
                }
            }

            let product = ((IOHIDDeviceGetProperty(device, kIOHIDProductKey as CFString) as? String) ?? "HID 外设")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let vendorID = IOHIDDeviceGetProperty(device, kIOHIDVendorIDKey as CFString) as? Int
            let productID = IOHIDDeviceGetProperty(device, kIOHIDProductIDKey as CFString) as? Int
            let serial = (IOHIDDeviceGetProperty(device, kIOHIDSerialNumberKey as CFString) as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let usagePage = IOHIDDeviceGetProperty(device, kIOHIDPrimaryUsagePageKey as CFString) as? Int
            let usage = IOHIDDeviceGetProperty(device, kIOHIDPrimaryUsageKey as CFString) as? Int

            let canonicalID: String
            if let vid = vendorID, let pid = productID {
                canonicalID = String(format: "hid-%04x-%04x-%@", vid, pid, serial ?? product.lowercased())
            } else {
                canonicalID = "stdhid-\(product.lowercased())"
            }

            let transport = DeviceClassifier.inferTransport(
                rawTransport: transportRaw,
                productName: product,
                productID: productID
            )
            let category = DeviceClassifier.classify(name: product, usagePage: usagePage, usage: usage)
            let bluetoothAddress = (IOHIDDeviceGetProperty(device, "DeviceAddress" as CFString) as? String)
                ?? (IOHIDDeviceGetProperty(device, "BD_ADDR" as CFString) as? String)
            let physicalLocationID = transport == .usb || transport == .wireless24G ? desc.locationID : nil
            let reading = PeripheralDevice(
                id: canonicalID,
                name: product,
                category: category,
                transport: transport,
                batteryLevel: percent,
                chargingState: chargingState,
                source: .hidStandardPower,
                sourceDetail: "标准 HID Power",
                vendorID: vendorID,
                productID: productID,
                serialNumber: serial,
                bluetoothAddress: bluetoothAddress,
                physicalLocationID: physicalLocationID,
                isExternal: true,
                isConnected: true
            )

            var registryID: UInt64 = 0
            let service = IOHIDDeviceGetService(device)
            if service != 0 { IORegistryEntryGetRegistryEntryID(service, &registryID) }
            let fallbackID = registryID == 0 ? "observation-\(devices.count)" : "registry-\(registryID)"
            let observationID = reading.diagnosticGroupKey ?? fallbackID
            guard seenIDs.insert(observationID).inserted else { continue }
            devices.append(reading)
            diagnostics.append(
                DiagnosticEntry(
                    id: "stdhid-\(canonicalID)",
                    name: product,
                    transport: transport.badgeText,
                    vendorIDHex: DeviceClassifier.formatHex(vendorID),
                    productIDHex: DeviceClassifier.formatHex(productID),
                    usagePageHex: DeviceClassifier.formatHex(usagePage),
                    usageHex: DeviceClassifier.formatHex(usage),
                    matchedDriver: "Standard HID Power (0x06/0x85)",
                    batterySummary: "\(percent)%",
                    rawNote: "raw=\(rawInt) range=\(logicalMin)...\(logicalMax)",
                    deviceGroupKey: reading.diagnosticGroupKey
                )
            )
        }

        return ProviderResult(devices: devices, diagnostics: diagnostics)
    }
}
