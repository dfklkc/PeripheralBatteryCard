import AppKit
import SwiftUI
import PeripheralBatteryCore

/// 无边框非激活悬浮桌面卡片面板（支持“贴靠桌面”与“置顶悬浮”层级切换及位置持久化）
@MainActor
public final class DesktopCardPanel: NSPanel {
    private static let originDefaultsKey = "PeripheralBatteryCard.cardTopLeftOrigin.v1"

    public let cardWidth: CGFloat = 312
    private var currentHeight: CGFloat = 200
    private var moveObserver: NSObjectProtocol?
    private var screenObserver: NSObjectProtocol?

    private var isPositionLocked: Bool = false
    private var dragStartMouse: NSPoint?
    private var dragStartOrigin: NSPoint?
    private var isDraggingWindow: Bool = false
    private var didPushDragCursor: Bool = false

    public init<Content: View>(rootView: Content) {
        let initialRect = NSRect(x: 0, y: 0, width: 312, height: 200)
        super.init(
            contentRect: initialRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        animationBehavior = .utilityWindow

        let hosting = NSHostingView(rootView: rootView)
        contentView = hosting

        restoreOrPlaceDefaultPosition()
        installObservers()
    }

    deinit {
        if let moveObserver {
            NotificationCenter.default.removeObserver(moveObserver)
        }
        if let screenObserver {
            NotificationCenter.default.removeObserver(screenObserver)
        }
    }

    public override var canBecomeKey: Bool { true }
    public override var canBecomeMain: Bool { false }

    public override func sendEvent(_ event: NSEvent) {
        switch event.type {
        case .leftMouseDown:
            if didPushDragCursor {
                NSCursor.pop()
                didPushDragCursor = false
            }
            isDraggingWindow = false
            if !isPositionLocked {
                dragStartMouse = NSEvent.mouseLocation
                dragStartOrigin = frame.origin
            } else {
                dragStartMouse = nil
                dragStartOrigin = nil
            }
            super.sendEvent(event)

        case .leftMouseDragged:
            if !isPositionLocked, let startMouse = dragStartMouse, let startOrigin = dragStartOrigin {
                let current = NSEvent.mouseLocation
                let dx = current.x - startMouse.x
                let dy = current.y - startMouse.y
                if !isDraggingWindow && hypot(dx, dy) >= 3.0 {
                    isDraggingWindow = true
                    NSCursor.closedHand.push()
                    didPushDragCursor = true
                }
                if isDraggingWindow {
                    setFrameOrigin(NSPoint(x: startOrigin.x + dx, y: startOrigin.y + dy))
                    return
                }
            }
            super.sendEvent(event)

        case .leftMouseUp:
            if isDraggingWindow {
                if didPushDragCursor {
                    NSCursor.pop()
                    didPushDragCursor = false
                }
                let clamped = clampFrameToVisibleScreen(frame, preferredPoint: NSEvent.mouseLocation)
                setFrame(clamped, display: true)
                persistTopLeftOrigin()

                dragStartMouse = nil
                dragStartOrigin = nil
                isDraggingWindow = false

                if let cancelUp = NSEvent.mouseEvent(
                    with: .leftMouseUp,
                    location: NSPoint(x: -10000, y: -10000),
                    modifierFlags: event.modifierFlags,
                    timestamp: event.timestamp,
                    windowNumber: event.windowNumber,
                    context: nil,
                    eventNumber: event.eventNumber,
                    clickCount: event.clickCount,
                    pressure: 0
                ) {
                    super.sendEvent(cancelUp)
                }
                return
            }
            dragStartMouse = nil
            dragStartOrigin = nil
            isDraggingWindow = false
            super.sendEvent(event)

        default:
            super.sendEvent(event)
        }
    }

    public func applyPreferences(_ prefs: AppPreferences) {
        switch prefs.windowLevelMode {
        case .desktop:
            let desktopLevel = Int(CGWindowLevelForKey(.desktopIconWindow)) + 1
            level = NSWindow.Level(rawValue: desktopLevel)
        case .floating:
            level = .floating
        }
        isPositionLocked = prefs.isPositionLocked
        isMovable = !prefs.isPositionLocked
        isMovableByWindowBackground = false

        switch prefs.themeMode {
        case .system:
            appearance = nil
        case .dark:
            appearance = NSAppearance(named: .darkAqua)
        case .light:
            appearance = NSAppearance(named: .aqua)
        }
    }

    /// 保持顶部边缘不动，动态调整面板高度
    public func updateCardHeight(_ targetHeight: CGFloat) {
        let clamped = min(max(targetHeight, 132), 520)
        guard abs(clamped - currentHeight) > 0.5 else { return }

        let oldFrame = frame
        let topY = oldFrame.maxY
        let newOriginY = topY - clamped
        currentHeight = clamped

        var newFrame = NSRect(x: oldFrame.origin.x, y: newOriginY, width: cardWidth, height: clamped)
        newFrame = clampFrameToVisibleScreen(newFrame)
        setFrame(newFrame, display: true, animate: false)
    }

    public func resetToDefaultPosition() {
        UserDefaults.standard.removeObject(forKey: Self.originDefaultsKey)
        placeAtTopRight(height: currentHeight)
        persistTopLeftOrigin()
    }

    private func restoreOrPlaceDefaultPosition() {
        if let saved = UserDefaults.standard.dictionary(forKey: Self.originDefaultsKey),
           let x = saved["x"] as? Double,
           let topY = saved["topY"] as? Double {
            let candidate = NSRect(x: x, y: topY - currentHeight, width: cardWidth, height: currentHeight)
            setFrame(clampFrameToVisibleScreen(candidate), display: true)
        } else {
            placeAtTopRight(height: currentHeight)
        }
    }

    private func placeAtTopRight(height: CGFloat) {
        let visible = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
        let x = visible.maxX - cardWidth - 24
        let y = visible.maxY - height - 24
        setFrame(NSRect(x: x, y: y, width: cardWidth, height: height), display: true)
    }

    private func clampFrameToVisibleScreen(_ rect: NSRect, preferredPoint: NSPoint? = nil) -> NSRect {
        let screens = NSScreen.screens
        guard !screens.isEmpty else { return rect }

        let center = NSPoint(x: rect.midX, y: rect.midY)
        let targetScreen: NSScreen = {
            if let point = preferredPoint, let match = screens.first(where: { $0.frame.contains(point) }) {
                return match
            }
            if let match = screens.first(where: { $0.frame.contains(center) }) {
                return match
            }
            if let best = screens.max(by: { lhs, rhs in
                let a = lhs.visibleFrame.intersection(rect)
                let b = rhs.visibleFrame.intersection(rect)
                let areaA = a.isNull ? 0 : a.width * a.height
                let areaB = b.isNull ? 0 : b.width * b.height
                return areaA < areaB
            }), !best.visibleFrame.intersection(rect).isNull {
                return best
            }
            return NSScreen.main ?? screens[0]
        }()

        let vf = targetScreen.visibleFrame

        var r = rect
        if r.maxX > vf.maxX - 8 { r.origin.x = vf.maxX - r.width - 8 }
        if r.minX < vf.minX + 8 { r.origin.x = vf.minX + 8 }
        if r.maxY > vf.maxY - 8 { r.origin.y = vf.maxY - r.height - 8 }
        if r.minY < vf.minY + 8 { r.origin.y = vf.minY + 8 }
        return r
    }

    private func persistTopLeftOrigin() {
        let payload: [String: Double] = [
            "x": Double(frame.origin.x),
            "topY": Double(frame.maxY)
        ]
        UserDefaults.standard.set(payload, forKey: Self.originDefaultsKey)
    }

    private func installObservers() {
        moveObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didMoveNotification,
            object: self,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.persistTopLeftOrigin()
            }
        }

        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let clamped = self.clampFrameToVisibleScreen(self.frame)
                self.setFrame(clamped, display: true)
            }
        }
    }
}
