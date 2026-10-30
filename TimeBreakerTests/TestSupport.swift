import Foundation
@testable import TimeBreaker

/// A fixed timeline for deterministic tests: `t(90)` is 90 seconds after the start.
struct Timeline {
    let origin = ContinuousClock.now

    func t(_ seconds: Int) -> Instant {
        origin + .seconds(seconds)
    }
}

/// A controllable clock for scheduler tests.
@MainActor
final class ManualClock {
    var now: Instant

    init(_ now: Instant) {
        self.now = now
    }
}

func configurations(
    short: (work: Int, rest: Int, skip: Bool) = (1200, 20, true),
    long: (work: Int, rest: Int, skip: Bool) = (3600, 300, true),
    shortEnabled: Bool = true,
    longEnabled: Bool = true
) -> [BreakConfiguration] {
    [
        BreakConfiguration(kind: .short, isEnabled: shortEnabled, workIntervalSeconds: short.work, breakDurationSeconds: short.rest, allowsSkip: short.skip),
        BreakConfiguration(kind: .long, isEnabled: longEnabled, workIntervalSeconds: long.work, breakDurationSeconds: long.rest, allowsSkip: long.skip),
    ]
}

/// An isolated defaults suite so tests never touch the app's real preferences.
func makeTestDefaults() -> UserDefaults {
    let name = "TimeBreakerTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: name)!
    defaults.removePersistentDomain(forName: name)
    return defaults
}

func makeTemporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appending(path: "TimeBreakerTests-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}
