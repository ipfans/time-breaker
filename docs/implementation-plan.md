# Time Breaker Implementation Plan

Date: 2026-10-30

Status: first version implemented for local development on Apple silicon. Automated tests pass and runtime validation on the development host is recorded in the [validation report](validation-report.md). Release qualification is not complete. In particular, macOS 26 has not been tested, and several interaction and system-event scenarios still need manual verification; see section 8.

This document defines the first version of Time Breaker, a native macOS menu bar application that reminds users to take short and long breaks through fullscreen overlays on every available display. It is intended for the engineer implementing the app and the person evaluating its behavior.

This implementation plan takes precedence over conflicting recommendations in the [technical research](research/macos-break-reminder.md). The research remains the source of supporting API references and investigation history. This documentation task does not create an application project, prototype, translation catalog, or runtime test results.

## 1. Requirements and selected defaults

### Confirmed requirements

- Support **macOS 26 or later on Apple silicon (`arm64`) only**, using Swift, AppKit, and SwiftUI in a single process.
- Remain in the menu bar without a Dock icon. Start scheduling automatically on launch; closing Settings does not quit the app.
- Provide independently configurable short and long breaks, including enablement, work interval, break duration, and skip permission.
- Keep break overlays in front of ordinary application content on all currently available displays, with one shared break state.
- Allow **Pause and normal Quit at all times**, including during a break whose Skip action is disabled.
- Freeze remaining work or break time during manual pause, hide the overlays, and continue that remaining time on Resume.
- Credit independently observed system absence as a natural break. Manual pause alone does not earn this credit.
- Support shared solid-color or static-image backgrounds, background transparency from **0–99%**, and Stretch, Center, and Scale to Fit image modes.
- Provide an application language setting with English as the first-launch default and fallback. Support the eight languages listed below, using **Portuguese from Portugal (`pt-PT`)**.
- Minimize background wakeups and retain only the resources needed for the current UI.

“Disable Skip” is an application command restriction, not a system lock. It does not prohibit pausing, quitting, or using system recovery tools. Do not implement the stronger restrictions proposed in the earlier research.

### Selected defaults

| Setting | First-version default |
| --- | --- |
| Short break | Enabled; 20 minutes of work, then a 20-second break |
| Long break | Enabled; 60 minutes of work, then a 5-minute break |
| Skip permission | Enabled independently for both break types |
| Work interval meaning | Time spent working, excluding breaks and suspension |
| Scheduling after launch | Start fresh work intervals for enabled plans |
| Launch at login | Disabled until explicitly enabled by the user |
| Background | Solid color, fully opaque |
| Background transparency | 0%; valid integer range is 0–99% |
| Image layout | Scale to Fit |
| Appearance scope | One configuration shared by both break types and all displays |
| Application language | English, even when macOS uses another language |
| Manual pause | Continue remaining time on Resume; no automatic resume on wake |

Work intervals and break durations must be positive. The long-break duration must be at least the short-break duration. Validate edits before applying or persisting them, retain the previous valid configuration on invalid input, and recover corrupted stored values to valid defaults. These durations are configurable product defaults, not medical recommendations.

### Decisions superseding the research

| Earlier research position | Implementation decision |
| --- | --- |
| macOS 13 is a possible API baseline | The product supports macOS 26+ |
| Architecture was not specified | Build for Apple silicon (`arm64`) only; Intel is out of scope |
| A strict break could disable Pause and normal Quit | Only direct Skip actions are restricted; Pause and Quit remain available |
| Manual suspension behavior was not fully specified | Hide overlays, freeze remaining time, and resume the previous state |
| Portuguese locale remained generic or undecided | Use Portuguese from Portugal, `pt-PT` |

## 2. Architecture and state contracts

Keep four responsibilities within one application. No external API, database, generic workflow engine, background helper, or privileged process is required.

| Responsibility | Owns | Communicates through |
| --- | --- | --- |
| Application lifecycle and menu bar | Initialization, `NSStatusItem`, `NSMenu`, Settings entry point, login-item UI, termination | User commands to the scheduler and settings; read-only state for menu presentation |
| Break scheduling | Work deadlines, one active break, skip decisions, suspension, natural-break credit, cancellable waits | Validated configuration and events in; a current state snapshot out |
| Display overlays | Per-display AppKit windows, SwiftUI content, geometry, ordering, focus, cleanup | Shared state and appearance in; Skip, Pause, and Quit requests out |
| Settings and resources | Validated preferences, image import/storage, localization resources | Configuration changes and localized presentation values |

