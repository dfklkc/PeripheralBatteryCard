import Foundation

/// 电量采集器返回结果
public struct ProviderResult: Sendable {
    public var devices: [PeripheralDevice]
    public var diagnostics: [DiagnosticEntry]
    public var needsInputMonitoring: Bool

    public init(
        devices: [PeripheralDevice] = [],
        diagnostics: [DiagnosticEntry] = [],
        needsInputMonitoring: Bool = false
    ) {
        self.devices = devices
        self.diagnostics = diagnostics
        self.needsInputMonitoring = needsInputMonitoring
    }
}

/// 统一电量采集协议
public protocol BatteryProvider: AnyObject, Sendable {
    var name: String { get }
    func fetch() -> ProviderResult
}
