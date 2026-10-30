import Foundation
import os

/// Persists validated preferences in `UserDefaults`.
///
/// Only configuration is stored: never monotonic instants, countdown values, or image bytes.
struct PreferencesStore {
    static let key = "preferences.v1"

    private let defaults: UserDefaults
    private let logger = Logger(subsystem: Log.subsystem, category: "Preferences")

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Loads stored preferences, recovering corrupted or invalid values to defaults.
    func load() -> AppPreferences {
        guard let data = defaults.data(forKey: Self.key) else { return AppPreferences() }
        do {
            return try JSONDecoder().decode(AppPreferences.self, from: data)
        } catch {
            logger.error("Stored preferences were unreadable; using defaults: \(error.localizedDescription, privacy: .public)")
            return AppPreferences()
        }
    }

    /// Saves preferences that passed validation.
    func save(_ preferences: AppPreferences) {
        precondition(preferences.validate().isEmpty, "Only validated preferences may be saved")
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            defaults.set(try encoder.encode(preferences), forKey: Self.key)
        } catch {
            logger.error("Could not encode preferences: \(error.localizedDescription, privacy: .public)")
        }
    }
}
