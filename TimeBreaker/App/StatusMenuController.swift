import AppKit

/// The menu bar item. Its icon is static; status text is computed when the menu opens and
/// refreshed only while the menu is visible.
@MainActor
final class StatusMenuController: NSObject, NSMenuDelegate {
    private let scheduler: BreakScheduler
    private let localizer: Localizer
    private let openSettings: () -> Void
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let menu = NSMenu()
    private var planItems: [BreakKind: NSMenuItem] = [:]
    private var refreshTimer: Timer?

    init(scheduler: BreakScheduler, localizer: Localizer, openSettings: @escaping () -> Void) {
        self.scheduler = scheduler
        self.localizer = localizer
        self.openSettings = openSettings
        super.init()
        menu.delegate = self
        menu.autoenablesItems = false
        statusItem.menu = menu
        updateButton()
    }

    func languageDidChange() {
        updateButton()
    }

    private func updateButton() {
        let name = localizer.string(.appName)
        let image = NSImage(systemSymbolName: "cup.and.saucer", accessibilityDescription: name)
        image?.isTemplate = true
        statusItem.button?.image = image
        statusItem.button?.toolTip = name
        statusItem.button?.setAccessibilityLabel(name)
    }

    // MARK: NSMenuDelegate

    func menuNeedsUpdate(_ menu: NSMenu) {
        rebuild()
    }

    func menuWillOpen(_ menu: NSMenu) {
        refreshTimer?.invalidate()
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refreshPlanLines()
            }
        }
        timer.tolerance = 0.2
        // Menu tracking runs the event-tracking run loop mode.
        RunLoop.main.add(timer, forMode: .common)
        refreshTimer = timer
    }

    func menuDidClose(_ menu: NSMenu) {
        refreshTimer?.invalidate()
        refreshTimer = nil
    }

    // MARK: Building

    private func rebuild() {
        menu.removeAllItems()
        planItems.removeAll()
        let snapshot = scheduler.snapshot
        let now = scheduler.currentInstant

        if let status = StatusMenuText.statusLine(snapshot: snapshot, localizer: localizer) {
            menu.addItem(informationalItem(status))
        }
        for kind in BreakKind.allCases {
            let item = informationalItem(StatusMenuText.planLine(kind, snapshot: snapshot, now: now, localizer: localizer))
            planItems[kind] = item
            menu.addItem(item)
        }
        menu.addItem(.separator())

        if snapshot.isManuallyPaused {
            menu.addItem(actionItem(localizer.string(.menuResume), #selector(resume)))
        } else {
            menu.addItem(actionItem(localizer.string(.menuPause), #selector(pause)))
        }
        if let session = snapshot.activeBreak {
            let skip = actionItem(localizer.string(.menuSkip), #selector(skip))
            skip.isEnabled = session.allowsSkip
            skip.representedObject = NSNumber(value: session.id)
            if !session.allowsSkip {
                skip.toolTip = localizer.string(.menuSkipNotAllowed)
            }
            menu.addItem(skip)
        }
        menu.addItem(.separator())
        let settings = actionItem(localizer.string(.menuSettings), #selector(showSettings))
        settings.keyEquivalent = ","
        menu.addItem(settings)
        let quit = actionItem(localizer.string(.menuQuit), #selector(quit))
        quit.keyEquivalent = "q"
        menu.addItem(quit)
    }

    private func refreshPlanLines() {
        let snapshot = scheduler.snapshot
        let now = scheduler.currentInstant
        for (kind, item) in planItems {
            let title = StatusMenuText.planLine(kind, snapshot: snapshot, now: now, localizer: localizer)
            if item.title != title {
                item.title = title
            }
        }
    }

    private func informationalItem(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private func actionItem(_ title: String, _ action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    // MARK: Actions

    @objc private func pause() {
        scheduler.pause()
    }

    @objc private func resume() {
        scheduler.resume()
    }

    /// Routed through the scheduler, which rejects the request if the session forbids skipping.
    @objc private func skip(_ sender: NSMenuItem) {
        guard let id = (sender.representedObject as? NSNumber)?.uint64Value else { return }
        scheduler.skip(sessionID: id)
    }

    @objc private func showSettings() {
        openSettings()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}

/// Status menu wording, kept separate from AppKit for testing.
enum StatusMenuText {
    @MainActor
    static func statusLine(snapshot: SchedulerSnapshot, localizer: Localizer) -> String? {
        if snapshot.isManuallyPaused { return localizer.string(.menuStatusPaused) }
        if !snapshot.systemSuspensionReasons.isEmpty { return localizer.string(.menuStatusAway) }
        if snapshot.phase == .disabled { return localizer.string(.menuStatusDisabled) }
        return nil
    }

    @MainActor
    static func planLine(_ kind: BreakKind, snapshot: SchedulerSnapshot, now: Instant, localizer: Localizer) -> String {
        let isShort = kind == .short
        if let session = snapshot.activeBreak, session.kind == kind {
            let seconds = Int(session.timing.remaining(at: now).timeInterval.rounded(.up))
            return localizer.format(isShort ? .menuShortActive : .menuLongActive, localizer.countdown(seconds: seconds))
        }
        guard let timing = snapshot.plans[kind] else {
            return localizer.string(isShort ? .menuShortOff : .menuLongOff)
        }
        let remaining = timing.remaining(at: now).timeInterval
        if remaining < 60 {
            return localizer.string(isShort ? .menuShortUnderMinute : .menuLongUnderMinute)
        }
        let minutes = Int((remaining / 60).rounded(.up))
        return localizer.format(isShort ? .menuShortInMinutes : .menuLongInMinutes, minutes)
    }
}
