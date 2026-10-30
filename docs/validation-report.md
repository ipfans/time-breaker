# Time Breaker v1 Validation Report

Date: 2026-10-30

This report records what was verified for the first version of Time Breaker, how it was verified, and what remains unverified. It distinguishes **local development completion** (the app builds, its automated tests pass, and core behavior was observed on the development Mac) from **release qualification** (macOS 26 compatibility, manual interaction checks, and hardware or system configurations not available here). Release qualification is not complete.

## 1. Test environment

| Item | Value |
| --- | --- |
| Hardware | MacBook Pro, Apple M1 Pro (Apple silicon) |
| Operating system | macOS 27.0.1. **macOS 26 was not available and was not tested.** |
| Toolchain | Xcode 27.1 (27A9275), Swift 6.4, macOS 27.0 SDK; deployment target macOS 26.0, `arm64` only |
| Display 1 | Built-in Liquid Retina XDR, 1512 × 982 points at 2× (3024 × 1964 pixels), notched (32-point top safe area), primary |
| Display 2 | LG 27GL850, 2560 × 1440 at 1×, arranged to the left, with Cocoa frame origin (−2560, −458) |
| Spaces | “Displays have separate Spaces” **off** (`NSScreen.screensHaveSeparateSpaces == false`). The on setting was not tested. |
| Power | AC power, Low Power Mode off |
| Screen lock | “Require password” immediately after sleep or screen saver |
| Automation limits | The validating process had Screen Recording access but **no** Accessibility or event-posting permission, so it could not synthesize clicks or keystrokes |

The automation limits matter. Visibility, ordering, window geometry, and timing were measured directly. The actual delivery of mouse clicks and keystrokes to the overlay could not be exercised automatically. Those checks are listed as manual in section 6.

## 2. Automated tests

Command (see the [README](../README.md)):

```sh
xcodebuild -project TimeBreaker.xcodeproj -scheme TimeBreaker -destination 'platform=macOS,arch=arm64' -derivedDataPath build/DerivedData test
```

Result: **all suites pass** (Swift Testing; 107 test functions, several parameterized, in 6 suites).

| Suite | Coverage |
| --- | --- |
| Scheduling rules (`BreakEngineTests`) | Fresh intervals on launch. Short and long transitions. Both plans due starts exactly one long break with no catch-up short break. The default schedule makes the third short break a long break. Skipping a long break preserves a due short break, including an unskippable one. A Skip that arrives after a break has run out completes it instead of skipping it. Skip rejection, with Pause still working. Repeated and stale skip requests. Pause and resume while working and during a break. Manual pause earns no credit. Wake does not clear manual pause. Resume during system suspension. Overlapping and duplicate suspension reasons count one absence. Natural-break thresholds below, at, and above each plan's break duration. Absence credited to an active break, including completing it exactly once. Sleep during a manual pause. Settings changes while working and during a break. Disabling plans during a break. Disabling and re-enabling all plans. |
| Deadline waiting (`BreakSchedulerTests`) | One wait for the nearest deadline. A stale generation cannot start or complete a newer break. No wait while suspended or disabled. Central skip rejection. A real `ContinuousClock` wait starts and completes a break. A cancelled wait never fires. |
| Preferences (`PreferencesTests`) | Product defaults. Work-interval, break-duration, and long-versus-short validation. Transparency boundaries 0, 1, 50, and 99 are accepted. −1 and 100 are rejected. Text input rejects `-1`, `100`, `50.5`, `abc`, empty input, `1e1`, `+5`, non-ASCII digits, and hex. Break fields reject out-of-range values, including `Int.max`, without overflow. Round-trip persistence. Corrupted data and per-field recovery, including a path-traversal image identifier. Only configuration is persisted. Invalid edits keep the last valid preferences. Appearance and language changes leave the active break, its skip permission, and the scheduling generation untouched. |
| Image layout (`ImageLayoutTests`) | Stretch, Center, and Scale to Fit geometry, including letterboxing, pillarboxing, enlargement, and portrait displays. Pixel requests bounded by display and image size, with Stretch capped for extreme aspect ratios. Center crops large images. Center size does not depend on decoded resolution. |
| Image import and decoding (`BackgroundImageStoreTests`) | PNG, JPEG, and HEIC import with a byte-identical private copy that survives deletion of the original. EXIF orientation swaps logical size. Rejects mislabeled GIF, TIFF, non-image data, truncated PNG, JPEG, and HEIC, animated PNG, oversized dimensions, and missing files, without leaving files behind. Replaced-image cleanup. Orientation-correct decoding. Center cropping. A missing asset falls back to color. The renderer reuses, releases, and budgets variants, and does not cache a decode that finishes after its variant was released. |
| Localization (`LocalizationTests`) | All eight `.lproj` bundles ship. Every key is translated in every language and never exposes its key. Placeholders match English. No stray `%`. Live language switching. Simplified and Traditional Chinese are distinct. Unsupported identifiers fall back to English. First launch is English, and the selection persists. Missing translations fall back to English. Plural rules for English, Portuguese (Portugal), French, and Japanese. Localized durations and countdowns. Positional arguments. Status menu wording for each state. |

