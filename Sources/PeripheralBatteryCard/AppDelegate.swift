import AppKit
import Combine
import SwiftUI
import UserNotifications
import PeripheralBatteryCore

@MainActor
public final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let monitor = BatteryMonitorService()
    private var cardPanel: DesktopCardPanel?
    private var statusItem: NSStatusItem?
    private var statusMenu: NSMenu?

    private var settingsWindow: NSWindow?
    private var diagnosticsWindow: NSWindow?

    private var cancellables = Set<AnyCancellable>()
    private var alertedDeviceIDs = Set<String>()
    private var didRequestNotificationAuth = false
    private var wakeObserver: NSObjectProtocol?

    public func applicationDidFinishLaunching(_ notification: Notification) {
        setupCardPanel()
        setupStatusBar()
        bindMonitorUpdates()
        observeSystemWake()
        monitor.start()
    }

    public func applicationWillTerminate(_ notification: Notification) {
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
        }
    }

    // MARK: - 桌面卡片与菜单栏初始化

    private func setupCardPanel() {
        let rootView = DesktopCardView(
            monitor: monitor,
            onOpenSettings: { [weak self] in self?.openSettingsWindow() },
            onOpenDiagnostics: { [weak self] in self?.openDiagnosticsWindow() },
            onRequestInputMonitoring: { [weak self] in self?.openInputMonitoringSettings() },
            onRenameDevice: { [weak self] dev in self?.promptRenameDevice(dev) },
            onResetPosition: { [weak self] in self?.cardPanel?.resetToDefaultPosition() },
            onHeightChange: { [weak self] h in self?.cardPanel?.updateCardHeight(h) }
        )
        let panel = DesktopCardPanel(rootView: rootView)
        panel.applyPreferences(monitor.preferences)
        panel.orderFront(nil)
        self.cardPanel = panel
    }

    private func setupStatusBar() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        self.statusItem = item
        self.statusMenu = menu
        updateStatusBarButton()
    }

    private func bindMonitorUpdates() {
        monitor.$devices
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.updateStatusBarButton()
                self?.evaluateLowBatteryAlerts()
            }
            .store(in: &cancellables)

        monitor.$preferences
            .receive(on: DispatchQueue.main)
            .sink { [weak self] prefs in
                guard let self else { return }
                self.cardPanel?.applyPreferences(prefs)
                self.updateStatusBarButton()
            }
            .store(in: &cancellables)
    }

    private func observeSystemWake() {
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.monitor.scheduleWakeRefresh()
            }
        }
    }

    private func updateStatusBarButton() {
        guard let button = statusItem?.button else { return }

        let externalLevels = monitor.visibleDevices
            .filter { $0.isExternal && $0.isConnected && !$0.hasStaleBatteryReading }
            .compactMap(\.effectiveBatteryLevel)

        if let lowest = externalLevels.min() {
            let symbolName: String
            switch lowest {
            case 80...100: symbolName = "battery.100"
            case 55..<80: symbolName = "battery.75"
            case 30..<55: symbolName = "battery.50"
            case 11..<30: symbolName = "battery.25"
            default: symbolName = "battery.0"
            }
            let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: "外设电量")
            image?.isTemplate = true
            button.image = image
            button.imagePosition = .imageLeading
            button.title = " \(lowest)%"
        } else {
            let image = NSImage(systemSymbolName: "bolt.batteryblock", accessibilityDescription: "外设电量")
            image?.isTemplate = true
            button.image = image
            button.imagePosition = .imageOnly
            button.title = ""
        }
    }

    // MARK: - NSMenuDelegate

    public func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        let visible = monitor.visibleDevices
        if visible.isEmpty {
            let emptyItem = NSMenuItem(title: "暂未检测到带电量外设", action: nil, keyEquivalent: "")
            emptyItem.isEnabled = false
            menu.addItem(emptyItem)
        } else {
            for device in visible {
                let name = monitor.displayName(for: device)
                let batText: String
                if let lvl = device.effectiveBatteryLevel {
                    if device.hasStaleBatteryReading {
                        batText = "上次 \(lvl)%"
                    } else {
                        let chargeSuffix = device.chargingState.isActivelyChargingOrFull ? " ⚡︎" : ""
                        batText = "\(lvl)%\(chargeSuffix)"
                    }
                } else if device.requiresInputMonitoring {
                    batText = "需输入监控权限"
                } else {
                    batText = "未上报"
                }
                let title = "\(name)  ·  \(device.transport.badgeText)  ·  \(batText)"
                let row = NSMenuItem(title: title, action: nil, keyEquivalent: "")
                if let img = NSImage(systemSymbolName: device.category.sfSymbol, accessibilityDescription: name) {
                    img.isTemplate = true
                    row.image = img
                }
                row.isEnabled = false
                menu.addItem(row)
            }
        }

        menu.addItem(.separator())

        if monitor.needsInputMonitoring {
            let permItem = NSMenuItem(
                title: "开启「输入监控」权限（读取键盘外设电量）...",
                action: #selector(openInputMonitoringAction),
                keyEquivalent: ""
            )
            permItem.target = self
            menu.addItem(permItem)
            menu.addItem(.separator())
        }

        let isCardVisible = cardPanel?.isVisible ?? false
        let toggleCard = NSMenuItem(
            title: isCardVisible ? "隐藏桌面卡片" : "显示桌面卡片",
            action: #selector(toggleCardVisibility),
            keyEquivalent: ""
        )
        toggleCard.target = self
        menu.addItem(toggleCard)

        let layoutTitle = monitor.preferences.layoutMode == .list ? "切换为圆形网格视图" : "切换为列表卡片视图"
        let layoutItem = NSMenuItem(title: layoutTitle, action: #selector(toggleLayoutMode), keyEquivalent: "")
        layoutItem.target = self
        menu.addItem(layoutItem)

        let levelTitle = monitor.preferences.windowLevelMode == .desktop ? "窗口层级：切换为置顶悬浮" : "窗口层级：切换为贴靠桌面"
        let levelItem = NSMenuItem(title: levelTitle, action: #selector(toggleWindowLevel), keyEquivalent: "")
        levelItem.target = self
        menu.addItem(levelItem)

        menu.addItem(.separator())

        let refreshItem = NSMenuItem(title: "立即扫描外设", action: #selector(refreshNow), keyEquivalent: "r")
        refreshItem.target = self
        menu.addItem(refreshItem)

        let diagItem = NSMenuItem(title: "设备协议诊断...", action: #selector(openDiagnosticsAction), keyEquivalent: "d")
        diagItem.target = self
        menu.addItem(diagItem)

        let settingsItem = NSMenuItem(title: "偏好设置...", action: #selector(openSettingsAction), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "退出外设电量卡片", action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
    }

    // MARK: - Actions

    @objc private func toggleCardVisibility() {
        guard let panel = cardPanel else { return }
        if panel.isVisible {
            panel.orderOut(nil)
        } else {
            panel.orderFront(nil)
        }
    }

    @objc private func toggleLayoutMode() {
        monitor.preferences.layoutMode = monitor.preferences.layoutMode == .list ? .compactGrid : .list
    }

    @objc private func toggleWindowLevel() {
        monitor.preferences.windowLevelMode = monitor.preferences.windowLevelMode == .desktop ? .floating : .desktop
    }

    @objc private func refreshNow() {
        monitor.refresh()
    }

    @objc private func openDiagnosticsAction() {
        openDiagnosticsWindow()
    }

    @objc private func openSettingsAction() {
        openSettingsWindow()
    }

    @objc private func openInputMonitoringAction() {
        openInputMonitoringSettings()
    }

    private func openInputMonitoringSettings() {
        monitor.requestInputMonitoringAccess()
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }

    // MARK: - 窗口管理与重命名弹窗

    private func openSettingsWindow() {
        if settingsWindow == nil {
            let view = SettingsView(
                monitor: monitor,
                onResetPosition: { [weak self] in self?.cardPanel?.resetToDefaultPosition() },
                onPreferencesApplied: { [weak self] in
                    guard let self else { return }
                    self.cardPanel?.applyPreferences(self.monitor.preferences)
                }
            )
            let win = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 440, height: 520),
                styleMask: [.titled, .closable, .miniaturizable],
                backing: .buffered,
                defer: false
            )
            win.title = "偏好设置 - 外设电量卡片"
            win.isReleasedWhenClosed = false
            win.center()
            win.contentView = NSHostingView(rootView: view)
            self.settingsWindow = win
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    private func openDiagnosticsWindow() {
        if diagnosticsWindow == nil {
            let view = DiagnosticsView(
                monitor: monitor,
                onRequestInputMonitoring: { [weak self] in self?.openInputMonitoringSettings() }
            )
            let win = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 760, height: 520),
                styleMask: [.titled, .closable, .resizable, .miniaturizable],
                backing: .buffered,
                defer: false
            )
            win.title = "设备协议诊断 - 外设电量卡片"
            win.isReleasedWhenClosed = false
            win.center()
            win.contentView = NSHostingView(rootView: view)
            self.diagnosticsWindow = win
        }
        NSApp.activate(ignoringOtherApps: true)
        diagnosticsWindow?.makeKeyAndOrderFront(nil)
    }

    private func promptRenameDevice(_ device: PeripheralDevice) {
        let alert = NSAlert()
        alert.messageText = "重命名外设别名"
        alert.informativeText = "原始设备名称：\(device.name)\n留空可恢复默认名称。"
        alert.alertStyle = .informational
        alert.addButton(withTitle: "保存")
        alert.addButton(withTitle: "取消")

        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = monitor.preferences.customAliases[device.id] ?? device.name
        alert.accessoryView = field

        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            let text = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if text == device.name || text.isEmpty {
                monitor.setAlias(nil, for: device.id)
            } else {
                monitor.setAlias(text, for: device.id)
            }
        }
    }

    // MARK: - 低电量通知（仅在 .app Bundle 中启用）

    private func evaluateLowBatteryAlerts() {
        guard Bundle.main.bundleURL.pathExtension == "app" else { return }
        guard monitor.preferences.lowBatteryAlertEnabled else { return }

        let threshold = monitor.preferences.lowBatteryThreshold
        let center = UNUserNotificationCenter.current()

        if !didRequestNotificationAuth {
            didRequestNotificationAuth = true
            center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
        }

        for dev in monitor.visibleDevices where dev.isExternal && dev.isConnected && !dev.hasStaleBatteryReading {
            guard let level = dev.effectiveBatteryLevel else { continue }
            if dev.chargingState.isActivelyChargingOrFull || level > threshold + 5 {
                alertedDeviceIDs.remove(dev.id)
                continue
            }
            if level <= threshold && !alertedDeviceIDs.contains(dev.id) {
                alertedDeviceIDs.insert(dev.id)
                let content = UNMutableNotificationContent()
                content.title = "外设电量过低"
                content.body = "\(monitor.displayName(for: dev)) 当前剩余电量 \(level)%，请及时充电。"
                content.sound = .default
                let request = UNNotificationRequest(
                    identifier: "low-battery-\(dev.id)",
                    content: content,
                    trigger: nil
                )
                center.add(request, withCompletionHandler: nil)
            }
        }
    }
}
