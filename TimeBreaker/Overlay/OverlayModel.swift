import CoreGraphics
import Observation

/// Presentation state shared by every display's overlay.
@MainActor
@Observable
final class OverlayModel {
    var session: ActiveBreak?
    /// Whole seconds left, rounded up. Updated by one shared ticker.
    var remainingSeconds = 0
    var appearance = AppearanceSettings()
    /// Decoded backgrounds per display; missing entries fall back to the background color.
    var backgrounds: [CGDirectDisplayID: RenderedBackground] = [:]
}

/// User commands available from an overlay; each is routed through the scheduler or app.
struct OverlayActions {
    var pause: @MainActor () -> Void
    var skip: @MainActor (ActiveBreak.ID) -> Void
    var quit: @MainActor () -> Void
}
