import AppKit
import os

/// Builds the app's long-lived objects and connects them. Scheduling starts at launch without
/// opening Settings, and closing Settings leaves the app running.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var model: AppModel?
    private var scheduler: BreakScheduler?
    private var overlay: OverlayController?
    private var systemMonitor: SystemActivityMonitor?
    private var schedulingActivity: SchedulingActivity?
    private var statusMenu: StatusMenuController?
    private var settingsWindow: SettingsWindowController?
    private var terminationSignal: DispatchSourceSignal?
    private let logger = Logger(subsystem: Log.subsystem, category: "App")

    func applicationDidFinishLaunching(_ notification: Notification) {
        let preferencesStore = PreferencesStore()
        let diagnostics = DiagnosticOptions(defaults: .standard)
        let imageStore = BackgroundImageStore(directory: BackgroundImageStore.defaultDirectory())
        let storedPreferences = preferencesStore.load()
        imageStore.removeImages(keeping: Set([storedPreferences.appearance.image?.identifier].compactMap { $0 }))
        let preferences = diagnostics.apply(to: storedPreferences, imageStore: imageStore)
        let localizer = Localizer(language: preferences.language)

        let scheduler = BreakScheduler(configurations: diagnostics.apply(to: preferences.breakConfigurations))
        let overlay = OverlayController(
            localizer: localizer,
            imageStore: imageStore,
            renderer: BackgroundImageRenderer(store: imageStore),
            appearance: preferences.appearance,
            actions: OverlayActions(
                pause: { scheduler.pause() },
                skip: { scheduler.skip(sessionID: $0) },
                quit: { NSApp.terminate(nil) }
            )
        )
        let schedulingActivity = SchedulingActivity(isEnabled: diagnostics.holdsSchedulingActivity)
        scheduler.addObserver { snapshot in
            overlay.update(with: snapshot)
            schedulingActivity.update(with: snapshot)
        }
        schedulingActivity.update(with: scheduler.snapshot)

        let systemMonitor = SystemActivityMonitor(scheduler: scheduler)
        systemMonitor.start()

        let model = AppModel(
            preferences: preferences,
            store: preferencesStore,
            localizer: localizer,
            imageStore: imageStore,
            diagnostics: diagnostics,
            scheduler: scheduler,
            overlay: overlay
        )
        let statusMenu = StatusMenuController(scheduler: scheduler, localizer: localizer) { [weak self] in
            self?.showSettings(nil)
        }
        model.onLanguageChange = { [weak self] in
            self?.installMainMenu(localizer: localizer)
            self?.settingsWindow?.languageDidChange()
            statusMenu.languageDidChange()
        }
        installMainMenu(localizer: localizer)
        terminateNormallyOnSIGTERM()

        self.model = model
        self.scheduler = scheduler
        self.overlay = overlay
        self.systemMonitor = systemMonitor
        self.schedulingActivity = schedulingActivity
        self.statusMenu = statusMenu
        self.settingsWindow = SettingsWindowController(
            model: model,
            localizer: localizer,
            initialSection: diagnostics.settingsSection ?? .breaks
        )

        logger.notice("""
            Launched; scheduling started (diagnostic overrides: \(diagnostics.isActive, privacy: .public), \
            scheduling activity: \(diagnostics.holdsSchedulingActivity, privacy: .public), \
            login item status: \(model.launchAtLogin.status.rawValue, privacy: .public))
            """)
    }

    func applicationWillTerminate(_ notification: Notification) {
        overlay?.tearDown()
        scheduler?.stop()
        systemMonitor?.stop()
        schedulingActivity?.end()
        logger.notice("Terminating")
    }

    /// Opening the app again from Finder shows Settings, since there is no Dock icon.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showSettings(nil)
        return false
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        true
    }

    @objc func showSettings(_ sender: Any?) {
        settingsWindow?.show()
    }

    /// Routes SIGTERM through normal termination so overlays and activities are cleaned up.
    private func terminateNormallyOnSIGTERM() {
        signal(SIGTERM, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        source.setEventHandler {
            MainActor.assumeIsolated {
                NSApp.terminate(nil)
            }
        }
        source.resume()
        terminationSignal = source
    }

    private func installMainMenu(localizer: Localizer) {
        NSApp.mainMenu = MainMenuBuilder.makeMenu(localizer: localizer, settingsTarget: self)
    }
}