The tests use a supplied clock and never wait for real minute-long intervals. They are not evidence of App Nap behavior or window behavior; sections 3 and 5 cover those.

## 3. Runtime validation on the development Mac

Runs used the Debug build, except for the performance runs, which used Release. Each run used the diagnostic launch arguments in the README. Evidence came from three sources:

- the app's unified-log coverage records, made from inside the app;
- an external `CGWindowList` observer that reports window layers, bounds, on-screen state, and the frontmost window at each display's center;
- screenshots, taken only while an overlay covered the screen.

### Overlay presentation and coverage

| Scenario | Result |
| --- | --- |
| Break on both displays | **Verified.** There is one overlay per display at window layer 1000 (screen saver) with exact display frames, including the negative-origin display. The overlay covers the menu bar and notch area. It is frontmost at each display's center according to both the external window list and AppKit hit testing (`NSWindow.windowNumber(at:)`), and occlusion state is visible. Both displays showed the same countdown in simultaneous screenshots. The final Release build's records from the 20-minute run show the same result, with the display under the pointer holding key focus. |
| Mixed backing scales (2× and 1×) at the same time | **Verified.** |
| Presentation latency | 51–103 ms from break start to all windows ordered front, across 15 runs. |
| Completion leaves no residual windows | **Verified** by the external window list after every run. |
| Keyboard focus | **Finding, fixed.** The initial `NSWindow` configuration was never key: under cooperative activation, `NSApp.activate()` is refused while the user works in another app (the log showed `app active=false`, `key=false`). A standalone probe compared three approaches: `activate()` was refused; the deprecated `activate(ignoringOtherApps:)` stole activation; and a **non-activating `NSPanel`** became key while the other app stayed frontmost. The overlay now uses the non-activating panel. After the change, the overlay under the pointer reports `key=true` while Chrome or another app remains frontmost. Whether keystrokes actually reach the overlay is **not verified** automatically; see section 6. |
| Mouse interception | **Partially verified.** Window-server hit testing returns the overlay at each display's center, including at 99% transparency, and `ignoresMouseEvents` is explicitly `false`. Actual click delivery, including over transparent image regions, is **not verified** automatically. |
| Native fullscreen app in its own Space | **Verified.** A helper app entered native fullscreen before the break. The overlay was frontmost on both displays over the fullscreen Space. At 50% and 99% transparency, the fullscreen app was visible through the background, which confirms the overlay is above it. |
| Fullscreen Space torn down during a break | **Verified.** The Space-change notification triggered a single re-order, and coverage remained on both displays. |
| Mission Control during a break | **Verified.** Mission Control was invoked through its launcher during a break. The overlays stayed full-size and frontmost. A control run without a break confirmed that Mission Control engages. |
| Mirroring, then extended mode (display removal and addition) | **Verified** using `CGCompleteDisplayConfiguration(.forAppOnly)`, which reverts automatically. Mirroring reduced the overlay to one window and released the other. Unmirroring added a window that joined the same session. Exactly one session was presented throughout. |
| Primary-display change and rearrangement | **Verified.** The external display became primary at (0, 0) and the built-in display moved to the right. Both frames followed exactly, and restoring the arrangement restored the frames. |
| Live backing-scale change on one display | **Not verified.** The requested HiDPI mode for the external display did not take effect. |
| Unskippable break | **Verified.** Skip is hidden, a localized notice appears, and Pause and Quit are shown. |
| Termination during a break | **Verified.** SIGTERM is routed through normal `NSApp.terminate`: overlays are dismissed and no completion is recorded. SIGKILL leaves no residual windows. Relaunching starts a fresh cycle. |
| Other apps' high-level windows | **Conflicting case recorded.** A third-party app's window at the same level (layer 1000) appeared above a corner of the overlay. The break content stayed visible. Notification Center windows are at layer 21, below the overlay. The overlay deliberately stays at the screen-saver level, so it does not compete with system security or recovery interfaces. |

