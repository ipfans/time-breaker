import AppKit
import StoreKit
import SwiftUI

/// Creates the Settings window on demand and releases it, with its previews, when it closes.
@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    private let model: AppModel
    private let localizer: Localizer
    private let initialSection: SettingsView.Section
    private var window: NSWindow?

    init(model: AppModel, localizer: Localizer, initialSection: SettingsView.Section = .breaks) {
        self.model = model
        self.localizer = localizer
        self.initialSection = initialSection
    }

    func show() {
        let window = window ?? makeWindow()
        self.window = window
        model.launchAtLogin.refresh()
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    private func makeWindow() -> NSWindow {
        let root = SettingsView(
            model: model,
            localizer: localizer,
            initialSection: initialSection,
            chooseImage: { [weak self] in await self?.chooseImageURL() },
            purchase: { [weak self] product in try await self?.purchase(product) ?? .userCancelled }
        )
        let host = NSHostingController(rootView: root)
        host.sizingOptions = [.preferredContentSize]
        let window = NSWindow(contentViewController: host)
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.title = localizer.string(.settingsTitle)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        return window
    }

    func languageDidChange() {
        window?.title = localizer.string(.settingsTitle)
    }

    func windowWillClose(_ notification: Notification) {
        window?.contentViewController = nil
        window = nil
        model.previewRenderer.removeAll()
    }

    private func chooseImageURL() async -> URL? {
        guard let window else { return nil }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = BackgroundImageStore.allowedContentTypes
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = localizer.string(.openPanelMessage)
        panel.prompt = localizer.string(.openPanelPrompt)
        let response = await panel.beginSheetModal(for: window)
        return response == .OK ? panel.url : nil
    }

    /// Attaches the App Store purchase sheet to Settings. Without a window there is nothing to
    /// attach to, so the purchase is treated as cancelled.
    private func purchase(_ product: Product) async throws -> Product.PurchaseResult {
        guard let window else { return .userCancelled }
        return try await product.purchase(confirmIn: window)
    }
}