### Minimal configuration and state interfaces

The following are conceptual contracts, not a requirement to create a public library or a separate module for every type.

| Contract | Required information |
| --- | --- |
| `BreakConfiguration` | Short or long identity, enabled flag, work interval, break duration, and skip permission |
| `AppearanceSettings` | Solid-color or image mode, background color, internal image identifier, image layout, and integer transparency |
| `AppPreferences` | Both break configurations, shared appearance, selected language; login-item status is also read from Service Management |
| `ActiveBreak` | Session identifier, break type, duration and skip permission captured at start, and effective end time or frozen remaining duration |
| `SchedulerSnapshot` | Working, on-break, or disabled base state; per-plan timing; optional active break; manual pause flag and active system-suspension reasons |

A paused presentation is derived from suspension state while retaining the underlying work or break state. Do not create a second scheduler inside a menu, view, or individual display window.

All state transitions run on the main actor. Inputs are launch, configuration changes, deadline callbacks, Skip, Pause, Resume, system-suspension changes, and Quit. Display changes update window presentation without resetting scheduling state.

Keep transition logic testable with a supplied current time. The production waiting mechanism and AppKit integration must not force state tests to wait for real minute-long intervals.

### Deadline scheduling

Use `ContinuousClock` for in-process elapsed time and `ContinuousClock.sleep(until:tolerance:)` for one cancellable task waiting for the nearest required transition. Start with a one-second tolerance as a scheduling hint, not a guarantee of exact execution.

While working, wait for the earlier enabled work deadline. During a break, wait for its end time. During suspension, or when both plans are disabled and no break is active, retain no active deadline wait.

Cancel the old wait whenever a transition changes its meaning. Check cancellation and the current scheduling generation before handling a callback, and then read the current clock and state again. A cancelled or stale callback must never create an overlay or complete a newer break.

Calculate displayed remaining time from the effective deadline, clamped at zero. Refresh countdown text only while it is visible, at approximately one update per second, with a shared refresh source across displays. UI refreshes do not determine break completion.

### Persistence and startup

Persist configuration through `UserDefaults`, not monotonic instants, per-second countdown values, or image bytes. Store imported images separately in Application Support. A normal relaunch starts fresh work intervals, including after the user quits during a break.

Initialize settings, localization, menu state, and scheduling without requiring the Settings window to be opened. Use `LSUIElement = true` with an AppKit menu bar item. Register launch at login only when the user enables it through `SMAppService.mainApp`; show actual service status and handle registration errors instead of assuming success.

The intended permission footprint does not include Screen Recording, global Input Monitoring, or Accessibility control of other apps. Verify that goal with a clean account and sandboxed build. User-selected image access requires the appropriate file-reading capability.

## 3. Break behavior and suspension

### Scheduling transitions

| Event | Required behavior |
| --- | --- |
| Launch | Establish fresh work intervals for both enabled plans |
| Short break starts | Freeze the other plan’s remaining work time; create one shared break session |
| Short break completes | Restart the short interval and continue the long plan’s remaining work time |
| Long break completes | Restart both enabled work intervals |
| Both plans are due | Start only the long break; do not stack overlays or queue an automatic catch-up short break after successful completion |
| Allowed Skip | End that break without marking it completed; restart only that plan and preserve the other plan’s remaining work time |
| Skip is disabled | Reject every direct Skip request centrally; Pause and Quit remain available |
| Both plans are disabled | Stop future scheduling and show the disabled state |
| Quit | Clean up windows and activity tokens and terminate normally; do not record an interrupted break as completed |

Time spent on an active break does not consume another plan’s work interval, including when the active break is later skipped. If both plans were due and the long break is skipped, the short break remains due and must be reevaluated; it must not disappear as a side effect.

Work-schedule changes made while working reschedule the affected plan using the validated settings. An active break retains its captured duration and skip permission; changes to its plan apply to future scheduling. Disabling a plan does not silently dismiss its already-active break. Pause and Quit remain the explicit available interruption paths.

