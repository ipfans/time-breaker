import Foundation
import Testing
@testable import TimeBreaker

@Suite("Scheduling rules")
struct BreakEngineTests {
    let time = Timeline()
    func t(_ seconds: Int) -> Instant { time.t(seconds) }

    // MARK: Launch and transitions

    @Test func launchStartsFreshIntervalsForEnabledPlans() {
        let engine = BreakEngine(configurations: configurations(), now: t(0))
        #expect(engine.phase == .working)
        #expect(engine.plans[.short] == .running(deadline: t(1200)))
        #expect(engine.plans[.long] == .running(deadline: t(3600)))
        #expect(engine.nextDeadline == t(1200))
        #expect(engine.activeBreak == nil)
    }

    @Test func launchWithOnePlanDisabledSchedulesOnlyTheOther() {
        let engine = BreakEngine(configurations: configurations(shortEnabled: false), now: t(0))
        #expect(engine.plans[.short] == nil)
        #expect(engine.nextDeadline == t(3600))
    }

    @Test func evaluatingBeforeTheDeadlineDoesNothing() {
        var engine = BreakEngine(configurations: configurations(), now: t(0))
        #expect(engine.evaluate(at: t(1199)).isEmpty)
        #expect(engine.activeBreak == nil)
    }

    @Test func shortBreakStartsAndFreezesTheLongPlan() {
        var engine = BreakEngine(configurations: configurations(), now: t(0))
        let events = engine.evaluate(at: t(1200))

        #expect(events == [.breakStarted(1, .short)])
        let session = try! #require(engine.activeBreak)
        #expect(session.kind == .short)
        #expect(session.duration == .seconds(20))
        #expect(session.allowsSkip)
        #expect(session.timing == .running(deadline: t(1220)))
        #expect(engine.plans[.long] == .frozen(remaining: .seconds(2400)))
        #expect(engine.nextDeadline == t(1220))
    }

    @Test func completingShortBreakRestartsShortAndPreservesLongRemainder() {
        var engine = BreakEngine(configurations: configurations(), now: t(0))
        engine.evaluate(at: t(1200))
        let events = engine.evaluate(at: t(1220))

        #expect(events == [.breakCompleted(1, .short)])
        #expect(engine.phase == .working)
        #expect(engine.plans[.short] == .running(deadline: t(1220 + 1200)))
        // The 20-second break did not consume long-plan work time.
        #expect(engine.plans[.long] == .running(deadline: t(1220 + 2400)))
    }

    @Test func completingLongBreakRestartsBothPlans() {
        var engine = BreakEngine(configurations: configurations(long: (600, 300, true)), now: t(0))
        #expect(engine.evaluate(at: t(600)) == [.breakStarted(1, .long)])
        #expect(engine.evaluate(at: t(900)) == [.breakCompleted(1, .long)])
        #expect(engine.plans[.short] == .running(deadline: t(900 + 1200)))
        #expect(engine.plans[.long] == .running(deadline: t(900 + 600)))
    }

    @Test func bothPlansDueStartsExactlyOneLongBreak() {
        var engine = BreakEngine(configurations: configurations(short: (600, 20, true), long: (600, 300, true)), now: t(0))
        let events = engine.evaluate(at: t(605))

        #expect(events == [.breakStarted(1, .long)])
        #expect(engine.activeBreak?.kind == .long)
        #expect(engine.plans[.short] == .frozen(remaining: .zero))
    }

    @Test func completingLongBreakDoesNotQueueACatchUpShortBreak() {
        var engine = BreakEngine(configurations: configurations(short: (600, 20, true), long: (600, 300, true)), now: t(0))
        engine.evaluate(at: t(600))
        let events = engine.evaluate(at: t(900))

        #expect(events == [.breakCompleted(1, .long)])
        #expect(engine.activeBreak == nil)
        #expect(engine.plans[.short] == .running(deadline: t(1500)))
    }

    @Test func defaultScheduleAlignsLongBreakWithThirdShortBreak() {
        // Work time excludes breaks, so the long plan becomes due exactly when the third short
        // break would; only the long break starts.
        var engine = BreakEngine(configurations: configurations(), now: t(0))
        var started: [BreakKind] = []
        for _ in 0..<5 {
            guard let deadline = engine.nextDeadline else { break }
            for case .breakStarted(_, let kind) in engine.evaluate(at: deadline) {
                started.append(kind)
            }
        }
        #expect(started == [.short, .short, .long])
    }

    // MARK: Skip

