import Foundation

/// 外设硬件类型分类
public enum DeviceCategory: String, Codable, CaseIterable, Sendable {
    case mouse
    case keyboard
    case trackpad
    case headphones
    case earbuds
    case gamepad
    case stylus
    case speaker
    case ups
    case phone
    case tablet
    case laptop
    case other

    public var sfSymbol: String {
        switch self {
        case .mouse: return "computermouse.fill"
        case .keyboard: return "keyboard.fill"
        case .trackpad: return "rectangle.and.hand.point.up.left.fill"
        case .headphones: return "headphones"
        case .earbuds: return "airpodspro"
        case .gamepad: return "gamecontroller.fill"
        case .stylus: return "pencil.tip"
        case .speaker: return "hifispeaker.fill"
        case .ups: return "bolt.batteryblock.fill"
        case .phone: return "iphone"
        case .tablet: return "ipad"
        case .laptop: return "laptopcomputer"
        case .other: return "battery.100"
        }
    }

    public var label: String {
        switch self {
        case .mouse: return "鼠标"
        case .keyboard: return "键盘"
        case .trackpad: return "触控板"
        case .headphones: return "头戴耳机"
        case .earbuds: return "无线耳机"
        case .gamepad: return "游戏手柄"
        case .stylus: return "手写笔"
        case .speaker: return "音箱"
        case .ups: return "UPS 电源"
        case .phone: return "手机"
        case .tablet: return "平板"
        case .laptop: return "本机"
        case .other: return "外设"
        }
    }
}

/// 连接传输方式
public enum DeviceTransport: String, Codable, Sendable {
    case usb
    case wireless24G
    case bluetooth
    case ble
    case builtIn
    case unknown

    public var badgeText: String {
        switch self {
        case .usb: return "USB"
        case .wireless24G: return "2.4G"
        case .bluetooth: return "蓝牙"
        case .ble: return "BLE"
        case .builtIn: return "本机"
        case .unknown: return "外设"
        }
    }
}

/// 充电与电源状态
public enum ChargingState: String, Codable, Sendable {
    case charging
    case discharging
    case full
    case wiredPower
    case sleeping
    case unknown

    public var displayText: String? {
        switch self {
        case .charging: return "充电中"
        case .full: return "已充满"
        case .wiredPower: return "有线供电"
        case .sleeping: return "休眠中"
        case .discharging, .unknown: return nil
        }
    }

    public var isActivelyChargingOrFull: Bool {
        self == .charging || self == .full
    }
}

/// 子电池信息（如 TWS 左耳/右耳/充电盒，分体键盘左手/右手）
public struct SubBattery: Identifiable, Codable, Equatable, Sendable {
    public var id: String
    public var label: String
    public var level: Int
    public var chargingState: ChargingState

    public init(id: String, label: String, level: Int, chargingState: ChargingState = .unknown) {
        self.id = id
        self.label = label
        self.level = min(max(level, 0), 100)
        self.chargingState = chargingState
    }
}

/// 电量采集来源类型
public enum BatterySourceKind: String, Codable, Sendable {
    case vendorHID
    case coreBluetoothBAS
    case iokitHID
    case bluetoothProfiler
    case hidStandardPower
    case ioPowerSources
    case usbInventory

    /// 来源优先级（数值越大越优先保留）
    public var priority: Int {
        switch self {
        case .vendorHID: return 70
        case .coreBluetoothBAS: return 60
        case .iokitHID: return 50
        case .bluetoothProfiler: return 40
        case .hidStandardPower: return 30
        case .ioPowerSources: return 20
        case .usbInventory: return 10
        }
    }
}