Appearance and language changes update presentation without changing the break identifier, remaining time, or permissions.

### Manual pause

Pause cancels scheduling waits and countdown refreshes, captures remaining work or break time, and hides every overlay. The menu shows Resume and Quit. Resuming restores the retained base state and rebuilds deadlines from the current monotonic time and the remaining durations.

Do not count the duration of manual pause as work or as a natural break. A system wake event must not clear the manual pause flag. Clicking Resume while a system-suspension reason remains active clears only the manual flag; the app remains suspended until the system reasons clear.

### Natural-break accounting

Observe device sleep, display sleep, and user-session inactivity through documented workspace events. Subscribe through `NSWorkspace.shared.notificationCenter`. Treat these signals as an approximation of time away, not proof that the user stood up.

Track a set of active system-suspension reasons. Begin an absence interval when the set changes from empty to nonempty, and end it when the last reason clears. Duplicate or overlapping notifications must not create additional absence intervals.

On return:

- If the absence meets a break type’s required duration, reset that plan to a full work interval.
- Otherwise, preserve that plan’s remaining work time.
- Apply absence time to the remaining duration of an interrupted active break. Complete it once if enough time has elapsed; otherwise retain the unsatisfied duration.
- Apply the normal completion rules for an active break that is satisfied by the absence. Do not reset the same plan twice in response to duplicate events.

Actual system absence can still earn credit while the user has manually paused. Account for that absence independently, update the retained state once, and remain manually paused until Resume. Time that is only manually paused earns no credit.

Do not infer screen locking from session switching alone or make an undocumented lock notification a correctness dependency. A locked but illuminated screen is an explicit prototype test case. Do not promise exact lock detection until validated.

## 4. Fullscreen presentation and settings

### Window configuration to validate

Create one borderless AppKit window per currently available `NSScreen`, using its full `frame`. Do not rely on a normal window entering a separate fullscreen Space.

The initial prototype should evaluate:

| Concern | Initial configuration or approach |
| --- | --- |
| Ordering | Evaluate the `screenSaver` window level |
| Visibility across Spaces and apps | Evaluate `canJoinAllSpaces`, `canJoinAllApplications`, and `fullScreenAuxiliary` together |
| Mission Control | Evaluate `stationary`, without combining it with `managed` or `transient` |
| App deactivation | Explicitly set `hidesOnDeactivate = false` |
| Keyboard input | Make the borderless window eligible to become key and validate activation/focus behavior |
| Mouse input | Set `ignoresMouseEvents = false` and validate hit testing across the full overlay |
| Transparency | Keep window-wide `alphaValue = 1`; compose transparency only in the background content |

These are candidates, not demonstrated guarantees. Raising a window does not establish keyboard focus, and activation requests can fail. Test visibility, mouse interception, and keyboard delivery separately.

Every display shares the same break identifier, effective end time, skip permission, and appearance. Prepare windows before requesting presentation in the same UI update cycle. Completion, Skip, or Pause is processed once and applied to all windows; repeated requests from multiple displays must be harmless.

Each overlay presents readable break text and a countdown, plus **Pause and Quit controls at all times**. Show Skip only when the active session allows it. Closing a window or pressing Esc must not become an unguarded alternate Skip path. Keep system force quit, logout, and shutdown available.

Do not enable stronger presentation restrictions that disable normal Quit or system recovery. Do not attempt to cover login or security interfaces, disable Force Quit, or continually seize focus. Use event-driven ordering recovery rather than a polling loop.

### Display changes and cleanup

Re-read `NSScreen.screens` on display configuration changes. Add new display windows to the current session with its existing end time, release removed display windows, and update geometry after rotation, scaling, rearrangement, or primary-display changes. Also reconcile presentation after Space changes.

Handle negative screen coordinates, mixed backing scales, mirroring, and clamshell operation from the actual available screen configuration. Do not assume the primary display is the only active display or that closing a laptop lid means the system is asleep.

Physical displays may refresh at different times; the requirement is one synchronized break session without independent countdowns or noticeably staggered starts, not identical physical refresh frames.

If no displays are available, suspend presentation and reconcile when they return. Display absence alone must not invent natural-break credit without the defined system-absence signals. Failed window creation must not be reported as successful coverage.