    @Test(arguments: [true, false])
    func skippingLongBreakPreservesADueShortBreak(shortAllowsSkip: Bool) throws {
        var engine = BreakEngine(
            configurations: configurations(short: (600, 20, shortAllowsSkip), long: (600, 300, true)),
            now: t(0)
        )
        engine.evaluate(at: t(600))
        let longSession = try #require(engine.activeBreak)

        let events = try engine.skip(sessionID: longSession.id, at: t(610)).get()

        #expect(events == [.breakSkipped(longSession.id, .long), .breakStarted(2, .short)])
        let shortSession = try #require(engine.activeBreak)
        #expect(shortSession.kind == .short)
        #expect(shortSession.allowsSkip == shortAllowsSkip)
        // Only the skipped long plan restarted; it is frozen during the short break.
        #expect(engine.plans[.long] == .frozen(remaining: .seconds(600)))
    }

    @Test func lateSkipCompletesAFinishedBreakInsteadOfSkippingIt() throws {
        // Both plans were due, so the long break started with the short plan held at zero.
        var engine = BreakEngine(configurations: configurations(short: (600, 20, true), long: (600, 300, true)), now: t(0))
        engine.evaluate(at: t(600))

        // The countdown has reached zero but the deadline callback has not run yet.
        let events = try engine.skip(sessionID: 1, at: t(901)).get()

        #expect(events == [.breakCompleted(1, .long)])
        #expect(engine.activeBreak == nil)
        #expect(engine.plans[.short] == .running(deadline: t(901 + 600)))
        #expect(engine.plans[.long] == .running(deadline: t(901 + 600)))
    }

    @Test func skippingShortBreakRestartsOnlyTheShortPlan() throws {
        var engine = BreakEngine(configurations: configurations(), now: t(0))
        engine.evaluate(at: t(1200))
        _ = try engine.skip(sessionID: 1, at: t(1205)).get()

        #expect(engine.activeBreak == nil)
        #expect(engine.plans[.short] == .running(deadline: t(1205 + 1200)))
        #expect(engine.plans[.long] == .running(deadline: t(1205 + 2400)))
    }

    @Test func skipIsRejectedWhenTheSessionForbidsIt() {
        var engine = BreakEngine(configurations: configurations(short: (1200, 20, false)), now: t(0))
        engine.evaluate(at: t(1200))
        let session = engine.activeBreak

        #expect(throws: SkipRejection.notAllowed) { try engine.skip(sessionID: 1, at: t(1201)).get() }
        #expect(engine.activeBreak == session)

        // Pause still works for an unskippable break.
        engine.pause(at: t(1202))
        #expect(engine.isManuallyPaused)
        #expect(engine.snapshot().isPresentingBreak == false)
        #expect(engine.activeBreak?.id == session?.id)
    }

    @Test func repeatedOrStaleSkipRequestsAreHarmless() throws {
        var engine = BreakEngine(configurations: configurations(), now: t(0))
        engine.evaluate(at: t(1200))

        #expect(throws: SkipRejection.noMatchingBreak) { try engine.skip(sessionID: 99, at: t(1201)).get() }
        _ = try engine.skip(sessionID: 1, at: t(1201)).get()
        let afterFirstSkip = engine.snapshot()
        // A second display delivering the same request changes nothing.
        #expect(throws: SkipRejection.noMatchingBreak) { try engine.skip(sessionID: 1, at: t(1201)).get() }
        #expect(engine.snapshot() == afterFirstSkip)
    }

    // MARK: Manual pause

    @Test func pauseWhileWorkingFreezesRemainingWorkTime() {
        var engine = BreakEngine(configurations: configurations(), now: t(0))
        engine.pause(at: t(100))

        #expect(engine.plans[.short] == .frozen(remaining: .seconds(1100)))
        #expect(engine.plans[.long] == .frozen(remaining: .seconds(3500)))
        #expect(engine.nextDeadline == nil)
        #expect(engine.evaluate(at: t(99_999)).isEmpty)

        engine.resume(at: t(5000))
        #expect(engine.plans[.short] == .running(deadline: t(6100)))
        #expect(engine.plans[.long] == .running(deadline: t(8500)))
    }

    @Test func pauseDuringBreakHidesItAndResumeContinuesTheSameSession() {
        var engine = BreakEngine(configurations: configurations(), now: t(0))
        engine.evaluate(at: t(1200))
        engine.pause(at: t(1205))

        let paused = engine.snapshot()
        #expect(paused.isPresentingBreak == false)
        #expect(paused.activeBreak?.timing == .frozen(remaining: .seconds(15)))

        engine.resume(at: t(2000))
        #expect(engine.activeBreak?.id == 1)
        #expect(engine.activeBreak?.timing == .running(deadline: t(2015)))
        #expect(engine.snapshot().isPresentingBreak)
    }

    @Test func manualPauseAloneEarnsNoNaturalBreakCredit() {
        var engine = BreakEngine(configurations: configurations(), now: t(0))
        engine.pause(at: t(100))
        let events = engine.resume(at: t(100 + 7200))
        #expect(events.isEmpty)
        #expect(engine.plans[.short] == .running(deadline: t(7300 + 1100)))
    }

