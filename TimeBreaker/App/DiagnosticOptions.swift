import Foundation
import os

/// Command-line overrides used for runtime validation, for example:
///
///     open TimeBreaker.app --args -TBShortWorkSeconds 30 -TBShortBreakSeconds 10
///
/// Values come only from the launch arguments and are not written to preferences unless the
/// user later edits Settings during the same run.
struct DiagnosticOptions: Sendable {
    var workSeconds: [BreakKind: Int] = [:]
    var breakSeconds: [BreakKind: Int] = [:]
    var skipAllowed: [BreakKind: Bool] = [:]
    /// Holds a `userInitiatedAllowingIdleSystemSleep` activity while waiting for a deadline.
    var holdsSchedulingActivity = false
    var language: AppLanguage?
    var transparency: Int?
    var fadeInSeconds: Double?
    var fadeOutSeconds: Double?
    var layout: ImageLayout?
    var color: RGBColor?
    /// An image the sandbox can read, imported through the normal pipeline at launch.
    var backgroundImagePath: String?
    /// The Settings section shown first.
    var settingsSection: SettingsView.Section?

    var isActive: Bool {
        !workSeconds.isEmpty || !breakSeconds.isEmpty || !skipAllowed.isEmpty || language != nil
            || transparency != nil || fadeInSeconds != nil || fadeOutSeconds != nil
            || layout != nil || color != nil || backgroundImagePath != nil
    }

    init() {}

    init(defaults: UserDefaults) {
        let arguments = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
        func integer(_ key: String) -> Int? {
            guard let value = arguments[key] else { return nil }
            let parsed = (value as? NSNumber)?.intValue ?? (value as? String).flatMap { Int($0) }
            return parsed.flatMap { $0 > 0 ? $0 : nil }
        }
        func boolean(_ key: String) -> Bool? {
            guard let value = arguments[key] else { return nil }
            return (value as? NSNumber)?.boolValue ?? (value as? NSString)?.boolValue
        }
        for kind in BreakKind.allCases {
            let prefix = kind == .short ? "TBShort" : "TBLong"
            workSeconds[kind] = integer("\(prefix)WorkSeconds")
            breakSeconds[kind] = integer("\(prefix)BreakSeconds")
            skipAllowed[kind] = boolean("\(prefix)AllowsSkip")
        }
        holdsSchedulingActivity = boolean("TBSchedulingActivity") ?? false
        language = (arguments["TBLanguage"] as? String).flatMap(AppLanguage.init(rawValue:))
        transparency = (arguments["TBTransparency"] as? String).flatMap(AppearanceSettings.parseTransparency)
        func fadeSeconds(_ key: String) -> Double? {
            (arguments[key] as? String).flatMap(Double.init).flatMap {
                AppearanceSettings.fadeDurationRange.contains($0) ? $0 : nil
            }
        }
        fadeInSeconds = fadeSeconds("TBFadeInSeconds")
        fadeOutSeconds = fadeSeconds("TBFadeOutSeconds")
        layout = (arguments["TBLayout"] as? String).flatMap(ImageLayout.init(rawValue:))
        if let hex = arguments["TBColor"] as? String, hex.count == 6, let value = Int(hex, radix: 16) {
            color = RGBColor(
                red: Double(value >> 16 & 0xFF) / 255,
                green: Double(value >> 8 & 0xFF) / 255,
                blue: Double(value & 0xFF) / 255
            )
        }
        backgroundImagePath = arguments["TBBackgroundImage"] as? String
        settingsSection = (arguments["TBSettingsTab"] as? String).flatMap(SettingsView.Section.init(rawValue:))
    }

    /// Applies appearance and language overrides in memory.
    func apply(to preferences: AppPreferences, imageStore: BackgroundImageStore) -> AppPreferences {
        var preferences = preferences
        if let language { preferences.language = language }
        if let transparency { preferences.appearance.transparency = transparency }
        if let fadeInSeconds { preferences.appearance.fadeInDurationSeconds = fadeInSeconds }
        if let fadeOutSeconds { preferences.appearance.fadeOutDurationSeconds = fadeOutSeconds }
        if let layout { preferences.appearance.layout = layout }
        if let color { preferences.appearance.color = color }
        if let backgroundImagePath {
            do {
                preferences.appearance.image = try imageStore.importImage(from: URL(filePath: backgroundImagePath))
                preferences.appearance.source = .image
            } catch {
                Logger(subsystem: Log.subsystem, category: "App")
                    .error("Diagnostic background import failed: \(String(describing: error), privacy: .public)")
            }
        }
        return preferences
    }

    func apply(to configurations: [BreakConfiguration]) -> [BreakConfiguration] {
        configurations.map { configuration in
            var configuration = configuration
            if let seconds = workSeconds[configuration.kind] {
                configuration.workIntervalSeconds = seconds
            }
            if let seconds = breakSeconds[configuration.kind] {
                configuration.breakDurationSeconds = seconds
            }
            if let allowed = skipAllowed[configuration.kind] {
                configuration.allowsSkip = allowed
            }
            return configuration
        }
    }
}
