import Combine
import Foundation
import IOKit.hid
import IOKit.ps
import os

/// 外设电量采集调度与实时监听服务
@MainActor
public final class BatteryMonitorService: ObservableObject {
    private static let logger = Logger(subsystem: "com.peripheralbattery.card", category: "monitor")

    @Published public private(set) var devices: [PeripheralDevice] = []
    @Published public private(set) var diagnostics: [DiagnosticEntry] = []
    @Published public private(set) var isRefreshing: Bool = false
    @Published public private(set) var lastUpdated: Date?
    @Published public private(set) var needsInputMonitoring: Bool = false
    @Published public private(set) var restrictedDeviceNames: [String] = []

    @Published public var preferences: AppPreferences {
        didSet {
            savePreferences()
            if oldValue.refreshIntervalSeconds != preferences.refreshIntervalSeconds {
                restartTimer()
            }
        }
    }

    private static let prefsStorageKey = "PeripheralBatteryCard.preferences.v1"

    private let aggregator = BatteryAggregator()
    private let coreBluetoothProvider = CoreBluetoothBASProvider()
    private let providers: [BatteryProvider]

    private let scanQueue = DispatchQueue(label: "com.peripheralbattery.scan", qos: .utility)
    private var refreshTimer: Timer?
    private var debounceWorkItem: DispatchWorkItem?
    private var lastScanResults: [ProviderResult] = []
    private var refreshPending = false
    private var hidNotificationPort: IONotificationPortRef?
    private var hidMatchedIterator: io_iterator_t = 0
    private var hidTerminatedIterator: io_iterator_t = 0
    private var powerSourceRunLoopSource: CFRunLoopSource?
    private var isStarted = false

    public convenience init() {
        self.init(providers: Self.defaultProviders())
    }

