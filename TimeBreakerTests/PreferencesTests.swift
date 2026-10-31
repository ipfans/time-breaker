import Foundation
import Testing
@testable import TimeBreaker

@Suite("Preferences")
struct PreferencesTests {
    @Test func defaultsMatchTheProductDefaults() {
        let preferences = AppPreferences()
        #expect(preferences.validate().isEmpty)
        #expect(preferences.shortBreak == BreakConfiguration(kind: .short, isEnabled: true, workIntervalSeconds: 1200, breakDurationSeconds: 20, allowsSkip: true))
        #expect(preferences.longBreak == BreakConfiguration(kind: .long, isEnabled: true, workIntervalSeconds: 3600, breakDurationSeconds: 300, allowsSkip: true))
        #expect(preferences.appearance.source == .color)
        #expect(preferences.appearance.transparency == 0)
        #expect(preferences.appearance.layout == .scaleToFit)
        #expect(preferences.appearance.fadeInDurationSeconds == 0.5)
        #expect(preferences.appearance.fadeOutDurationSeconds == 0.5)
        #expect(preferences.language == .english)
    }

    @Test(arguments: [0, 30, 90, 721 * 60])
    func invalidWorkIntervalsAreRejected(seconds: Int) {
        var preferences = AppPreferences()
        preferences.shortBreak.workIntervalSeconds = seconds
        #expect(preferences.validate() == [.workIntervalOutOfRange(.short)])
    }

    @Test(arguments: [4, 3601, -1])
    func invalidBreakDurationsAreRejected(seconds: Int) {
        var preferences = AppPreferences()
        preferences.longBreak.breakDurationSeconds = seconds
        #expect(preferences.validate().contains(.breakDurationOutOfRange(.long)))
    }

    @Test func fieldInputOutsideItsRangeIsRejectedWithoutOverflow() {
        #expect(BreakConfiguration.workIntervalSeconds(minutes: 20) == 1200)
        #expect(BreakConfiguration.workIntervalSeconds(minutes: 0) == nil)
        #expect(BreakConfiguration.workIntervalSeconds(minutes: 721) == nil)
        #expect(BreakConfiguration.workIntervalSeconds(minutes: .max) == nil)
        #expect(BreakConfiguration.workIntervalSeconds(minutes: .min) == nil)

        #expect(BreakConfiguration.breakDurationSeconds(minutes: 1, seconds: 30) == 90)
        #expect(BreakConfiguration.breakDurationSeconds(minutes: 1, seconds: 90) == nil)
        #expect(BreakConfiguration.breakDurationSeconds(minutes: -1, seconds: 30) == nil)
        #expect(BreakConfiguration.breakDurationSeconds(minutes: 0, seconds: -5) == nil)
        #expect(BreakConfiguration.breakDurationSeconds(minutes: .max, seconds: 0) == nil)
        #expect(BreakConfiguration.breakDurationSeconds(minutes: 61, seconds: 0) == nil)
    }

    @Test func longBreakMustNotBeShorterThanShortBreak() {
        var preferences = AppPreferences()
        preferences.shortBreak.breakDurationSeconds = 120
        preferences.longBreak.breakDurationSeconds = 60
        #expect(preferences.validate() == [.longBreakShorterThanShortBreak])

        preferences.longBreak.breakDurationSeconds = 120
        #expect(preferences.validate().isEmpty)
    }

    @Test(arguments: [0, 1, 50, 99])
    func transparencyBoundariesAreAccepted(value: Int) {
        var preferences = AppPreferences()
        preferences.appearance.transparency = value
        #expect(preferences.validate().isEmpty)
        #expect(abs(preferences.appearance.backgroundOpacity - (1 - Double(value) / 100)) < 1e-9)
    }

    @Test(arguments: [-1, 100])
    func transparencyOutsideRangeIsRejected(value: Int) {
        var preferences = AppPreferences()
        preferences.appearance.transparency = value
        #expect(preferences.validate() == [.transparencyOutOfRange])
    }

    @Test func opacityAtTheLimitsKeepsTheBackgroundVisible() {
        var appearance = AppearanceSettings()
        appearance.transparency = 0
        #expect(appearance.backgroundOpacity == 1)
        appearance.transparency = 99
        #expect(abs(appearance.backgroundOpacity - 0.01) < 1e-9)
    }

    @Test(arguments: [0.5, 0.6, 1.7, 3.0])
    func fadeDurationBoundariesAreAccepted(seconds: Double) {
        var preferences = AppPreferences()
        preferences.appearance.fadeInDurationSeconds = seconds
        preferences.appearance.fadeOutDurationSeconds = seconds
        #expect(preferences.validate().isEmpty)
    }