    @Test func systemWakeDoesNotClearManualPause() {
        var engine = BreakEngine(configurations: configurations(), now: t(0))
        engine.pause(at: t(100))
        engine.beginSystemSuspension(.systemSleep, at: t(200))
        engine.endSystemSuspension(.systemSleep, at: t(210))

        #expect(engine.isManuallyPaused)
        #expect(engine.nextDeadline == nil)
    }

    @Test func resumeWhileSystemSuspendedWaitsForAllReasonsToClear() {
        var engine = BreakEngine(configurations: configurations(), now: t(0))
        engine.evaluate(at: t(1200))
        engine.pause(at: t(1205))
        engine.beginSystemSuspension(.displaySleep, at: t(1300))
        engine.resume(at: t(1310))

        #expect(engine.isManuallyPaused == false)
        #expect(engine.isSuspended)
        #expect(engine.nextDeadline == nil)
        #expect(engine.snapshot().isPresentingBreak == false)

        // 10 s of display sleep is credited to the 15 s of remaining rest.
        engine.endSystemSuspension(.displaySleep, at: t(1310))
        #expect(engine.snapshot().isPresentingBreak)
        #expect(engine.activeBreak?.timing == .running(deadline: t(1315)))
    }

    // MARK: Natural breaks

    @Test func overlappingAndDuplicateSuspensionsCountOneAbsence() {
        var engine = BreakEngine(configurations: configurations(), now: t(0))
        var events: [BreakEngineEvent] = []
        events += engine.beginSystemSuspension(.displaySleep, at: t(100))
        events += engine.beginSystemSuspension(.systemSleep, at: t(110))
        events += engine.beginSystemSuspension(.systemSleep, at: t(120))
        events += engine.endSystemSuspension(.systemSleep, at: t(300))
        #expect(engine.isSuspended)
        events += engine.endSystemSuspension(.systemSleep, at: t(310))
        events += engine.endSystemSuspension(.displaySleep, at: t(350))
        events += engine.endSystemSuspension(.displaySleep, at: t(360))

        let credits = events.filter { if case .naturalBreakCredited = $0 { true } else { false } }
        #expect(credits == [.naturalBreakCredited(absence: .seconds(250), resetPlans: [.short])])
        #expect(engine.plans[.short] == .running(deadline: t(350 + 1200)))
        #expect(engine.plans[.long] == .running(deadline: t(350 + 3500)))
    }

    @Test(arguments: [(19, false), (20, true), (21, true)])
    func shortPlanResetsOnlyWhenAbsenceMeetsItsDuration(absence: Int, resets: Bool) {
        var engine = BreakEngine(configurations: configurations(), now: t(0))
        engine.beginSystemSuspension(.systemSleep, at: t(100))
        engine.endSystemSuspension(.systemSleep, at: t(100 + absence))

        let returned = 100 + absence
        #expect(engine.plans[.short] == .running(deadline: t(returned + (resets ? 1200 : 1100))))
        #expect(engine.plans[.long] == .running(deadline: t(returned + 3500)))
    }

    @Test(arguments: [(299, false), (300, true), (301, true)])
    func longPlanResetsOnlyWhenAbsenceMeetsItsDuration(absence: Int, resets: Bool) {
        var engine = BreakEngine(configurations: configurations(), now: t(0))
        engine.beginSystemSuspension(.displaySleep, at: t(100))
        engine.endSystemSuspension(.displaySleep, at: t(100 + absence))

        let returned = 100 + absence
        #expect(engine.plans[.short] == .running(deadline: t(returned + 1200)))
        #expect(engine.plans[.long] == .running(deadline: t(returned + (resets ? 3600 : 3500))))
    }

    @Test func absenceDuringBreakIsCreditedToRemainingRest() {
        var engine = BreakEngine(configurations: configurations(), now: t(0))
        engine.evaluate(at: t(1200))
        engine.beginSystemSuspension(.displaySleep, at: t(1205))
        let events = engine.endSystemSuspension(.displaySleep, at: t(1215))

        #expect(!events.contains(.breakCompleted(1, .short)))
        #expect(engine.activeBreak?.id == 1)
        #expect(engine.activeBreak?.timing == .running(deadline: t(1220)))
    }

    @Test func absenceThatSatisfiesABreakCompletesItOnce() {
        var engine = BreakEngine(configurations: configurations(long: (600, 300, true)), now: t(0))
        engine.evaluate(at: t(600))
        engine.beginSystemSuspension(.systemSleep, at: t(650))
        engine.beginSystemSuspension(.displaySleep, at: t(651))
        var events = engine.endSystemSuspension(.systemSleep, at: t(1000))
        events += engine.endSystemSuspension(.displaySleep, at: t(1001))
        events += engine.endSystemSuspension(.displaySleep, at: t(1002))

        #expect(events.filter { $0 == .breakCompleted(1, .long) }.count == 1)
        #expect(!events.contains { if case .breakStarted = $0 { true } else { false } })
        #expect(engine.activeBreak == nil)
        #expect(engine.plans[.short] == .running(deadline: t(1001 + 1200)))
        #expect(engine.plans[.long] == .running(deadline: t(1001 + 600)))
    }