Hide or release windows and stop UI refreshes when they are no longer needed. Restore any presentation options changed by the app, and attempt to return focus appropriately after completion or Pause. Respect Reduce Motion and keep transitions brief.

### Backgrounds and image layouts

Use one appearance configuration across all displays and both break types. Support a solid color and imported static images, with an opaque solid background as the default.

| Mode | Layout |
| --- | --- |
| Stretch | Scale width and height independently to the display area; distortion is allowed |
| Center | Use a fixed logical image size, center it, and clip overflow |
| Scale to Fit | Preserve the aspect ratio, scale the complete image into the available area, and center it |

Use the selected background color wherever the image does not cover the display or contains transparent pixels. Layout is calculated independently per display, not across one combined desktop canvas. Scale to Fit is the default.

Normalize image orientation on import and preserve its logical dimensions separately from decoded cache dimensions. For Center, use the normalized pixel dimensions as equivalent logical point dimensions; reducing decoding resolution must not change layout size. Use display backing scale only to determine rendering needs.

Transparency accepts integer values from **0–99%**. The composed background opacity is `1 − transparency / 100`: 0% transparency is fully opaque, and 99% retains 1% opacity. Apply this once to the background color/image composition. Keep reminder text and controls on a separate legible layer with predictable contrast.

Import through the system file picker, validate format and dimensions, and copy the asset to Application Support without modifying the original. Update preferences only after import succeeds. A failed import retains the last valid configuration; an unavailable background at presentation time falls back to the selected color without delaying the overlay.

Use ImageIO downsampling with an explicit maximum output pixel size derived from the display and layout requirements. Reuse only the decoded variants needed by active displays and previews, keep the cache bounded, and release unnecessary images after use. Never decode on each countdown refresh or store image bytes in `UserDefaults`.

Visual transparency is not permission for input to pass through. Test interception at the 99% limit and over image regions containing transparency.

### Language selection and localization

English is the first-launch language regardless of the operating system language. Persist the selected identifier and use English when it is missing, invalid, or unsupported.

| Language | Identifier |
| --- | --- |
| English | `en` |
| Simplified Chinese | `zh-Hans` |
| Traditional Chinese | `zh-Hant` |
| Japanese | `ja` |
| Korean | `ko` |
| Spanish | `es` |
| French | `fr` |
| Portuguese (Portugal) | `pt-PT` |

Use each language’s native name in the selector. Portuguese must use vocabulary and conventions from Portugal; do not substitute Brazilian Portuguese or an unspecified Portuguese variant.

Use a bundled `Localizable.xcstrings` String Catalog with English source text. Cover settings, menu commands and status, break prompts, skip restrictions, Pause and Quit, background modes, validation errors, duration units, tooltips, and accessibility labels and hints.

Use full localized phrases and placeholders, with plural variants and locale-aware formatting where applicable. Do not build sentences by concatenating fragments or persist localized strings as configuration values.

The language choice must update both SwiftUI content and AppKit menu titles. All existing overlay windows use the same selection. Changing language does not reset scheduling, change skip permission, or close overlays. Allow wrapping and sufficient control sizing for longer translations, and use system fonts with suitable character coverage.

Missing strings fall back to English rather than exposing internal keys. This recovery behavior does not substitute for completing and reviewing every supported translation. Keep resources bundled and available offline; no runtime translation service is needed. System-owned dialogs and security prompts retain macOS language behavior.

## 5. Development milestones

The milestones below were written before implementation. Section 8 records their status.

| Milestone | Implementation work | Exit evidence |
| --- | --- | --- |
| 1. Window feasibility | Build the smallest overlay prototype with shared multi-display state, candidate window configuration, input handling, and accessible Pause/Quit controls | Recorded results for foreground visibility, keyboard focus, mouse interception, synchronized coverage, display changes, and recovery paths on macOS 26 and the development OS |
| 2. Scheduler and lifecycle | Add deadlines, cancellation, overlap rules, manual/system suspension, natural-break accounting, menu lifecycle, preferences, and optional login registration | Deterministic state tests; sleep/wake and pause integration results; initial background wakeup and timing measurements |
| 3. Appearance and settings | Add validated configuration, background selection, image import, three layouts, transparency, persistence, and error recovery | Appearance/input tests, import failure cases, mixed-display rendering checks, and memory-release measurements |
| 4. Localization and release validation | Complete eight localizations, accessibility review, compatibility checks, and Release-build resource measurements | Reviewed language coverage, completed acceptance matrix for supported configurations, explicit unverified cases, and recorded resource/timing results |

