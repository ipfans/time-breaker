# Time Breaker macOS Technical Research

> **Implementation decisions (2026-10-30):** Follow the [implementation plan](../implementation-plan.md) where it differs from this research. Version 1 targets macOS 26+; disabling Skip leaves Pause and normal Quit available; manual pause freezes remaining time and earns no natural-break credit by itself; Portuguese uses `pt-PT`. These decisions supersede earlier recommendations below. The original research and citations are retained for reference.

Research date: 2026-10-30. Scope: a native Swift macOS menu bar app with automatic scheduling, short and long breaks, persistent overlays across all displays, configurable backgrounds and transparency, image layout options, per-break skip permissions, an application language setting with eight supported languages, and low resource usage while running in the background. This work produces a technical proposal only; no app project or prototype has been implemented. Confirmed requirements and proposed behavior are identified separately. Recommendations have not yet been approved as the final product specification.

**Conclusion: the core functionality is feasible. Use Swift, AppKit, and SwiftUI in a single user-space process, store deadlines with a monotonic clock, and wait only for the next state transition. The main technical risks are overlay visibility and keyboard focus across Spaces, and reminder delays under App Nap.** “Cannot skip” should mean that a break cannot be skipped through the app; it cannot guarantee that the user cannot bypass it through the operating system.

## Requirements and technology choices

| Requirement | Proposed implementation | Boundaries to clarify |
| --- | --- | --- |
| Remain in the menu bar without a Dock icon during normal use | `LSUIElement = true`, AppKit `NSStatusItem`, and `NSMenu` | Closing Settings must not terminate the process; reminders cannot continue after the system terminates the app |
| Start scheduling automatically on launch | Read settings and establish both deadlines during initialization | Do not wait for the user to open Settings; starting timers on launch and launching at login are separate capabilities |
| Short and long breaks | Store an enabled flag, work interval, break duration, and skip permission for each | Define whether intervals include break time and which break takes priority when they overlap |
| Keep fullscreen reminders in front and show them on all displays simultaneously | One borderless AppKit window per currently available display, sharing the same break state | Acceptance must cover normal desktops, other apps’ fullscreen Spaces, Stage Manager, and changing display configurations |
| Background styles and 0–99% transparency | Solid color or a local static image, with transparency applied only to the background layer | Text and controls remain legible; verify that transparent regions do not let mouse input pass through |
| Stretch, center, and proportionally scale images | Native image layout, calculated independently for each display | Define empty space, cropping, and behavior across displays with different scaling |
| Configurable application language, English by default | Bundle English and seven additional localizations, and persist the selected language | Apply the same selection to SwiftUI, AppKit menus, and accessibility text without changing break state |
| Breaks that cannot be skipped | Central state logic checks skip permission for every in-app entry point | Hiding a button is insufficient; the app cannot prevent process termination or a system restart |
| Minimize resource usage | One deadline-waiting task, a static menu bar icon, and UI created on demand | Measure wakeups, memory, GPU usage, and reminder timing as well as CPU usage |

