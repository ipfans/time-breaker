import Foundation

/// Application languages bundled with Time Breaker.
///
/// The raw value is the stable identifier persisted in preferences and the `.lproj` name.
enum AppLanguage: String, Codable, CaseIterable, Identifiable, Sendable {
    case english = "en"
    case simplifiedChinese = "zh-Hans"
    case traditionalChinese = "zh-Hant"
    case japanese = "ja"
    case korean = "ko"
    case spanish = "es"
    case french = "fr"
    case portuguesePortugal = "pt-PT"

    var id: String { rawValue }

    /// Resolves a stored identifier, falling back to English when it is missing or unsupported.
    init(identifier: String?) {
        self = identifier.flatMap(AppLanguage.init(rawValue:)) ?? .english
    }

    /// The language's name in its own language, so users can find it in any interface language.
    var nativeName: String {
        switch self {
        case .english: "English"
        case .simplifiedChinese: "简体中文"
        case .traditionalChinese: "繁體中文"
        case .japanese: "日本語"
        case .korean: "한국어"
        case .spanish: "Español"
        case .french: "Français"
        case .portuguesePortugal: "Português (Portugal)"
        }
    }

    var locale: Locale { Locale(identifier: rawValue) }
}
