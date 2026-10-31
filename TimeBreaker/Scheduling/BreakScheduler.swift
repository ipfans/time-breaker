import Foundation
import os

/// Owns the single break schedule and the one cancellable task waiting for its next deadline.
///
/// All transitions run on the main actor. A scheduling generation identifies the current wait so
/// that a cancelled or obsolete callback cannot complete or start a newer break.
@MainActor
final class BreakScheduler {
    typealias Observer = @MainActor (SchedulerSnapshot) -> Void

    private(set) var snapshot: SchedulerSnapshot
    /// Deadline of the pending wait, if any.
    private(set) var scheduledDeadline: Instant?
    /// Identifies the current wait; incremented whenever the wait is replaced or cancelled.
    private(set) var generation: UInt64 = 0
    /// When the most recent deadline callback ran, relative to its deadline. Diagnostic only.
    private(set) var lastCallbackLateness: Duration?

    var hasPendingWait: Bool { waitTask != nil }

    private var engine: BreakEngine
    private let now: () -> Instant
    private let sleep: @Sendable (Instant, Duration) async throws -> Void
    private let tolerance: Duration
    private var waitTask: Task<Void, Never>?
    private var observers: [Observer] = []
    private let logger = Logger(subsystem: Log.subsystem, category: "Scheduler")

    /// Starts fresh work intervals immediately.
    ///
    /// - Parameters:
    ///   - now: Source of the current monotonic time. Tests supply a controllable value.
    ///   - sleep: Waits until a deadline with the given tolerance and throws on cancellation.
    init(
        configurations: [BreakConfiguration],
        tolerance: Duration = .seconds(1),
        now: @escaping () -> Instant = { ContinuousClock.now },
        sleep: @escaping @Sendable (Instant, Duration) async throws -> Void = { deadline, tolerance in
            try await ContinuousClock().sleep(until: deadline, tolerance: tolerance)
        }
    ) {
        self.now = now
        self.sleep = sleep
        self.tolerance = tolerance
        engine = BreakEngine(configurations: configurations, now: now())
        snapshot = engine.snapshot()
        rescheduleWait()
    }

    func addObserver(_ observer: @escaping Observer) {
        observers.append(observer)
    }

    /// Current monotonic time from the scheduler's clock.
    var currentInstant: Instant { now() }

    // MARK: - Commands

    func pause() {
        perform("pause") { $0.pause(at: $1) }
    }

    func resume() {
        perform("resume") { $0.resume(at: $1) }
    }

    /// Requests a skip of the given session. Rejected centrally when the session forbids it.
    @discardableResult
    func skip(sessionID: ActiveBreak.ID) -> Result<Void, SkipRejection> {
        var outcome: Result<Void, SkipRejection> = .success(())
        perform("skip") { engine, now in
            switch engine.skip(sessionID: sessionID, at: now) {
            case .success(let events):
                return events
            case .failure(let rejection):
                outcome = .failure(rejection)
                return []
            }
        }
        if case .failure(let rejection) = outcome {
            logger.notice("Skip rejected for session \(sessionID, privacy: .public): \(String(describing: rejection), privacy: .public)")
        }
        return outcome
    }

    /// Starts a break of `kind` now. Ignored during a break or while paused or away.
    func takeBreak(_ kind: BreakKind) {
        perform("take \(kind.rawValue) break") { $0.takeBreak(kind, at: $1) }
    }

    func beginSystemSuspension(_ reason: SystemSuspensionReason) {
        perform("suspend \(reason.rawValue)") { $0.beginSystemSuspension(reason, at: $1) }
    }

    func endSystemSuspension(_ reason: SystemSuspensionReason) {
        perform("unsuspend \(reason.rawValue)") { $0.endSystemSuspension(reason, at: $1) }
    }

    func updateConfigurations(_ configurations: [BreakConfiguration]) {
        perform("configure") { $0.updateConfigurations(configurations, at: $1) }
    }

    /// Cancels the pending wait. Used during termination.
    func stop() {
        waitTask?.cancel()
        waitTask = nil
        scheduledDeadline = nil
        generation &+= 1
    }

    // MARK: - Deadline handling

    /// Handles a completed wait. Stale generations and cancelled tasks are ignored.
    func deadlineReached(generation: UInt64) {
        guard generation == self.generation, !Task.isCancelled else {
            logger.debug("Ignored stale deadline callback (generation \(generation, privacy: .public))")
            return
        }
        let firedAt = now()
        if let deadline = scheduledDeadline {
            let lateness = firedAt - deadline
            lastCallbackLateness = lateness
            logger.notice("Deadline callback lateness: \(lateness.milliseconds, privacy: .public) ms")
        }
        waitTask = nil
        scheduledDeadline = nil
        perform("deadline", at: firedAt) { $0.evaluate(at: $1) }
    }

    // MARK: - Private

    private func perform(
        _ label: String,
        at instant: Instant? = nil,
        _ body: (inout BreakEngine, Instant) -> [BreakEngineEvent]
    ) {
        let previous = snapshot
        let events = body(&engine, instant ?? now())
        snapshot = engine.snapshot()
        rescheduleWait()
        for event in events {
            logger.notice("\(label, privacy: .public): \(String(describing: event), privacy: .public)")
        }
        guard snapshot != previous else { return }
        for observer in observers {
            observer(snapshot)
        }
    }

    private func rescheduleWait() {
        let deadline = engine.nextDeadline
        if deadline == scheduledDeadline, (deadline == nil) == (waitTask == nil) {
            return
        }
        waitTask?.cancel()
        waitTask = nil
        generation &+= 1
        scheduledDeadline = deadline
        guard let deadline else { return }

        let generation = generation
        let sleep = sleep
        let tolerance = tolerance
        waitTask = Task { [weak self] in
            do {
                try await sleep(deadline, tolerance)
            } catch {
                return
            }
            self?.deadlineReached(generation: generation)
        }
    }
}

extension Duration {
    /// Whole milliseconds, for diagnostics.
    var milliseconds: Int64 {
        let (seconds, attoseconds) = components
        return seconds * 1000 + attoseconds / 1_000_000_000_000_000
    }

    /// Seconds as a floating-point value.
    var timeInterval: Double {
        let (seconds, attoseconds) = components
        return Double(seconds) + Double(attoseconds) / 1e18
    }
}
