# Pause, split-screen, and the single-window fix

Date: 2026-09-13
Branch: `multi-display` (fork `natelake/targetBridge`, 5 commits ahead of `swellweb/main`; upstream unmoved)

## Goals

Three changes to the sender/receiver pair, in the order they should be built:

- **W0 — Single window.** Opening the TargetBridge UI after a long session reveals up to twenty
  stacked windows that must be dismissed one at a time. Exactly one window should ever exist.
- **W1 — Pause / resume, per screen.** A control on each screen's tile in the Screens bento that
  suspends streaming and hands that iMac's panel back to its own desktop, keeping the virtual
  display, the window arrangement on it, and the TCP session alive. Resume restores the picture
  with nothing moved.
- **W2 — Split screen.** Share one iMac panel between its native desktop and the mini's streamed
  desktop, at snap presets (Full / 70 / 60 / 50 with a left-or-right side), each rendered 1:1 sharp.

## Non-regression contract

Every behavior below is currently relied on and must still hold after each work item. Each was
verified by reading the code or the tooling, not assumed.

| # | Behavior that must survive | Where it lives | Which item threatens it | Guard |
|---|---|---|---|---|
| R1 | Receiver reaps a session only after 10s of total silence; heartbeats every 2s keep it alive | `main.c` `TB_SENDER_IDLE_TIMEOUT_MS`, `sendHeartbeat()` | W1 (no frames) | Pause stops frames only. Heartbeat, cursor, brightness, clipboard and volume packets keep flowing. |
| R2 | `tb-watchdog` must not "repair" a healthy setup | `~/bin/tb-watchdog` | W1 | Verified safe with no change: the watchdog checks only that the display name appears in `tb-displaynames` and that a `.54321` socket is `ESTABLISHED`. A pause keeps both. |
| R3 | `tb-selftest`'s motion probe correctly identifies which stream feeds which iMac | `~/bin/tb-selftest` check 4 | W1 | **Real risk.** A paused session emits zero bytes, so it can never clear `RISE_MIN`, and the probe reports a fault that sends `tb-connect` into a rebuild. Guard: any (re)connect clears pause — a session always comes back unpaused — so no probe ever runs against a paused stream. |
| R4 | Never reconnect one session alone; a lone reconnect binds both sessions to the same virtual display | sender defect, documented in `tb-connect` | W2 | A layout change tears down and rebuilds **both** sessions in fixed order through the existing `tb-connect` path. No single-session rebuild is introduced. |
| R5 | `tb-arrange` places displays correctly | `~/bin/tb-arrange` | W2 | **Real risk, and there is no source.** It is a 34 KB compiled Mach-O with placement hardcoded ("2020 iMac 5K %.0fHz -> bottom left"), identifying machines by refresh rate (48 Hz vs 60 Hz) and assuming both virtual displays carry 5K HiDPI backings. Changing a virtual display's size changes the arrangement geometry it computes against. Guard: W2 is gated on reconstructing `tb-arrange` from source first (see W2 step 0). Refresh-rate identification is unaffected. |
| R6 | Display identity by `NSScreen.localizedName` ("TB Extend - Built-in Retina Display" = 2020, "TB Extend - iMac" = 2012); CG display IDs change on every reconnect and must never be cached | `tb-displaynames`, watchdog, selftest | W2 | Names are not derived from resolution and do not change. No item caches a display ID. |
| R7 | Sender windows are not required for streaming — the process is what matters; `tb-connect` launches it with `open -g -j -a TargetBridge` and hides it | `tb-connect` | W0 | Status-item activation and launch-argument handling move from the window's `.task` into the app delegate's `applicationDidFinishLaunching`, so they run whether or not a window is ever shown. |
| R8 | `targetbridge://connect|disconnect` URLs and `--connect/--disconnect` launch arguments drive the same in-process paths as the GUI | `TBSenderAutomation` | W0 | URL delivery moves to `application(_:open:)`. Parsing and dispatch (`TBSenderAutomation.handle`/`run`) are untouched, and `TBSenderAutomationParsingTests` continues to cover them. |
| R9 | Per-session brightness reaches the real backlight (protocol `0x35`), and the sender re-sends persisted brightness on every connect | `TBDisplaySenderSession.brightness`, `tb_disp_set_brightness` | W1, W2 | Brightness is orthogonal to pause and continues to be delivered while paused. |
| R10 | Input relay, input capture, and the gesture bridge behave as today when not paused | `TBInputRelayController`, receiver input capture | W1, W2 | Pause suspends relay for that session only, and restores the prior mode on resume. Unpaused sessions see no change. |
| R11 | The 2012 iMac's receiver still builds on Catalina (`CGPreflightListenEventAccess` resolved via `dlsym`; SDL 2.28.5 + ffmpeg 6.1.2 static, custom clang link) | `~/tbbuild/build-receiver.sh` on that machine | W1, W2 | New receiver code uses only long-standing SDL2 calls (`SDL_HideWindow`, `SDL_ShowWindow`, `SDL_SetWindowBordered`, `SDL_SetWindowPosition/Size`). No new macOS-11+ symbols. |
| R12 | `ci.yml` (sender `xcodebuild test` + both receiver arches) and `release.yml` stay green | `.github/workflows/` | all | New tests join the existing targets; no workflow changes. |
| R13 | Full-screen streaming behaves exactly as it does today | whole pipeline | W2 | `Full` is the default layout and takes the identical code path — the effective-mode computation returns the preset's own width/height unchanged. |

