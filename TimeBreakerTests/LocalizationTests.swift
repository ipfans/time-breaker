import Foundation
import Testing
@testable import TimeBreaker

@MainActor
@Suite("Localization")
struct LocalizationTests {
    /// Compiled resources for one language, read from the built app bundle.
    struct CompiledStrings {
        let strings: [String: String]
        let plurals: [String: [String: String]]

        init(language: AppLanguage) throws {
            let lproj = try #require(Bundle.main.url(forResource: language.rawValue, withExtension: "lproj"))
            strings = (NSDictionary(contentsOf: lproj.appending(path: "Localizable.strings")) as? [String: String]) ?? [:]
            let dictionary = (NSDictionary(contentsOf: lproj.appending(path: "Localizable.stringsdict")) as? [String: [String: Any]]) ?? [:]
            plurals = dictionary.mapValues { entry in
                let variable = entry.values.compactMap { $0 as? [String: String] }.first ?? [:]
                return variable.filter { !$0.key.hasPrefix("NSString") }
            }
        }

        /// Every value a key can produce, including each plural variant.
        func values(for key: String) -> [String] {
            if let value = strings[key] { return [value] }
            return plurals[key].map { Array($0.values) } ?? []
        }
    }

    static func placeholders(in value: String) -> [String] {
        let pattern = /%(?:(\d+)\$)?(?:ll|l)?([@dDiuUxXfeEgGcCsSp])/
        return value.matches(of: pattern).map { match in
            let position = match.output.1.map { "\($0)$" } ?? ""
            return "\(position)\(match.output.2)"
        }.sorted()
    }

    @Test func everyLanguageShipsInTheBundle() {
        let bundled = Set(Bundle.main.localizations)
        for language in AppLanguage.allCases {
            #expect(bundled.contains(language.rawValue), "Missing \(language.rawValue).lproj")
        }
    }

    @Test(arguments: AppLanguage.allCases)
    func everyKeyIsTranslated(language: AppLanguage) throws {
        let compiled = try CompiledStrings(language: language)
        for key in L10n.allCases {
            let values = compiled.values(for: key.rawValue)
            #expect(!values.isEmpty, "\(language.rawValue) lacks \(key.rawValue)")
            for value in values {
                #expect(!value.isEmpty && value != key.rawValue, "\(language.rawValue) exposes key \(key.rawValue)")
            }
        }
    }

    @Test(arguments: AppLanguage.allCases)
    func placeholdersMatchEnglish(language: AppLanguage) throws {
        let english = try CompiledStrings(language: .english)
        let compiled = try CompiledStrings(language: language)
        for key in L10n.allCases {
            let expected = english.values(for: key.rawValue).map(Self.placeholders(in:)).first ?? []
            for value in compiled.values(for: key.rawValue) {
                #expect(Self.placeholders(in: value) == expected, "\(language.rawValue) \(key.rawValue): \(value)")
            }
        }
    }

    @Test func noLiteralPercentSignsOutsidePlaceholders() throws {
        for language in AppLanguage.allCases {
            let compiled = try CompiledStrings(language: language)
            for key in L10n.allCases {
                for value in compiled.values(for: key.rawValue) {
                    let stripped = value.replacing(/%(?:\d+\$)?(?:ll|l)?[@dDiuUxXfeEgGcCsSp]/, with: "")
                    #expect(!stripped.contains("%"), "\(language.rawValue) \(key.rawValue)")
                }
            }
        }
    }

    @Test func localizerResolvesEveryKeyInEveryLanguage() {
        let localizer = Localizer(language: .english)
        for language in AppLanguage.allCases {
            localizer.setLanguage(language)
            for key in L10n.allCases {
                let value = localizer.string(key)
                #expect(!value.isEmpty && value != key.rawValue)
            }
        }
    }

    @Test func languageChangesApplyImmediately() {
        let localizer = Localizer(language: .english)
        #expect(localizer.string(.overlayPause) == "Pause")
        localizer.setLanguage(.japanese)
        #expect(localizer.string(.overlayPause) == "一時停止")
        localizer.setLanguage(.portuguesePortugal)
        #expect(localizer.string(.overlayPause) == "Suspender")
        #expect(localizer.string(.layoutScaleToFit) == "Ajustar ao ecrã")
    }

    @Test func chineseVariantsAreDistinct() {
        let localizer = Localizer(language: .simplifiedChinese)
        let simplified = localizer.string(.menuSettings)
        localizer.setLanguage(.traditionalChinese)
        #expect(simplified != localizer.string(.menuSettings))
        #expect(AppLanguage.simplifiedChinese.nativeName != AppLanguage.traditionalChinese.nativeName)
    }

    @Test func nativeNamesAreUnique() {
        #expect(Set(AppLanguage.allCases.map(\.nativeName)).count == AppLanguage.allCases.count)
        #expect(AppLanguage.portuguesePortugal.nativeName == "Português (Portugal)")
    }

    @Test(arguments: [nil, "", "xx", "pt", "pt-BR", "zh", "EN"])
    func unsupportedIdentifiersFallBackToEnglish(identifier: String?) {
        #expect(AppLanguage(identifier: identifier) == .english)
    }

