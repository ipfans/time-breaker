import AppKit
import os

/// A borderless panel covering one display's full frame during a break.
///
/// It is a non-activating panel: under cooperative activation, `NSApp.activate()` is refused
/// while the user works in another app, but a non-activating panel can still become key and
/// receive keyboard input without taking activation from that app.
///
/// The window stays at full `alphaValue`; background transparency is composed inside the content.
/// Closing it or pressing Esc is not a way to end the break.
final class OverlayWindow: NSPanel {
    let displayID: CGDirectDisplayID
    private let logger = Logger(subsystem: Log.subsystem, category: "Overlay")

    init(screen: NSScreen, displayID: CGDirectDisplayID) {
        self.displayID = displayID
        super.init(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isReleasedWhenClosed = false
        becomesKeyOnlyIfNeeded = false
        isFloatingPanel = false
        level = .screenSaver
        collectionBehavior = [
            .canJoinAllSpaces,
            .canJoinAllApplications,
            .fullScreenAuxiliary,
            .stationary,
            .ignoresCycle,
        ]
        hidesOnDeactivate = false
        ignoresMouseEvents = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        alphaValue = 1
        isMovable = false
        animationBehavior = .none
        tabbingMode = .disallowed
        setFrame(screen.frame, display: false)
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    /// Keeps the frame exactly on the display, including above the menu bar and notch.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }

    /// Records that keyboard input reached the overlay, without recording which keys.
    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown {
            logger.debug("Key event delivered to overlay on display \(self.displayID, privacy: .public)")
        }
        super.sendEvent(event)
    }

    override func cancelOperation(_ sender: Any?) {}

    override func performClose(_ sender: Any?) {}

    /// Swallows unhandled keys silently instead of beeping for every keystroke during a break.
    override func noResponder(for eventSelector: Selector) {
        if eventSelector == #selector(NSResponder.keyDown(with:)) { return }
        super.noResponder(for: eventSelector)
    }
}

extension NSScreen {
    var displayID: CGDirectDisplayID? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }
}
