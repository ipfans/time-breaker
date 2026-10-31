import Foundation

typealias Instant = ContinuousClock.Instant

/// A documented system signal that the user is probably away.
enum SystemSuspensionReason: String, CaseIterable, Hashable, Sendable {
    case systemSleep
    case displaySleep
    case sessionInactive
}

/// Remaining time that is either counting down toward a deadline or frozen.
enum CountdownTiming: Equatable, Sendable {
    case running(deadline: Instant)
    case frozen(remaining: Duration)

    /// Remaining time at `now`, clamped at zero.
    func remaining(at now: Instant) -> Duration {
        switch self {
        case .running(let deadline): max(.zero, deadline - now)
        case .frozen(let remaining): max(.zero, remaining)
        }
    }

    var deadline: Instant? {
        if case .running(let deadline) = self { deadline } else { nil }
    }

    func frozen(at now: Instant) -> CountdownTiming {
        .frozen(remaining: remaining(at: now))
    }

    func running(from now: Instant) -> CountdownTiming {
        switch self {
        case .running: self
        case .frozen(let remaining): .running(deadline: now + max(.zero, remaining))
        }
    }
}

/// One shared break session presented on every display.
struct ActiveBreak: Equatable, Sendable, Identifiable {
    typealias ID = UInt64

    let id: ID
    let kind: BreakKind
    /// Duration captured when the break started; later settings changes do not alter it.
    let duration: Duration
    /// Skip permission captured when the break started.
    let allowsSkip: Bool
    var timing: CountdownTiming
}

/// Read-only scheduling state for menus, overlays, and diagnostics.
struct SchedulerSnapshot: Equatable, Sendable {
    enum Phase: Equatable, Sendable {
        case working
        case onBreak
        case disabled
    }

    var phase: Phase
    /// Work timing for each enabled plan. Frozen while on a break or suspended.
    var plans: [BreakKind: CountdownTiming]
    var activeBreak: ActiveBreak?
    var isManuallyPaused: Bool
    var systemSuspensionReasons: Set<SystemSuspensionReason>

    var isSuspended: Bool { isManuallyPaused || !systemSuspensionReasons.isEmpty }

    /// Overlays are shown only for an active break that is not suspended.
    var isPresentingBreak: Bool { activeBreak != nil && !isSuspended }

    /// A break can be started on request only while working and not suspended.
    var canTakeBreak: Bool { activeBreak == nil && !isSuspended }
}

/// Outcomes of engine transitions, used for diagnostics and tests.
enum BreakEngineEvent: Equatable, Sendable {
    case breakStarted(ActiveBreak.ID, BreakKind)
    case breakCompleted(ActiveBreak.ID, BreakKind)
    case breakSkipped(ActiveBreak.ID, BreakKind)
    case naturalBreakCredited(absence: Duration, resetPlans: Set<BreakKind>)
}

enum SkipRejection: Error, Equatable, Sendable {
    /// No active break matches the requested session.
    case noMatchingBreak
    /// The active break was captured with skipping disabled.
    case notAllowed
}

/// Deterministic break scheduling rules.
///
/// Every transition takes the current monotonic time as an argument, so the rules can be tested
/// without waiting. Timings run only while they should consume time: plan work timers while
/// working, the break timer while on a break, and nothing while suspended. `settle(at:)`
/// enforces that invariant after each change.
struct BreakEngine: Sendable {
    private(set) var configurations: [BreakKind: BreakConfiguration]
    private(set) var plans: [BreakKind: CountdownTiming] = [:]
    private(set) var activeBreak: ActiveBreak?
    private(set) var isManuallyPaused = false
    private(set) var systemSuspensionReasons: Set<SystemSuspensionReason> = []
    private var absenceStart: Instant?
    private var nextSessionID: ActiveBreak.ID = 1

    /// Starts fresh work intervals for every enabled plan.
    init(configurations: [BreakConfiguration], now: Instant) {
        var byKind = Dictionary(uniqueKeysWithValues: BreakKind.allCases.map { ($0, BreakConfiguration.default(for: $0)) })
        for configuration in configurations {
            byKind[configuration.kind] = configuration
        }
        self.configurations = byKind
        for kind in BreakKind.allCases {
            restartPlan(kind)
        }
        settle(at: now)
    }