    @Test func firstLaunchIsEnglishAndSelectionPersists() {
        let defaults = makeTestDefaults()
        let store = PreferencesStore(defaults: defaults)
        #expect(store.load().language == .english)

        var preferences = AppPreferences()
        preferences.language = .korean
        store.save(preferences)
        #expect(PreferencesStore(defaults: defaults).load().language == .korean)
    }

    @Test func missingTranslationsFallBackToEnglishWithoutExposingKeys() throws {
        let bundle = try Self.makeBundle(languages: [
            "en": ["app.name": "English Name"],
            // Untranslated catalog entries compile to their key.
            "fr": ["app.name": "app.name"],
        ])
        let localizer = Localizer(language: .french, resourceBundle: bundle)
        #expect(localizer.string(.appName) == "English Name")
        #expect(localizer.string(.menuQuit) == "")

        let unbundledLanguage = Localizer(language: .korean, resourceBundle: bundle)
        #expect(unbundledLanguage.string(.appName) == "English Name")
    }

    @Test func pluralsFollowEachLanguagesRules() {
        let localizer = Localizer(language: .english)
        #expect(localizer.format(.menuShortInMinutes, 1) == "Short break in 1 minute")
        #expect(localizer.format(.menuShortInMinutes, 2) == "Short break in 2 minutes")
        localizer.setLanguage(.portuguesePortugal)
        #expect(localizer.format(.menuLongInMinutes, 1) == "Pausa longa daqui a 1 minuto")
        #expect(localizer.format(.menuLongInMinutes, 40) == "Pausa longa daqui a 40 minutos")
        localizer.setLanguage(.french)
        #expect(localizer.format(.menuShortInMinutes, 1) == "Pause courte dans 1 minute")
        #expect(localizer.format(.menuShortInMinutes, 5) == "Pause courte dans 5 minutes")
        localizer.setLanguage(.japanese)
        #expect(localizer.format(.menuShortInMinutes, 1) == "1分後に短い休憩")
    }

    @Test func durationsAndCountdownsUseTheAppLanguage() {
        let localizer = Localizer(language: .english)
        #expect(localizer.duration(seconds: 20) == "20 seconds")
        #expect(localizer.duration(seconds: 60) == "1 minute")
        #expect(localizer.duration(seconds: 90) == "1 minute, 30 seconds")
        #expect(localizer.countdown(seconds: 300) == "5:00")
        #expect(localizer.countdown(seconds: 3600) == "1:00:00")
        localizer.setLanguage(.portuguesePortugal)
        #expect(localizer.duration(seconds: 1200) == "20 minutos")
        localizer.setLanguage(.japanese)
        #expect(localizer.duration(seconds: 20) == "20秒")
    }

    @Test func positionalArgumentsKeepTheirMeaning() {
        let localizer = Localizer(language: .japanese)
        let summary = localizer.format(.breaksSummary, "WORK", "REST")
        #expect(summary == "WORK作業したら、REST休憩します。")
        localizer.setLanguage(.korean)
        #expect(localizer.format(.breaksSummary, "WORK", "REST") == "WORK 동안 작업한 후 REST 동안 휴식합니다.")
    }

    @Test func statusMenuLinesDescribeEachState() {
        let time = Timeline()
        let localizer = Localizer(language: .english)
        var snapshot = SchedulerSnapshot(
            phase: .working,
            plans: [.short: .running(deadline: time.t(61)), .long: .frozen(remaining: .seconds(30))],
            activeBreak: nil,
            isManuallyPaused: false,
            systemSuspensionReasons: []
        )
        #expect(StatusMenuText.planLine(.short, snapshot: snapshot, now: time.t(0), localizer: localizer) == "Short break in 2 minutes")
        #expect(StatusMenuText.planLine(.long, snapshot: snapshot, now: time.t(0), localizer: localizer) == "Long break in less than a minute")
        #expect(StatusMenuText.statusLine(snapshot: snapshot, localizer: localizer) == nil)

        snapshot.plans[.long] = nil
        snapshot.activeBreak = ActiveBreak(id: 3, kind: .short, duration: .seconds(20), allowsSkip: false, timing: .running(deadline: time.t(15)))
        snapshot.phase = .onBreak
        #expect(StatusMenuText.planLine(.short, snapshot: snapshot, now: time.t(0), localizer: localizer) == "Short break: 0:15 left")
        #expect(StatusMenuText.planLine(.long, snapshot: snapshot, now: time.t(0), localizer: localizer) == "Long break is off")

        snapshot.isManuallyPaused = true
        snapshot.systemSuspensionReasons = [.systemSleep]
        #expect(StatusMenuText.statusLine(snapshot: snapshot, localizer: localizer) == "Paused")
        snapshot.isManuallyPaused = false
        #expect(StatusMenuText.statusLine(snapshot: snapshot, localizer: localizer) == "Paused while you’re away")
    }

    /// Builds a minimal resource bundle with the given `.strings` contents.
    static func makeBundle(languages: [String: [String: String]]) throws -> Bundle {
        let root = try makeTemporaryDirectory().appending(path: "Fake.bundle")
        for (language, strings) in languages {
            let lproj = root.appending(path: "\(language).lproj")
            try FileManager.default.createDirectory(at: lproj, withIntermediateDirectories: true)
            let data = try PropertyListSerialization.data(fromPropertyList: strings, format: .binary, options: 0)
            try data.write(to: lproj.appending(path: "Localizable.strings"))
        }
        return try #require(Bundle(url: root))
    }
}