/// 统一的外设电量模型
public struct PeripheralDevice: Identifiable, Codable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var category: DeviceCategory
    public var transport: DeviceTransport
    public var batteryLevel: Int?
    public var subBatteries: [SubBattery]
    public var chargingState: ChargingState
    public var voltageMillivolts: Int?
    public var source: BatterySourceKind
    public var sourceDetail: String
    public var vendorID: Int?
    public var productID: Int?
    public var serialNumber: String?
    public var bluetoothAddress: String?
    public var physicalLocationID: Int?
    public var legacyIDs: [String]?
    public var isExternal: Bool
    public var isConnected: Bool
    public var lastUpdated: Date
    public var batteryReadingAt: Date?
    public var batteryReadingIsStale: Bool?
    public var statusHint: String?
    public var requiresInputMonitoring: Bool

    public init(
        id: String,
        name: String,
        category: DeviceCategory = .other,
        transport: DeviceTransport = .unknown,
        batteryLevel: Int? = nil,
        subBatteries: [SubBattery] = [],
        chargingState: ChargingState = .unknown,
        voltageMillivolts: Int? = nil,
        source: BatterySourceKind,
        sourceDetail: String,
        vendorID: Int? = nil,
        productID: Int? = nil,
        serialNumber: String? = nil,
        bluetoothAddress: String? = nil,
        physicalLocationID: Int? = nil,
        isExternal: Bool = true,
        isConnected: Bool = true,
        lastUpdated: Date = Date(),
        statusHint: String? = nil,
        requiresInputMonitoring: Bool = false
    ) {
        self.id = id
        self.name = name
        self.category = category
        self.transport = transport
        self.batteryLevel = batteryLevel.map { min(max($0, 0), 100) }
        self.subBatteries = subBatteries
        self.chargingState = chargingState
        self.voltageMillivolts = voltageMillivolts
        self.source = source
        self.sourceDetail = sourceDetail
        self.vendorID = vendorID
        self.productID = productID
        self.serialNumber = serialNumber
        self.bluetoothAddress = bluetoothAddress
        self.physicalLocationID = physicalLocationID.flatMap { $0 > 0 ? $0 : nil }
        self.isExternal = isExternal
        self.isConnected = isConnected
        self.lastUpdated = lastUpdated
        self.batteryReadingAt = batteryLevel != nil || !subBatteries.isEmpty ? lastUpdated : nil
        self.statusHint = statusHint
        self.requiresInputMonitoring = requiresInputMonitoring
    }

    public var hasStaleBatteryReading: Bool { batteryReadingIsStale == true }

    public var diagnosticGroupKey: String? {
        Self.hardwareGroupKey(vendorID: vendorID, productID: productID, serialNumber: serialNumber,
                              bluetoothAddress: bluetoothAddress, physicalLocationID: physicalLocationID)
    }

    static func hardwareGroupKey(vendorID: Int?, productID: Int?, serialNumber: String?,
                                 bluetoothAddress: String? = nil, physicalLocationID: Int? = nil) -> String? {
        if let address = normalizedBluetoothAddress(bluetoothAddress) {
            return "bt-\(address)"
        }
        guard let vendorID, let productID else { return nil }
        let model = String(format: "%04x-%04x", vendorID, productID)
        if let physicalLocationID, physicalLocationID > 0 {
            return "usb-\(model)-location-\(String(physicalLocationID, radix: 16))"
        }
        if let serial = normalizedSerial(serialNumber) {
            return "usb-\(model)-serial-\(serial)"
        }
        return nil
    }

    static func normalizedBluetoothAddress(_ value: String?) -> String? {
        guard let value else { return nil }
        let raw = value.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        let address = raw.replacingOccurrences(of: "-", with: "").replacingOccurrences(of: ":", with: "")
        guard address.count == 12, address.allSatisfy(\.isHexDigit),
              address != "000000000000", address != "FFFFFFFFFFFF" else { return nil }
        return address
    }

    static func normalizedSerial(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !value.isEmpty else { return nil }
        return value
    }

    /// 有效主电量：优先取 batteryLevel；若为分体式/TWS 设备且无主电量，取非充电盒部件的最低电量
    public var effectiveBatteryLevel: Int? {
        if let batteryLevel {
            return batteryLevel
        }
        let nonCase = subBatteries.filter { sub in
            let lower = sub.label.lowercased()
            return !lower.contains("盒") && !lower.contains("case")
        }
        if let minNonCase = nonCase.map(\.level).min() {
            return minNonCase
        }
        return subBatteries.map(\.level).min()
    }
}