    init(providers: [BatteryProvider]) {
        self.preferences = Self.loadPreferences()
        self.providers = providers
        coreBluetoothProvider.setOnUpdate { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.receiveBluetoothSnapshot(self.coreBluetoothProvider.snapshot())
            }
        }
    }

    deinit {
        refreshTimer?.invalidate()
        debounceWorkItem?.cancel()
        if hidMatchedIterator != 0 {
            IOObjectRelease(hidMatchedIterator)
        }
        if hidTerminatedIterator != 0 {
            IOObjectRelease(hidTerminatedIterator)
        }
        if let port = hidNotificationPort {
            IONotificationPortDestroy(port)
        }
        if let src = powerSourceRunLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), src, CFRunLoopMode.defaultMode)
        }
    }

    /// 按用户偏好过滤后应展示在桌面卡片上的设备列表
    public var visibleDevices: [PeripheralDevice] {
        devices.filter { dev in
            if preferences.hiddenDeviceIDs.contains(dev.id) {
                return false
            }
            if !dev.isExternal && !preferences.showInternalBattery {
                return false
            }
            let hasVendorStatus = dev.isConnected && dev.source == .vendorHID && dev.statusHint != nil
            if dev.effectiveBatteryLevel == nil && !dev.requiresInputMonitoring && !preferences.showDevicesWithoutBattery
                && dev.chargingState != .sleeping && !dev.hasStaleBatteryReading && !hasVendorStatus {
                return false
            }
            return true
        }
    }

    public func displayName(for device: PeripheralDevice) -> String {
        if let alias = preferences.customAliases[device.id], !alias.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return alias
        }
        return device.name
    }

    public func start() {
        guard !isStarted else { return }
        isStarted = true
        coreBluetoothProvider.startIfPermitted()
        installHardwareWatchers()
        restartTimer()
        refresh()
    }

    public func refresh() {
        if isRefreshing {
            refreshPending = true
            return
        }
        isRefreshing = true
        scanProviders()
    }

    private func scanProviders() {
        coreBluetoothProvider.triggerRefresh()

        let activeProviders = providers
        scanQueue.async { [weak self] in
            let results = Self.collectConcurrently(providers: activeProviders)
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.lastScanResults = results
                self.publishSnapshot(bluetooth: self.coreBluetoothProvider.snapshot())
                self.lastUpdated = Date()

                let summary = self.devices.map { d in
                    "\(d.name)=\(d.effectiveBatteryLevel.map { "\($0)%" } ?? (d.requiresInputMonitoring ? "perm" : "nil"))"
                }.joined(separator: ", ")
                let accessRaw = IOHIDCheckAccess(kIOHIDRequestTypeListenEvent).rawValue
                Self.logger.notice("Scan finished: total=\(self.devices.count, privacy: .public), needsInputMonitoring=\(self.needsInputMonitoring, privacy: .public), hidAccess=\(accessRaw, privacy: .public), devices=[\(summary, privacy: .public)]")

                if self.refreshPending {
                    self.refreshPending = false
                    self.scanProviders()
                } else {
                    self.isRefreshing = false
                }
            }
        }
    }

    func receiveBluetoothSnapshot(_ bluetooth: ProviderResult) {
        // The in-flight scan reads the current Bluetooth snapshot when it completes.
        guard !isRefreshing else { return }
        publishSnapshot(bluetooth: bluetooth)
    }

    private func publishSnapshot(bluetooth: ProviderResult) {
        let results = lastScanResults + [bluetooth]
        let freshFor = max(60, preferences.refreshIntervalSeconds + 15)
        let merged = aggregator.aggregate(results: results, now: Date(), freshFor: freshFor)
        migrateDevicePreferences(for: merged.devices)
        devices = merged.devices
        diagnostics = merged.diagnostics
        needsInputMonitoring = results.contains(where: \.needsInputMonitoring)
            || merged.devices.contains(where: \.requiresInputMonitoring)
        restrictedDeviceNames = merged.devices.filter(\.requiresInputMonitoring).map(displayName(for:))
    }

    private func migrateDevicePreferences(for devices: [PeripheralDevice]) {
        let storedIDs = Set(preferences.customAliases.keys).union(preferences.hiddenDeviceIDs)
        guard !storedIDs.isEmpty else { return }

        let activeIDs = Set(devices.map(\.id))
        var targets: [String: Set<String>] = [:]
        for device in devices {
            for id in device.legacyIDs ?? [] where storedIDs.contains(id) && !activeIDs.contains(id) {
                targets[id, default: []].insert(device.id)
            }
        }

        var migrated = preferences
        for (legacyID, matches) in targets.sorted(by: { $0.key < $1.key }) where matches.count == 1 {
            guard let canonicalID = matches.first else { continue }
            if let alias = migrated.customAliases.removeValue(forKey: legacyID), migrated.customAliases[canonicalID] == nil {
                migrated.customAliases[canonicalID] = alias
            }
            if migrated.hiddenDeviceIDs.remove(legacyID) != nil {
                migrated.hiddenDeviceIDs.insert(canonicalID)
            }
        }
        if migrated.customAliases != preferences.customAliases || migrated.hiddenDeviceIDs != preferences.hiddenDeviceIDs {
            preferences = migrated
        }
    }

    public var inputMonitoringAccessStatus: IOHIDAccessType {
        IOHIDCheckAccess(kIOHIDRequestTypeListenEvent)
    }

    public func requestInputMonitoringAccess() {
        _ = IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
    }

    public func scheduleWakeRefresh() {
        scheduleDebouncedRefresh(delay: 1.5)
    }

    public func scheduleDebouncedRefresh(delay: TimeInterval = 0.8) {
        debounceWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            self?.refresh()
        }
        debounceWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }

    public func setAlias(_ alias: String?, for deviceID: String) {
        let trimmed = alias?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if trimmed.isEmpty {
            preferences.customAliases.removeValue(forKey: deviceID)
        } else {
            preferences.customAliases[deviceID] = trimmed
        }
    }

    public func hideDevice(_ deviceID: String) {
        preferences.hiddenDeviceIDs.insert(deviceID)
    }

    public func unhideDevice(_ deviceID: String) {
        preferences.hiddenDeviceIDs.remove(deviceID)
    }

    public func restoreAllHiddenDevices() {
        preferences.hiddenDeviceIDs.removeAll()
    }

    // MARK: - CLI / 一次性快照

    public nonisolated static func runOneShotDump() -> MonitorSnapshot {
        let results = collectConcurrently(providers: defaultProviders())
        let agg = BatteryAggregator()
        let merged = agg.aggregate(results: results, now: Date())
        return MonitorSnapshot(generatedAt: Date(), devices: merged.devices, diagnostics: merged.diagnostics)
    }

    private nonisolated static func defaultProviders() -> [BatteryProvider] {
        [
            IOKitHIDBatteryProvider(),
            BluetoothProfilerProvider(),
            StandardHIDBatteryProvider(),
            IOPowerSourcesProvider(),
            VendorHIDBatteryProvider(),
            ExternalUSBInventoryProvider()
        ]
    }

    public nonisolated static func oneShotDumpJSON(pretty: Bool = true) -> String {
        let snapshot = runOneShotDump()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = pretty ? [.prettyPrinted, .sortedKeys] : [.sortedKeys]
        guard let data = try? encoder.encode(snapshot),
              let json = String(data: data, encoding: .utf8)
        else {
            return "{}"
        }
        return json
    }

    private nonisolated static func collectConcurrently(providers: [BatteryProvider]) -> [ProviderResult] {
        let group = DispatchGroup()
        let lock = NSLock()
        var results: [ProviderResult] = []
        results.reserveCapacity(providers.count)

        for provider in providers {
            group.enter()
            DispatchQueue.global(qos: .utility).async {
                let res = provider.fetch()
                lock.lock()
                results.append(res)
                lock.unlock()
                group.leave()
            }
        }
        group.wait()
        return results
    }

    // MARK: - 定时刷新与硬件热插拔监听

    private func restartTimer() {
        refreshTimer?.invalidate()
        let interval = max(15, preferences.refreshIntervalSeconds)
        refreshTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refresh()
            }
        }
    }

    private func installHardwareWatchers() {
        // 1. 通过免权限 IORegistry 通知监听 HID 设备插拔（不触发 IOHIDManagerOpen(nil)）
        if let port = IONotificationPortCreate(kIOMainPortDefault) {
            IONotificationPortSetDispatchQueue(port, DispatchQueue.main)
            let ctx = Unmanaged.passUnretained(self).toOpaque()
            let callback: IOServiceMatchingCallback = { rawCtx, iterator in
                while case let svc = IOIteratorNext(iterator), svc != 0 {
                    IOObjectRelease(svc)
                }
                guard let rawCtx else { return }
                let service = Unmanaged<BatteryMonitorService>.fromOpaque(rawCtx).takeUnretainedValue()
                Task { @MainActor in
                    service.scheduleDebouncedRefresh(delay: 0.9)
                }
            }

            if let matchDict = IOServiceMatching("IOHIDDevice"),
               IOServiceAddMatchingNotification(port, kIOMatchedNotification, matchDict, callback, ctx, &hidMatchedIterator) == KERN_SUCCESS {
                while case let svc = IOIteratorNext(hidMatchedIterator), svc != 0 {
                    IOObjectRelease(svc)
                }
            }
            if let termDict = IOServiceMatching("IOHIDDevice"),
               IOServiceAddMatchingNotification(port, kIOTerminatedNotification, termDict, callback, ctx, &hidTerminatedIterator) == KERN_SUCCESS {
                while case let svc = IOIteratorNext(hidTerminatedIterator), svc != 0 {
                    IOObjectRelease(svc)
                }
            }
            self.hidNotificationPort = port
        }

        // 2. IOPowerSources 电源变化监听（UPS / 本机充电 / 外接电源变化）
        let psCtx = Unmanaged.passUnretained(self).toOpaque()
        let psCallback: IOPowerSourceCallbackType = { rawCtx in
            guard let rawCtx else { return }
            let service = Unmanaged<BatteryMonitorService>.fromOpaque(rawCtx).takeUnretainedValue()
            Task { @MainActor in
                service.scheduleDebouncedRefresh(delay: 0.6)
            }
        }
        if let src = IOPSNotificationCreateRunLoopSource(psCallback, psCtx)?.takeRetainedValue() {
            CFRunLoopAddSource(CFRunLoopGetMain(), src, CFRunLoopMode.defaultMode)
            self.powerSourceRunLoopSource = src
        }
    }

    private static func loadPreferences() -> AppPreferences {
        guard let data = UserDefaults.standard.data(forKey: prefsStorageKey),
              let decoded = try? JSONDecoder().decode(AppPreferences.self, from: data)
        else {
            return AppPreferences()
        }
        return decoded
    }

    private func savePreferences() {
        if let data = try? JSONEncoder().encode(preferences) {
            UserDefaults.standard.set(data, forKey: Self.prefsStorageKey)
        }
    }
}
