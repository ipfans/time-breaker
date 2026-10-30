import Foundation

/// Optional App Nap mitigation: a bounded activity held only while a deadline is pending.
///
/// Disabled by default. It permits idle system sleep and is ended during suspension, disabled
/// scheduling, and termination.
@MainActor
final class SchedulingActivity {
    let isEnabled: Bool
    private var token: NSObjectProtocol?

    init(isEnabled: Bool) {
        self.isEnabled = isEnabled
    }

    var isHeld: Bool { token != nil }

    func update(with snapshot: SchedulerSnapshot) {
        let needed = isEnabled && !snapshot.isSuspended && snapshot.phase != .disabled
        if needed, token == nil {
            token = ProcessInfo.processInfo.beginActivity(
                options: .userInitiatedAllowingIdleSystemSleep,
                reason: "Waiting for the next break"
            )
        } else if !needed {
            end()
        }
    }

    func end() {
        if let token {
            ProcessInfo.processInfo.endActivity(token)
        }
        token = nil
    }
}
