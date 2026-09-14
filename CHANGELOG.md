# Changelog — `natelake/targetBridge` fork

Fork of [`swellweb/targetBridge`](https://github.com/swellweb/targetBridge), branch `multi-display`.
Every entry below is a tag in this fork; upstream releases are not repeated here.

## A note on the version string

The app reports **3.3.0** in its About box and Info.plist regardless of which fork tag it was
built from. `MARKETING_VERSION` is hardcoded in two places — `TargetBridge-Sender/project.yml`
and the "Stamp Sender Build Info" pre-build script inside it — and neither reads the git tag.
The only reliable way to tell builds apart is the build number, a `YYYYMMDDHHMMSS` stamp the same
script writes into `TBDisplaySenderBuildInfo.swift` at compile time, shown in the About box as
`3.3.0 + build <stamp>`. Match that stamp against the tag dates below.

---

## v3.4.3-multidisplay.8 — 2026-09-13 (`e3e4416`)

**Regression fixes for the single-Window change in `.5`.**

- Fixed: **closing the app's window quit the app**, which killed the process and therefore both
  screens, and made every subsequent watchdog repair fail. Under `WindowGroup` this was masked —
  URL-spawned windows meant there was always another window — so the single-instance `Window`
  exposed it. `applicationShouldTerminateAfterLastWindowClosed` now returns false. Streaming needs
  the process, not a window; `tb-connect` deliberately starts the sender hidden with `open -g -j`.
- Added: `.onOpenURL` back on the `Window`'s content, plus a `kAEGetURL` handler the delegate
  re-registers after SwiftUI has installed its own, so URLs still land when the window is closed.
  Safe under `Window` in a way it was not under `WindowGroup`: a single-instance scene cannot mint
  a second window, so the twenty-window fix is unaffected.

Diagnostic note for whoever reads this next: `log show --predicate 'process == "TargetBridge"'`
returns **nothing at all** for this app, so its `NSLog` output is not a usable signal. The app's own
UI is the reliable instrument — it surfaces `Desktop capture error: … does not have Screen Recording
permission` directly on the session card. An empty log query proves nothing here.

## v3.4.3-multidisplay.6 — 2026-09-13 (`2715051`)

**Per-screen pause / resume.**

- Added: a pause button on every session tile in the Screens bento. Pause hands that iMac's panel
  back to its own desktop; resume restores the picture with nothing moved. The tile's state dot
  turns yellow and its tag reads `paused`, localized in all five languages.
- Added: protocol packet `0x38` display-state, JSON `{"paused":bool}`. Both parsers skip unknown
  packet types, so an un-updated receiver ignores it and simply keeps showing its last frame.
- Sender: `TBDisplaySenderSession.isPaused` pushes the flag down to `TBVideoPipeline`, which returns
  early from both encode entry points. Capture keeps running, so resume is instant; encode and
  network drop to zero. Heartbeats keep flowing every 2s, which is what holds the session open —
  the receiver only reaps after 10s of total silence. The virtual display is never destroyed, so the
  arrangement and the windows on it survive untouched.
- Sender: `connect()` clears pause. A session can never come back paused, because `tb-selftest`'s
  motion probe measures byte-rate rise and would read a paused stream as a dead one.
- Receiver: while paused it leaves fullscreen, hides its window and restores the system cursor, so
  the Mac's own desktop is fully usable. Resume reclaims the panel through the existing
  `tb_disp_refresh_window_mode()` path.

**Receivers must be rebuilt for this release** — unlike `.5`, this one changes receiver code. The
2012 iMac has no git checkout; its sources live in `~/tbbuild/TargetBridge-Receiver` and
`~/tbbuild/TargetBridge-Shared`, and are rebuilt with `~/tbbuild/build-receiver.sh` against the
static deps in `~/tbdeps`. Bump the `TB_RECEIVER_VERSION` define in that script when you sync.

## v3.4.3-multidisplay.5 — 2026-09-13 (`8cd10ca`)

**One sender window, ever.**

- Fixed: opening the TargetBridge UI after a long session revealed up to twenty stacked windows
  that had to be dismissed one at a time. The scene was a `WindowGroup` with `.onOpenURL` on the
  window's content, and SwiftUI opens a new window in the group for every incoming URL no existing
  window claims — `tb-connect` fires several `targetbridge://` URLs per rebuild.
- Changed: the scene is now a single-instance `Window`, which SwiftUI cannot duplicate.
- Added: `TBDisplaySenderAppDelegate`, installed via `@NSApplicationDelegateAdaptor`. It receives
  URLs through `application(_:open:)`, so no window is needed to handle one; runs status-item
  activation and `--connect` launch-argument handling in `applicationDidFinishLaunching`, so the
  hidden launch path (`open -g -j -a TargetBridge`) still starts a fully working sender; and raises
  the existing window on Dock click instead of creating another.
- Added: `TBSenderAutomation.parseURL(_:)`, a pure URL → (action, params) split, with tests.
  Dispatch logic is unchanged.
- Docs: design spec and implementation plan under `docs/superpowers/`.

Sender only — no protocol change, and receivers do **not** need rebuilding for this release.

## v3.4.3-multidisplay.4 — 2026-08-06 (`dc907f0`)

**Bento brightness crash fixed; native DDC for the hardware display.**

- Fixed: adjusting the hardware display's brightness slider crashed the sender every time. The
  `TBDDCBrightness` debounce work item is `@MainActor`-isolated but was scheduled on a global
  queue, tripping `dispatch_assert_queue` on each slider move. Now scheduled with
  `DispatchQueue.main.asyncAfter`.
- Added: `tb_ddc.c` / `tb_ddc.h` in the sender — DDC/CI over `IOAVServiceCreate` / `ReadI2C` /
  `WriteI2C`, resolved with `dlsym`. Replaces the `m1ddc` CLI, which segfaults when virtual
  displays are present and assumes a 0–100 luminance range.
- Changed: brightness percentages are scaled to the panel's own reported maximum, read back from
  the panel rather than assumed. Read → set → read round-trips verified.

## v3.4.3-multidisplay.3 — 2026-08-06 (`55a98d6`)

**Screens bento box.**

- Added: `TBScreensBentoCard` in the sender — a live miniature of the whole desk, drawing every
  display at its true position and relative size from `CGDisplayBounds`, with per-tile name, mode,
  connection state and brightness slider. Session tiles drive the receiver's real backlight through
  the existing `0x35` brightness packet; the main hardware display is driven over DDC.
- Fixed: a `private static var` inside an enum failed Swift 6 concurrency checking as shared mutable
  state; the enum is now `@MainActor`.
- Note: tiles are split into `TBSessionBentoTile` (which observes the session, so its percentage
  stays live) and `TBStaticBentoTile`.

## v3.4.3-multidisplay.2 — 2026-08-06 (`983368f`)

Same bento work as `.3` before the concurrency fix. Superseded — build `.3` or later.

## v3.4.3-multidisplay.1 — 2026-08-05 (`ed80196`)

**One receiver instance per attached display.**

- Added (receiver): `--port` / `--display` flags plus `TB_RECEIVER_PORT` / `TB_RECEIVER_DISPLAY`
  environment variables, unique Bonjour service names per instance, and per-display brightness
  scoping. A second instance is started with
  `open -n -a "TargetBridge Receiver" --args --display 1 --port 54322`.
- Added (sender): `host:port` accepted anywhere a receiver address is entered, discovery carries the
  Bonjour SRV port, and the receiver dropdown shows the port. The blocker upstream was a hardcoded
  `TBMonitorProtocol.port`.
- Added: `CGPreflightListenEventAccess` resolved at runtime via `dlsym` (`c7b06fe`), so the receiver
  still builds and runs on Catalina, where that symbol does not exist. Required for the 2012 iMac.

---

## Building and installing a fork release

There is no local build on the Apple Silicon mini used for this fork — it has Command Line Tools
only, no Xcode and no `xcodegen`. All builds run in GitHub Actions:

- `ci.yml` — on push to `multi-display` (and PRs into it): sender `xcodebuild test`, plus receiver
  builds for `x86_64` and `arm64`.
- `release.yml` — on a pushed tag: builds the same three artifacts and opens a draft release.

To install a sender build:

```bash
gh release download <tag> --repo natelake/targetBridge -p TargetBridge-arm64.app.zip
unzip -q TargetBridge-arm64.app.zip
chmod -R u+w TargetBridge.app && xattr -cr TargetBridge.app   # the zip unpacks read-only + quarantined
```

Replacing the sender invalidates its Screen Recording TCC grant and the screens stay black until it
is re-approved:

```bash
tccutil reset ScreenCapture com.targetbridge.sender
open -a TargetBridge      # connect once to re-trigger the prompt, then approve in System Settings
```

Receiver builds must be installed on each iMac. The 2012 iMac runs Catalina, which no prebuilt
binary supports; it is built from source there instead.