Do not build a complete settings interface before validating the core window behavior. A failure to cover fullscreen apps or intercept input is a feasibility finding, not a cosmetic defect to hide behind the rest of the interface.

### App Nap and performance gate

Measure default scheduling before adding activity assertions. Record actual due time, callback time, and overlay presentation delay while the app remains in the background.

If App Nap causes unacceptable delays, compare a bounded `ProcessInfo` activity using `userInitiatedAllowingIdleSystemSleep` while scheduling is active. End it during suspension, disabled scheduling, and termination. Record the energy tradeoff before adopting it. Do not use `latencyCritical`, permanently disable App Nap without evidence, or prevent device/display sleep to improve ordinary reminders.

Window configurations and App Nap mitigation remain validation gates. Do not claim unconditional foreground coverage, precise timing, zero CPU, or a fixed memory ceiling without measurements. Record the operating conditions and timing behavior supported by each result.

## 6. Acceptance plan

Use deterministic state tests for scheduling and real AppKit/device tests for presentation. A fake clock or supplied transition time must not be mistaken for evidence of real App Nap or window behavior. The detailed display matrix in the [technical research](research/macos-break-reminder.md) is a supporting checklist; apply this plan’s updated Pause/Quit behavior and `pt-PT` language choice.

### Scheduling and lifecycle

| Case | Expected result |
| --- | --- |
| Launch without opening Settings | Both enabled plans begin immediately; closing Settings leaves the app running |
| Both deadlines reached in one callback | Exactly one long-break session starts |
| Complete a short break | Short interval restarts; long remaining work time is preserved |
| Complete a long break | Both enabled intervals restart |
| Skip a long break while a short break is already due | Only the long plan resets; the short break remains due, including when its Skip action is disabled |
| Skip disabled | Direct Skip requests from buttons, menu commands, or keyboard paths are rejected; Pause and normal Quit still work |
| Obsolete callback after rescheduling | No stale overlay, duplicate completion, or change to the new session |
| Pause while working, wait, then Resume | Remaining work time is unchanged by manual pause |
| Pause during a break, wait, then Resume | All overlays hide during pause; the same session resumes with its remaining duration |
| System wake during manual pause | The manual pause remains in effect |
| Resume while system suspension remains active | No overlay or work scheduling starts until all system reasons clear |
| Overlapping device/display sleep and duplicate notifications | One absence is accounted for once; no premature resume |
| Absence below, at, and above a break-duration threshold | Only qualifying plans reset; others retain their work remainder |
| Absence during an active break | Remaining rest is credited once; a satisfied break completes once |
| Actual system sleep during manual pause | Only observed system absence earns credit; accounting does not clear manual pause |
| Change schedule while working | Only the affected plan is rescheduled using valid settings |
| Change duration or skip permission during a break | The active session retains its captured values; future sessions use the new settings |
| Disable plans during an active break | Future scheduling stops as configured, but the active break is not silently dismissed |
| Change appearance or language | No deadline, session identifier, or skip-permission reset |
| Change system wall-clock time | Monotonic work and rest durations remain correct |
| Quit during a break and relaunch | Windows are removed, no completion is fabricated, and a fresh work cycle begins |
| Both plans disabled and no active break | No deadline wait remains; the menu shows the disabled state |
| Invalid configuration or failed login registration | Retain valid state and show an appropriate error or actual service status |

### Display and interaction

Verify every available display, not just the primary one. Test foreground visibility, focus, and input interception independently, including during transitions.