Apple provides `LSUIElement` for background agent apps that do not appear in the Dock. `NSStatusItem` represents an item in the system menu bar. Here, “agent” describes the application’s presentation; it does not require installing a LaunchAgent or privileged service. [LSUIElement](https://developer.apple.com/documentation/bundleresources/information-property-list/lsuielement), [NSStatusItem](https://developer.apple.com/documentation/appkit/nsstatusitem)

SwiftUI’s `MenuBarExtra` is also an option. Prefer `NSStatusItem` for this project: fullscreen windows and application lifecycle management already require AppKit, so keeping menu state under the same control is straightforward. Apple also notes that an app whose only presence is a `MenuBarExtra` terminates automatically when the user removes that item. Account for this in the product’s behavior. This is a lifecycle decision, not evidence that AppKit uses less memory than SwiftUI. [MenuBarExtra](https://developer.apple.com/documentation/swiftui/menubarextra)

The core APIs allow a baseline of **macOS 13**: `ContinuousClock`, `MenuBarExtra`, the relevant modern window collection behaviors, and `SMAppService` are available on that release. The minimum shipping version still depends on the intended maintenance scope; API availability does not establish compatibility without testing. The AppKit SDK headers on this machine also mark `canJoinAllApplications` as available from macOS 13.0. [ContinuousClock](https://developer.apple.com/documentation/swift/continuousclock), [SMAppService](https://developer.apple.com/documentation/servicemanagement/smappservice)

## Relevant behavior in Time Out

The local `/Applications/Time Out.app/Contents/Info.plist` identifies the installed version as **3.1 (3105)** and its minimum system version as macOS 26.0. These are facts about the installed package, not requirements for this project or evidence of Time Out’s internal architecture.

Time Out’s current official help describes break content and synchronized control panels on multiple displays, optional disabling of skip and postpone buttons, and themes built with HTML, CSS, and JavaScript. This supports the proposed interaction model of two break types, overlays on every display, and configurable controls. This project does not require extensible themes, so native views are recommended. [Time Out break control panel](https://dejal.com/help/timeout/en/control-panel.html)

Its historical release notes explicitly describe changing scheduling to use one timer with multiple due dates. That aligns with this project’s goal of minimizing wakeups. The notes do not identify the timing API used in the current version or establish its present CPU or memory usage. [Time Out release notes](https://www.dejal.com/timeout/release/?to=1002)

## Schedule with deadlines and calculate countdowns for display

The proposed deadline-based approach is appropriate, but storing a time alone will not trigger a reminder. A system waiting mechanism must resume execution when the deadline is reached. Separate two concerns:

- **Scheduling state:** store the short-break and long-break deadlines; during a break, store its end time.
- **Display state:** calculate remaining time as “deadline − current time” when the UI needs it, instead of maintaining a counter that decreases every second.

A delayed refresh then corrects itself on the next update. State changes occur only on launch, a deadline, break completion, a skip, a settings change, or a system event.

### Clock selection

| Clock | Suitable uses | Considerations for this app |
| --- | --- | --- |
| `Date` | Calendar time, logs, and displaying the expected clock time of the next break | Do not use it as the sole basis for work intervals; system clock corrections or user changes can move wall-clock time |
| `ContinuousClock` | Elapsed time within the process; continues advancing during system sleep | Recommended as the common timing reference; product rules determine whether sleep counts as a break |
| `SuspendingClock` | Time while the system is awake; stops advancing during system sleep | System awake time is not user work time: the machine may remain awake while the user is away or the screen is locked |

Apple explicitly distinguishes the sleep behavior of these two monotonic clocks. `ContinuousClock.Instant` values are comparable within the current program execution; do not serialize them as reliable timestamps across processes or restarts. [ContinuousClock](https://developer.apple.com/documentation/swift/continuousclock), [SuspendingClock](https://developer.apple.com/documentation/swift/suspendingclock)

Use `ContinuousClock` while the process runs and persist only configuration. Start a fresh scheduling cycle on each normal launch. This meets the requirement to start immediately and avoids adding clock restoration across launches. If preserving remaining time after quitting and reopening becomes a requirement, design a separate restoration policy rather than directly persisting an `Instant`.

### A single waiting task is sufficient

Start with Swift Concurrency’s `ContinuousClock.sleep(until:tolerance:)`: find the nearest deadline and create one cancellable Task to wait for it. Apple confirms that this call suspends the task without blocking its underlying thread, supports a tolerance, and throws `CancellationError` when cancelled. [Clock sleep](https://developer.apple.com/documentation/swift/continuousclock/sleep(until:tolerance:))

The proposed scheduling sequence is:

1. Establish both work deadlines on launch and wait for the earlier one.
2. When the wait completes, read the clock and current state again to decide which break should begin.
3. During a break, wait for that break’s end time instead.
4. After completion or an allowed skip, calculate the next event.
5. Cancel the previous task and reschedule when settings or system state change.

A cancelled task must not continue with its stale deadline action. Handle cancellation and check the current state and scheduling identifier before entering a break. Do not swallow a cancellation error and let an old task continue. Keep state transitions on the main actor so that two breaks cannot create windows simultaneously.

A one-shot `DispatchSourceTimer` is also suitable and supports leeway. It is a reasonable alternative if the team prefers GCD. There is no need to maintain both mechanisms, and no evidence here that a Task necessarily uses less energy than GCD. [DispatchSourceTimer](https://developer.apple.com/documentation/dispatch/dispatchsourcetimer)

An initial reminder tolerance of approximately one second is a suggested product tradeoff to refine through measurement, not a system timing guarantee. Apple recommends reducing unnecessary timer wakeups, cancelling repeating timers when they are no longer needed, and allowing the system to coalesce wakeups. Even zero tolerance does not guarantee exact execution time. [Apple timer energy guidance](https://developer.apple.com/library/archive/documentation/Performance/Conceptual/power_efficiency_guidelines_osx/Timers.html)

`NSBackgroundActivityScheduler` is intended for deferrable maintenance work whose execution time the system chooses partly according to energy considerations. It is not recommended for reminders that promise to appear at a specified interval. [NSBackgroundActivityScheduler](https://developer.apple.com/documentation/foundation/nsbackgroundactivityscheduler)

## Proposed rules for short and long breaks

Support two break types in the first version, without an editor for an arbitrary number of schedules. Each type has an enabled flag, work interval, break duration, and skip permission. Validate positive durations and reasonable upper limits, and recover invalid or corrupted settings to valid values. A zero interval must not cause repeated immediate overlays.

Label the interval as **how long to work before taking a break**, excluding the break itself. Example initial values are 20 minutes of work followed by a 20-second short break, and 60 minutes of work followed by a 5-minute long break. These are adjustable product defaults, not medical advice or a promise of health benefits.

| Event | Proposed behavior |
| --- | --- |
| Application launch | Immediately start the work interval for each enabled break type |
| Short break completes | Restart the short-break interval; retain the long break’s remaining work time, excluding the time spent on this break |
| Long break completes | Restart both intervals so a short break does not appear immediately afterward |
| Both breaks are overdue | Start only the long break; do not stack overlays or queue a catch-up short break |
| A break is skipped | Reschedule only that break type; do not mark it completed or reset the other type as a consequence |
| Settings change | While working, reschedule the affected plan; an active break retains the duration and skip permission captured when it began |
| Both types are disabled | Keep no scheduled waiting task and clearly show the disabled state in the menu |

Allowing a completed long break to satisfy a short break assumes that the long break lasts at least as long as the short one. Settings should preserve that constraint. Skipping a long break must not cancel an unskippable short break as a side effect.

The minimal states are working, on a break, suspended because of system state, and fully disabled. Break windows exist only while on a break. Suspension must retain the preceding state and remaining time. No database, message bus, or general workflow engine is needed.

## Sleep, time away, and screen locking

An ordinary app cannot be expected to display fullscreen reminders while the system is asleep, and it should not prevent the user’s Mac from sleeping just to deliver a reminder. Observe system events and reevaluate state on return.

Apple provides `NSWorkspace` notifications for device sleep, wake, display sleep, and user session switching. Subscribe to the corresponding workspace notifications through `NSWorkspace.shared.notificationCenter`; display configuration changes use AppKit’s display-change notification. [Device sleep](https://developer.apple.com/documentation/appkit/nsworkspace/willsleepnotification), [Device wake](https://developer.apple.com/documentation/appkit/nsworkspace/didwakenotification), [Display sleep](https://developer.apple.com/documentation/appkit/nsworkspace/screensdidsleepnotification)

The following recovery rules are proposed to avoid immediately presenting an overdue break after the user returns from an hour away:

- At the start of the absence, save the remaining work time, cancel the reminder wait, and record when the absence began.
- On return, reset a break type’s work interval if the absence meets that break’s duration requirement. Otherwise, restore its remaining work time.
- An absence can also satisfy a break that was already in progress. If it does not, continue the remaining break duration.
- Device sleep, display sleep, and session switching can overlap. Track the suspension reasons and resume only when all relevant reasons have cleared. Duplicate notifications must not repeatedly subtract or reset time.

These are proposed “natural break” semantics. Treating a powered-off display as an indication that the user is away is an approximation; it does not prove that the user has stood up.

**Do not treat user-session switching notifications as officially guaranteed screen-lock notifications.** The documented meaning of `sessionDidResignActiveNotification` is that the user session is switching out, and display sleep does not cover every locked-screen state. The commonly cited distributed notification name `com.apple.screenIsLocked` should not be a foundation of first-version correctness. Prototype cases such as a locked screen that remains lit and subsequent unlocking before promising precise suspension on screen lock. [Session switching notification](https://developer.apple.com/documentation/appkit/nsworkspace/sessiondidresignactivenotification)

Keyboard and mouse idle detection is not currently a core requirement. If added later, the public `CGEventSource.secondsSinceLastEventType` API can report time since the last input, but it does not detect whether a person is present: reading or watching a video may involve no input. Its permission behavior must also be tested on the target systems and in the sandbox. Consider querying at a deadline or sampling infrequently instead of continuously polling every second or recording every input event. [Quartz input elapsed-time query](https://developer.apple.com/documentation/coregraphics/cgeventsource/secondssincelasteventtype(_:eventtype:))

## Fullscreen reminder windows

**Confirmed requirement: throughout a break, the overlay must remain in front of ordinary application content and appear on every currently available display. Switching applications, desktops, or display configurations must not end the break or leave an uncovered display where work can continue.** This is a first-version acceptance requirement. The window configurations below are implementation candidates that still need validation.

Use **borderless windows covering the entire display**, rather than relying on a normal window’s green fullscreen button. Create one window for each `NSScreen`, positioned using `screen.frame` rather than `visibleFrame`, which excludes the Dock and menu bar areas. The content comprises a configurable solid-color or image background, native text, remaining time, and a skip button shown only when allowed. [NSScreen.frame](https://developer.apple.com/documentation/appkit/nsscreen/frame)

AppKit configurations to evaluate include:

- `canJoinAllSpaces`: allows the overlay to appear in multiple Spaces.
- `canJoinAllApplications`: Apple explicitly identifies floating windows and system overlays as uses for this behavior. It can join other apps’ fullscreen Spaces when eligible and also affects Stage Manager behavior.
- `fullScreenAuxiliary`: test it as part of candidate configurations on supported systems; an older configuration recipe is not a substitute for validation.
- `stationary`: Apple describes this as remaining visible and stationary in Mission Control. Evaluate it to keep the overlay out of ordinary window-overview behavior. Do not combine it with `managed` or `transient`.
- The `screenSaver` window level is a starting point for testing. It is only a window level; it does not grant the ability to cover system security interfaces or actually lock the computer.

Apple qualifies `canJoinAllApplications` with “when eligible”; it is mutually exclusive with `primary` and `auxiliary`. Prototypes must establish which combinations meet the focus and multi-display requirements. Research alone cannot establish that a few configuration flags cover every scenario. [Across Spaces](https://developer.apple.com/documentation/appkit/nswindow/collectionbehavior-swift.struct/canjoinallspaces), [Across applications and fullscreen Spaces](https://developer.apple.com/documentation/appkit/nswindow/collectionbehavior-swift.struct/canjoinallapplications), [screenSaver level](https://developer.apple.com/documentation/appkit/nswindow/level-swift.struct/screensaver)

Overlay visibility and correct keyboard focus are separate requirements. A borderless window may not become the key window by default and needs suitable `canBecomeKey` behavior. Apple also explicitly states that `NSApplication.activate()` requests activation without guaranteeing it. Test whether input still reaches the previous app when the overlay appears, and whether the skip button works correctly with the keyboard and VoiceOver. [canBecomeKey](https://developer.apple.com/documentation/appkit/nswindow/canbecomekey), [activate](https://developer.apple.com/documentation/appkit/nsapplication/activate())

When displays are connected, removed, or rearranged during a break, respond to `didChangeScreenParametersNotification` by adding, removing, or adjusting their windows. Every display shares one break state and end time rather than running its own scheduler. [Display configuration notification](https://developer.apple.com/documentation/appkit/nsapplication/didchangescreenparametersnotification)

Limit the first version to brief fade transitions and avoid continuous blur, video, or animated backgrounds. Respect the system’s Reduce Motion setting. Release windows and views when the break ends, and attempt to return focus to the application that was active before the break so the user can resume keyboard interaction in the appropriate place. [Reduce Motion](https://developer.apple.com/documentation/appkit/nsworkspace/accessibilitydisplayshouldreducemotion)

### Acceptance criteria for remaining in front and handling input

Keeping overlays in front requires window levels, behavior on deactivation, and visibility across Spaces to work together. Calling an activation method once at the beginning of a break is insufficient.

- **Window level:** a higher-level window can appear ahead of lower-level windows. This does not establish that it will remain above every system window or other overlay at the same level. [NSWindow.level](https://developer.apple.com/documentation/appkit/nswindow/level-swift.property)
- **Visibility after switching apps:** explicitly keep `hidesOnDeactivate = false`. This is particularly important for `NSPanel`, whose default is `true`, conflicting with the requirement. [hidesOnDeactivate](https://developer.apple.com/documentation/appkit/nswindow/hidesondeactivate)
- **Ordering and focus are separate:** `orderFrontRegardless()` moves a window to the front of its own level without changing the key window. It does not establish that input stops reaching the previous app. Apple also advises using this method sparingly; do not repeatedly call it in a loop to seize the foreground. [orderFrontRegardless](https://developer.apple.com/documentation/appkit/nswindow/orderfrontregardless())
- **Recovery after desktop changes:** respond to `activeSpaceDidChangeNotification` and display configuration events by reconciling overlays. Candidate Mission Control behavior includes `stationary`; validate the actual effect and configuration combinations. [Space change notification](https://developer.apple.com/documentation/appkit/nsworkspace/activespacedidchangenotification), [stationary](https://developer.apple.com/documentation/appkit/nswindow/collectionbehavior-swift.struct/stationary)

Mouse input must not pass through the overlay to the application beneath it. Once a break window has focus, keyboard input must not continue reaching the previous application. If skipping is allowed, the controls on every display must work; otherwise, all displays enforce the same restriction. Controls may appear on multiple displays, but windows must not repeatedly compete to become the key window. The currently interacting window should receive keyboard focus.

Coordinate windows through events rather than adding continuous polling to repeatedly raise or activate them. Coalesce ordering recovery after app switches and check that a break is still active. Do not compete with system lock screens, authorization prompts, or the Force Quit interface for focus. Login, lock, and security interfaces are outside the promise of remaining above all interfaces; when the normal user session returns, reconcile overlays according to the recovery rules.

Also test special high-level floating windows from other applications. If one can persistently obscure the break content, that scenario has not passed the foreground-visibility requirement. Ordinary public window APIs do not provide an exclusive guarantee against being covered by any other process.

### Synchronization and changing display configurations

A single break is the unit of synchronization: every display uses the same break identifier, start time, end time, and skip permission. Prepare all display windows first, then issue their display requests in the same UI update cycle. Process completion or an allowed skip once and close every overlay together. Different refresh rates and transport mechanisms prevent a guarantee that every physical panel updates on the same frame, but the product must not run separate countdowns or visibly stagger break starts across displays.

Read `NSScreen.screens` again whenever the display configuration changes. Do not permanently cache the launch-time array or rely only on `NSScreen.main`. Apple explicitly notes that displays can be added, removed, and reconfigured dynamically, and that the primary display may differ from the display containing the active window. [NSScreen.screens](https://developer.apple.com/documentation/appkit/nsscreen/screens)

The overlay controller should reconcile its window collection using current display identities: a newly connected display joins the active break with its original end time; removing a display releases its window; changes in position, rotation, scaling, or the primary display update geometry. Screen coordinates may be negative, so do not assume that every display is to the right of the primary one. Native layout uses points, and displays with different Retina scaling cannot share a single pixel multiplier.

In extended mode, cover each independently drawable display area. In mirrored mode, verify that the content is reproduced on every physical display rather than blindly creating overlapping controls based on the number of panels. Include Sidecar, AirPlay, and virtual displays when the system exposes them as available screens, but verify support with the corresponding devices or software.

Display changes must not restart the break or reset its end time. When no displays are available, apply the suspension and absence rules. A window creation or configuration failure must not silently count as successful fullscreen coverage; retain diagnostic information and mark the scenario as not yet passing acceptance.

### Display and interaction compatibility matrix

This is an acceptance checklist for development, not a record of tests already passed. Core desktop scenarios and supported display configurations must be tested before release. Cases requiring particular hardware or software must be explicitly marked unverified until tested.

| Scenario | Expected result |
| --- | --- |
| Single display, multiple extended displays, primary display changes | Cover every available display area without omitting secondary displays; maintain consistent break state |
| Displays to the left of or above the primary display, portrait orientation, different resolutions and scaling | Correct coverage, with clear text and controls that stay within bounds |
| Mixed refresh rates and Retina/non-Retina displays | Share the end time and countdown; do not add a separate scheduler for each display |
| Switching between mirrored and extended modes | Correctly mirror or independently cover content, without duplicate controls or missed displays |
| Connecting or removing external displays, disconnecting or reconnecting a dock | New displays join the current break; obsolete windows are released; remaining time stays consistent |
| Laptop operating with its lid closed and an external display, then reopening the lid | Follow the actual available display set; do not assume that closing the lid means the entire system has gone to sleep |
| Multiple desktops, trackpad Space switching, Mission Control, Show Desktop | All available displays remain covered after the transition; record any exposed content or opportunity for interaction during the transition |
| “Displays have separate Spaces” enabled and disabled | Test both system configurations rather than only the default |
| Browsers, video, presentations, and games in fullscreen or split-screen modes | Verify actual visibility and input focus; success in ordinary fullscreen mode does not replace testing other modes |
| Stage Manager, other apps’ dialogs, and high-level floating windows | The overlay is not absorbed into an app group or hidden when the original app changes; identify conflicting cases |
| Command-Tab, moving the pointer between displays, continuous keyboard input | Ordinary application switching does not remove the overlay; mouse input does not pass through; keyboard focus follows the defined rules |
| Skippable and strict breaks, simultaneous clicks on multiple displays | Skip permission is consistent everywhere; one valid action ends only one break |
| Sleep and wake, display power-off, screen locking, fast user switching | Do not disrupt system sessions; restore according to timing rules without duplicate overlays |
| Sidecar, AirPlay, DisplayLink, virtual displays | Individually verify exposed screens, connection changes, overlays, and transmission latency |
| Notched displays, automatically hidden menu bar or Dock, large text, VoiceOver, Reduce Motion | Backgrounds cover the drawable area; controls avoid unavailable areas and remain accessible |
| Break completion, application failure, or system force quit | No leftover overlays; restore presentation state and appropriate focus on normal completion, and preserve system recovery paths |

Read the “Displays have separate Spaces” setting through `NSScreen.screensHaveSeparateSpaces`. It affects fullscreen presentation strategy and must be a test dimension. [screensHaveSeparateSpaces](https://developer.apple.com/documentation/appkit/nsscreen/screenshaveseparatespaces)

## Background settings, transparency, and image layout

**Confirmed requirements: configurable backgrounds such as solid colors and images, a transparency range of 0–99, and image modes for stretching, centering, and proportional scaling.** For the first version, implement solid colors and local static images, with one appearance configuration shared by both break types and all displays. Separate configurations per break or display, animated backgrounds, and additional styles have not been explicitly requested and should not be added in advance.

| Setting | Proposed behavior |
| --- | --- |
| Background type | Solid color or local image |
| Background color | The color used in solid-color mode, and behind an image when it leaves empty space, contains transparent regions, or fails to load |
| Background image | Import through the system file picker; consider static formats decoded by the system, such as PNG, JPEG, and HEIC |
| Image layout | Stretch, Center, or Scale to Fit; default to showing the entire image proportionally |
| Background transparency | An integer percentage from 0 to 99, with a synchronized slider and numeric value; apply only to the composited background |

### Image layout semantics

| Mode | Scaling and cropping rules | When image and display aspect ratios differ |
| --- | --- | --- |
| Stretch | Scale width and height independently to cover the full display area | No layout gaps, but the image may be distorted |
| Center | Center the image at its original logical display size without automatically resizing it to fit the screen | Small images leave the background color visible around them; crop portions of large images that extend beyond the display |
| Scale to Fit | Preserve the aspect ratio, enlarge or shrink the image until the whole image fits within the display, and center it | Empty space may remain above and below or on either side; fill it with the background color without cropping image content |

“Proportional scaling” is provisionally defined here as showing the complete image (fit), rather than cropping it to fill the display (fill). All three modes lay out the image independently within each display’s actual area, without spanning one image across a combined multi-display canvas. Portrait and landscape displays may therefore have different margins while using the same image and setting.

SwiftUI provides native image stretching, proportional fitting, and rectangular clipping. Stretch can use `resizable` with the target area, and proportional fitting can use `scaledToFit`. Centering requires preserving the original layout size and clipping to the display boundary. No image-layout dependency is needed. [resizable](https://developer.apple.com/documentation/swiftui/image/resizable(capinsets:resizingmode:)), [scaledToFit](https://developer.apple.com/documentation/swiftui/view/scaledtofit()), [clipped](https://developer.apple.com/documentation/swiftui/view/clipped(antialiased:))

The “original size” used for centering must be separate from the decoded cache size. After correcting image orientation during import, establish a fixed logical display size in points; the first version could normalize pixel dimensions to numerically equivalent point dimensions. Creating a thumbnail to save memory must not make the centered image smaller during the next break. A display’s backing scale determines the pixels needed for rendering, not a change to the established logical layout size. This is a proposed centering convention whose visible result should be shown in the settings preview.

### Apply transparency only to the background

Interpret the value as a transparency percentage: **0% means fully opaque, and 99% means almost transparent, with 1% opacity remaining**. Background opacity is `1 − transparency / 100`; 100% transparency is outside the allowed range. Keep the label “Transparency” consistent with this direction. A recommended default is 0% for complete visual coverage. Validate both slider and numeric input against the same inclusive 0–99 range.

The window has two separate visual layers: the background comprises the base color and image, while the content contains the reminder text, countdown, and buttons. Apply transparency once to the composited background and keep the content legible. A solid content panel with predictable contrast is recommended so that white images, dark images, or the desktop showing through cannot make the text unreadable.

Keep the overall window at `alphaValue = 1` and use a nonopaque window as needed for the background, rather than implementing the slider through the window’s overall alpha. `alphaValue` controls the entire window, and `isOpaque` describes whether it is opaque. Separating the content from the background is this project’s design choice. [alphaValue](https://developer.apple.com/documentation/appkit/nswindow/alphavalue), [isOpaque](https://developer.apple.com/documentation/appkit/nswindow/isopaque)

Visual transparency must not imply input passing through. Set `ignoresMouseEvents = false` and handle hit testing across the entire covered area. Specifically test the 99% transparency limit and transparent regions in PNG files; neither the property value nor excluding fully transparent backgrounds proves that input interception works. Even when users can see the application underneath, the break window must remain in front and intercept interaction according to the defined rules. [ignoresMouseEvents](https://developer.apple.com/documentation/appkit/nswindow/ignoresmouseevents)

### Image storage and resource usage

Use `NSOpenPanel` to select an image, read and validate it, and import it into the app’s own Application Support directory. Update the configuration only after the new file is saved successfully; retain the previous valid background on failure. This prevents moving or deleting the original file from breaking the setting and avoids maintaining long-lived bookmarks to its external path. Sandboxed builds need the appropriate access to read user-selected files. Never modify or delete the user’s original image. [NSOpenPanel](https://developer.apple.com/documentation/appkit/nsopenpanel), [Application Support](https://developer.apple.com/documentation/foundation/filemanager/searchpathdirectory/applicationsupportdirectory)

Store only the background type, color, transparency, layout mode, and internal image identifier in `UserDefaults`, not image bytes. Do not retain unnecessary large decoded images during background scheduling. Use thumbnails for settings previews, reuse a bounded decoded-image cache according to display requirements during breaks, and release it afterward. Updating countdown text each second must not decode the image again.

Validate the actual format, pixel dimensions, and file size on import to bound the cost of unusually large images. Use ImageIO to generate renderable versions with explicit pixel limits through `CGImageSourceCreateThumbnailAtIndex` and `kCGImageSourceThumbnailMaxPixelSize`. Choose sampling dimensions according to the output area, layout mode, and backing scale, and set a total cache budget. Simply displaying a large image at a small size in SwiftUI does not establish that decoding uses less memory. [ImageIO thumbnails](https://developer.apple.com/documentation/imageio/cgimagesourcecreatethumbnailatindex(_:_:_:)), [Maximum pixel size](https://developer.apple.com/documentation/imageio/kcgimagesourcethumbnailmaxpixelsize)

For example, the pixel data alone for a 3840 × 2160 image in 8-bit RGBA is approximately 31.6 MiB, excluding windows, compositing textures, and caches. This is a calculation at four bytes per pixel, not an app measurement. Include image backgrounds on multiple displays in memory and GPU acceptance testing. If reading or decoding fails, fall back promptly to the background color; a failed asset must not delay the break overlay.

Additional acceptance cases: test all three layouts with small, large, ultrawide, and portrait images; verify EXIF orientation, transparent PNGs, corrupted or oversized files, image availability after restarting, moving or deleting the original file, and layout across mixed Retina displays. Test transparency values of at least 0, 1, 50, and 99; reject invalid input such as -1, 100, or nonnumeric values. In every case, also verify text readability, input interception, multi-display synchronization, and memory release. Seeing the underlying app at high transparency is a user-selected visual effect, not forced concealment of its content.

## Application language and localization

**Confirmed requirement: provide an application language setting, defaulting to English, with support for Simplified Chinese, Traditional Chinese, Japanese, Korean, Spanish, French, and Portuguese.** This is eight languages in total. On the first launch, use English even if the operating system uses another language. After the user selects a language, persist that selection and restore it on subsequent launches.

| Language | Localization identifier | Initial behavior |
| --- | --- | --- |
| English | `en` | Default application language and fallback |
| Simplified Chinese | `zh-Hans` | Available in the language selector |
| Traditional Chinese | `zh-Hant` | Available separately from Simplified Chinese |
| Japanese | `ja` | Available in the language selector |
| Korean | `ko` | Available in the language selector |
| Spanish | `es` | Available in the language selector |
| French | `fr` | Available in the language selector |
| Portuguese | `pt` | Available in the language selector |

Use a language picker in Settings and identify each choice by its native language name so users can find their language even when the current interface is unfamiliar. Store a stable language identifier in `UserDefaults`, not the translated display name. If the stored identifier is missing or unsupported, select English. Regional variants are not separate settings in the initial scope; Portuguese regional wording should be settled during translation review rather than silently adding multiple Portuguese choices.

### Native localization approach

Use an English source localization and a bundled `Localizable.xcstrings` String Catalog for all eight languages. Xcode supports extracting localizable text, maintaining translations, and defining plural variants in string catalogs. Include translator comments for terms such as “short break,” “long break,” “skip,” “transparency,” and the three image layout modes. Use complete localized phrases with placeholders rather than concatenating translated fragments, and handle duration units and plurals through localization resources. [Apple String Catalog guidance](https://developer.apple.com/documentation/xcode/localizing-and-varying-text-with-a-string-catalog)

The saved app language must drive all app-owned UI. Supply the corresponding locale to SwiftUI views, including each display’s hosted break view. AppKit menu titles and other already-created strings also need to be resolved and refreshed from the selected language resources; setting a SwiftUI environment value alone does not update those strings. SwiftUI exposes a locale environment value, and Foundation provides localized string lookup through bundles. [SwiftUI locale](https://developer.apple.com/documentation/swiftui/environmentvalues/locale), [Bundle string lookup](https://developer.apple.com/documentation/foundation/bundle/localizedstring(forkey:value:table:))

Do not rely solely on the system’s preferred language because the first-launch requirement is explicitly English. Resolve the selected supported language and use English as an explicit fallback for unavailable translations. Never display internal localization keys to users. Fallback is a runtime recovery behavior, not a substitute for completing all seven additional translations before declaring them supported.

Localize Settings labels and explanations, menu bar commands and status text, short- and long-break prompts, countdown units, skip restrictions, background and image layout controls, validation errors, app-owned alerts, tooltips, and accessibility labels and hints. System-owned panels and security prompts remain under macOS language behavior; the app language setting must not change global system preferences.

### Switching language and validating translations

Proposed behavior is to apply a language change to the app’s existing UI without resetting schedules. Refresh menu titles and visible text consistently across every display. Language changes must not recreate the scheduling state, reset deadlines, change skip permissions, or dismiss a strict break. Keep localization resources bundled and available offline; no runtime translation service or background polling is needed.

Allow controls and text to accommodate longer translations, wrapping and resizing where appropriate rather than assuming English string lengths. Use system fonts with appropriate character coverage, and preserve clear layouts for Chinese, Japanese, and Korean text. Format user-facing numbers and duration units with locale-aware APIs rather than embedding English units in otherwise translated messages. Keep scheduling values independent of their localized display strings.

Acceptance must cover all eight languages in Settings, AppKit menus, and every display’s break overlay, including VoiceOver labels. Verify English on a fresh installation under a non-English system language, persistence after restarting, fallback for an invalid stored language or a missing string, and a language change while a break is active without altering its timing or restrictions. Check plural and duration formatting, untranslated strings, clipping, wrapping, and character rendering. Review translations for meaning and consistency before release; configuring language identifiers alone does not establish language support.

## What “cannot skip” means

Define it as: **once this break starts, the app offers no ordinary way to end it before its required duration has elapsed.**

This must cover break buttons, menu commands, Esc, closing the window, any future shortcuts, and settings changes that could indirectly end the active break. During a strict break, the app’s own pause, reset, and normal quit paths should obey the same rule. System logout, shutdown, and recovery from failure must remain available. Every entry point ultimately checks permission in the scheduling state; hiding buttons alone is insufficient.

AppKit presentation options can hide the Dock and menu bar and disable the Command-Tab switching interface while the app is active. They are not system access controls. Even `disableForceQuit` only promises to disable the Force Quit panel, not to make the process impossible to terminate. Preserve system force-quit capability in the first version, without adding administrator privileges, event interception, daemons, or mechanisms that relaunch the app after it is killed. [presentationOptions](https://developer.apple.com/documentation/appkit/nsapplication/presentationoptions-swift.property), [disableProcessSwitching](https://developer.apple.com/documentation/appkit/nsapplication/presentationoptions-swift.struct/disableprocessswitching), [disableForceQuit](https://developer.apple.com/documentation/appkit/nsapplication/presentationoptions-swift.struct/disableforcequit)

Product wording should therefore be “This break cannot be skipped,” rather than “Impossible to bypass.” Users may still terminate the app through the system or restart their computer; this is a boundary of an ordinary user-space application. Apple also provides force-quit and restart recovery paths. [Apple force-quit guidance](https://support.apple.com/en-ie/102586)

## Background resource usage and App Nap

Translate resource goals into these design constraints:

| Scenario | Proposed activity |
| --- | --- |
| Work interval running, menu closed | Static icon and one task waiting for the nearest deadline, with no app-scheduled per-second tick |
| Status menu opened | Calculate expected break times when opened; a native menu can show absolute times without continuous refreshes |
| Visible countdown panel or break UI | Refresh text approximately once per second only when needed, sharing the refresh source across displays; cancel when closed |
| Settings changed | Validate and save to `UserDefaults`; do not write remaining time to disk every second |
| System asleep or both break types disabled | Cancel scheduling and UI updates; do not create assertions that prevent sleep |

The resource goal is to reduce wakeups and UI work, not to eliminate every timer. A waiting task still uses runtime and system timing facilities, and frameworks may schedule their own events. Do not promise absolutely zero wakeups, zero CPU usage, or a fixed memory ceiling before measuring.

**App Nap requires separate validation.** Apple states that background apps may receive lower priority and have their timers throttled. An accurately stored deadline makes the decision correct when execution resumes; it does not guarantee that the callback runs on time. [Apple App Nap guidance](https://developer.apple.com/library/archive/documentation/Performance/Conceptual/power_efficiency_guidelines_osx/AppNap.html)

Measure default behavior first. If App Nap causes unacceptable delays, compare a `ProcessInfo` activity with a bounded lifetime. For example, evaluate `userInitiatedAllowingIdleSystemSleep` while the user has scheduling enabled, ending the activity when scheduling is disabled or suspended by system state. This option permits idle system sleep but may reduce App Nap’s energy savings. Do not hold it indefinitely by default without measurement, and do not use `latencyCritical` or prevent display sleep to solve ordinary reminder timing. [Activity lifecycle](https://developer.apple.com/documentation/foundation/processinfo/beginactivity(options:reason:)), [Activity allowing idle system sleep](https://developer.apple.com/documentation/foundation/processinfo/activityoptions/userinitiatedallowingidlesystemsleep)

Measure a Release build outside the debugger. Record the machine, OS version, display count, and power state. Test quiet background operation, an open menu, break overlays, recovery after sleep, and extended runtime. Inspect CPU time, Idle Wake Ups, physical footprint, Energy Impact, GPU activity, and actual reminder delay. Primary acceptance goals are no app-generated background 1 Hz wakeup cycle, no memory growth with repeated breaks, and the agreed reminder timing accuracy on a normal interactive desktop. [Activity Monitor energy metrics](https://support.apple.com/en-ca/guide/activity-monitor/-actmntr43697/mac)

Being written in native Swift does not replace these measurements. In particular, compare overlay costs on one display and on multiple high-resolution displays, and confirm that views, windows, and closures are released afterward.

## Launch behavior, permissions, and minimal structure

Starting the countdown when the app opens should happen immediately after initialization. Launching automatically at login should be a separate setting, registered through `SMAppService.mainApp` and reflecting the actual authorization state. Handle approval and registration errors. Opening the app is not consent to add a login item, and this capability does not require an additional helper. [mainApp](https://developer.apple.com/documentation/servicemanagement/smappservice/mainapp), [register](https://developer.apple.com/documentation/servicemanagement/smappservice/register())

Under this proposal, the core path creates only the app’s own windows and handles its own input. It does not capture the screen, read another application’s content, or monitor keyboard input globally. The design target is therefore to avoid requesting Screen Recording, Input Monitoring, or Accessibility control permissions. This is an inference from the proposed design and must be verified with a clean user account and a sandboxed build. Reassess it if global input monitoring, automation of other apps, or stronger blocking is introduced.

Use only the following responsibilities rather than introducing a multilayer framework:

- Application entry point and menu bar: lifecycle, status menu, and access to Settings.
- Break scheduling: two plans, one state, the nearest deadline, system recovery, and skip rules.
- Overlay control: per-display windows, focus, and window release.
- Settings UI and persistence: SwiftUI, `UserDefaults`, input validation, and the application language selection shared by SwiftUI and AppKit.

The first version needs no third-party dependencies, WebView, database, network service, or privileged background process. Distribution has not yet been decided. If the app will be distributed, address signing, notarization, or the Mac App Store process later; this technical feasibility assessment is not a conclusion that it will pass review.

## Validation before full development

In order of risk, build two small technical prototypes before implementing the complete settings interface:

1. **Overlay and input prototype:** use the display and interaction matrix above. Focus on persistent foreground visibility, synchronized coverage of every display, dynamic reconfiguration, and system exit paths. Record overlay visibility, mouse input passing through, keyboard focus, skip permissions, and brief gaps during transitions separately. A screenshot of the primary display does not establish that multi-display coverage and foreground behavior work.
2. **Scheduling and energy prototype:** validate monotonic deadlines, cancellation and rescheduling, App Nap, Low Power Mode, device and display sleep, a locked screen that remains lit, user session switching, and forward or backward system-clock changes. Compare reminder delays and resource usage with default scheduling and the activity-based alternative.

Then add small tests for timing state logic with a controllable current time, without waiting for real minute-long intervals. At minimum, cover simultaneous deadlines starting only one break, skipping a long break without discarding a strict short break, cancelled tasks not creating overlays, settings changes during a break not bypassing restrictions, and duplicate sleep notifications accounting for the absence only once. Include the 0–99 transparency boundary checks and localization acceptance cases above when validating Settings and the UI.

This research establishes API capabilities and an implementation direction. Window configurations, permissions, App Nap timing, and resource usage have not yet been tested, nor has compatibility across every supported OS version. The eight-language requirement is documented; application translations and localization testing have not yet been produced. The product decisions most worth settling before implementation are the minimum macOS version, how natural breaks are counted, and whether strict mode adopts the definition used here: no in-app skip, while system termination remains possible.
