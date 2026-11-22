import AppKit
import IOKit.hid
import SwiftUI
import PeripheralBatteryCore

/// 设备协议扫描诊断窗口
public struct DiagnosticsView: View {
    @ObservedObject var monitor: BatteryMonitorService
    let onRequestInputMonitoring: () -> Void
    @State private var searchText: String = ""
    @State private var copiedBanner: Bool = false

    public init(
        monitor: BatteryMonitorService,
        onRequestInputMonitoring: @escaping () -> Void = {}
    ) {
        self.monitor = monitor
        self.onRequestInputMonitoring = onRequestInputMonitoring
    }

    private var groups: [DiagnosticDeviceGroup] {
        DiagnosticReport.group(devices: monitor.devices, entries: monitor.diagnostics)
    }

    private var filteredGroups: [DiagnosticDeviceGroup] {
        let term = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return groups }
        return groups.filter { group in
            group.name.localizedCaseInsensitiveContains(term)
                || group.interfaces.contains { item in
                    [item.name, item.vendorIDHex, item.productIDHex, item.matchedDriver, item.usagePageHex, item.usageHex, item.batterySummary]
                        .contains { $0.localizedCaseInsensitiveContains(term) }
                }
        }
    }

    public var body: some View {
        VStack(spacing: 0) {
            // 顶部工具栏
            HStack(spacing: 10) {
                TextField("按名称、VID/PID、UsagePage 或驱动筛选...", text: $searchText)
                    .textFieldStyle(.roundedBorder)

                Button {
                    monitor.refresh()
                } label: {
                    Label("重新扫描", systemImage: "arrow.clockwise")
                }
                .disabled(monitor.isRefreshing)

                Button {
                    copyDiagnosticsJSON()
                } label: {
                    Label(copiedBanner ? "已复制" : "复制脱敏诊断 JSON", systemImage: copiedBanner ? "checkmark" : "doc.on.doc")
                }
                .help("导出协议和电量状态，隐去设备名称、序列号和蓝牙地址")

                Button {
                    let url = CustomJSONRuleDriver.ensureSampleTemplateFile()
                    NSWorkspace.shared.open(url)
                } label: {
                    Label("自定义协议配置", systemImage: "slider.horizontal.3")
                }

                Button {
                    onRequestInputMonitoring()
                } label: {
                    Label("输入监控设置", systemImage: "lock.shield")
                }
            }
            .padding(14)

            // 支持协议与权限状态说明栏
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Text("内置支持协议矩阵")
                        .font(.system(size: 12, weight: .semibold))
                    Spacer()
                    let accessGranted = monitor.inputMonitoringAccessStatus == kIOHIDAccessTypeGranted
                    HStack(spacing: 4) {
                        Circle()
                            .fill(accessGranted ? Color.green : Color.orange)
                            .frame(width: 7, height: 7)
                        Text(accessGranted ? "输入监控权限：已授权" : "输入监控权限：未授权（键盘类复合 HID 外设需授权）")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(accessGranted ? .green : .orange)
                    }
                }
                Text("Apple / 蓝牙 HID、AirPods 与蓝牙音频（含左/右耳/盒）、BLE GATT 0x180F（ZMK/QMK 分体键盘）、标准 HID Power (0x06/0x85)、UPS 电源、Logitech HID++ 2.0、Razer 90B、EVision (VXE/VGN/ATK/Rainy75/Ajazz/Akko/CHERRY)、YJX-CHIP (MCHOSE)、Compx (R1/蜻蜓/Pulsar/Lamzu/Darmoshark)、Sony DualSense/DS4、SteelSeries、Corsair Bragi，以及自定义 JSON 规则。")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(Color.accentColor.opacity(0.08))

            Divider()

            let visibleGroups = filteredGroups
            if visibleGroups.isEmpty {
                VStack(spacing: 8) {
                    Spacer()
                    Image(systemName: "magnifyingglass")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                    Text("没有匹配的设备诊断条目")
                        .foregroundStyle(.secondary)
                    Spacer()
                }
            } else {
                List(visibleGroups) { group in
                    if group.interfaces.isEmpty && group.devices.count <= 1 {
                        deviceHeader(group)
                    } else {
                        DisclosureGroup {
                            if group.devices.count > 1 {
                                ForEach(group.devices) { device in
                                    HStack {
                                        Text(device.name)
                                        Spacer()
                                        if let level = device.effectiveBatteryLevel {
                                            Text(device.hasStaleBatteryReading ? "上次读数 \(level)%" : "\(level)%")
                                                .monospacedDigit()
                                        }
                                    }
                                    .font(.system(size: 11, weight: .medium))
                                    .padding(.vertical, 3)
                                }
                            }
                            ForEach(Array(group.interfaces.enumerated()), id: \.offset) { _, item in
                                interfaceRow(item)
                            }
                        } label: {
                            deviceHeader(group)
                        }
                    }
                }
            }
        }
        .frame(minWidth: 740, minHeight: 500)
    }

    private func deviceHeader(_ group: DiagnosticDeviceGroup) -> some View {
        HStack(spacing: 8) {
            Text(group.name)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)
            Text(group.transport)
                .font(.system(size: 10, weight: .medium))
                .padding(.horizontal, 6)
                .padding(.vertical, 1.5)
                .background(Color.secondary.opacity(0.14), in: Capsule())
            Spacer()
            Text(group.summary)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(group.hasCurrentReading ? Color.green : Color.secondary)
        }
        .padding(.vertical, 4)
    }

    private func interfaceRow(_ item: DiagnosticEntry) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(item.matchedDriver)
                    .font(.system(size: 11, weight: .medium))
                Spacer()
                Text(item.batterySummary)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 14) {
                Label("VID/PID \(item.vendorIDHex)/\(item.productIDHex)", systemImage: "cpu")
                Label("Usage \(item.usagePageHex)/\(item.usageHex)", systemImage: "puzzlepiece.extension")
            }
            .font(.system(size: 11, design: .monospaced))
            .foregroundStyle(.secondary)
            if !item.rawNote.isEmpty {
                Text(item.rawNote)
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 4)
    }

    private func copyDiagnosticsJSON() {
        guard let data = try? DiagnosticReport.redactedJSON(groups: groups, generatedAt: monitor.lastUpdated),
              let json = String(data: data, encoding: .utf8)
        else {
            return
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(json, forType: .string)
        copiedBanner = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            copiedBanner = false
        }
    }
}
