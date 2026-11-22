import Foundation

/// 通过 `system_profiler SPBluetoothDataType -json` 解析已连接蓝牙设备的电量（包含 AirPods 左/右耳/充电盒、蓝牙耳机、键鼠、手柄等）
public final class BluetoothProfilerProvider: BatteryProvider {
    public let name = "Bluetooth System Profiler"

    public init() {}

    public func fetch() -> ProviderResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
        process.arguments = ["SPBluetoothDataType", "-json"]

        let stdoutPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = FileHandle.nullDevice

        let semaphore = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in
            semaphore.signal()
        }

        do {
            try process.run()
        } catch {
            return ProviderResult()
        }

        let waitResult = semaphore.wait(timeout: .now() + 5.0)
        if waitResult == .timedOut {
            process.terminate()
            return ProviderResult()
        }

        let data = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        guard !data.isEmpty else { return ProviderResult() }
        return Self.parseBluetoothProfilerJSON(data)
    }

    /// 纯解析方法，便于单元测试直接验证各种蓝牙设备 JSON 输出
    public static func parseBluetoothProfilerJSON(_ data: Data) -> ProviderResult {
        guard
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let entries = root["SPBluetoothDataType"] as? [[String: Any]]
        else {
            return ProviderResult()
        }

        var devices: [PeripheralDevice] = []
        var diagnostics: [DiagnosticEntry] = []

        for controllerEntry in entries {
            if let connectedList = controllerEntry["device_connected"] as? [[String: Any]] {
                for item in connectedList {
                    for (deviceName, rawInfo) in item {
                        guard let info = rawInfo as? [String: Any] else { continue }
                        let parsed = buildDevice(name: deviceName, info: info, isConnected: true)
                        devices.append(parsed.device)
                        diagnostics.append(parsed.diagnostic)
                    }
                }
            }
            if let disconnectedList = controllerEntry["device_not_connected"] as? [[String: Any]] {
                for item in disconnectedList {
                    for (deviceName, rawInfo) in item {
                        guard let info = rawInfo as? [String: Any] else { continue }
                        let vendorID = parseHexInt(info["device_vendorID"] as? String)
                        let productID = parseHexInt(info["device_productID"] as? String)
                        let address = info["device_address"] as? String
                        diagnostics.append(
                            DiagnosticEntry(
                                id: "bt-disc-\(deviceName)-\(address ?? "")",
                                name: deviceName,
                                transport: "蓝牙(未连接)",
                                vendorIDHex: DeviceClassifier.formatHex(vendorID),
                                productIDHex: DeviceClassifier.formatHex(productID),
                                usagePageHex: "-",
                                usageHex: "-",
                                matchedDriver: "SPBluetoothDataType",
                                batterySummary: "未连接",
                                rawNote: "已在系统配对，当前未连接",
                                deviceGroupKey: PeripheralDevice.hardwareGroupKey(
                                    vendorID: vendorID, productID: productID, serialNumber: nil, bluetoothAddress: address
                                )
                            )
                        )
                    }
                }
            }
        }

        return ProviderResult(devices: devices, diagnostics: diagnostics)
    }

    private static func buildDevice(
        name: String,
        info: [String: Any],
        isConnected: Bool
    ) -> (device: PeripheralDevice, diagnostic: DiagnosticEntry) {
        let btAddress = normalizeAddress(info["device_address"] as? String)
        let minorType = info["device_minorType"] as? String
        let vendorID = parseHexInt(info["device_vendorID"] as? String)
        let productID = parseHexInt(info["device_productID"] as? String)

        let mainBattery = parsePercent(info["device_batteryLevelMain"])
        let leftBattery = parsePercent(info["device_batteryLevelLeft"])
        let rightBattery = parsePercent(info["device_batteryLevelRight"])
        let caseBattery = parsePercent(info["device_batteryLevelCase"])

        var subBatteries: [SubBattery] = []
        if let left = leftBattery {
            subBatteries.append(SubBattery(id: "left", label: "左耳", level: left))
        }
        if let right = rightBattery {
            subBatteries.append(SubBattery(id: "right", label: "右耳", level: right))
        }
        if let box = caseBattery {
            subBatteries.append(SubBattery(id: "case", label: "充电盒", level: box))
        }

        var category = DeviceClassifier.classify(name: name, minorType: minorType)
        if !subBatteries.isEmpty && (category == .headphones || category == .other) {
            category = .earbuds
        }

        var effectiveMain = mainBattery
        if effectiveMain == nil, !subBatteries.isEmpty {
            let buds = subBatteries.filter { $0.id == "left" || $0.id == "right" }.map(\.level)
            effectiveMain = buds.min() ?? subBatteries.map(\.level).min()
        }

        let canonicalID = btAddress.map { "bt-\($0)" } ?? "bt-\(name.lowercased())"
        let hasBattery = effectiveMain != nil || !subBatteries.isEmpty

        let device = PeripheralDevice(
            id: canonicalID,
            name: name,
            category: category,
            transport: .bluetooth,
            batteryLevel: effectiveMain,
            subBatteries: subBatteries,
            chargingState: hasBattery ? .discharging : .unknown,
            source: .bluetoothProfiler,
            sourceDetail: "系统蓝牙",
            vendorID: vendorID,
            productID: productID,
            bluetoothAddress: btAddress,
            isExternal: true,
            isConnected: isConnected
        )

        let summary: String
        if !subBatteries.isEmpty {
            summary = subBatteries.map { "\($0.label) \($0.level)%" }.joined(separator: " / ")
        } else if let main = effectiveMain {
            summary = "\(main)%"
        } else {
            summary = "已连接（蓝牙未上报电量）"
        }

        let diag = DiagnosticEntry(
            id: "bt-\(canonicalID)",
            name: name,
            transport: "蓝牙",
            vendorIDHex: DeviceClassifier.formatHex(vendorID),
            productIDHex: DeviceClassifier.formatHex(productID),
            usagePageHex: "-",
            usageHex: "-",
            matchedDriver: "SPBluetoothDataType",
            batterySummary: summary,
            rawNote: minorType ?? "",
            deviceGroupKey: device.diagnosticGroupKey
        )
        return (device, diag)
    }

    static func parsePercent(_ value: Any?) -> Int? {
        if let num = value as? Int {
            return min(max(num, 0), 100)
        }
        if let num = value as? NSNumber {
            return min(max(num.intValue, 0), 100)
        }
        if let str = value as? String {
            let digits = str.trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: "%", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if let v = Int(digits) {
                return min(max(v, 0), 100)
            }
        }
        return nil
    }

    static func parseHexInt(_ text: String?) -> Int? {
        guard let text else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let token = trimmed.split(separator: " ").first.map(String.init) else {
            return nil
        }
        let cleaned = token.lowercased().hasPrefix("0x") ? String(token.dropFirst(2)) : token
        return Int(cleaned, radix: 16)
    }

    private static func normalizeAddress(_ addr: String?) -> String? {
        guard let addr = addr?.trimmingCharacters(in: .whitespacesAndNewlines), !addr.isEmpty else {
            return nil
        }
        return addr.uppercased().replacingOccurrences(of: "-", with: ":")
    }
}
