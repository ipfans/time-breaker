import AppKit

let app = NSApplication.shared
// Unit tests run inside this app; they must not start scheduling or show overlays.
let isHostingTests = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
let delegate = isHostingTests ? nil : AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