## W0 — Single window

### Root cause

`TBDisplaySenderApp.swift` declares `WindowGroup("TargetBridge", id: "main")` and attaches
`.onOpenURL` to the window's content. SwiftUI opens a **new window in the group for each incoming
URL** that no existing window claims. `tb-connect` sends several `targetbridge://` URLs per rebuild,
and rebuilds happen throughout a session, so windows accumulate.

### Design

- Replace `WindowGroup` with `Window("TargetBridge", id: "main")` — a single-instance scene
  (macOS 13+; the deployment target is 14.0). `.defaultSize` is supported unchanged.
- Add an `NSApplicationDelegateAdaptor`:
  - `application(_:open:)` forwards to `TBSenderAutomation.handle(url:)`, so a URL needs no window.
  - `applicationDidFinishLaunching` calls `statusItemController.activate()` and
    `TBSenderAutomation.handleLaunchArguments(CommandLine.arguments)` — moved out of the window's
    `.task` so they run in the hidden-launch case (R7).
  - `applicationShouldHandleReopen(_:hasVisibleWindows:)` raises the existing window rather than
    creating one.
- `TBSenderAutomation.didHandleLaunchArguments` stays as-is; it already guards re-entry.

### Files

`TargetBridge-Sender/TBDisplaySender/TBDisplaySenderApp.swift` (rewrite, ~40 lines),
new `TBDisplaySenderAppDelegate.swift`.

### Testing

- Unit: existing `TBSenderAutomationParsingTests` must stay green (parsing path untouched).
- New unit: dispatching N URLs through the delegate performs N actions and touches no window API.
- Manual: with the app running, fire 20 `targetbridge://connect` URLs; `NSApp.windows` count stays
  at 1. Then confirm `open -g -j -a TargetBridge` still starts a working, hidden sender (R7).

Sender-only. **No receiver rebuild.**

## W1 — Pause / resume

### Sender

- `TBDisplaySenderSession` gains `@Published var isPaused: Bool = false`, following the existing
  `brightness` pattern: `didSet` sends the state packet and applies local effects.
- Local effects while paused:
  - `encode(_:)` and `encodeDisplaySurface(_:)` return early. Capture keeps running, so resume is
    immediate; encode and network drop to zero.
  - Input relay for that session suspends, restoring the prior mode on resume (R10).
  - Heartbeat, cursor, brightness, clipboard and volume continue (R1, R9).
- The virtual display is never destroyed, so the arrangement and the windows on it are preserved.
- **Any connect or reconnect clears `isPaused`** (R3), including the wake path (`autoRestartOnWake`).

### Protocol

New packet `0x38 TB_PKT_DISPLAY_STATE`, JSON `{"paused":<bool>}`. Added to `proto.h` and to
`TBMonitorPacketType`. Both parsers already skip unknown type bytes, so a receiver that predates
this change ignores it and degrades to a frozen last frame instead of failing.

### Receiver

`tb_disp_refresh_window_mode()` gains a paused state:

- Paused: leave fullscreen, `SDL_HideWindow`, restore the system cursor (`CGDisplayShowCursor`),
  drop input capture. The iMac's own desktop is fully usable.
- Resumed: `SDL_ShowWindow` and fall through to the existing fullscreen path.

