import Foundation

/// 根据设备名称、蓝牙 MinorType、HID UsagePage/Usage 识别外设类型与连接方式
public enum DeviceClassifier {
    public static func classify(
        name: String,
        minorType: String? = nil,
        usagePage: Int? = nil,
        usage: Int? = nil,
        usagePairs: [(Int, Int)] = [],
        isUPS: Bool = false,
        isInternal: Bool = false
    ) -> DeviceCategory {
        if isInternal {
            return .laptop
        }
        if isUPS {
            return .ups
        }

        if let minor = minorType?.lowercased() {
            if minor.contains("mouse") { return .mouse }
            if minor.contains("keyboard") { return .keyboard }
            if minor.contains("trackpad") { return .trackpad }
            if minor.contains("gamepad") || minor.contains("joystick") { return .gamepad }
            if minor.contains("headphone") || minor.contains("headset") { return .headphones }
            if minor.contains("speaker") { return .speaker }
        }

        let lower = name.lowercased()

        // 名称强特征优先（防止多功能复合 HID 键盘鼠标误判）
        if matchesAny(lower, [
            "airpods", "earbuds", "freebuds", "wf-", "buds", "liberty",
            "earfun", "encos", "earpiece", "tws"
        ]) {
            return .earbuds
        }
        if matchesAny(lower, [
            "headset", "headphone", "arctis", "nova pro", "nova 5", "nova 7",
            "hs80", "virtuoso", "cloud", "barracuda", "blackshark", "kraken",
            "wh-1000", "qc35", "qc45", "studio3", "solo", "airpods max", "momentum",
            "g733", "g435", "g pro x", "void", "耳机"
        ]) {
            return .headphones
        }
        if matchesAny(lower, [
            "trackpad", "触控板"
        ]) {
            return .trackpad
        }
        if matchesAny(lower, [
            "xbox", "dualsense", "dualshock", "playstation", "joy-con", "pro controller",
            "8bitdo", "gamesir", "flydigi", "gulikit", "gamepad", "controller", "手柄"
        ]) {
            return .gamepad
        }
        if matchesAny(lower, [
            "apple pencil", "stylus", "wacom", "intuos", "cintiq", "xppen", "huion", "手写笔"
        ]) {
            return .stylus
        }
        if matchesAny(lower, [
            "ups", "apc ", "cyberpower", "back-ups", "smart-ups", "eaton"
        ]) {
            return .ups
        }
        if matchesAny(lower, ["iphone"]) {
            return .phone
        }
        if matchesAny(lower, ["ipad"]) {
            return .tablet
        }
        if matchesAny(lower, ["speaker", "homepod", "soundlink", "jbl ", "marshall", "音箱"]) {
            return .speaker
        }

        // 常见外设品牌型号前缀/关键字
        if matchesAny(lower, [
            "mouse", "mchose", "g7", "g3", "r1", "viper", "deathadder", "basilisk", "naga",
            "cobra", "orochi", "mx master", "mx anywhere", "mx vertical", "g pro", "superlight",
            "g304", "g305", "g502", "g703", "g903", "aerox", "rival", "prime", "pulsar",
            "lamzu", "ninjutso", "sora", "darmoshark", "zaopin", "dragonfly", "atk f1", "atk x1",
            "aj139", "aj199", "vt9", "vt3", "maya", "鼠标"
        ]) {
            return .mouse
        }
        if matchesAny(lower, [
            "keyboard", "v87", "v75", "v98", "s99", "f75", "f87", "f99", "k87", "k99",
            "rainy75", "crush80", "keychron", "hhkb", "nuphy", "lofree", "mx keys", "mx mechanical",
            "zmk", "qmk", "ak820", "ak992", "gmk87", "hi75", "nj80", "leobog", "aula",
            "wobkey", "akko", "monsgeek", "melgeek", "cidoo", "wooting", "kbd", "键盘"
        ]) {
            return .keyboard
        }

        // 退化到标准 HID UsagePage / Usage 判断
        let allPairs = [(usagePage ?? 0, usage ?? 0)] + usagePairs
        for (page, use) in allPairs {
            if page == 1 {
                if use == 2 { return .mouse }
                if use == 6 { return .keyboard }
                if use == 4 || use == 5 { return .gamepad }
            }
            if page == 13 && (use == 1 || use == 2 || use == 4) {
                return .stylus
            }
        }

        return .other
    }

    public static func inferTransport(
        rawTransport: String?,
        productName: String,
        productID: Int? = nil,
        isBluetooth: Bool = false,
        isBLE: Bool = false
    ) -> DeviceTransport {
        if isBLE { return .ble }
        if isBluetooth { return .bluetooth }

        let lowerTransport = (rawTransport ?? "").lowercased()
        let lowerName = productName.lowercased()

        if lowerTransport.contains("bluetoothlowenergy") || lowerTransport.contains("ble") {
            return .ble
        }
        if lowerTransport.contains("bluetooth") {
            return .bluetooth
        }
        if lowerTransport.contains("spi") || lowerTransport.contains("internal") {
            return .builtIn
        }
        if lowerTransport.contains("usb") {
            if looksLikeWirelessReceiver(name: lowerName, productID: productID) {
                return .wireless24G
            }
            return .usb
        }
        if looksLikeWirelessReceiver(name: lowerName, productID: productID) {
            return .wireless24G
        }
        return .unknown
    }

    public static func looksLikeWirelessReceiver(name: String, productID: Int? = nil) -> Bool {
        let lower = name.lowercased()
        let receiverKeywords = [
            "receiver", "dongle", "lightspeed", "unifying", "logi bolt", "bolt",
            "2.4g", "2.4 g", "hyperspeed", "slipstream", "wireless", "接收器", "nano"
        ]
        if matchesAny(lower, receiverKeywords) {
            return true
        }
        if let pid = productID {
            // 常见 2.4G 无线接收器 PID（Logitech Unifying/Bolt/Lightspeed, EVision 5088 等）
            let knownDonglePIDs: Set<Int> = [
                0xC52B, 0xC548, 0xC539, 0xC53F, 0xC545, 0xC547, 0xC54D, 0xC534,
                0x5088
            ]
            if knownDonglePIDs.contains(pid) {
                return true
            }
        }
        return false
    }

    public static func formatHex(_ value: Int?, width: Int = 4) -> String {
        guard let value else { return "-" }
        return String(format: "0x%0\(width)X", value)
    }

    private static func matchesAny(_ text: String, _ keywords: [String]) -> Bool {
        for kw in keywords where text.contains(kw) {
            return true
        }
        return false
    }
}
