import Foundation
import IOKit.ps

/// 从 macOS `IOPowerSources` 读取外部 UPS 电源、外接配件电源及（可选显示的）本机 Mac 电池
public final class IOPowerSourcesProvider: BatteryProvider {
    public let name = "IOPowerSources"

    public init() {}

    public func fetch() -> ProviderResult {
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue() as? [CFTypeRef]
        else {
            return ProviderResult()
        }

        var devices: [PeripheralDevice] = []
        var diagnostics: [DiagnosticEntry] = []

        for item in list {
            guard let desc = IOPSGetPowerSourceDescription(snapshot, item)?.takeUnretainedValue() as? [String: Any] else {
                continue
            }

            let psType = (desc[kIOPSTypeKey] as? String) ?? ""
            let isPresent = (desc[kIOPSIsPresentKey] as? Bool) ?? true
            guard isPresent else { continue }

            let isInternal = psType == kIOPSInternalBatteryType
            let isUPS = psType == kIOPSUPSType

            let rawName = (desc[kIOPSNameKey] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "电源设备"
            let displayName = isInternal ? "Mac 本机电池" : rawName

            let currentCap = (desc[kIOPSCurrentCapacityKey] as? Int) ?? 0
            let maxCap = (desc[kIOPSMaxCapacityKey] as? Int) ?? 100
            let percentage: Int? = maxCap > 0
                ? min(max(Int((Double(currentCap) / Double(maxCap) * 100.0).rounded()), 0), 100)
                : nil

            let isCharging = (desc[kIOPSIsChargingKey] as? Bool) ?? false
            let isCharged = (desc[kIOPSIsChargedKey] as? Bool) ?? false
            let powerState = (desc[kIOPSPowerSourceStateKey] as? String) ?? ""

            let chargingState: ChargingState
            if isCharging {
                chargingState = .charging
            } else if isCharged || (percentage == 100 && powerState == kIOPSACPowerValue) {
                chargingState = .full
            } else if powerState == kIOPSACPowerValue && isInternal {
                chargingState = .wiredPower
            } else {
                chargingState = .discharging
            }

            let category = DeviceClassifier.classify(
                name: displayName,
                isUPS: isUPS,
                isInternal: isInternal
            )
            let transport: DeviceTransport = isInternal ? .builtIn : (isUPS ? .usb : .unknown)
            let psID = desc[kIOPSPowerSourceIDKey] as? Int
            let id = isInternal ? "internal-battery" : "iops-\(psID ?? rawName.hashValue)-\(rawName.lowercased())"

            let device = PeripheralDevice(
                id: id,
                name: displayName,
                category: category,
                transport: transport,
                batteryLevel: percentage,
                chargingState: chargingState,
                source: .ioPowerSources,
                sourceDetail: isUPS ? "UPS 电源" : (isInternal ? "本机电池" : "外接电源"),
                vendorID: desc[kIOPSVendorIDKey] as? Int,
                productID: desc[kIOPSProductIDKey] as? Int,
                isExternal: !isInternal,
                isConnected: true,
                statusHint: isInternal && powerState == kIOPSACPowerValue && !isCharging ? "已接电源" : nil
            )
            devices.append(device)

            diagnostics.append(
                DiagnosticEntry(
                    id: "diag-\(id)",
                    name: displayName,
                    transport: transport.badgeText,
                    vendorIDHex: DeviceClassifier.formatHex(desc[kIOPSVendorIDKey] as? Int),
                    productIDHex: DeviceClassifier.formatHex(desc[kIOPSProductIDKey] as? Int),
                    usagePageHex: "-",
                    usageHex: "-",
                    matchedDriver: "IOPowerSources (\(psType))",
                    batterySummary: percentage.map { "\($0)%" } ?? "未知",
                    rawNote: "state=\(powerState), charging=\(isCharging)"
                )
            )
        }

        return ProviderResult(devices: devices, diagnostics: diagnostics)
    }
}
