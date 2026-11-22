import Foundation
import IOKit
import IOKit.hid

/// 从 IOHIDDevice 提取的不可变设备描述符快照
public struct HIDDeviceDescriptor: Sendable {
    public let vendorID: Int
    public let productID: Int
    public let product: String
    public let manufacturer: String
    public let serialNumber: String?
    public let transport: String
    public let locationID: Int?
    public let primaryUsagePage: Int
    public let primaryUsage: Int
    public let usagePairs: [(page: Int, usage: Int)]
    public let maxInputReportSize: Int
    public let maxOutputReportSize: Int
    public let maxFeatureReportSize: Int
    public let isBuiltIn: Bool

    public func hasUsagePair(page: Int, usage: Int? = nil) -> Bool {
        if primaryUsagePage == page && (usage == nil || primaryUsage == usage) {
            return true
        }
        return usagePairs.contains { pair in
            pair.page == page && (usage == nil || pair.usage == usage)
        }
    }

    public func hasVendorUsagePage() -> Bool {
        if primaryUsagePage >= 0xFF00 { return true }
        return usagePairs.contains { $0.page >= 0xFF00 }
    }
}

/// 安全的非独占（Non-Seize）IOKit HID 同步收发工具，所有操作均串行化在专用队列执行
public enum HIDDeviceHelper {
    public static let ioQueue = DispatchQueue(label: "com.peripheralbattery.hid.io", qos: .utility)

    private static let queryRunLoopMode = CFRunLoopMode("com.peripheralbattery.hid.query" as CFString)

    private final class CaptureContext {
        let matcher: (_ reportID: UInt32, _ bytes: [UInt8]) -> Bool
        let capacity: Int
        var captured: [UInt8]?

        init(capacity: Int, matcher: @escaping (_ reportID: UInt32, _ bytes: [UInt8]) -> Bool) {
            self.capacity = capacity
            self.matcher = matcher
        }
    }

