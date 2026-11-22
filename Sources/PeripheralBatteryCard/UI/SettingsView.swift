import AppKit
import SwiftUI
import PeripheralBatteryCore

/// 偏好设置窗口视图
public struct SettingsView: View {
    @ObservedObject var monitor: BatteryMonitorService
    let onResetPosition: () -> Void
    let onPreferencesApplied: () -> Void

    @State private var launchAtLogin: Bool = LaunchAtLoginManager.isEnabled()

    public init(
        monitor: BatteryMonitorService,
        onResetPosition: @escaping () -> Void,
        onPreferencesApplied: @escaping () -> Void
    ) {
        self.monitor = monitor
        self.onResetPosition = onResetPosition
        self.onPreferencesApplied = onPreferencesApplied
    }

    public var body: some View {
        Form {
            Section("外观与桌面卡片") {
                Picker("卡片布局", selection: binding(\.layoutMode)) {
                    ForEach(CardLayoutMode.allCases, id: \.self) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                .pickerStyle(.segmented)

                Picker("窗口层级", selection: binding(\.windowLevelMode)) {
                    ForEach(WindowLevelMode.allCases, id: \.self) { level in
                        Text(level.label).tag(level)
                    }
                }
                .pickerStyle(.segmented)

                Picker("主题风格", selection: binding(\.themeMode)) {
                    ForEach(ThemeMode.allCases, id: \.self) { theme in
                        Text(theme.label).tag(theme)
                    }
                }

                HStack {
                    Text("卡片不透明度")
                    Slider(value: binding(\.cardOpacity), in: 0.55...1.0, step: 0.02)
                    Text("\(Int((monitor.preferences.cardOpacity * 100).rounded()))%")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .frame(width: 40, alignment: .trailing)
                }

                Toggle("锁定卡片位置（禁止拖动）", isOn: binding(\.isPositionLocked))

                HStack {
                    Spacer()
                    Button("重置位置到屏幕右上角") {
                        onResetPosition()
                    }
                }
            }

            Section("扫描与提醒") {
                Picker("自动刷新频率", selection: binding(\.refreshIntervalSeconds)) {
                    Text("15 秒").tag(15.0)
                    Text("30 秒").tag(30.0)
                    Text("60 秒").tag(60.0)
                    Text("3 分钟").tag(180.0)
                }

                Toggle("同时显示 Mac 本机电池", isOn: binding(\.showInternalBattery))
                Toggle("显示暂未上报电量的外接 USB/蓝牙设备", isOn: binding(\.showDevicesWithoutBattery))

                Toggle("低电量系统通知提醒", isOn: binding(\.lowBatteryAlertEnabled))

                if monitor.preferences.lowBatteryAlertEnabled {
                    Stepper(
                        "低电量提醒阈值：\(monitor.preferences.lowBatteryThreshold)%",
                        value: binding(\.lowBatteryThreshold),
                        in: 10...35,
                        step: 5
                    )
                }

                Toggle("开机自动启动", isOn: Binding(
                    get: { launchAtLogin },
                    set: { newValue in
                        launchAtLogin = LaunchAtLoginManager.setEnabled(newValue)
                    }
                ))
            }

            Section("已隐藏设备与自定义别名") {
                if monitor.preferences.hiddenDeviceIDs.isEmpty && monitor.preferences.customAliases.isEmpty {
                    Text("暂无隐藏设备或自定义别名（可在卡片设备行右键隐藏或重命名）")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    if !monitor.preferences.hiddenDeviceIDs.isEmpty {
                        ForEach(Array(monitor.preferences.hiddenDeviceIDs).sorted(), id: \.self) { id in
                            HStack {
                                Text(id)
                                    .font(.caption.monospaced())
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Spacer()
                                Button("恢复显示") {
                                    monitor.unhideDevice(id)
                                }
                                .controlSize(.small)
                            }
                        }
                        Button("恢复全部隐藏设备") {
                            monitor.restoreAllHiddenDevices()
                        }
                    }

                    if !monitor.preferences.customAliases.isEmpty {
                        ForEach(monitor.preferences.customAliases.sorted(by: { $0.key < $1.key }), id: \.key) { key, alias in
                            HStack {
                                Text(alias)
                                    .fontWeight(.medium)
                                Spacer()
                                Button("清除别名") {
                                    monitor.setAlias(nil, for: key)
                                }
                                .controlSize(.small)
                            }
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 440, height: 520)
        .onChange(of: monitor.preferences) { _, _ in
            onPreferencesApplied()
        }
    }

    private func binding<Value>(_ keyPath: WritableKeyPath<AppPreferences, Value>) -> Binding<Value> {
        Binding(
            get: { monitor.preferences[keyPath: keyPath] },
            set: { monitor.preferences[keyPath: keyPath] = $0 }
        )
    }
}

/// 通过 LaunchAgents plist 管理开机自启
public enum LaunchAtLoginManager {
    private static let label = "com.peripheralbattery.card"

    private static var plistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents", isDirectory: true)
            .appendingPathComponent("\(label).plist")
    }

    public static func isEnabled() -> Bool {
        FileManager.default.fileExists(atPath: plistURL.path)
    }

    @discardableResult
    public static func setEnabled(_ enabled: Bool) -> Bool {
        if !enabled {
            try? FileManager.default.removeItem(at: plistURL)
            return false
        }

        let execPath = Bundle.main.executablePath ?? ProcessInfo.processInfo.arguments.first ?? ""
        guard !execPath.isEmpty else { return false }

        let dir = plistURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let plist: [String: Any] = [
            "Label": label,
            "ProgramArguments": [execPath],
            "RunAtLoad": true,
            "KeepAlive": false
        ]

        guard let data = try? PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0) else {
            return false
        }
        do {
            try data.write(to: plistURL, options: .atomic)
            return true
        } catch {
            return false
        }
    }
}
