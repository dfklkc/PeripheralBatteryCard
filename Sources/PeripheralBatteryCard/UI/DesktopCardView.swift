import AppKit
import SwiftUI
import PeripheralBatteryCore

/// macOS 原生毛玻璃背景封装
public struct VisualEffectBlurView: NSViewRepresentable {
    public var material: NSVisualEffectView.Material
    public var blendingMode: NSVisualEffectView.BlendingMode
    public var themeMode: ThemeMode

    public init(
        material: NSVisualEffectView.Material = .hudWindow,
        blendingMode: NSVisualEffectView.BlendingMode = .behindWindow,
        themeMode: ThemeMode = .system
    ) {
        self.material = material
        self.blendingMode = blendingMode
        self.themeMode = themeMode
    }

    public func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.state = .active
        view.material = material
        view.blendingMode = blendingMode
        applyTheme(to: view)
        return view
    }

    public func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
        applyTheme(to: nsView)
    }

    private func applyTheme(to view: NSVisualEffectView) {
        switch themeMode {
        case .system: view.appearance = nil
        case .dark: view.appearance = NSAppearance(named: .darkAqua)
        case .light: view.appearance = NSAppearance(named: .aqua)
        }
    }
}

private struct CardContentHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 200
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

/// 桌面外设电量主卡片视图
public struct DesktopCardView: View {
    @ObservedObject var monitor: BatteryMonitorService
    let onOpenSettings: () -> Void
    let onOpenDiagnostics: () -> Void
    let onRequestInputMonitoring: () -> Void
    let onRenameDevice: (PeripheralDevice) -> Void
    let onResetPosition: () -> Void
    let onHeightChange: (CGFloat) -> Void

    @Environment(\.colorScheme) private var systemColorScheme
    @State private var isHoveringCard = false

    public init(
        monitor: BatteryMonitorService,
        onOpenSettings: @escaping () -> Void,
        onOpenDiagnostics: @escaping () -> Void,
        onRequestInputMonitoring: @escaping () -> Void,
        onRenameDevice: @escaping (PeripheralDevice) -> Void,
        onResetPosition: @escaping () -> Void,
        onHeightChange: @escaping (CGFloat) -> Void
    ) {
        self.monitor = monitor
        self.onOpenSettings = onOpenSettings
        self.onOpenDiagnostics = onOpenDiagnostics
        self.onRequestInputMonitoring = onRequestInputMonitoring
        self.onRenameDevice = onRenameDevice
        self.onResetPosition = onResetPosition
        self.onHeightChange = onHeightChange
    }

    private var effectiveColorScheme: ColorScheme? {
        switch monitor.preferences.themeMode {
        case .system: return nil
        case .dark: return .dark
        case .light: return .light
        }
    }

    private var isDarkSurface: Bool {
        switch monitor.preferences.themeMode {
        case .dark: return true
        case .light: return false
        case .system: return systemColorScheme == .dark
        }
    }

