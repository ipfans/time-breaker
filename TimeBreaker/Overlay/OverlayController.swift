import AppKit
import SwiftUI
import os

/// Presents one shared break session on every available display.
///
/// Windows exist only while a break is presented. Display, Space, and activation changes are
/// handled through notifications; nothing polls to keep the overlay in front.
@MainActor
final class OverlayController {
    private let localizer: Localizer
    private let renderer: BackgroundImageRenderer
    private let imageStore: BackgroundImageStore
    private let actions: OverlayActions
    private let model = OverlayModel()
    private let logger = Logger(subsystem: Log.subsystem, category: "Overlay")

    private var windows: [CGDirectDisplayID: OverlayWindow] = [:]
    private var screens: [CGDirectDisplayID: NSScreen] = [:]
    private var backgroundRequests: [CGDirectDisplayID: BackgroundRenderRequest] = [:]
    private var tickerTask: Task<Void, Never>?
    private var backgroundTask: Task<Void, Never>?
    private var diagnosticsTask: Task<Void, Never>?
    private var previousApplication: NSRunningApplication?
    private var notificationTokens: [(NotificationCenter, NSObjectProtocol)] = []
    private var orderingRecoveryScheduled = false

    init(
        localizer: Localizer,
        imageStore: BackgroundImageStore,
        renderer: BackgroundImageRenderer,
        appearance: AppearanceSettings,
        actions: OverlayActions
    ) {
        self.localizer = localizer
        self.imageStore = imageStore
        self.renderer = renderer
        self.actions = actions
        model.appearance = appearance
        observeEnvironmentChanges()
    }

    var isPresenting: Bool { model.session != nil }
    var windowCount: Int { windows.count }

    /// Shows, updates, or hides overlays to match the scheduler state.
    func update(with snapshot: SchedulerSnapshot) {
        if snapshot.isPresentingBreak, let session = snapshot.activeBreak {
            present(session)
        } else {
            dismiss()
        }
    }

    /// Updates appearance in place without changing the session.
    func setAppearance(_ appearance: AppearanceSettings) {
        guard appearance != model.appearance else { return }
        model.appearance = appearance
        if isPresenting {
            loadBackgrounds()
        }
    }

    /// Updates AppKit-level text; SwiftUI content follows the localizer automatically.
    func languageDidChange() {
        for window in windows.values {
            window.setAccessibilityLabel(localizer.string(.overlayWindowAccessibility))
        }
    }

    /// Removes every overlay window. Called on termination.
    func tearDown() {
        dismiss(restoringFocus: false)
        for (center, token) in notificationTokens {
            center.removeObserver(token)
        }
        notificationTokens.removeAll()
    }

    // MARK: - Presentation

    private func present(_ session: ActiveBreak) {
        let previous = model.session
        model.session = session
        if previous?.timing != session.timing || previous?.id != session.id {
            startTicker()
        }
        guard previous == nil else { return }

        let presentationStart = ContinuousClock.now
        let frontmost = NSWorkspace.shared.frontmostApplication
        previousApplication = frontmost?.processIdentifier == ProcessInfo.processInfo.processIdentifier ? nil : frontmost

        // Prepare every window first, then order them all front in the same update cycle.
        reconcileWindows()
        for window in windows.values {
            window.orderFrontRegardless()
        }
        windowUnderPointer()?.makeKeyAndOrderFront(nil)
        loadBackgrounds()

        let now = ContinuousClock.now
        let consumed = session.duration - session.timing.remaining(at: now)
        logger.notice("""
            Presented session \(session.id, privacy: .public) (\(session.kind.rawValue, privacy: .public)) on \
            \(self.windows.count, privacy: .public) display(s) in \((now - presentationStart).milliseconds, privacy: .public) ms; \
            break time already elapsed: \(consumed.milliseconds, privacy: .public) ms
            """)
        scheduleCoverageDiagnostics()
    }