    @Test func actualSleepDuringManualPauseEarnsCreditButStaysPaused() {
        var engine = BreakEngine(configurations: configurations(), now: t(0))
        engine.pause(at: t(100))
        engine.beginSystemSuspension(.systemSleep, at: t(200))
        let events = engine.endSystemSuspension(.systemSleep, at: t(600))

        #expect(events == [.naturalBreakCredited(absence: .seconds(400), resetPlans: [.short, .long])])
        #expect(engine.isManuallyPaused)
        #expect(engine.plans[.short] == .frozen(remaining: .seconds(1200)))
        #expect(engine.plans[.long] == .frozen(remaining: .seconds(3600)))

        engine.resume(at: t(1000))
        #expect(engine.plans[.short] == .running(deadline: t(2200)))
    }

    @Test func sleepDuringPausedBreakCanCompleteItWhileStayingPaused() {
        var engine = BreakEngine(configurations: configurations(), now: t(0))
        engine.evaluate(at: t(1200))
        engine.pause(at: t(1205))
        engine.beginSystemSuspension(.systemSleep, at: t(1300))
        let events = engine.endSystemSuspension(.systemSleep, at: t(1330))

        #expect(events.contains(.breakCompleted(1, .short)))
        #expect(engine.isManuallyPaused)
        #expect(engine.activeBreak == nil)
        #expect(engine.plans[.short] == .frozen(remaining: .seconds(1200)))
    }

    // MARK: Configuration changes

    @Test func changingAWorkIntervalReschedulesOnlyThatPlan() {
        var engine = BreakEngine(configurations: configurations(), now: t(0))
        engine.updateConfigurations(configurations(short: (600, 20, true)), at: t(100))

        #expect(engine.plans[.short] == .running(deadline: t(700)))
        #expect(engine.plans[.long] == .running(deadline: t(3600)))
    }

    @Test func unchangedConfigurationDoesNotResetTimers() {
        var engine = BreakEngine(configurations: configurations(), now: t(0))
        let before = engine.snapshot()
        engine.updateConfigurations(configurations(), at: t(500))
        #expect(engine.snapshot() == before)
    }

    @Test func breakKeepsCapturedDurationAndSkipPermission() throws {
        var engine = BreakEngine(configurations: configurations(), now: t(0))
        engine.evaluate(at: t(1200))
        engine.updateConfigurations(configurations(short: (1200, 60, false)), at: t(1205))

        let session = try #require(engine.activeBreak)
        #expect(session.duration == .seconds(20))
        #expect(session.allowsSkip)
        #expect(session.timing == .running(deadline: t(1220)))
        _ = try engine.skip(sessionID: session.id, at: t(1206)).get()

        // The next short break uses the new settings.
        engine.evaluate(at: t(1206 + 1200))
        #expect(engine.activeBreak?.duration == .seconds(60))
        #expect(engine.activeBreak?.allowsSkip == false)
    }

    @Test func disablingPlansDuringABreakDoesNotDismissIt() {
        var engine = BreakEngine(configurations: configurations(), now: t(0))
        engine.evaluate(at: t(1200))
        engine.updateConfigurations(configurations(shortEnabled: false, longEnabled: false), at: t(1205))

        #expect(engine.phase == .onBreak)
        #expect(engine.nextDeadline == t(1220))

        engine.evaluate(at: t(1220))
        #expect(engine.phase == .disabled)
        #expect(engine.nextDeadline == nil)
    }

    @Test func disablingBothPlansStopsSchedulingAndReenablingStartsFresh() {
        var engine = BreakEngine(configurations: configurations(), now: t(0))
        engine.updateConfigurations(configurations(shortEnabled: false, longEnabled: false), at: t(100))

        #expect(engine.phase == .disabled)
        #expect(engine.nextDeadline == nil)
        #expect(engine.evaluate(at: t(100_000)).isEmpty)

        engine.updateConfigurations(configurations(longEnabled: false), at: t(200))
        #expect(engine.phase == .working)
        #expect(engine.plans[.short] == .running(deadline: t(1400)))
        #expect(engine.plans[.long] == nil)
    }

    @Test func overdueTransitionsAreProcessedBeforePausing() {
        var engine = BreakEngine(configurations: configurations(), now: t(0))
        let events = engine.pause(at: t(1300))
        #expect(events == [.breakStarted(1, .short)])
        #expect(engine.activeBreak?.timing == .frozen(remaining: .seconds(20)))
    }
}