- Single and multiple displays; primary-display changes; displays with negative coordinates; portrait orientation; mixed resolutions, backing scales, and refresh rates.
- Mirroring versus extended mode; hot-plugging; dock reconnection; laptop clamshell use and reopening.
- Multiple Spaces, both “Displays have separate Spaces” settings, Mission Control, Show Desktop, Stage Manager, and fullscreen or split-screen applications.
- Browsers, video playback, presentations, games, and other applications’ elevated floating windows. Record unsupported or conflicting cases.
- Sidecar, AirPlay, DisplayLink, and virtual displays where the necessary hardware or software is available. Mark untested configurations explicitly.
- Mouse movement and interaction across displays, continuous keyboard input, and repeated simultaneous commands. Input must not reach the underlying app while the overlay is expected to intercept it.
- Pause and Quit visible and usable on each overlay, including when Skip is absent. A request from one display affects the shared session once.
- Sleep/wake, locked but illuminated screens, unlocking, and user switching without interfering with system security or recovery interfaces.
- Notched displays, hidden menu bar/Dock, large text, VoiceOver, and Reduce Motion. Keep controls within usable areas.
- Break completion, Pause, normal Quit, abnormal termination, and system force quit leave no residual overlays or unusable presentation state.

Do not treat a screenshot as proof of input interception or synchronized behavior. Record brief content exposure or interaction gaps during Space and fullscreen transitions.

### Backgrounds and settings

- Exercise Stretch, Center, and Scale to Fit with small, large, ultrawide, and portrait images. Confirm the documented distortion, clipping, and empty-space behavior.
- Verify image orientation, transparent PNG regions, mixed Retina layouts, and stable Center dimensions after cache downsampling.
- Test corrupted, unsupported, and oversized inputs without destroying the previous working background or blocking reminder presentation.
- Verify imported images after restarting and after moving or deleting the original. An unavailable imported asset falls back to the configured color.
- Test transparency values **0, 1, 50, and 99**; reject -1, 100, fractional values, and nonnumeric input.
- Confirm that transparency affects only the background, all text and controls remain readable, and mouse input does not pass through at 99%.
- Change appearance during a break and hot-plug displays while images are visible. Preserve the session and its end time.
- Repeatedly open and close previews and take breaks. Verify that decoded images, windows, and views do not accumulate.

### Localization and accessibility

- Start with no stored preference under a non-English system language and verify an English interface.
- Select each of the eight languages, restart, and confirm persistence in Settings, AppKit menus, and every display’s overlay.
- Verify Portuguese from Portugal (`pt-PT`), and ensure Simplified and Traditional Chinese remain distinct choices.
- Test invalid stored identifiers and missing strings, with English fallback and no exposed internal keys.
- Change language during work, manual pause, and a break with Skip disabled. Timing, suspension, and permissions remain unchanged; Pause and Quit stay usable.
- Check pluralization, duration units, localized numbers, long translations, wrapping, clipping, and character coverage.
- Review translated meanings and consistent terminology, not merely catalog completeness. Verify VoiceOver labels and keyboard access in each language.

### Resource and system compatibility measurements

Run a Release build outside the debugger. Record hardware, exact OS version, display topology and scaling, power source, and Low Power Mode state.

Measure CPU time, Idle Wake Ups, physical memory footprint, Energy Impact, GPU activity, reminder delay, and resource release across quiet background work, open menus, visible countdowns, image-backed breaks, sleep recovery, and repeated cycles.

Acceptance requires no app-generated background 1 Hz polling loop, no continuously growing retained resources, no decoding tied to countdown ticks, and no sleep-prevention mechanism added for ordinary reminders. Record measured reminder delays and the effect of any App Nap mitigation instead of asserting an unmeasured guarantee.

Test **macOS 26 itself**. The development host inspected during planning runs macOS 27; successful tests there do not establish compatibility with the minimum supported version. Clearly label untested OS, device, and display configurations.

## 7. Documentation scope and completion checks

This section describes the original planning deliverable. Section 8 records the implementation that followed.

This change delivers an English implementation plan and a precedence notice in the preserved research document. It does not create application code, an Xcode project, image assets, a translation catalog, or runtime tests.

Before delivering the documents:

- Confirm every agreed requirement and selected default is represented.
- Verify consistent 0–99% transparency semantics and `pt-PT` localization.
- Check that no implementation section restricts Pause or normal Quit merely because Skip is disabled.
- Preserve the research body and its citations, with a notice explaining the superseded recommendations.
- Keep proposed configurations and future acceptance tests distinct from observed results.
- Validate Markdown structure and local document links.