    private func dismiss(restoringFocus: Bool = true) {
        guard model.session != nil || !windows.isEmpty else { return }
        tickerTask?.cancel()
        tickerTask = nil
        backgroundTask?.cancel()
        backgroundTask = nil
        diagnosticsTask?.cancel()
        diagnosticsTask = nil
        model.session = nil

        for window in windows.values {
            window.orderOut(nil)
            window.contentView = nil
            window.close()
        }
        windows.removeAll()
        screens.removeAll()
        backgroundRequests.removeAll()
        model.backgrounds.removeAll()
        renderer.removeAll()
        logger.notice("Dismissed overlays")

        if restoringFocus {
            restoreFocus()
        }
        previousApplication = nil
    }

    /// Matches windows to the current displays without restarting the session.
    private func reconcileWindows() {
        var current: [CGDirectDisplayID: NSScreen] = [:]
        for screen in NSScreen.screens {
            if let id = screen.displayID {
                current[id] = screen
            }
        }
        screens = current

        for (id, window) in windows where current[id] == nil {
            window.orderOut(nil)
            window.contentView = nil
            window.close()
            windows[id] = nil
            model.backgrounds[id] = nil
            backgroundRequests[id] = nil
        }

        for (id, screen) in current {
            if let window = windows[id] {
                if window.frame != screen.frame {
                    window.setFrame(screen.frame, display: true)
                }
            } else {
                windows[id] = makeWindow(for: screen, displayID: id)
            }
        }
        if current.isEmpty {
            logger.error("No displays available; overlay presentation is suspended until displays return")
        }
    }

    private func makeWindow(for screen: NSScreen, displayID: CGDirectDisplayID) -> OverlayWindow {
        let window = OverlayWindow(screen: screen, displayID: displayID)
        let root = BreakOverlayView(model: model, displayID: displayID, localizer: localizer, actions: actions)
        let hostingView = NSHostingView(rootView: root)
        hostingView.sizingOptions = []
        window.contentView = hostingView
        window.setAccessibilityLabel(localizer.string(.overlayWindowAccessibility))
        return window
    }

    private func windowUnderPointer() -> OverlayWindow? {
        let pointer = NSEvent.mouseLocation
        return windows.values.first { NSMouseInRect(pointer, $0.frame, false) } ?? windows.values.first
    }

    // MARK: - Countdown

