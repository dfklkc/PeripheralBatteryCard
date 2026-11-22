import Foundation
import IOKit

/// 枚举外接 USB 外设清单（跳过 Hub、Billboard、内置器件），用于诊断列表与可选显示“未上报电量的有线/接收器外设”
public final class ExternalUSBInventoryProvider: BatteryProvider {
    public let name = "External USB Inventory"

    public init() {}

    public func fetch() -> ProviderResult {
        guard let matching = IOServiceMatching("IOUSBHostDevice") else {
            return ProviderResult()
        }
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else {
            return ProviderResult()
        }
        defer { IOObjectRelease(iterator) }

        var devices: [PeripheralDevice] = []
        var diagnostics: [DiagnosticEntry] = []
        var seen = Set<String>()

        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }

            var propsRef: Unmanaged<CFMutableDictionary>?
            guard IORegistryEntryCreateCFProperties(service, &propsRef, kCFAllocatorDefault, 0) == KERN_SUCCESS,
                  let props = propsRef?.takeRetainedValue() as? [String: Any]
            else {
                continue
            }

            let deviceClass = (props["bDeviceClass"] as? Int) ?? 0
            // 9 = USB Hub, 17 = Billboard Device
            if deviceClass == 9 || deviceClass == 17 {
                continue
            }

            let product = ((props["USB Product Name"] as? String) ?? (props["kUSBProductString"] as? String) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if product.isEmpty { continue }

            let lowerName = product.lowercased()
            if lowerName.contains("hub") || lowerName.contains("billboard") || lowerName.contains("apple internal") {
                continue
            }

            let vendorID = props["idVendor"] as? Int
            let productID = props["idProduct"] as? Int
            let serial = ((props["USB Serial Number"] as? String) ?? (props["kUSBSerialNumberString"] as? String))?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let locationID = (props["locationID"] ?? props["LocationID"]) as? Int

            var entryID: UInt64 = 0
            IORegistryEntryGetRegistryEntryID(service, &entryID)
            let groupKey = PeripheralDevice.hardwareGroupKey(vendorID: vendorID, productID: productID,
                serialNumber: serial, physicalLocationID: locationID)
            let dedupKey = groupKey ?? "registry-\(entryID)"
            if seen.contains(dedupKey) { continue }
            seen.insert(dedupKey)

            let canonicalID: String
            if let vid = vendorID, let pid = productID {
                canonicalID = String(format: "hid-%04x-%04x-%@", vid, pid, serial ?? lowerName)
            } else {
                canonicalID = "usb-\(lowerName)"
            }

            let transport = DeviceClassifier.inferTransport(
                rawTransport: "USB",
                productName: product,
                productID: productID
            )
            let category = DeviceClassifier.classify(name: product)

            devices.append(
                PeripheralDevice(
                    id: canonicalID,
                    name: product,
                    category: category,
                    transport: transport,
                    batteryLevel: nil,
                    chargingState: .unknown,
                    source: .usbInventory,
                    sourceDetail: "USB 设备清单",
                    vendorID: vendorID,
                    productID: productID,
                    serialNumber: serial,
                    physicalLocationID: locationID,
                    isExternal: true,
                    isConnected: true,
                    statusHint: "未识别电量协议"
                )
            )
            diagnostics.append(
                DiagnosticEntry(
                    id: "usb-inv-\(canonicalID)",
                    name: product,
                    transport: transport.badgeText,
                    vendorIDHex: DeviceClassifier.formatHex(vendorID),
                    productIDHex: DeviceClassifier.formatHex(productID),
                    usagePageHex: "-",
                    usageHex: "-",
                    matchedDriver: "USB Inventory",
                    batterySummary: "未读取到电量",
                    rawNote: serial.map { "SN=\($0)" } ?? "USB 设备",
                    deviceGroupKey: groupKey
                )
            )
        }

        return ProviderResult(devices: devices, diagnostics: diagnostics)
    }
}