/// 诊断记录：呈现所有扫描到的 HID/USB/蓝牙/电源条目及协议匹配情况
public struct DiagnosticEntry: Identifiable, Codable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var transport: String
    public var vendorIDHex: String
    public var productIDHex: String
    public var usagePageHex: String
    public var usageHex: String
    public var matchedDriver: String
    public var batterySummary: String
    public var rawNote: String
    public var deviceGroupKey: String?

    public init(
        id: String,
        name: String,
        transport: String,
        vendorIDHex: String,
        productIDHex: String,
        usagePageHex: String,
        usageHex: String,
        matchedDriver: String,
        batterySummary: String,
        rawNote: String,
        deviceGroupKey: String? = nil
    ) {
        self.id = id
        self.name = name
        self.transport = transport
        self.vendorIDHex = vendorIDHex
        self.productIDHex = productIDHex
        self.usagePageHex = usagePageHex
        self.usageHex = usageHex
        self.matchedDriver = matchedDriver
        self.batterySummary = batterySummary
        self.rawNote = rawNote
        self.deviceGroupKey = deviceGroupKey
    }
}

public enum CardLayoutMode: String, Codable, CaseIterable, Sendable {
    case list
    case compactGrid

    public var label: String {
        switch self {
        case .list: return "列表卡片"
        case .compactGrid: return "圆形网格"
        }
    }
}

public enum WindowLevelMode: String, Codable, CaseIterable, Sendable {
    case desktop
    case floating

    public var label: String {
        switch self {
        case .desktop: return "贴靠桌面"
        case .floating: return "置顶悬浮"
        }
    }
}

public enum ThemeMode: String, Codable, CaseIterable, Sendable {
    case system
    case dark
    case light

    public var label: String {
        switch self {
        case .system: return "跟随系统"
        case .dark: return "深色毛玻璃"
        case .light: return "浅色毛玻璃"
        }
    }
}

/// 卡片持久化配置
public struct AppPreferences: Codable, Equatable, Sendable {
    public var layoutMode: CardLayoutMode = .list
    public var windowLevelMode: WindowLevelMode = .desktop
    public var themeMode: ThemeMode = .system
    public var cardOpacity: Double = 0.92
    public var isPositionLocked: Bool = false
    public var refreshIntervalSeconds: Double = 60
    public var showInternalBattery: Bool = false
    public var showDevicesWithoutBattery: Bool = false
    public var lowBatteryAlertEnabled: Bool = true
    public var lowBatteryThreshold: Int = 20
    public var customAliases: [String: String] = [:]
    public var hiddenDeviceIDs: Set<String> = []

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        layoutMode = try c.decodeIfPresent(CardLayoutMode.self, forKey: .layoutMode) ?? .list
        windowLevelMode = try c.decodeIfPresent(WindowLevelMode.self, forKey: .windowLevelMode) ?? .desktop
        themeMode = try c.decodeIfPresent(ThemeMode.self, forKey: .themeMode) ?? .system
        cardOpacity = try c.decodeIfPresent(Double.self, forKey: .cardOpacity) ?? 0.92
        isPositionLocked = try c.decodeIfPresent(Bool.self, forKey: .isPositionLocked) ?? false
        refreshIntervalSeconds = try c.decodeIfPresent(Double.self, forKey: .refreshIntervalSeconds) ?? 60
        showInternalBattery = try c.decodeIfPresent(Bool.self, forKey: .showInternalBattery) ?? false
        showDevicesWithoutBattery = try c.decodeIfPresent(Bool.self, forKey: .showDevicesWithoutBattery) ?? false
        lowBatteryAlertEnabled = try c.decodeIfPresent(Bool.self, forKey: .lowBatteryAlertEnabled) ?? true
        lowBatteryThreshold = try c.decodeIfPresent(Int.self, forKey: .lowBatteryThreshold) ?? 20
        customAliases = try c.decodeIfPresent([String: String].self, forKey: .customAliases) ?? [:]
        hiddenDeviceIDs = try c.decodeIfPresent(Set<String>.self, forKey: .hiddenDeviceIDs) ?? []
    }
}

/// CLI `--dump-json` 输出结构
public struct MonitorSnapshot: Codable, Sendable {
    public var generatedAt: Date
    public var devices: [PeripheralDevice]
    public var diagnostics: [DiagnosticEntry]

    public init(generatedAt: Date = Date(), devices: [PeripheralDevice], diagnostics: [DiagnosticEntry]) {
        self.generatedAt = generatedAt
        self.devices = devices
        self.diagnostics = diagnostics
    }
}