    public static func extractDescriptor(from device: IOHIDDevice) -> HIDDeviceDescriptor {
        let vendorID = (IOHIDDeviceGetProperty(device, kIOHIDVendorIDKey as CFString) as? Int) ?? 0
        let productID = (IOHIDDeviceGetProperty(device, kIOHIDProductIDKey as CFString) as? Int) ?? 0
        let product = ((IOHIDDeviceGetProperty(device, kIOHIDProductKey as CFString) as? String) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let manufacturer = ((IOHIDDeviceGetProperty(device, kIOHIDManufacturerKey as CFString) as? String) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let serial = (IOHIDDeviceGetProperty(device, kIOHIDSerialNumberKey as CFString) as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let transport = (IOHIDDeviceGetProperty(device, kIOHIDTransportKey as CFString) as? String) ?? ""
        let locationID = IOHIDDeviceGetProperty(device, kIOHIDLocationIDKey as CFString) as? Int
        let primaryUsagePage = (IOHIDDeviceGetProperty(device, kIOHIDPrimaryUsagePageKey as CFString) as? Int) ?? 0
        let primaryUsage = (IOHIDDeviceGetProperty(device, kIOHIDPrimaryUsageKey as CFString) as? Int) ?? 0
        let maxIn = (IOHIDDeviceGetProperty(device, kIOHIDMaxInputReportSizeKey as CFString) as? Int) ?? 0
        let maxOut = (IOHIDDeviceGetProperty(device, kIOHIDMaxOutputReportSizeKey as CFString) as? Int) ?? 0
        let maxFeat = (IOHIDDeviceGetProperty(device, kIOHIDMaxFeatureReportSizeKey as CFString) as? Int) ?? 0
        let isBuiltIn = (IOHIDDeviceGetProperty(device, kIOHIDBuiltInKey as CFString) as? Bool) ?? false

        var pairs: [(page: Int, usage: Int)] = []
        if let rawPairs = IOHIDDeviceGetProperty(device, kIOHIDDeviceUsagePairsKey as CFString) as? [[String: Any]] {
            for item in rawPairs {
                let page = (item[kIOHIDDeviceUsagePageKey] as? Int) ?? 0
                let usage = (item[kIOHIDDeviceUsageKey] as? Int) ?? 0
                pairs.append((page: page, usage: usage))
            }
        }

        return HIDDeviceDescriptor(
            vendorID: vendorID,
            productID: productID,
            product: product,
            manufacturer: manufacturer,
            serialNumber: serial,
            transport: transport,
            locationID: locationID,
            primaryUsagePage: primaryUsagePage,
            primaryUsage: primaryUsage,
            usagePairs: pairs,
            maxInputReportSize: maxIn,
            maxOutputReportSize: maxOut,
            maxFeatureReportSize: maxFeat,
            isBuiltIn: isBuiltIn
        )
    }

    /// 直接通过 IORegistry 枚举所有外部 IOHIDDevice（绕开 IOHIDManagerOpen(nil) 触发整体 TCC 权限拦截）
    public static func enumerateExternalHIDDevices() -> [(device: IOHIDDevice, descriptor: HIDDeviceDescriptor)] {
        guard let matching = IOServiceMatching("IOHIDDevice") else {
            return []
        }
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else {
            return []
        }
        defer { IOObjectRelease(iterator) }

        var results: [(device: IOHIDDevice, descriptor: HIDDeviceDescriptor)] = []
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            guard let hidDevice = IOHIDDeviceCreate(kCFAllocatorDefault, service) else {
                continue
            }
            let desc = extractDescriptor(from: hidDevice)
            if desc.isBuiltIn { continue }
            let transport = desc.transport.lowercased()
            if transport == "spi" || transport == "spu" || transport == "audio" { continue }
            if desc.vendorID == 0 && desc.productID == 0 { continue }
            results.append((device: hidDevice, descriptor: desc))
        }
        return results
    }

    /// 探测单个 IOHIDDevice 的非独占打开权限状态（成功会立刻关闭句柄）
    public static func probeOpenStatus(_ device: IOHIDDevice) -> IOReturn {
        let status = IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone))
        if status == kIOReturnSuccess {
            IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone))
        }
        return status
    }

    /// 以非独占模式打开设备并执行操作（严禁使用 kIOHIDOptionsTypeSeizeDevice）
    public static func withOpenDevice<T>(_ device: IOHIDDevice, body: (IOHIDDevice) -> T?) -> T? {
        let openResult = IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone))
        guard openResult == kIOReturnSuccess else {
            return nil
        }
        defer {
            IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone))
        }
        return body(device)
    }

    /// 发送 Output Report 并等待匹配的 Input Report 返回
    public static func exchangeOutputInputReport(
        device: IOHIDDevice,
        outputReportID: Int,
        payload: [UInt8],
        expectedInputSize: Int = 64,
        timeout: TimeInterval = 0.6,
        matcher: @escaping (_ reportID: UInt32, _ bytes: [UInt8]) -> Bool
    ) -> [UInt8]? {
        withOutputInputReportReader(
            device: device, outputReportID: outputReportID, payload: payload, expectedInputSize: expectedInputSize,
            timeout: timeout, matcher: matcher
        ) { read in
            read()
        }
    }

    // Keep one live registration for all requests in a confirmation read.
    static func withOutputInputReportReader<T>(
        device: IOHIDDevice, outputReportID: Int, payload: [UInt8], expectedInputSize: Int = 64,
        timeout: TimeInterval = 0.6, matcher: @escaping (_ reportID: UInt32, _ bytes: [UInt8]) -> Bool,
        body: (_ read: () -> [UInt8]?) -> T?
    ) -> T? {
        withInputReportCapture(device: device, expectedInputSize: expectedInputSize, matcher: matcher) { context in
            body {
                if context.captured != nil {
                    // Drain any queued replies to the previous request before re-arming capture.
                    CFRunLoopRunInMode(queryRunLoopMode, 0.002, false)
                }
                context.captured = nil
                let result = payload.withUnsafeBytes { rawBuffer -> IOReturn in
                    guard let bytes = rawBuffer.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                        return kIOReturnBadArgument
                    }
                    return IOHIDDeviceSetReport(device, kIOHIDReportTypeOutput, CFIndex(outputReportID), bytes, payload.count)
                }
                guard result == kIOReturnSuccess else { return nil }
                return waitForInputReport(context, timeout: timeout)
            }
        }
    }

    /// 被动监听 Input Report（不发送写请求，适用于 Sony DualSense / DualShock 4）
    public static func listenInputReport(
        device: IOHIDDevice,
        expectedInputSize: Int = 128,
        timeout: TimeInterval = 0.35,
        matcher: @escaping (_ reportID: UInt32, _ bytes: [UInt8]) -> Bool
    ) -> [UInt8]? {
        withInputReportCapture(device: device, expectedInputSize: expectedInputSize, matcher: matcher) { context in
            waitForInputReport(context, timeout: timeout)
        }
    }

    private static func withInputReportCapture<T>(
        device: IOHIDDevice, expectedInputSize: Int,
        matcher: @escaping (_ reportID: UInt32, _ bytes: [UInt8]) -> Bool,
        body: (CaptureContext) -> T?
    ) -> T? {
        guard let runLoop = CFRunLoopGetCurrent() else { return nil }
        let bufSize = max(expectedInputSize, 64)
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufSize)
        buffer.initialize(repeating: 0, count: bufSize)

        let context = CaptureContext(capacity: bufSize, matcher: matcher)
        let ctxPtr = Unmanaged.passRetained(context).toOpaque()

        let callback: IOHIDReportCallback = { rawCtx, result, _, _, reportID, report, reportLength in
            guard result == kIOReturnSuccess, let rawCtx else { return }
            let ctx = Unmanaged<CaptureContext>.fromOpaque(rawCtx).takeUnretainedValue()
            guard ctx.captured == nil, reportLength > 0, reportLength <= ctx.capacity else { return }
            let bytes = Array(UnsafeBufferPointer(start: report, count: reportLength))
            if ctx.matcher(reportID, bytes) {
                ctx.captured = bytes
            }
        }

        IOHIDDeviceRegisterInputReportCallback(device, buffer, bufSize, callback, ctxPtr)
        IOHIDDeviceScheduleWithRunLoop(device, runLoop, queryRunLoopMode.rawValue)

        defer {
            IOHIDDeviceUnscheduleFromRunLoop(device, runLoop, queryRunLoopMode.rawValue)
            // IOKit removes a registration by its original context pointer.
            IOHIDDeviceRegisterInputReportCallback(device, buffer, bufSize, nil, ctxPtr)
            Unmanaged<CaptureContext>.fromOpaque(ctxPtr).release()
            buffer.deallocate()
        }
        return body(context)
    }

    private static func waitForInputReport(_ context: CaptureContext, timeout: TimeInterval) -> [UInt8]? {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while context.captured == nil && ProcessInfo.processInfo.systemUptime < deadline {
            CFRunLoopRunInMode(queryRunLoopMode, 0.02, false)
        }
        return context.captured
    }

    /// 通过 Feature Report 读写（如 Razer 90 字节协议）
    public static func exchangeFeatureReport(
        device: IOHIDDevice,
        reportID: Int,
        request: [UInt8],
        responseLength: Int,
        delayMs: Int = 35
    ) -> [UInt8]? {
        let setRes = request.withUnsafeBytes { rawBuf -> IOReturn in
            guard let base = rawBuf.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                return kIOReturnBadArgument
            }
            return IOHIDDeviceSetReport(device, kIOHIDReportTypeFeature, CFIndex(reportID), base, request.count)
        }
        guard setRes == kIOReturnSuccess else {
            return nil
        }

        if delayMs > 0 {
            usleep(useconds_t(delayMs * 1000))
        }

        var response = [UInt8](repeating: 0, count: responseLength)
        var outLen = CFIndex(responseLength)
        let getRes = response.withUnsafeMutableBytes { rawBuf -> IOReturn in
            guard let base = rawBuf.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                return kIOReturnBadArgument
            }
            return IOHIDDeviceGetReport(device, kIOHIDReportTypeFeature, CFIndex(reportID), base, &outLen)
        }
        guard getRes == kIOReturnSuccess else {
            return nil
        }
        return Array(response.prefix(max(0, outLen)))
    }
}