    @Test(arguments: [0.4, 0.49, 3.01, 3.1, 0, -1, .nan, .infinity])
    func fadeDurationsOutsideRangeAreRejected(seconds: Double) {
        var preferences = AppPreferences()
        preferences.appearance.fadeInDurationSeconds = seconds
        #expect(preferences.validate() == [.fadeInDurationOutOfRange])

        preferences = AppPreferences()
        preferences.appearance.fadeOutDurationSeconds = seconds
        #expect(preferences.validate() == [.fadeOutDurationOutOfRange])
    }

    @Test(arguments: [("0", 0), ("1", 1), ("50", 50), ("99", 99), (" 7 ", 7)])
    func transparencyTextAcceptsWholeNumbers(text: String, expected: Int) {
        #expect(AppearanceSettings.parseTransparency(text) == expected)
    }

    @Test(arguments: ["-1", "100", "50.5", "abc", "", "1e1", "+5", "٥", "0x10"])
    func transparencyTextRejectsEverythingElse(text: String) {
        #expect(AppearanceSettings.parseTransparency(text) == nil)
    }

    // MARK: Persistence

    @Test func savedPreferencesRoundTrip() {
        let store = PreferencesStore(defaults: makeTestDefaults())
        var preferences = AppPreferences()
        preferences.shortBreak.workIntervalSeconds = 25 * 60
        preferences.longBreak.allowsSkip = false
        preferences.appearance.transparency = 42
        preferences.appearance.layout = .center
        preferences.appearance.fadeInDurationSeconds = 1.2
        preferences.appearance.fadeOutDurationSeconds = 3
        preferences.language = .portuguesePortugal
        store.save(preferences)

        #expect(store.load() == preferences)
    }

    @Test func missingPreferencesUseEnglishDefaults() {
        let store = PreferencesStore(defaults: makeTestDefaults())
        #expect(store.load() == AppPreferences())
    }

    @Test func corruptedDataRecoversToDefaults() {
        let defaults = makeTestDefaults()
        defaults.set(Data("not json".utf8), forKey: PreferencesStore.key)
        #expect(PreferencesStore(defaults: defaults).load() == AppPreferences())
    }

    @Test func invalidStoredFieldsRecoverIndividually() {
        let defaults = makeTestDefaults()
        let json = """
        {
          "shortBreak": {"kind": "short", "isEnabled": false, "workIntervalSeconds": 0, "breakDurationSeconds": 30, "allowsSkip": false},
          "longBreak": {"kind": "long", "isEnabled": true, "workIntervalSeconds": 2700, "breakDurationSeconds": 999999, "allowsSkip": true},
          "appearance": {"source": "image", "color": {"red": 7, "green": 0, "blue": 0}, "layout": "diagonal", "transparency": 150,
                         "fadeInDurationSeconds": 0.1, "fadeOutDurationSeconds": "slow",
                         "image": {"identifier": "../../secret.png", "pixelWidth": 10, "pixelHeight": 10}},
          "language": "pt-BR"
        }
        """
        defaults.set(Data(json.utf8), forKey: PreferencesStore.key)
        let loaded = PreferencesStore(defaults: defaults).load()

        #expect(loaded.shortBreak == BreakConfiguration(kind: .short, isEnabled: false, workIntervalSeconds: 1200, breakDurationSeconds: 30, allowsSkip: false))
        #expect(loaded.longBreak == BreakConfiguration(kind: .long, isEnabled: true, workIntervalSeconds: 2700, breakDurationSeconds: 300, allowsSkip: true))
        #expect(loaded.appearance == AppearanceSettings())
        #expect(loaded.language == .english)
        #expect(loaded.validate().isEmpty)
    }

    @Test func storedAppearanceWithoutFadeDurationsKeepsItsOtherValues() {
        let defaults = makeTestDefaults()
        let json = """
        {"appearance": {"source": "color", "color": {"red": 1, "green": 0, "blue": 0}, "layout": "center", "transparency": 40}}
        """
        defaults.set(Data(json.utf8), forKey: PreferencesStore.key)
        let appearance = PreferencesStore(defaults: defaults).load().appearance
        #expect(appearance.transparency == 40)
        #expect(appearance.layout == .center)
        #expect(appearance.fadeInDurationSeconds == 0.5)
        #expect(appearance.fadeOutDurationSeconds == 0.5)
    }

    @Test func storedLongBreakShorterThanShortRestoresDefaultDurations() {
        let defaults = makeTestDefaults()
        let json = """
        {"shortBreak": {"kind": "short", "isEnabled": true, "workIntervalSeconds": 1200, "breakDurationSeconds": 600, "allowsSkip": true},
         "longBreak": {"kind": "long", "isEnabled": true, "workIntervalSeconds": 3600, "breakDurationSeconds": 60, "allowsSkip": true}}
        """
        defaults.set(Data(json.utf8), forKey: PreferencesStore.key)
        let loaded = PreferencesStore(defaults: defaults).load()
        #expect(loaded.shortBreak.breakDurationSeconds == 20)
        #expect(loaded.longBreak.breakDurationSeconds == 300)
    }

