import Foundation
import Observation

/// Resolves app-owned text in the selected application language, independently of the system
/// language.
///
/// Strings come from the bundled String Catalog. A string missing from the selected language falls
/// back to English; internal keys are never shown.
@MainActor
@Observable
final class Localizer {
    private(set) var language: AppLanguage
    private var bundle: Bundle

    @ObservationIgnored private let resourceBundle: Bundle
    @ObservationIgnored private let englishBundle: Bundle

    init(language: AppLanguage, resourceBundle: Bundle = .main) {
        self.resourceBundle = resourceBundle
        englishBundle = Self.bundle(for: .english, in: resourceBundle) ?? resourceBundle
        self.language = language
        bundle = Self.bundle(for: language, in: resourceBundle) ?? englishBundle
    }

    func setLanguage(_ language: AppLanguage) {
        guard language != self.language else { return }
        self.language = language
        bundle = Self.bundle(for: language, in: resourceBundle) ?? englishBundle
    }

    var locale: Locale { language.locale }

    /// A plain localized string.
    func string(_ key: L10n) -> String {
        Self.lookup(key.rawValue, in: bundle) ?? Self.lookup(key.rawValue, in: englishBundle) ?? ""
    }

    /// A localized format string filled with arguments; plural variants use the app language's rules.
    func format(_ key: L10n, _ arguments: any CVarArg...) -> String {
        String(format: string(key), locale: locale, arguments: arguments)
    }

    // MARK: Durations

    /// A countdown such as “4:59” or “1:00:00”, with locale-appropriate digits.
    func countdown(seconds: Int) -> String {
        let duration = Duration.seconds(max(0, seconds))
        let pattern: Duration.TimeFormatStyle.Pattern = seconds >= 3600 ? .hourMinuteSecond : .minuteSecond
        return duration.formatted(.time(pattern: pattern).locale(locale))
    }

    /// A spelled-out duration such as “5 minutes” or “1 minute, 30 seconds”, with plural rules.
    func duration(seconds: Int, width: Duration.UnitsFormatStyle.UnitWidth = .wide) -> String {
        Duration.seconds(max(0, seconds)).formatted(
            .units(allowed: [.hours, .minutes, .seconds], width: width).locale(locale)
        )
    }

    /// A locale-formatted integer.
    func number(_ value: Int) -> String {
        value.formatted(.number.locale(locale))
    }

    // MARK: Bundle lookup

    nonisolated static func bundle(for language: AppLanguage, in resourceBundle: Bundle) -> Bundle? {
        resourceBundle.path(forResource: language.rawValue, ofType: "lproj").flatMap(Bundle.init(path:))
    }

    /// Returns the string for `key`, or `nil` if the bundle lacks a real translation.
    ///
    /// The String Catalog compiler emits untranslated entries with the key as their value, so a
    /// value equal to the key also counts as missing.
    nonisolated static func lookup(_ key: String, in bundle: Bundle) -> String? {
        let missing = "\u{0}missing"
        let value = bundle.localizedString(forKey: key, value: missing, table: nil)
        return value == missing || value == key ? nil : value
    }
}