    public var body: some View {
        let visible = monitor.visibleDevices

        VStack(spacing: 0) {
            headerBar(deviceCount: visible.count)

            Divider()
                .opacity(isDarkSurface ? 0.16 : 0.24)
                .padding(.horizontal, 14)

            if visible.isEmpty {
                emptyStateView
            } else if monitor.preferences.layoutMode == .list {
                listBody(devices: visible)
            } else {
                gridBody(devices: visible)
            }

            if monitor.needsInputMonitoring {
                inputMonitoringBanner
            }

            footerBar
        }
        .frame(width: 312)
        .background(
            GeometryReader { geo in
                Color.clear.preference(key: CardContentHeightKey.self, value: geo.size.height)
            }
        )
        .onPreferenceChange(CardContentHeightKey.self) { height in
            onHeightChange(height)
        }
        .background(
            ZStack {
                VisualEffectBlurView(
                    material: .hudWindow,
                    blendingMode: .behindWindow,
                    themeMode: monitor.preferences.themeMode
                )
                (isDarkSurface ? Color.black : Color.white)
                    .opacity(max(0, (monitor.preferences.cardOpacity - 0.72) * 0.45))
            }
        )
        .opacity(monitor.preferences.cardOpacity)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(isDarkSurface ? 0.24 : 0.65),
                            Color.white.opacity(isDarkSurface ? 0.06 : 0.20)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 1
                )
        )
        .preferredColorScheme(effectiveColorScheme)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.16)) {
                isHoveringCard = hovering
            }
        }
    }

    private func headerBar(deviceCount: Int) -> some View {
        HStack(spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "bolt.batteryblock.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.tint)
                Text("外设电量")
                    .font(.system(size: 13, weight: .semibold))
                Text("\(deviceCount)")
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1.5)
                    .background(.primary.opacity(0.08), in: Capsule())
                if monitor.preferences.isPositionLocked {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                        .help("卡片位置已锁定，可在菜单中解锁")
                }
            }
            .help(monitor.preferences.isPositionLocked ? "卡片位置已锁定，可在菜单中解锁" : "按住卡片任意区域可拖动位置")

            Spacer()

            HStack(spacing: 4) {
                Button {
                    withAnimation(.spring(response: 0.25, dampingFraction: 0.85)) {
                        monitor.preferences.layoutMode =
                            monitor.preferences.layoutMode == .list ? .compactGrid : .list
                    }
                } label: {
                    Image(systemName: monitor.preferences.layoutMode == .list ? "square.grid.2x2" : "list.bullet")
                        .font(.system(size: 12, weight: .medium))
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("切换列表 / 圆形网格视图")

                Button {
                    monitor.refresh()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 12, weight: .medium))
                        .rotationEffect(.degrees(monitor.isRefreshing ? 360 : 0))
                        .animation(
                            monitor.isRefreshing
                                ? .linear(duration: 0.9).repeatForever(autoreverses: false)
                                : .default,
                            value: monitor.isRefreshing
                        )
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("立即扫描所有外设")

                Menu {
                    Button(monitor.preferences.windowLevelMode == .desktop ? "✓ 贴靠桌面层" : "切换为贴靠桌面") {
                        monitor.preferences.windowLevelMode = .desktop
                    }
                    Button(monitor.preferences.windowLevelMode == .floating ? "✓ 置顶悬浮窗" : "切换为置顶悬浮") {
                        monitor.preferences.windowLevelMode = .floating
                    }
                    Divider()
                    Button(monitor.preferences.isPositionLocked ? "✓ 已锁定卡片位置" : "锁定卡片位置") {
                        monitor.preferences.isPositionLocked.toggle()
                    }
                    Button("重置位置到右上角") {
                        onResetPosition()
                    }
                    Divider()
                    Button("设备协议诊断...") {
                        onOpenDiagnostics()
                    }
                    Button("偏好设置...") {
                        onOpenSettings()
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.system(size: 12.5, weight: .medium))
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("更多选项")
            }
            .foregroundStyle(.secondary)
            .opacity(isHoveringCard || monitor.isRefreshing ? 1.0 : 0.55)
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 9)
    }

    private func listBody(devices: [PeripheralDevice]) -> some View {
        let needsScroll = devices.count > 6
        return Group {
            if needsScroll {
                ScrollView(.vertical, showsIndicators: false) {
                    listStack(devices: devices)
                }
                .frame(maxHeight: 410)
            } else {
                listStack(devices: devices)
            }
        }
    }

    private func listStack(devices: [PeripheralDevice]) -> some View {
        VStack(spacing: 8) {
            ForEach(devices) { device in
                DeviceListRowView(
                    device: device,
                    displayName: monitor.displayName(for: device),
                    isDarkSurface: isDarkSurface
                )
                .contextMenu {
                    deviceContextMenu(for: device)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private func gridBody(devices: [PeripheralDevice]) -> some View {
        let rows = Int(ceil(Double(devices.count) / 2.0))
        let needsScroll = rows > 3
        let columns = [
            GridItem(.flexible(), spacing: 10),
            GridItem(.flexible(), spacing: 10)
        ]

        return Group {
            if needsScroll {
                ScrollView(.vertical, showsIndicators: false) {
                    LazyVGrid(columns: columns, spacing: 10) {
                        ForEach(devices) { device in
                            DeviceRingTileView(
                                device: device,
                                displayName: monitor.displayName(for: device),
                                isDarkSurface: isDarkSurface
                            )
                            .contextMenu {
                                deviceContextMenu(for: device)
                            }
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                }
                .frame(maxHeight: 410)
            } else {
                LazyVGrid(columns: columns, spacing: 10) {
                    ForEach(devices) { device in
                        DeviceRingTileView(
                            device: device,
                            displayName: monitor.displayName(for: device),
                            isDarkSurface: isDarkSurface
                        )
                        .contextMenu {
                            deviceContextMenu(for: device)
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
            }
        }
    }

    @ViewBuilder
    private func deviceContextMenu(for device: PeripheralDevice) -> some View {
        Button("重命名别名...") {
            onRenameDevice(device)
        }
        Button("立即刷新") {
            monitor.refresh()
        }
        Divider()
        Button("隐藏此设备", role: .destructive) {
            monitor.hideDevice(device.id)
        }
    }

    private var emptyStateView: some View {
        VStack(spacing: 8) {
            Image(systemName: "cable.connector.horizontal")
                .font(.system(size: 24, weight: .light))
                .foregroundStyle(.secondary)
            Text("暂未检测到外接外设")
                .font(.system(size: 13, weight: .medium))
            Text("支持蓝牙、BLE、2.4G 接收器及 USB 外设")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            HStack(spacing: 8) {
                Button("立即扫描") {
                    monitor.refresh()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)

                Button("设备诊断") {
                    onOpenDiagnostics()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            .padding(.top, 4)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 22)
    }

    private var inputMonitoringBanner: some View {
        let names = monitor.restrictedDeviceNames
        let titleText: String
        if let first = names.first {
            titleText = names.count > 1 ? "\(first) 等需「输入监控」权限" : "\(first) 需「输入监控」权限"
        } else {
            titleText = "部分键盘外设需「输入监控」权限"
        }

        return HStack(spacing: 8) {
            Image(systemName: "lock.shield.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.orange)
            Text(titleText)
                .font(.system(size: 11, weight: .medium))
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 4)
            Button("去开启") {
                onRequestInputMonitoring()
            }
            .buttonStyle(.borderedProminent)
            .tint(.orange)
            .controlSize(.mini)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.orange.opacity(isDarkSurface ? 0.16 : 0.12))
        )
        .padding(.horizontal, 12)
        .padding(.bottom, 6)
    }

    private var footerBar: some View {
        HStack {
            if monitor.isRefreshing {
                Text("正在扫描外设...")
            } else if let updated = monitor.lastUpdated {
                Text("扫描于 \(BatteryVisuals.timeFormatter.string(from: updated))")
            } else {
                Text("准备就绪")
            }

            Spacer()

            Button("诊断") {
                onOpenDiagnostics()
            }
            .buttonStyle(.plain)
            .opacity(isHoveringCard ? 0.9 : 0.45)
        }
        .font(.system(size: 10.5))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 14)
        .padding(.bottom, 10)
        .padding(.top, 2)
    }
}

// MARK: - 列表单行组件

private struct DeviceListRowView: View {
    let device: PeripheralDevice
    let displayName: String
    let isDarkSurface: Bool

    private var level: Int? { device.effectiveBatteryLevel }
    private var accentColor: Color {
        if level == nil && device.requiresInputMonitoring {
            return .orange
        }
        return BatteryVisuals.color(for: level, charging: device.chargingState)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(accentColor.opacity(isDarkSurface ? 0.18 : 0.14))
                    Image(systemName: device.category.sfSymbol)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(accentColor)
                }
                .frame(width: 34, height: 34)

                VStack(alignment: .leading, spacing: 3) {
                    Text(displayName)
                        .font(.system(size: 13, weight: .medium))
                        .lineLimit(1)
                        .truncationMode(.tail)

                    HStack(spacing: 5) {
                        Text(device.transport.badgeText)
                            .font(.system(size: 9.5, weight: .semibold))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(.primary.opacity(0.08), in: Capsule())
                            .foregroundStyle(.secondary)

                        if let statusText = resolvedSubtitle {
                            Text(statusText)
                                .font(.system(size: 10.5))
                                .foregroundStyle(device.chargingState.isActivelyChargingOrFull ? accentColor : .secondary)
                                .lineLimit(1)
                        }
                    }
                }

                Spacer(minLength: 6)

                if let level {
                    VStack(alignment: .trailing, spacing: 4) {
                        HStack(spacing: 3) {
                            if device.chargingState.isActivelyChargingOrFull {
                                Image(systemName: "bolt.fill")
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundStyle(accentColor)
                            }
                            Text("\(level)%")
                                .font(.system(size: 14, weight: .semibold, design: .rounded))
                                .monospacedDigit()
                        }

                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                Capsule()
                                    .fill(.primary.opacity(0.12))
                                Capsule()
                                    .fill(accentColor)
                                    .frame(width: max(4, geo.size.width * CGFloat(level) / 100.0))
                            }
                        }
                        .frame(width: 56, height: 5)
                        BatteryReadingTime(device: device)
                    }
                } else if device.requiresInputMonitoring {
                    HStack(spacing: 3) {
                        Image(systemName: "lock.fill")
                            .font(.system(size: 9.5, weight: .semibold))
                        Text("需授权")
                            .font(.system(size: 10.5, weight: .semibold))
                    }
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Color.orange.opacity(0.14), in: Capsule())
                } else {
                    VStack(alignment: .trailing, spacing: 4) {
                        Text("—")
                            .font(.system(size: 13, weight: .medium, design: .rounded))
                            .foregroundStyle(.tertiary)
                        BatteryReadingTime(device: device)
                    }
                }
            }

            if !device.subBatteries.isEmpty {
                HStack(spacing: 6) {
                    ForEach(device.subBatteries) { sub in
                        HStack(spacing: 4) {
                            Text(sub.label)
                                .foregroundStyle(.secondary)
                            Text("\(sub.level)%")
                                .fontWeight(.semibold)
                                .monospacedDigit()
                                .foregroundStyle(BatteryVisuals.color(for: sub.level, charging: sub.chargingState))
                        }
                        .font(.system(size: 10.5, design: .rounded))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(.primary.opacity(0.06), in: Capsule())
                    }
                }
                .padding(.leading, 44)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.primary.opacity(isDarkSurface ? 0.06 : 0.045))
        )
    }

    private var resolvedSubtitle: String? {
        if let hint = device.statusHint, !hint.isEmpty {
            return hint
        }
        if let stateText = device.chargingState.displayText {
            return stateText
        }
        if let mv = device.voltageMillivolts {
            return String(format: "%.2fV", Double(mv) / 1000.0)
        }
        return nil
    }
}

// MARK: - 圆形进度环网格组件

private struct DeviceRingTileView: View {
    let device: PeripheralDevice
    let displayName: String
    let isDarkSurface: Bool

    private var level: Int? { device.effectiveBatteryLevel }
    private var accentColor: Color {
        if level == nil && device.requiresInputMonitoring {
            return .orange
        }
        return BatteryVisuals.color(for: level, charging: device.chargingState)
    }

    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                Circle()
                    .stroke(.primary.opacity(0.12), lineWidth: 5)
                if let level {
                    Circle()
                        .trim(from: 0, to: CGFloat(level) / 100.0)
                        .stroke(
                            accentColor,
                            style: StrokeStyle(lineWidth: 5, lineCap: .round)
                        )
                        .rotationEffect(.degrees(-90))
                }
                Image(systemName: device.category.sfSymbol)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle((level == nil && !device.requiresInputMonitoring) ? Color.secondary : accentColor)

                if device.chargingState.isActivelyChargingOrFull {
                    Image(systemName: "bolt.fill")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(3.5)
                        .background(accentColor, in: Circle())
                        .offset(x: 20, y: 20)
                }
            }
            .frame(width: 54, height: 54)
            .padding(.top, 4)

            if let level {
                Text("\(level)%")
                    .font(.system(size: 14, weight: .bold, design: .rounded))
                    .monospacedDigit()
            } else if device.requiresInputMonitoring {
                Text("需授权")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.orange)
            } else {
                Text("—")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.tertiary)
            }

            Text(displayName)
                .font(.system(size: 11, weight: .medium))
                .lineLimit(1)
                .truncationMode(.tail)

            if !device.subBatteries.isEmpty {
                Text(device.subBatteries.map { "\($0.label.prefix(1))\($0.level)%" }.joined(separator: " "))
                    .font(.system(size: 9.5, design: .rounded))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            } else {
                Text(device.transport.badgeText)
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundStyle(.secondary)
            }

            BatteryReadingTime(device: device)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 8)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.primary.opacity(isDarkSurface ? 0.06 : 0.045))
        )
    }
}

private struct BatteryReadingTime: View {
    let device: PeripheralDevice

    var body: some View {
        if let readingAt = device.batteryReadingAt {
            let isCurrent = !device.hasStaleBatteryReading && device.effectiveBatteryLevel != nil
            let label = isCurrent ? "读取于" : "上次读数"
            let time = Calendar.current.isDateInToday(readingAt)
                ? BatteryVisuals.timeFormatter.string(from: readingAt)
                : readingAt.formatted(date: .numeric, time: .shortened)
            Text("\(label) \(time)")
                .font(.system(size: 9))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .help("\(label) \(readingAt.formatted(date: .abbreviated, time: .standard))")
        }
    }
}

private enum BatteryVisuals {
    static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    static func color(for level: Int?, charging: ChargingState) -> Color {
        if charging == .sleeping {
            return .indigo
        }
        guard let level else {
            return .secondary
        }
        if charging.isActivelyChargingOrFull {
            return .green
        }
        if level <= 20 {
            return .red
        }
        if level <= 40 {
            return .orange
        }
        return .green
    }
}