    @Test func persistedFormatContainsNoTimingState() throws {
        let defaults = makeTestDefaults()
        PreferencesStore(defaults: defaults).save(AppPreferences())
        let data = try #require(defaults.data(forKey: PreferencesStore.key))
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(Set(object.keys) == ["shortBreak", "longBreak", "appearance", "language"])
    }

    // MARK: Applying changes

    @MainActor
    @Test func invalidChangesKeepTheLastValidPreferences() throws {
        let harness = try AppModelHarness()
        var candidate = harness.model.preferences
        candidate.shortBreak.workIntervalSeconds = 0
        let issues = harness.model.apply(candidate)

        #expect(issues == [.workIntervalOutOfRange(.short)])
        #expect(harness.model.preferences == AppPreferences())
        #expect(harness.store.load() == AppPreferences())
    }

    @MainActor
    @Test func invalidFadeDurationsKeepTheLastValidPreferences() throws {
        let harness = try AppModelHarness()
        var candidate = harness.model.preferences
        candidate.appearance.fadeInDurationSeconds = 2
        candidate.appearance.fadeOutDurationSeconds = 3.5
        #expect(harness.model.apply(candidate) == [.fadeOutDurationOutOfRange])
        #expect(harness.model.preferences == AppPreferences())

        candidate.appearance.fadeOutDurationSeconds = 3
        #expect(harness.model.apply(candidate).isEmpty)
        #expect(harness.store.load().appearance.fadeInDurationSeconds == 2)
        #expect(harness.store.load().appearance.fadeOutDurationSeconds == 3)
    }

    @MainActor
    @Test func appearanceAndLanguageChangesDoNotTouchTheActiveBreak() throws {
        let harness = try AppModelHarness(configs: configurations(short: (1200, 20, false)))
        harness.clock.now = harness.time.t(1200)
        harness.scheduler.deadlineReached(generation: harness.scheduler.generation)
        let before = harness.scheduler.snapshot
        let generation = harness.scheduler.generation
        #expect(before.activeBreak?.allowsSkip == false)

        var candidate = harness.model.preferences
        candidate.appearance.transparency = 99
        candidate.appearance.color = RGBColor(red: 1, green: 1, blue: 1)
        candidate.appearance.fadeInDurationSeconds = 2
        candidate.appearance.fadeOutDurationSeconds = 1.5
        candidate.language = .japanese
        #expect(harness.model.apply(candidate).isEmpty)

        #expect(harness.scheduler.snapshot == before)
        #expect(harness.scheduler.generation == generation)
        #expect(harness.model.localizer.language == .japanese)
        #expect(harness.store.load().language == .japanese)
    }

    @MainActor
    @Test func breakChangesReachTheScheduler() throws {
        let harness = try AppModelHarness()
        var candidate = harness.model.preferences
        candidate.shortBreak.workIntervalSeconds = 600
        #expect(harness.model.apply(candidate).isEmpty)
        #expect(harness.scheduler.snapshot.plans[.short] == .running(deadline: harness.time.t(600)))
    }
}

/// An `AppModel` wired to a manual-clock scheduler, isolated defaults, and a temporary image folder.
@MainActor
struct AppModelHarness {
    let time = Timeline()
    let clock: ManualClock
    let scheduler: BreakScheduler
    let store: PreferencesStore
    let model: AppModel

    init(configs: [BreakConfiguration] = configurations()) throws {
        let clock = ManualClock(time.t(0))
        self.clock = clock
        scheduler = BreakScheduler(
            configurations: configs,
            now: { clock.now },
            sleep: { _, _ in try await Task.sleep(for: .seconds(86_400)) }
        )
        store = PreferencesStore(defaults: makeTestDefaults())
        let localizer = Localizer(language: .english)
        let imageStore = BackgroundImageStore(directory: try makeTemporaryDirectory())
        let overlay = OverlayController(
            localizer: localizer,
            imageStore: imageStore,
            renderer: BackgroundImageRenderer(store: imageStore),
            appearance: AppearanceSettings(),
            actions: OverlayActions(pause: {}, skip: { _ in }, quit: {})
        )
        model = AppModel(
            preferences: AppPreferences(),
            store: store,
            localizer: localizer,
            imageStore: imageStore,
            diagnostics: DiagnosticOptions(),
            scheduler: scheduler,
            overlay: overlay
        )
    }
}
