import Observation
import ServiceManagement
import os

/// Registers the app as a login item only on request and reports the actual service status.
@MainActor
@Observable
final class LaunchAtLoginController {
    private(set) var status: SMAppService.Status = .notRegistered
    private(set) var errorDescription: String?

    @ObservationIgnored private let logger = Logger(subsystem: Log.subsystem, category: "LoginItem")

    init() {
        refresh()
    }

    /// Treats a pending approval as on, matching what the user asked for.
    var isEnabled: Bool { status == .enabled || status == .requiresApproval }

    func refresh() {
        status = SMAppService.mainApp.status
    }

    func setEnabled(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            errorDescription = nil
        } catch {
            errorDescription = error.localizedDescription
            logger.error("Login item change failed: \(error.localizedDescription, privacy: .public)")
        }
        refresh()
    }

    func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