    var isSuspended: Bool { isManuallyPaused || !systemSuspensionReasons.isEmpty }

    var phase: SchedulerSnapshot.Phase {
        if activeBreak != nil { return .onBreak }
        return plans.isEmpty ? .disabled : .working
    }

    /// The next instant at which `evaluate(at:)` must run, or `nil` when nothing is waiting.
    var nextDeadline: Instant? {
        guard !isSuspended else { return nil }
        if let activeBreak {
            return activeBreak.timing.deadline
        }
        return plans.values.compactMap(\.deadline).min()
    }

    func snapshot() -> SchedulerSnapshot {
        SchedulerSnapshot(
            phase: phase,
            plans: plans,
            activeBreak: activeBreak,
            isManuallyPaused: isManuallyPaused,
            systemSuspensionReasons: systemSuspensionReasons
        )
    }

    // MARK: - Transitions

    /// Completes a finished break and starts a due break. Does nothing while suspended.
    @discardableResult
    mutating func evaluate(at now: Instant) -> [BreakEngineEvent] {
        guard !isSuspended else { return [] }
        var events: [BreakEngineEvent] = []
        // A completion can make another plan due; a few passes always reach a stable state.
        for _ in 0..<4 {
            if let activeBreak {
                guard activeBreak.timing.remaining(at: now) <= .zero else { break }
                complete(activeBreak, at: now)
                events.append(.breakCompleted(activeBreak.id, activeBreak.kind))
                continue
            }
            guard let kind = dueKind(at: now) else { break }
            let started = startBreak(kind, at: now)
            events.append(.breakStarted(started.id, started.kind))
        }
        return events
    }

    /// Ends the matching break early when its captured permission allows it.
    ///
    /// A break whose time has already run out completes normally instead, so a late Skip cannot
    /// turn a finished long break into a skipped one.
    mutating func skip(sessionID: ActiveBreak.ID, at now: Instant) -> Result<[BreakEngineEvent], SkipRejection> {
        let overdue = evaluate(at: now)
        guard let activeBreak, activeBreak.id == sessionID else {
            return overdue.isEmpty ? .failure(.noMatchingBreak) : .success(overdue)
        }
        guard activeBreak.allowsSkip else { return .failure(.notAllowed) }

        settle(at: now)
        self.activeBreak = nil
        // A skip is not a completion: restart only the skipped plan.
        restartPlan(activeBreak.kind)
        settle(at: now)

        var events = overdue + [.breakSkipped(activeBreak.id, activeBreak.kind)]
        events += evaluate(at: now)
        return .success(events)
    }

    /// Starts a break of `kind` on request, as if its plan had come due, with the plan's configured
    /// duration and skip permission. Completing or skipping it updates the plans like a scheduled
    /// break. Ignored during a break or while suspended; overdue transitions are processed first.
    @discardableResult
    mutating func takeBreak(_ kind: BreakKind, at now: Instant) -> [BreakEngineEvent] {
        let overdue = evaluate(at: now)
        guard activeBreak == nil, !isSuspended else { return overdue }
        let started = startBreak(kind, at: now)
        return overdue + [.breakStarted(started.id, started.kind)]
    }

    /// Freezes all remaining time. Overdue transitions are processed first.
    @discardableResult
    mutating func pause(at now: Instant) -> [BreakEngineEvent] {
        guard !isManuallyPaused else { return [] }
        let events = evaluate(at: now)
        isManuallyPaused = true
        settle(at: now)
        return events
    }

    /// Clears the manual pause. Timing continues only when no system suspension remains.
    @discardableResult
    mutating func resume(at now: Instant) -> [BreakEngineEvent] {
        guard isManuallyPaused else { return [] }
        isManuallyPaused = false
        settle(at: now)
        return evaluate(at: now)
    }

    @discardableResult
    mutating func beginSystemSuspension(_ reason: SystemSuspensionReason, at now: Instant) -> [BreakEngineEvent] {
        guard !systemSuspensionReasons.contains(reason) else { return [] }
        var events: [BreakEngineEvent] = []
        if systemSuspensionReasons.isEmpty {
            events = evaluate(at: now)
            absenceStart = now
        }
        systemSuspensionReasons.insert(reason)
        settle(at: now)
        return events
    }