Dispatch is one `case TB_PKT_DISPLAY_STATE` in `on_packet`, mirroring `TB_PKT_BRIGHTNESS`.

### UI

A pause/play button in `TBSessionBentoTile`, in the tile's header row beside the state dot. The tile
already observes the session, so the control and the state dot stay live. Tag text gains a `paused`
state alongside `live` / `idle`, localized in the five languages the bento already carries.

### Files

`proto.h`, `TBMonitorProtocol.swift`, `main.c`, `display.c`/`display.h`,
`TBDisplaySenderService.swift`, `TBDisplaySenderScreensBento.swift`.

### Testing

- Unit (sender): `TBMonitorProtocolTests` — encode/decode of the new packet; a paused session
  produces no frame packets but still produces heartbeats.
- Unit (receiver): `test_net_parser.c` — the new type parses; an unknown type is still skipped.
- Integration: `mock_sender.py` drives pause and resume without hardware.
- Manual on the real desk: pause → the iMac's desktop is usable; `tb-displaynames` still lists the
  virtual display; `netstat` still shows `ESTABLISHED`; `tb-watchdog` logs no fault across several
  minutes (R2). Resume → picture returns with windows unmoved.

Receiver change: **both iMacs need a rebuild**, the 2012 through its Catalina toolchain (R11).

## W2 — Split screen

### Step 0 — prerequisite

Reconstruct `~/bin/tb-arrange` from source (a small CoreGraphics tool: enumerate displays, identify
by refresh rate, `CGConfigureDisplayOrigin` for each) and check it into this repo under `cli/`. The
current binary has no source and hardcodes placement against today's display sizes (R5). W2 must not
start until its logic is editable.

### Model

`TBShareLayout { full, split70, split60, split50 }` plus `TBShareSide { left, right }`, persisted per
receiver in `UserDefaults` alongside the existing per-session arrangement keys.

### Sender

The service currently reads `width`/`height` directly off `TBDisplayCapturePreset`. Introduce a
computed `TBEffectiveMode` that returns:

- `full`: the preset's own width and height, unchanged — the identical path taken today (R13).
- a split: `panelWidth × fraction` rounded to an even number, by `panelHeight`, with codec, bitrate
  and frame rate still supplied by the preset.

Changing a layout recreates the virtual display at the new size, which means a **both-session
ordered rebuild** through `tb-connect`, never a single-session reconnect (R4), followed by
`tb-arrange`.

### Receiver

`tb_disp_refresh_window_mode()` gains a docked state: borderless, sized to the fraction, parked on
the chosen side of the preferred display, with the system cursor left visible so the remainder of
the panel stays natively usable. The layout arrives as fields on the `0x38` packet introduced in W1
(`{"paused":false,"layout":"split60","side":"left"}`).

Input relay is off in docked mode for v1 — the iMac has its own cursor there.

### UI

A segmented control on each session tile: Full / 70 / 60 / 50, plus a left/right side toggle.
Because a change costs a ~10s rebuild, the control confirms before applying and shows progress.

### Two unknowns W2 must resolve before its UI is built

Both are answered by a measurement, not a decision, and both belong to W2's first step:

- **HiDPI backing at split widths.** Whether a non-5K width such as 3072×2880 offers a HiDPI backing
  on the 5K panel. Measure by creating a virtual display at each candidate width and reading back
  `CGDisplayCopyDisplayMode` for a HiDPI variant. If a width has none, text renders at a different
  effective size than Full does, and that preset is either dropped or given a HiDPI-aware entry.
- **Menu bar and Dock reachability.** Whether the docked window covers the iMac's Dock when parked
  on the side the Dock occupies. Measure by docking on each side and checking `NSScreen.visibleFrame`
  against the docked rect. If it collides, the docked rect insets to `visibleFrame` rather than
  covering it.

## Deployment

| Item | Sender | Receiver rebuild | Notes |
|---|---|---|---|
| W0 | yes | no | Install on the mini; verify hidden launch still works |
| W1 | yes | both iMacs | 2012 via `~/tbbuild/build-receiver.sh` |
| W2 | yes | both iMacs | Ship with W1's receiver build if the two land together |

Replacing the sender invalidates its Screen Recording TCC grant. The recovery playbook that has
worked twice: `tccutil reset ScreenCapture com.targetbridge.sender`, relaunch, connect to
re-trigger the prompt, approve in System Settings, then `tb-connect`.
