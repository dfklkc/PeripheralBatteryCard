import Foundation
import Testing
@testable import PeripheralBatteryCore

struct MonitorRefreshTests {
    @MainActor
    @Test("扫描期间收到多次刷新请求时保留一次后续扫描")
    func coalescesRefreshRequests() async throws {
        let provider = CountingProvider()
        let monitor = BatteryMonitorService(providers: [provider])

        monitor.refresh()
        #expect(monitor.isRefreshing)
        monitor.refresh()
        monitor.refresh()
        monitor.refresh()

        try await waitForScan(monitor)

        #expect(!monitor.isRefreshing)
        #expect(provider.count == 2)
        #expect(monitor.lastUpdated != nil)
    }

    @MainActor
    @Test("蓝牙缓存更新与清除不会重新扫描其他来源")
    func publishesBluetoothWithoutScanning() async throws {
        let vendor = PeripheralDevice(id: "vendor-fixture", name: "已识别测试外设", source: .vendorHID,
                                      sourceDetail: "测试协议", statusHint: "电量波动 · 等待复核")
        let provider = CountingProvider(result: ProviderResult(devices: [vendor]))
        let monitor = BatteryMonitorService(providers: [provider])
        monitor.refresh()
        try await waitForScan(monitor)
        let completedAt = try #require(monitor.lastUpdated)
        #expect(monitor.visibleDevices.contains { $0.name == vendor.name && $0.effectiveBatteryLevel == nil })

        let bluetooth = PeripheralDevice(id: "ble-189e6375-3747-48ac-9577-44ec959338ca", name: "蓝牙测试外设",
                                          transport: .ble, batteryLevel: 80, source: .coreBluetoothBAS,
                                          sourceDetail: "测试电量服务")
        monitor.receiveBluetoothSnapshot(ProviderResult(devices: [bluetooth]))
        #expect(monitor.devices.contains { $0.id == bluetooth.id && $0.batteryReadingAt == bluetooth.batteryReadingAt })
        #expect(monitor.devices.contains { $0.name == vendor.name })

        monitor.receiveBluetoothSnapshot(ProviderResult())
        #expect(!monitor.devices.contains { $0.id == bluetooth.id })
        #expect(monitor.devices.contains { $0.name == vendor.name })
        #expect(!monitor.isRefreshing)
        #expect(monitor.lastUpdated == completedAt)
        #expect(provider.count == 1)
    }

    @MainActor
    private func waitForScan(_ monitor: BatteryMonitorService) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(5)
        while monitor.isRefreshing && clock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}

private final class CountingProvider: BatteryProvider, @unchecked Sendable {
    let name = "计数测试源"
    private let lock = NSLock()
    private var calls = 0
    private let result: ProviderResult

    init(result: ProviderResult = ProviderResult()) {
        self.result = result
    }

    var count: Int { lock.withLock { calls } }

    func fetch() -> ProviderResult {
        lock.withLock { calls += 1 }
        return result
    }
}