    /// Ends one suspension reason. When the last reason clears, the whole absence is credited once.
    @discardableResult
    mutating func endSystemSuspension(_ reason: SystemSuspensionReason, at now: Instant) -> [BreakEngineEvent] {
        guard systemSuspensionReasons.remove(reason) != nil else { return [] }
        guard systemSuspensionReasons.isEmpty, let absenceStart else { return [] }
        self.absenceStart = nil

        let absence = max(.zero, now - absenceStart)
        var events = creditNaturalBreak(absence, at: now)
        settle(at: now)
        events += evaluate(at: now)
        return events
    }

    /// Applies validated configuration changes.
    ///
    /// A plan whose enablement or work interval changed restarts with a full interval; other plans
    /// keep their remaining time. An active break keeps its captured duration and skip permission,
    /// and disabling its plan does not dismiss it.
    @discardableResult
    mutating func updateConfigurations(_ newConfigurations: [BreakConfiguration], at now: Instant) -> [BreakEngineEvent] {
        var events = evaluate(at: now)
        settle(at: now)
        for new in newConfigurations {
            let old = configurations[new.kind]
            configurations[new.kind] = new
            guard new.isEnabled else {
                plans[new.kind] = nil
                continue
            }
            let scheduleChanged = old?.isEnabled != true || old?.workIntervalSeconds != new.workIntervalSeconds
            if scheduleChanged || plans[new.kind] == nil {
                restartPlan(new.kind)
            }
        }
        settle(at: now)
        events += evaluate(at: now)
        return events
    }

    // MARK: - Private

    private func dueKind(at now: Instant) -> BreakKind? {
        let due = plans.filter { $0.value.remaining(at: now) <= .zero }.keys
        if due.contains(.long) { return .long }
        if due.contains(.short) { return .short }
        return nil
    }

    private mutating func startBreak(_ kind: BreakKind, at now: Instant) -> ActiveBreak {
        let configuration = configurations[kind] ?? .default(for: kind)
        let session = ActiveBreak(
            id: nextSessionID,
            kind: kind,
            duration: configuration.breakDuration,
            allowsSkip: configuration.allowsSkip,
            timing: .frozen(remaining: configuration.breakDuration)
        )
        nextSessionID += 1
        activeBreak = session
        settle(at: now)
        return activeBreak ?? session
    }

    private mutating func complete(_ session: ActiveBreak, at now: Instant) {
        activeBreak = nil
        switch session.kind {
        case .short:
            restartPlan(.short)
        case .long:
            for kind in BreakKind.allCases {
                restartPlan(kind)
            }
        }
        settle(at: now)
    }

    /// Credits an observed absence while all timings are frozen.
    private mutating func creditNaturalBreak(_ absence: Duration, at now: Instant) -> [BreakEngineEvent] {
        var events: [BreakEngineEvent] = []
        var resetPlans: Set<BreakKind> = []
        for kind in plans.keys {
            guard let configuration = configurations[kind], absence >= configuration.breakDuration else { continue }
            restartPlan(kind)
            resetPlans.insert(kind)
        }
        events.append(.naturalBreakCredited(absence: absence, resetPlans: resetPlans))

        if var session = activeBreak {
            let unsatisfied = session.timing.remaining(at: now) - absence
            if unsatisfied <= .zero {
                complete(session, at: now)
                events.append(.breakCompleted(session.id, session.kind))
            } else {
                session.timing = .frozen(remaining: unsatisfied)
                activeBreak = session
            }
        }
        return events
    }

    /// Sets a full, frozen work interval for an enabled plan; `settle(at:)` starts it if appropriate.
    private mutating func restartPlan(_ kind: BreakKind) {
        guard let configuration = configurations[kind], configuration.isEnabled else {
            plans[kind] = nil
            return
        }
        plans[kind] = .frozen(remaining: configuration.workInterval)
    }

    /// Runs exactly the timings that should consume time and freezes the rest at `now`.
    private mutating func settle(at now: Instant) {
        let plansRun = !isSuspended && activeBreak == nil
        for (kind, timing) in plans {
            plans[kind] = plansRun ? timing.running(from: now) : timing.frozen(at: now)
        }
        if var session = activeBreak {
            session.timing = isSuspended ? session.timing.frozen(at: now) : session.timing.running(from: now)
            activeBreak = session
        }
    }
}