### Backgrounds

All image runs used `/System/Library/Desktop Pictures/Sonoma.heic` (6016 × 6016 HEIC, 36 MP), imported inside the sandbox through the normal import path.

| Scenario | Result |
| --- | --- |
| Scale to Fit, Center, Stretch on both displays | **Verified visually.** Scale to Fit pillarboxes with the background color. Center shows the middle crop at 1 image pixel per point. Stretch fills and distorts. Each display is laid out independently. |
| Transparency 0, 1, 50, 99 | **Verified visually** over a fullscreen app. 0 and 1 are effectively opaque. At 50, the app shows through the composed image. At 99, the app is almost fully visible. The content panel stays opaque at every value. |
| Image decoding never delays the reminder | **Verified.** The overlay appears with the color immediately, and the image follows asynchronously. Presentation stayed within 90–103 ms with the 36 MP image. |
| Memory across repeated image-backed breaks | **Finding, fixed.** The first five-cycle Stretch run showed the footprint after each break climbing 16 → 46 → 68 → 92 MB before leveling off. `heap`, `malloc_history`, and `leaks --traceTree` traced this to Core Graphics' process-wide image-data cache: `CGContext.draw`, used to resample and crop, kept converted source data after the source image was released. Resampling with vImage removed that cache, but its large transient buffers then lingered in the system allocator's cache, with 35–45 MB dirty and none of it live. Now: Stretch uses a uniformly scaled ImageIO decode, capped at 1.5× the display's long side, and Center crops are copied with vImage. |
| Memory after the fix (Release, five cycles per layout) | During breaks: Stretch 84–90 MB, Center 50–51 MB, Scale to Fit 61–70 MB. Within 3–8 s of each dismissal, the footprint returns to 22–29 MB, and it stays flat across cycles. The baseline before the first break is 16–22 MB; first use of the overlay adds about 6 MB once for AppKit and SwiftUI initialization. |

### Localization and Settings

| Scenario | Result |
| --- | --- |
| Settings, all three sections, in all eight languages | **Verified visually** (24 captures). There is no clipping or untranslated text, and the window title is localized. Numbers follow each locale: for example, French uses “6 016”, while Portuguese and Spanish leave four-digit numbers ungrouped. |
| Break overlay in all eight languages | **Verified visually** (8 captures, unskippable variant). CJK text renders with system fonts, and buttons fit. |
| Window title | **Finding, fixed.** SwiftUI title bridging left the title as “Untitled”. The title is now set and updated directly. |
| Login item status | `SMAppService.mainApp.status` is reported as `.notFound` for the build-folder copies. Registering and unregistering through the switch were **not exercised**, to avoid changing your login items without your approval. |

### Independent code review

A separate read-only review against the plan found five defects. All five are fixed and covered by tests where testable:

1. A Skip clicked after a break ran out but before its deadline callback was recorded as a skip. That kept a due short break pending after a finished long break, so a catch-up short break started immediately.
2. Typing a very large number into a minutes field overflowed during conversion and crashed the app.
3. Out-of-range seconds, and negative minutes, were silently clamped and saved instead of being rejected with an error.
4. A decode that finished after its overlay was dismissed, or after Settings closed, was added back to the image cache. A cancelled background load also kept decoding for the remaining displays.
5. The overlay window's accessibility name was not updated when the language changed during a break.

## 4. Performance (Release build, outside the debugger)

The Release build was launched with `open`, not under Xcode, on AC power with Low Power Mode off and both displays attached. Measurements came from `ps` (CPU time), `top` (CPU percentage and idle wakeups, sampled every 30 s), `footprint` (physical footprint), and the app's own unified-log timing records. The app had no visible windows between breaks, so App Nap was free to act. No activity assertion was held.

### Reminder timing

| Run | Break-start callback lateness | Presentation | Completion lateness |
| --- | --- | --- | --- |
| Product defaults (20-minute work interval, 20-second break), 1 cycle | 807 ms | 103 ms | 34 ms |
| 240-second work intervals, 3 cycles | 404, 818, 994 ms | 36–75 ms | 5–69 ms |
| Short Debug runs (3–8 second intervals), 15+ cycles | 575–962 ms | 39–103 ms | 5–100 ms |

