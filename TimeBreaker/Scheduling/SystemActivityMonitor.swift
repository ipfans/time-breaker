import AppKit
import os

/// Translates documented workspace notifications into system-suspension reasons.
///
/// These signals approximate time away; they do not prove that the user stood up. Screen locking
/// is intentionally not inferred from session switching or undocumented notifications.
@MainActor
final class SystemActivityMonitor {
    private let scheduler: BreakScheduler
    private var tokens: [NSObjectProtocol] = []
    private let logger = Logger(subsystem: Log.subsystem, category: "SystemActivity")

    init(scheduler: BreakScheduler) {
        self.scheduler = scheduler
    }

    func start() {
        guard tokens.isEmpty else { return }
        let pairs: [(Notification.Name, SystemSuspensionReason, Bool)] = [
            (NSWorkspace.willSleepNotification, .systemSleep, true),
            (NSWorkspace.didWakeNotification, .systemSleep, false),
            (NSWorkspace.screensDidSleepNotification, .displaySleep, true),
            (NSWorkspace.screensDidWakeNotification, .displaySleep, false),
            (NSWorkspace.sessionDidResignActiveNotification, .sessionInactive, true),
            (NSWorkspace.sessionDidBecomeActiveNotification, .sessionInactive, false),
        ]
        let center = NSWorkspace.shared.notificationCenter
        for (name, reason, begins) in pairs {
            let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.handle(reason, begins: begins)
                }
            }
            tokens.append(token)
        }
    }

    func stop() {
        let center = NSWorkspace.shared.notificationCenter
        tokens.forEach(center.removeObserver)
        tokens.removeAll()
    }

    private func handle(_ reason: SystemSuspensionReason, begins: Bool) {
        logger.notice("System activity: \(reason.rawValue, privacy: .public) \(begins ? "began" : "ended", privacy: .public)")
        if begins {
            scheduler.beginSystemSuspension(reason)
        } else {
            scheduler.endSystemSuspension(reason)
        }
    }
}
