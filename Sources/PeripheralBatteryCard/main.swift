import AppKit
import Foundation
import PeripheralBatteryCore

if CommandLine.arguments.contains("--dump-json") {
    let json = BatteryMonitorService.oneShotDumpJSON(pretty: true)
    print(json)
    Foundation.exit(0)
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let delegate = AppDelegate()
    app.delegate = delegate
    withExtendedLifetime(delegate) {
        app.run()
    }
}