Lateness is measured from the monotonic deadline to the callback. It stays below the 1-second tolerance hint given to `ContinuousClock.sleep(until:tolerance:)`, so the system is coalescing within the allowed window rather than App Nap throttling it. **Decision:** keep default scheduling. The `userInitiatedAllowingIdleSystemSleep` activity remains available only as the diagnostic switch `-TBSchedulingActivity YES` and is not enabled by default. Low Power Mode, battery power, and multi-hour background periods were not measured.

### Background cost while waiting

| Measure | Result |
| --- | --- |
| CPU time across a 20-minute idle work interval | 0.15 s → 0.19 s (0.04 s in total) |
| `top` CPU while waiting | 0.0% in every 30-second sample |
| Idle wakeups | 0 during the 20-minute interval; 1 across the whole run, at the break |
| Polling | None observed. There is no app-generated 1 Hz work while waiting. The countdown ticker runs only while overlays are visible, and the menu timer only while the menu is open. |
| Total CPU time, including breaks | 0.67 s for a 22-minute run with one 20-second break; 0.72 s for a 12.7-minute run with three breaks |

### Memory

| Measure | Result |
| --- | --- |
| Footprint while idle, before the first break | 14–16 MB |
| Footprint after the first break | 21–23 MB, flat afterward. The first overlay presentation initializes AppKit and SwiftUI once. |
| Solid-color break | No measurable increase in the app's footprint. Window backing stores belong to the window server. |
| Image-backed breaks (36 MP HEIC, two displays) | See section 3. The footprint returns to 22–29 MB after every break, with no growth across five cycles per layout. |
| Overlay windows and views after a break | None remain (`heap` instance counts and the external window list) |

### Not measured

- GPU activity and Energy Impact: these require `powermetrics` (root) or Instruments; neither was used.
- Low Power Mode and battery power.
- Very long runs over several hours.

## 5. Sleep, wake, and session events

The rules are covered by deterministic tests (section 2). They were **not exercised at runtime**. With the screen lock set to “immediately”, display sleep would have locked the Mac during unattended validation. `SystemActivityMonitor` subscribes to the documented `NSWorkspace` notifications (`willSleep`/`didWake`, `screensDidSleep`/`screensDidWake`, `sessionDidResignActive`/`sessionDidBecomeActive`) and logs each one under the `SystemActivity` category, so a manual run can be checked in the log.

## 6. Unverified scenarios

These items need a person at the Mac, other hardware or software, or another macOS version. None of them should be reported as passing until checked.

**Manual interaction checks** (any Mac):

1. Click Pause, Skip, and Quit on each display. Each click must take effect once for the shared session. Pause hides all overlays, and Resume from the menu brings back the same countdown.
2. Click Skip on both displays as quickly as possible. Only one session should end.
3. During a break, type in the app that was frontmost before the break. The keystrokes must not appear there. The log shows `Key event delivered to overlay` (debug level) for each key.
4. Click through the overlay at 99% transparency and over transparent PNG regions. The app underneath must not receive the clicks.
5. Press Esc and ⌘W during a break. Neither may end the break. ⌘Q quits normally.
6. Use VoiceOver and Full Keyboard Access to reach every overlay and Settings control in at least one CJK language and one European language.
7. Enable Reduce Motion and confirm the overlay appears without a fade.
8. Import an image through Choose Image…, then move or delete the original and relaunch. The background must remain.
9. Turn Open at login on and off from the Release app copied to `/Applications`, and check System Settings › General › Login Items.

**System events:** sleep and wake; display sleep with a short timeout; a locked but lit screen; unlocking; fast user switching; sleep while manually paused; changing the system clock during a work interval.

**Display and window environments:** physical hot-plugging and dock reconnection; clamshell operation and reopening the lid; a portrait display; a live backing-scale change; “Displays have separate Spaces” turned on; Stage Manager; Show Desktop; split-screen fullscreen; full-screen games and video players; Sidecar, AirPlay, DisplayLink, and virtual displays; hidden menu bar and Dock; large text.

**Compatibility:** macOS 26 was not tested. A successful run on macOS 27 does not establish compatibility with the minimum supported version. Intel Macs are unsupported by design.
