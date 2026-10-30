import Foundation

/// An sRGB color with components in 0...1.
struct RGBColor: Codable, Equatable, Sendable {
    var red: Double
    var green: Double
    var blue: Double

    static let defaultBackground = RGBColor(red: 0.12, green: 0.16, blue: 0.22)

    var isValid: Bool {
        [red, green, blue].allSatisfy { $0.isFinite && (0...1).contains($0) }
    }
}

enum BackgroundSource: String, Codable, CaseIterable, Sendable {
    case color
    case image
}

enum ImageLayout: String, Codable, CaseIterable, Sendable {
    case stretch
    case center
    case scaleToFit
}

/// A private copy of an imported image in Application Support.
struct BackgroundImageReference: Codable, Hashable, Sendable {
    /// File name inside the backgrounds directory.
    var identifier: String
    /// Orientation-corrected pixel width, also used as the logical point width for Center.
    var pixelWidth: Int
    /// Orientation-corrected pixel height, also used as the logical point height for Center.
    var pixelHeight: Int

    var logicalSize: CGSize { CGSize(width: pixelWidth, height: pixelHeight) }

    /// Rejects identifiers that could escape the backgrounds directory.
    var isValid: Bool {
        pixelWidth > 0 && pixelHeight > 0
            && identifier.range(of: #"^[A-Za-z0-9-]+\.(png|jpg|heic)$"#, options: .regularExpression) != nil
    }
}

/// Background shared by both break types and every display.
struct AppearanceSettings: Codable, Equatable, Sendable {
    var source: BackgroundSource = .color
    var color: RGBColor = .defaultBackground
    var image: BackgroundImageReference?
    var layout: ImageLayout = .scaleToFit
    /// Integer percentage; 0 is fully opaque and 99 keeps 1% opacity.
    var transparency: Int = 0

    static let transparencyRange = 0...99

    /// Opacity applied once to the composed background color and image.
    var backgroundOpacity: Double {
        1 - Double(transparency.clamped(to: Self.transparencyRange)) / 100
    }

    /// The image to draw, if image mode is selected and one has been imported.
    var activeImage: BackgroundImageReference? {
        source == .image ? image : nil
    }

    init() {}

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = AppearanceSettings()
        source = (try? container.decodeIfPresent(BackgroundSource.self, forKey: .source)) ?? defaults.source
        color = (try? container.decodeIfPresent(RGBColor.self, forKey: .color)).flatMap { $0.isValid ? $0 : nil } ?? defaults.color
        image = (try? container.decodeIfPresent(BackgroundImageReference.self, forKey: .image)).flatMap { $0.isValid ? $0 : nil }
        layout = (try? container.decodeIfPresent(ImageLayout.self, forKey: .layout)) ?? defaults.layout
        let storedTransparency = (try? container.decodeIfPresent(Int.self, forKey: .transparency)) ?? defaults.transparency
        transparency = Self.transparencyRange.contains(storedTransparency) ? storedTransparency : defaults.transparency
        if source == .image, image == nil {
            source = .color
        }
    }

    /// Parses user-entered transparency. Accepts only whole numbers from 0 through 99.
    static func parseTransparency(_ text: String) -> Int? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed.allSatisfy(\.isASCIIDigit), let value = Int(trimmed) else { return nil }
        return transparencyRange.contains(value) ? value : nil
    }
}

/// A validation failure that keeps the previous valid preferences in effect.
enum PreferencesIssue: Hashable, Sendable {
    case workIntervalOutOfRange(BreakKind)
    case breakDurationOutOfRange(BreakKind)
    case longBreakShorterThanShortBreak
    case transparencyOutOfRange
}

/// Persisted break, appearance, and language settings.
///
/// Launch-at-login status is read from Service Management rather than stored here.
struct AppPreferences: Codable, Equatable, Sendable {
    var shortBreak: BreakConfiguration = .defaultShort
    var longBreak: BreakConfiguration = .defaultLong
    var appearance = AppearanceSettings()
    var language: AppLanguage = .english

    var breakConfigurations: [BreakConfiguration] { [shortBreak, longBreak] }

    subscript(kind: BreakKind) -> BreakConfiguration {
        get { kind == .short ? shortBreak : longBreak }
        set {
            switch kind {
            case .short: shortBreak = newValue
            case .long: longBreak = newValue
            }
        }
    }

    init() {}

    func validate() -> [PreferencesIssue] {
        var issues: [PreferencesIssue] = []
        for configuration in breakConfigurations {
            let minutes = BreakConfiguration.workIntervalMinutesRange
            if configuration.workIntervalSeconds % 60 != 0
                || !minutes.contains(configuration.workIntervalSeconds / 60) {
                issues.append(.workIntervalOutOfRange(configuration.kind))
            }
            if !BreakConfiguration.breakDurationSecondsRange.contains(configuration.breakDurationSeconds) {
                issues.append(.breakDurationOutOfRange(configuration.kind))
            }
        }
        if longBreak.breakDurationSeconds < shortBreak.breakDurationSeconds {
            issues.append(.longBreakShorterThanShortBreak)
        }
        if !AppearanceSettings.transparencyRange.contains(appearance.transparency) {
            issues.append(.transparencyOutOfRange)
        }
        return issues
    }

    /// Decodes stored values, replacing anything missing, corrupted, or invalid with defaults.
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        func configuration(_ key: CodingKeys, _ kind: BreakKind) -> BreakConfiguration {
            guard var stored = try? container.decodeIfPresent(BreakConfiguration.self, forKey: key) else {
                return .default(for: kind)
            }
            let fallback = BreakConfiguration.default(for: kind)
            stored.kind = kind
            if stored.workIntervalSeconds % 60 != 0
                || !BreakConfiguration.workIntervalMinutesRange.contains(stored.workIntervalSeconds / 60) {
                stored.workIntervalSeconds = fallback.workIntervalSeconds
            }
            if !BreakConfiguration.breakDurationSecondsRange.contains(stored.breakDurationSeconds) {
                stored.breakDurationSeconds = fallback.breakDurationSeconds
            }
            return stored
        }
        shortBreak = configuration(.shortBreak, .short)
        longBreak = configuration(.longBreak, .long)
        if longBreak.breakDurationSeconds < shortBreak.breakDurationSeconds {
            shortBreak.breakDurationSeconds = BreakConfiguration.defaultShort.breakDurationSeconds
            longBreak.breakDurationSeconds = BreakConfiguration.defaultLong.breakDurationSeconds
        }
        appearance = (try? container.decodeIfPresent(AppearanceSettings.self, forKey: .appearance)) ?? AppearanceSettings()
        let identifier = try? container.decodeIfPresent(String.self, forKey: .language)
        language = AppLanguage(identifier: identifier)
    }
}

extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}

extension Character {
    var isASCIIDigit: Bool { ("0"..."9").contains(self) }
}