Continuous foreground coverage, reliable input interception, App Nap timing, resource budgets, and system compatibility remain practical validation work. Distribution, signing/notarization, and any store submission are outside this documentation task and are not implied to be complete.

## 8. Implementation status and completion evidence

Updated 2026-10-30 after the first implementation. The [validation report](validation-report.md) records environments, commands, measurements, and the remaining manual checks in detail. This section summarizes the decisions made during implementation and the evidence for each milestone.

### Decisions made during implementation

| Topic | Decision | Reason |
| --- | --- | --- |
| Architecture | Apple silicon (`arm64`) only, deployment target macOS 26.0 | Agreed delivery scope; Intel is not supported |
| Project | Xcode project with filesystem-synchronized groups, a shared `TimeBreaker` scheme, a hosted Swift Testing target, ad hoc signing, and App Sandbox with user-selected read-only file access | Local development without Developer ID credentials |
| Overlay window class | Borderless **non-activating `NSPanel`** at the screen-saver level, with `canJoinAllSpaces`, `canJoinAllApplications`, `fullScreenAuxiliary`, `stationary`, and `ignoresCycle` | Under cooperative activation, `NSApp.activate()` is refused while another app is in use, so a plain window never became key. A non-activating panel becomes key without taking activation from the frontmost app. |
| Activation | No activation requests and no re-activation on deactivation. Ordering is restored once per Space change or deactivation event. | Avoids competing for focus with other apps and system recovery UI |
| Window level | Kept at the screen-saver level | Another app's window at the same level can appear above the overlay. Raising the level was rejected to avoid competing with system security and recovery interfaces. |
| Skip at zero | A Skip request is processed after any overdue completion | Otherwise, a Skip clicked after the countdown reaches zero, but before the deadline callback, recorded a finished long break as skipped and queued a catch-up short break |
| SIGTERM | Routed through normal termination | Overlays and activities are cleaned up when the process is terminated by signal |
| Image import | Byte-identical private copy. Truncated PNG, JPEG, and HEIC files are detected structurally, because ImageIO decodes them partially without failing. | Validation must not accept damaged files |
| Image decoding | ImageIO thumbnails sized to each display and layout. Stretch decodes are capped at 1.5× the display's long side. Center crops are copied with vImage, not `CGContext.draw`. | Drawing kept converted data in Core Graphics' process-wide cache, and separately resampled buffers lingered in the allocator cache. Both raised the footprint between breaks. |
| Localization | Semantic keys in `Localizable.xcstrings`, resolved through the selected language's `.lproj` bundle with English fallback. Durations use locale-aware Foundation formatting; menu countdowns use catalog plurals. | Lets the app language be chosen independently of the system language and switched live |
| App Nap | No activity assertion by default. An optional bounded activity remains available as a diagnostic switch (`-TBSchedulingActivity YES`). | Default scheduling met the timing goal in measurement; see the validation report |
| Diagnostics | Launch arguments for short intervals, appearance, language, and the initial Settings section. They are not persisted. | Makes runtime validation reproducible without changing saved settings |

### Evidence by milestone

| Milestone | Status on the development Mac (macOS 27.0.1) | Still required for release qualification |
| --- | --- | --- |
| 1. Window feasibility | These were verified: coverage of both displays (2× and 1×, negative coordinates), presence over a fullscreen app's Space, Mission Control, mirroring, rearrangement, primary-display changes, cleanup after completion and termination, and key-window status. | Manual click and keyboard delivery; Stage Manager; physical hot-plug; separate-Spaces on; macOS 26 |
| 2. Scheduler and lifecycle | Deterministic tests cover every scheduling, suspension, and natural-break rule. Release timing and resource measurements are recorded. | Runtime sleep, display-sleep, lock, and session-switch checks; login-item registration in `/Applications` |
| 3. Appearance and settings | Every layout and transparency value was checked. Import validation is tested. Memory release across repeated image-backed breaks was measured. | Manual import through the file picker; repeated preview open and close |
| 4. Localization and packaging | All eight languages were reviewed in Settings and overlays. Catalog coverage and placeholders are tested. The Release `.app` was built and its signature verified. | VoiceOver and Full Keyboard Access review in each language |
