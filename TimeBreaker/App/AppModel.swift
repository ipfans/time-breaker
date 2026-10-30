import Foundation
import Observation

/// The single owner of preferences. Validates every change before applying or persisting it and
/// routes each part to the component that uses it.
@MainActor
@Observable
final class AppModel {
    private(set) var preferences: AppPreferences

    @ObservationIgnored let localizer: Localizer
    @ObservationIgnored let imageStore: BackgroundImageStore
    @ObservationIgnored let launchAtLogin = LaunchAtLoginController()
    /// Decodes small preview images for Settings; emptied when Settings closes.
    @ObservationIgnored let previewRenderer: BackgroundImageRenderer
    @ObservationIgnored var onLanguageChange: (() -> Void)?

    @ObservationIgnored private let store: PreferencesStore
    @ObservationIgnored private let diagnostics: DiagnosticOptions
    @ObservationIgnored private let scheduler: BreakScheduler
    @ObservationIgnored private let overlay: OverlayController

    init(
        preferences: AppPreferences,
        store: PreferencesStore,
        localizer: Localizer,
        imageStore: BackgroundImageStore,
        diagnostics: DiagnosticOptions,
        scheduler: BreakScheduler,
        overlay: OverlayController
    ) {
        self.preferences = preferences
        self.store = store
        self.localizer = localizer
        self.imageStore = imageStore
        self.diagnostics = diagnostics
        self.scheduler = scheduler
        self.overlay = overlay
        previewRenderer = BackgroundImageRenderer(store: imageStore, byteBudget: 16 * 1024 * 1024)
    }

    /// Applies `candidate` if it is valid. On failure the previous preferences stay in effect.
    @discardableResult
    func apply(_ candidate: AppPreferences) -> [PreferencesIssue] {
        let issues = candidate.validate()
        guard issues.isEmpty else { return issues }
        guard candidate != preferences else { return [] }

        let previous = preferences
        preferences = candidate
        store.save(candidate)

        if previous.breakConfigurations != candidate.breakConfigurations {
            scheduler.updateConfigurations(diagnostics.apply(to: candidate.breakConfigurations))
        }
        if previous.appearance != candidate.appearance {
            overlay.setAppearance(candidate.appearance)
        }
        if previous.language != candidate.language {
            localizer.setLanguage(candidate.language)
            overlay.languageDidChange()
            onLanguageChange?()
        }
        return []
    }

    /// Imports an image off the main actor, then selects it. Preferences change only on success.
    func importBackgroundImage(from url: URL) async -> ImageImportError? {
        let store = imageStore
        let result = await Task.detached(priority: .userInitiated) {
            Result { () throws(ImageImportError) -> BackgroundImageReference in
                try store.importImage(from: url)
            }
        }.value

        switch result {
        case .success(let reference):
            var candidate = preferences
            candidate.appearance.image = reference
            candidate.appearance.source = .image
            // Remove superseded copies only once preferences reference the new one.
            let kept = apply(candidate).isEmpty ? reference : preferences.appearance.image
            store.removeImages(keeping: Set([kept?.identifier].compactMap { $0 }))
            return nil
        case .failure(let error):
            return error
        }
    }
}
