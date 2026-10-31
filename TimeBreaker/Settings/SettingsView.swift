import SwiftUI

struct SettingsView: View {
    enum Section: String, Hashable, Sendable {
        case breaks
        case appearance
        case general
        case support
    }

    let model: AppModel
    let localizer: Localizer
    let chooseImage: @MainActor () async -> URL?
    let purchase: TipJar.Purchase

    @State private var selection: Section

    init(
        model: AppModel,
        localizer: Localizer,
        initialSection: Section = .breaks,
        chooseImage: @escaping @MainActor () async -> URL?,
        purchase: @escaping TipJar.Purchase
    ) {
        self.model = model
        self.localizer = localizer
        self.chooseImage = chooseImage
        self.purchase = purchase
        _selection = State(initialValue: initialSection)
    }

    var body: some View {
        TabView(selection: $selection) {
            Tab(localizer.string(.settingsTabBreaks), systemImage: "timer", value: .breaks) {
                BreaksSettingsView(model: model, localizer: localizer)
            }
            Tab(localizer.string(.settingsTabAppearance), systemImage: "paintpalette", value: .appearance) {
                AppearanceSettingsView(model: model, localizer: localizer, chooseImage: chooseImage)
            }
            Tab(localizer.string(.settingsTabGeneral), systemImage: "gearshape", value: .general) {
                GeneralSettingsView(model: model, localizer: localizer)
            }
            Tab(localizer.string(.settingsTabSupport), systemImage: "heart", value: .support) {
                SupportSettingsView(tipJar: model.tipJar, localizer: localizer, purchase: purchase)
            }
        }
        .frame(width: 600)
        .fixedSize(horizontal: false, vertical: true)
        .environment(\.locale, localizer.locale)
    }
}

/// User-facing messages for validation and import failures.
extension Localizer {
    func message(for issue: PreferencesIssue) -> String {
        switch issue {
        case .workIntervalOutOfRange:
            let range = BreakConfiguration.workIntervalMinutesRange
            return format(.validationWorkInterval, number(range.lowerBound), number(range.upperBound))
        case .breakDurationOutOfRange:
            let range = BreakConfiguration.breakDurationSecondsRange
            return format(.validationBreakDuration, duration(seconds: range.lowerBound), duration(seconds: range.upperBound))
        case .longBreakShorterThanShortBreak:
            return string(.validationLongShorterThanShort)
        case .transparencyOutOfRange:
            return string(.validationTransparency)
        case .fadeInDurationOutOfRange, .fadeOutDurationOutOfRange:
            let range = AppearanceSettings.fadeDurationRange
            return format(
                .validationFadeDuration,
                fadeDuration(seconds: range.lowerBound, width: .wide),
                fadeDuration(seconds: range.upperBound, width: .wide)
            )
        }
    }

    func message(for error: ImageImportError) -> String {
        switch error {
        case .unsupportedFormat:
            return string(.importErrorUnsupported)
        case .unreadable:
            return string(.importErrorUnreadable)
        case .animated:
            return string(.importErrorAnimated)
        case .dimensionsTooLarge:
            let megapixels = BackgroundImageStore.maxPixelCount / 1_000_000
            return format(.importErrorTooLarge, number(BackgroundImageStore.maxPixelDimension), number(megapixels))
        case .fileTooLarge:
            let size = Int64(BackgroundImageStore.maxFileSize).formatted(.byteCount(style: .file).locale(locale))
            return format(.importErrorFileTooLarge, size)
        case .saveFailed:
            return string(.importErrorSaveFailed)
        }
    }
}