    /// One ticker shared by every display, waking only when the displayed second changes.
    private func startTicker() {
        tickerTask?.cancel()
        tickerTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, let timing = self.model.session?.timing else { return }
                let now = ContinuousClock.now
                let remaining = timing.remaining(at: now)
                let seconds = Int(remaining.timeInterval.rounded(.up))
                if self.model.remainingSeconds != seconds {
                    self.model.remainingSeconds = seconds
                }
                guard case .running = timing else { return }
                let untilNextChange = remaining - .seconds(max(0, seconds - 1))
                let wait = seconds > 0 ? max(untilNextChange, .milliseconds(20)) : .seconds(1)
                try? await Task.sleep(until: now + wait, tolerance: .milliseconds(100), clock: .continuous)
            }
        }
    }

    // MARK: - Backgrounds

    /// Decodes per-display variants asynchronously; the color shows until an image is ready.
    private func loadBackgrounds() {
        backgroundTask?.cancel()
        guard let image = model.appearance.activeImage, imageStore.fileExists(for: image) else {
            if model.appearance.activeImage != nil {
                logger.error("Background image file is missing; using the background color")
            }
            backgroundRequests.removeAll()
            model.backgrounds.removeAll()
            renderer.removeAll()
            return
        }

        var requests: [CGDirectDisplayID: BackgroundRenderRequest] = [:]
        for (id, screen) in screens {
            let variant = ImageLayoutCalculator.renderRequest(
                layout: model.appearance.layout,
                imageSize: image.logicalSize,
                container: screen.frame.size,
                backingScale: screen.backingScaleFactor
            )
            requests[id] = BackgroundRenderRequest(image: image, variant: variant)
        }
        for (id, request) in requests where backgroundRequests[id] != request {
            model.backgrounds[id] = nil
        }
        backgroundRequests = requests
        renderer.retainOnly(Set(requests.values))

        backgroundTask = Task { [weak self] in
            for (id, request) in requests {
                guard let self else { return }
                let rendered = await self.renderer.image(for: request)
                guard !Task.isCancelled else { return }
                guard self.backgroundRequests[id] == request else { continue }
                self.model.backgrounds[id] = rendered
            }
        }
    }

    // MARK: - Environment changes

    private func observeEnvironmentChanges() {
        let center = NotificationCenter.default
        let workspaceCenter = NSWorkspace.shared.notificationCenter
        observe(center, NSApplication.didChangeScreenParametersNotification) { controller in
            controller.displaysChanged()
        }
        observe(workspaceCenter, NSWorkspace.activeSpaceDidChangeNotification) { controller in
            controller.scheduleOrderingRecovery(reason: "space change")
        }
        observe(center, NSApplication.didResignActiveNotification) { controller in
            controller.scheduleOrderingRecovery(reason: "app deactivated")
        }
    }

    private func observe(
        _ center: NotificationCenter,
        _ name: Notification.Name,
        handler: @escaping @MainActor (OverlayController) -> Void
    ) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                handler(self)
            }
        }
        notificationTokens.append((center, token))
    }

    private func displaysChanged() {
        guard isPresenting else { return }
        let before = Set(windows.keys)
        reconcileWindows()
        logger.notice("Display configuration changed: \(before.count, privacy: .public) -> \(self.windows.count, privacy: .public) overlay window(s)")
        for window in windows.values {
            window.orderFrontRegardless()
        }
        if !windows.values.contains(where: \.isKeyWindow) {
            windowUnderPointer()?.makeKey()
        }
        loadBackgrounds()
        scheduleCoverageDiagnostics()
    }

    /// Re-orders overlays once after an event; coalesced and never repeated on a timer.
    private func scheduleOrderingRecovery(reason: String) {
        guard isPresenting, !orderingRecoveryScheduled else { return }
        orderingRecoveryScheduled = true
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.orderingRecoveryScheduled = false
                guard self.isPresenting else { return }
                for window in self.windows.values {
                    window.orderFrontRegardless()
                }
                self.logger.notice("Re-ordered overlays after \(reason, privacy: .public)")
            }
        }
    }

    /// Hands keyboard focus back to the app that was frontmost when the break began.
    private func restoreFocus() {
        guard let previous = previousApplication, !previous.isTerminated, NSApp.isActive else { return }
        // Leave focus alone when the user is working in one of the app's own windows.
        let hasOwnTitledWindow = NSApp.windows.contains { $0.isVisible && $0.styleMask.contains(.titled) }
        guard !hasOwnTitledWindow else { return }
        NSApp.yieldActivation(to: previous)
        previous.activate(from: .current, options: [])
    }

    // MARK: - Diagnostics

    /// Records whether each display's overlay is visible and frontmost at its center.
    private func scheduleCoverageDiagnostics() {
        diagnosticsTask?.cancel()
        diagnosticsTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(750))
            guard let self, !Task.isCancelled, self.isPresenting else { return }
            for (id, window) in self.windows {
                let center = NSPoint(x: window.frame.midX, y: window.frame.midY)
                let topWindow = NSWindow.windowNumber(at: center, belowWindowWithWindowNumber: 0)
                let screenFrame = self.screens[id]?.frame ?? .zero
                self.logger.notice("""
                    Coverage display=\(id, privacy: .public) frame=\(NSStringFromRect(window.frame), privacy: .public) \
                    screen=\(NSStringFromRect(screenFrame), privacy: .public) \
                    visible=\(window.isVisible, privacy: .public) \
                    occlusionVisible=\(window.occlusionState.contains(.visible), privacy: .public) \
                    activeSpace=\(window.isOnActiveSpace, privacy: .public) \
                    frontmostAtCenter=\(topWindow == window.windowNumber, privacy: .public) \
                    key=\(window.isKeyWindow, privacy: .public)
                    """)
            }
            let frontmost = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "none"
            self.logger.notice("Coverage app active=\(NSApp.isActive, privacy: .public) frontmost=\(frontmost, privacy: .public) displays=\(NSScreen.screens.count, privacy: .public) windows=\(self.windows.count, privacy: .public)")
        }
    }
}
