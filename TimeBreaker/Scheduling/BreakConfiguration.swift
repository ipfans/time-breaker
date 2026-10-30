import Foundation

/// Identifies one of the two break plans.
enum BreakKind: String, Codable, CaseIterable, Sendable {
    case short
    case long
}

/// Enablement, timing, and skip permission for one break plan.
///
/// Durations are stored as whole seconds so that persisted values stay readable and
/// independent of `Duration`'s encoding.
struct BreakConfiguration: Codable, Equatable, Sendable {
    var kind: BreakKind
    var isEnabled: Bool
    /// Working time before the break starts, excluding breaks and suspension.
    var workIntervalSeconds: Int
    /// Rest time required to complete the break.
    var breakDurationSeconds: Int
    var allowsSkip: Bool

    var workInterval: Duration { .seconds(workIntervalSeconds) }
    var breakDuration: Duration { .seconds(breakDurationSeconds) }

    static let defaultShort = BreakConfiguration(
        kind: .short,
        isEnabled: true,
        workIntervalSeconds: 20 * 60,
        breakDurationSeconds: 20,
        allowsSkip: true
    )

    static let defaultLong = BreakConfiguration(
        kind: .long,
        isEnabled: true,
        workIntervalSeconds: 60 * 60,
        breakDurationSeconds: 5 * 60,
        allowsSkip: true
    )

    static func `default`(for kind: BreakKind) -> BreakConfiguration {
        switch kind {
        case .short: defaultShort
        case .long: defaultLong
        }
    }

    /// Valid work intervals: 1 minute to 12 hours, in whole minutes.
    static let workIntervalMinutesRange = 1...720
    /// Valid break durations: 5 seconds to 60 minutes.
    static let breakDurationSecondsRange = 5...3600

    /// Converts a work-interval field value, or returns `nil` if it is out of range.
    static func workIntervalSeconds(minutes: Int) -> Int? {
        workIntervalMinutesRange.contains(minutes) ? minutes * 60 : nil
    }

    /// Combines break-duration fields, or returns `nil` if either field is out of its own range.
    /// The total is validated separately against `breakDurationSecondsRange`.
    static func breakDurationSeconds(minutes: Int, seconds: Int) -> Int? {
        guard (0...breakDurationSecondsRange.upperBound / 60).contains(minutes), (0...59).contains(seconds) else {
            return nil
        }
        return minutes * 60 + seconds
    }
}
