import Foundation
import Testing
@testable import TimeBreaker

@MainActor
@Suite("Deadline waiting")
struct BreakSchedulerTests {
    let time = Timeline()

    /// A scheduler driven by a manual clock whose waits never finish on their own.
    func makeScheduler(_ configs: [BreakConfiguration] = configurations()) -> (BreakScheduler, ManualClock) {
        let clock = ManualClock(time.t(0))
        let scheduler = BreakScheduler(
            configurations: configs,
            now: { clock.now },
            sleep: { _, _ in try await Task.sleep(for: .seconds(86_400)) }
        )
        return (scheduler, clock)
    }

    @Test func waitsForTheNearestDeadline() {
        let (scheduler, _) = makeScheduler()
        #expect(scheduler.scheduledDeadline == time.t(1200))
        #expect(scheduler.hasPendingWait)
    }

    @Test func currentCallbackStartsTheDueBreak() {
        let (scheduler, clock) = makeScheduler()
        clock.now = time.t(1200)
        scheduler.deadlineReached(generation: scheduler.generation)

        #expect(scheduler.snapshot.activeBreak?.kind == .short)
        #expect(scheduler.scheduledDeadline == time.t(1220))
    }

    @Test func staleCallbackAfterReschedulingIsIgnored() {
        let (scheduler, clock) = makeScheduler()
        let staleGeneration = scheduler.generation
        scheduler.pause()
        scheduler.resume()
        #expect(scheduler.generation != staleGeneration)

        clock.now = time.t(5000)
        scheduler.deadlineReached(generation: staleGeneration)
        #expect(scheduler.snapshot.activeBreak == nil)
    }

    @Test func staleCallbackCannotCompleteANewerBreak() {
        let (scheduler, clock) = makeScheduler()
        clock.now = time.t(1200)
        scheduler.deadlineReached(generation: scheduler.generation)
        let breakGeneration = scheduler.generation
        let session = scheduler.snapshot.activeBreak

        scheduler.pause()
        scheduler.resume()
        clock.now = time.t(1300)
        scheduler.deadlineReached(generation: breakGeneration)
        #expect(scheduler.snapshot.activeBreak == session)
    }

    @Test func noWaitRemainsWhileSuspendedOrDisabled() {
        let (scheduler, _) = makeScheduler()
        scheduler.pause()
        #expect(!scheduler.hasPendingWait)
        #expect(scheduler.scheduledDeadline == nil)

        scheduler.resume()
        #expect(scheduler.hasPendingWait)

        scheduler.beginSystemSuspension(.displaySleep)
        #expect(!scheduler.hasPendingWait)
        scheduler.endSystemSuspension(.displaySleep)

        scheduler.updateConfigurations(configurations(shortEnabled: false, longEnabled: false))
        #expect(!scheduler.hasPendingWait)
        #expect(scheduler.snapshot.phase == .disabled)
    }

    @Test func observersSeeEachChangeOnce() {
        let (scheduler, clock) = makeScheduler()
        var phases: [SchedulerSnapshot.Phase] = []
        scheduler.addObserver { phases.append($0.phase) }

        clock.now = time.t(1200)
        scheduler.deadlineReached(generation: scheduler.generation)
        scheduler.updateConfigurations(configurations())
        clock.now = time.t(1220)
        scheduler.deadlineReached(generation: scheduler.generation)

        #expect(phases == [.onBreak, .working])
    }

    @Test func skipIsRejectedCentrallyAndPauseAndResumeStillWork() throws {
        let (scheduler, clock) = makeScheduler(configurations(short: (1200, 20, false)))
        clock.now = time.t(1200)
        scheduler.deadlineReached(generation: scheduler.generation)
        let session = try #require(scheduler.snapshot.activeBreak)

        let result = scheduler.skip(sessionID: session.id)
        #expect(throws: SkipRejection.notAllowed) { try result.get() }
        #expect(scheduler.snapshot.activeBreak == session)

        scheduler.pause()
        #expect(scheduler.snapshot.isPresentingBreak == false)
        scheduler.resume()
        #expect(scheduler.snapshot.activeBreak?.id == session.id)
    }

    @Test func realClockWaitStartsAndCompletesABreak() async throws {
        let scheduler = BreakScheduler(
            configurations: configurations(short: (1, 1, true), long: (3600, 300, true)),
            tolerance: .milliseconds(20)
        )
        var sawBreak = false
        for _ in 0..<100 where !sawBreak {
            try await Task.sleep(for: .milliseconds(50))
            sawBreak = scheduler.snapshot.activeBreak != nil
        }
        #expect(sawBreak)

        var completed = false
        for _ in 0..<100 where !completed {
            try await Task.sleep(for: .milliseconds(50))
            completed = scheduler.snapshot.phase == .working
        }
        #expect(completed)
        #expect(try #require(scheduler.lastCallbackLateness) < .milliseconds(500))
        scheduler.stop()
    }

    @Test func cancelledWaitNeverStartsABreak() async throws {
        let scheduler = BreakScheduler(
            configurations: configurations(short: (1, 1, true)),
            tolerance: .milliseconds(20)
        )
        scheduler.pause()
        try await Task.sleep(for: .milliseconds(1500))
        #expect(scheduler.snapshot.activeBreak == nil)
        #expect(scheduler.lastCallbackLateness == nil)
        scheduler.stop()
    }
}
