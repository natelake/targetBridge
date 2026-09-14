# W1 Pause / Resume Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A pause control on each screen's tile in the Screens bento that hands that iMac's panel back to its own desktop, keeping the virtual display, the window arrangement on it, and the TCP session alive. Resume restores the picture with nothing moved.

**Architecture:** Pause is sender-driven state. The sender stops feeding the encoder while continuing to heartbeat, so the receiver's 10s idle reap never fires and the session survives; it also tells the receiver, over one new packet, to release the panel so the iMac's own desktop is usable. The virtual display object is never destroyed, which is what preserves the arrangement.

**Tech Stack:** Swift 6 (strict concurrency: minimal), SwiftUI, AppKit, C99 + SDL2 (receiver), XCTest, GitHub Actions.

**Spec:** `docs/superpowers/specs/2026-09-13-pause-split-single-window-design.md` (section "W1 — Pause / resume")

## Global Constraints

- macOS deployment target **14.0**; Swift **6.0**, `SWIFT_STRICT_CONCURRENCY: minimal`.
- **No local build.** This mini has Command Line Tools only. Every build and test runs in GitHub Actions. CI triggers on pushes to `multi-display` and on PRs into it.
- **Receiver code must still compile on Catalina 10.15** for the 2012 iMac (`~/tbbuild/build-receiver.sh` there). Use only long-standing SDL2 calls — `SDL_HideWindow`, `SDL_ShowWindow` — and no macOS 11+ symbols.
- **R1 (handshake):** the receiver reaps after `TB_SENDER_IDLE_TIMEOUT_MS` = 10000 ms of total silence. Heartbeats fire every 2s and must keep flowing while paused.
- **R3 (probe safety):** `tb-selftest`'s motion probe measures byte-rate rise and would see a paused stream as dead. Therefore **any connect clears pause** — a session always comes back unpaused.
- **R9:** brightness, volume, clipboard and cursor packets keep flowing while paused.
- **R10:** pause suspends input relay for that session only, restoring the previous mode on resume.

---

### Task 1: Protocol — the display-state packet

**Files:**
- Modify: `TargetBridge-Receiver/TBReceiverC/src/proto.h`
- Modify: `TargetBridge-Sender/TBDisplayShared/TBMonitorProtocol.swift`
- Test: `TargetBridge-Sender/TBDisplaySenderTests/TBMonitorProtocolTests.swift`

**Interfaces:**
- Produces: `TBMonitorPacketType.displayState = 0x38`; `struct TBMonitorDisplayState: Codable { var paused: Bool }`; C constant `TB_PKT_DISPLAY_STATE 0x38`.

- [ ] **Step 1: Write the failing test**

Append to `TBMonitorProtocolTests.swift`:

```swift
    // MARK: - display state (pause)

    func testDisplayStatePacketRoundTrips() {
        let packet = TBMonitorProtocol.makeJSONPacket(
            type: .displayState,
            value: TBMonitorDisplayState(paused: true)
        )
        var buffer = packet!
        let drained = try? TBMonitorProtocol.drainPacket(from: &buffer)
        XCTAssertEqual(drained??.0, .displayState)
        let decoded = TBMonitorProtocol.decodeJSON(TBMonitorDisplayState.self, from: drained!!.1)
        XCTAssertEqual(decoded?.paused, true)
    }

    func testDisplayStateUsesWireType0x38() {
        XCTAssertEqual(TBMonitorPacketType.displayState.rawValue, 0x38)
    }
```

- [ ] **Step 2: Run to verify it fails**

Run: `git push && gh run watch`
Expected: FAIL — `type 'TBMonitorPacketType' has no member 'displayState'`.

- [ ] **Step 3: Implement**

In `TBMonitorProtocol.swift`, add to the enum after `case volume = 0x37`:

```swift
    case displayState = 0x38   // pause/resume: receiver releases or reclaims the panel
```

and after `struct TBMonitorVolume`:

```swift
struct TBMonitorDisplayState: Codable {
    var paused: Bool
}
```

In `proto.h`, add after `#define TB_PKT_VOLUME 0x37`:

```c
#define TB_PKT_DISPLAY_STATE    0x38  /* pause/resume (JSON: {"paused":bool}) */
```

and document it in the header comment block alongside the other JSON types.

- [ ] **Step 4: Run to verify it passes**

Run: `git push && gh run watch` — Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add TargetBridge-Receiver/TBReceiverC/src/proto.h \
        TargetBridge-Sender/TBDisplayShared/TBMonitorProtocol.swift \
        TargetBridge-Sender/TBDisplaySenderTests/TBMonitorProtocolTests.swift
git commit -m "feat(proto): add 0x38 display-state packet for pause/resume"
```

---

### Task 2: Sender — pause state, encode gate, and clear-on-connect

**Files:**
- Modify: `TargetBridge-Sender/TBDisplaySender/TBDisplaySenderService.swift`

**Interfaces:**
- Consumes: `TBMonitorPacketType.displayState`, `TBMonitorDisplayState` from Task 1.
- Produces: `TBDisplaySenderSession.isPaused: Bool` (`@Published`), and `func setPaused(_:)` used by the bento tile in Task 4.

- [ ] **Step 1: Add the published property next to `brightness`**

After the `brightness` property (around line 1000), mirroring its shape:

```swift
    /// Pause hands the receiver's panel back to its own desktop without tearing
    /// anything down: frames stop, but heartbeats keep the session alive and the
    /// virtual display keeps existing, so the arrangement and the windows on it
    /// survive. Cleared by `connect()` so a rebuild always comes back live —
    /// tb-selftest's motion probe reads a paused stream as a dead one.
    @Published var isPaused: Bool = false {
        didSet {
            guard oldValue != isPaused else { return }
            sendDisplayStateUpdate()
            applyPauseToInputRelay()
        }
    }
```

- [ ] **Step 2: Add the send helper next to `sendBrightnessUpdate`**

```swift
    private func sendDisplayStateUpdate() {
        guard let packet = TBMonitorProtocol.makeJSONPacket(
            type: .displayState,
            value: TBMonitorDisplayState(paused: isPaused)
        ) else { return }
        send(packet)
    }
```

- [ ] **Step 3: Gate the two encode entry points**

In `encode(_ sampleBuffer: CMSampleBuffer)`, immediately after `markCaptureFrame()`:

```swift
        if isPaused { return }
```

In `encodeDisplaySurface(_ surface: IOSurfaceRef, displayTime: UInt64)`, immediately after `markCaptureFrame()`:

```swift
        if isPaused { return }
```

Capture keeps running so resume is instant; encode and network go to zero.

- [ ] **Step 4: Clear pause on connect**

At the top of `connect()`, before any transport work:

```swift
        isPaused = false
```

- [ ] **Step 5: Push and verify CI is green**

Run: `git push && gh run watch` — Expected: PASS on all three jobs.

- [ ] **Step 6: Commit**

```bash
git add TargetBridge-Sender/TBDisplaySender/TBDisplaySenderService.swift
git commit -m "feat(sender): pause state gates the encoder and survives as a live session"
```

---

### Task 3: Receiver — release and reclaim the panel

**Files:**
- Modify: `TargetBridge-Receiver/TBReceiverC/src/display.h`
- Modify: `TargetBridge-Receiver/TBReceiverC/src/display.c`
- Modify: `TargetBridge-Receiver/TBReceiverC/src/main.c`

**Interfaces:**
- Consumes: `TB_PKT_DISPLAY_STATE` from Task 1.
- Produces: `void tb_disp_set_paused(struct tb_display *d, int paused);`

- [ ] **Step 1: Declare the setter**

In `display.h`, after `void tb_disp_set_input_capture_active(...)`:

```c
void               tb_disp_set_paused(struct tb_display *d, int paused);
```

- [ ] **Step 2: Add the state field**

In `display.c`, in `struct tb_display` next to `preferred_fullscreen`:

```c
    int           is_paused;
```

- [ ] **Step 3: Implement the setter, mirroring `tb_disp_set_input_capture_active`**

```c
void tb_disp_set_paused(struct tb_display *d, int paused) {
    if (!d) return;
    if (d->is_paused == (paused ? 1 : 0)) return;
    d->is_paused = paused ? 1 : 0;
    fprintf(stderr, "[disp] %s\n", d->is_paused ? "paused — releasing the panel"
                                                : "resumed — reclaiming the panel");
    tb_disp_refresh_window_mode(d);
}
```

- [ ] **Step 4: Teach the window mode about pause**

In `tb_disp_refresh_window_mode`, make pause the first branch:

```c
    if (d->is_paused) {
        /* Hand the panel back: leave fullscreen and get out of the way so the
         * receiver Mac's own desktop is usable. The session, the virtual
         * display on the sender, and the window arrangement all stay alive. */
        SDL_SetWindowFullscreen(d->win, 0);
        SDL_HideWindow(d->win);
        SDL_ShowCursor(SDL_ENABLE);
        if (d->system_cursor_hidden) {
            CGDisplayShowCursor(CGMainDisplayID());
            d->system_cursor_hidden = 0;
        }
        return;
    }
    SDL_ShowWindow(d->win);
```

placed immediately after the `if (!d || !d->win) return;` guard, so the existing fullscreen/windowed logic below runs unchanged when not paused.

- [ ] **Step 5: Dispatch the packet**

In `main.c`'s `on_packet`, after the `TB_PKT_BRIGHTNESS` case:

```c
    case TB_PKT_DISPLAY_STATE:
        {
            /* extract_json_bool_field is not available; the payload is tiny and
             * fixed-shape, so match the literal the sender emits. */
            int paused = (memmem(payload, len, "\"paused\":true", 13) != NULL);
            tb_disp_set_paused(a->disp, paused);
        }
        break;
```

- [ ] **Step 6: Receiver parser test**

In `TargetBridge-Receiver/TBReceiverC/tests/test_net_parser.c`, add a case asserting a `0x38` packet parses to type `0x38` with its JSON payload intact, following the existing test's structure for `0x35`.

- [ ] **Step 7: Push and verify CI**

Run: `git push && gh run watch` — Expected: PASS on the sender job and both receiver arches.

- [ ] **Step 8: Commit**

```bash
git add TargetBridge-Receiver/TBReceiverC/src/display.h \
        TargetBridge-Receiver/TBReceiverC/src/display.c \
        TargetBridge-Receiver/TBReceiverC/src/main.c \
        TargetBridge-Receiver/TBReceiverC/tests/test_net_parser.c
git commit -m "feat(receiver): release the panel while paused, reclaim on resume"
```

---

### Task 4: The pause button in the Screens bento

**Files:**
- Modify: `TargetBridge-Sender/TBDisplaySender/TBDisplaySenderScreensBento.swift`

**Interfaces:**
- Consumes: `TBDisplaySenderSession.isPaused` from Task 2.

- [ ] **Step 1: Add the button to the tile header**

In `TBSessionBentoTile.body`, replace the `Spacer(minLength: 0)` in the header `HStack` with a spacer plus the control:

```swift
                Spacer(minLength: 0)
                Button {
                    session.isPaused.toggle()
                } label: {
                    Image(systemName: session.isPaused ? "play.fill" : "pause.fill")
                        .font(.system(size: 9, weight: .bold))
                }
                .buttonStyle(.plain)
                .help(session.isPaused ? resumeHelp : pauseHelp)
                .disabled(!session.isConnected)
```

- [ ] **Step 2: Add a paused tag and localized strings**

Change the tile's status line to report the paused state:

```swift
            Text("\(sizeText) · \(stateTag)")
```

with

```swift
    private var stateTag: String {
        if session.isPaused { return pausedTag }
        return session.isConnected ? liveTag : idleTag
    }
```

Add `pausedTag`, `pauseHelp` and `resumeHelp` as `let` properties on `TBSessionBentoTile`, passed down from `TBScreensBentoCard` alongside `liveTag` / `idleTag`, with the five-language switch the card already uses for every other string:

```swift
    private var pausedTag: String {
        switch service.language {
        case .english: return "paused"
        case .italian: return "in pausa"
        case .german:  return "pausiert"
        case .french:  return "en pause"
        case .chinese: return "已暂停"
        }
    }

    private var pauseHelp: String {
        switch service.language {
        case .english: return "Pause — hand this screen back to its own desktop"
        case .italian: return "Pausa — restituisci questo schermo al suo desktop"
        case .german:  return "Pause — Bildschirm an seinen eigenen Schreibtisch zurückgeben"
        case .french:  return "Pause — rendre cet écran à son propre bureau"
        case .chinese: return "暂停 — 将此屏幕交还给它自己的桌面"
        }
    }

    private var resumeHelp: String {
        switch service.language {
        case .english: return "Resume streaming to this screen"
        case .italian: return "Riprendi lo streaming su questo schermo"
        case .german:  return "Streaming auf diesem Bildschirm fortsetzen"
        case .french:  return "Reprendre la diffusion sur cet écran"
        case .chinese: return "恢复串流到此屏幕"
        }
    }
```

- [ ] **Step 3: Push and verify CI**

Run: `git push && gh run watch` — Expected: PASS.

- [ ] **Step 4: Commit**

```bash
git add TargetBridge-Sender/TBDisplaySender/TBDisplaySenderScreensBento.swift
git commit -m "feat(bento): per-screen pause button"
```

---

### Task 5: Release and deploy to all three machines

- [ ] **Step 1: Merge and tag**

```bash
cd ~/targetBridge
git checkout multi-display && git merge --no-ff w1-pause -m "Merge W1: pause/resume"
git tag v3.4.3-multidisplay.6 && git push origin multi-display --tags
gh run watch
```

- [ ] **Step 2: Update the changelog and the release notes**

Add a `## v3.4.3-multidisplay.6` section to `CHANGELOG.md` describing the pause control, the `0x38` packet, and the fact that **receivers must be rebuilt for this release** (unlike `.5`). Attach that section to the draft release with `gh release edit v3.4.3-multidisplay.6 --notes-file`.

- [ ] **Step 3: Install the sender on the mini**

```bash
touch ~/.tb-watchdog-off
cd /tmp && rm -rf tb-w1 && mkdir tb-w1 && cd tb-w1
gh release download v3.4.3-multidisplay.6 --repo natelake/targetBridge -p TargetBridge-arm64.app.zip
unzip -q TargetBridge-arm64.app.zip && chmod -R u+w TargetBridge.app && xattr -cr TargetBridge.app
killall TargetBridge; rm -rf /Applications/TargetBridge.app
cp -R TargetBridge.app /Applications/
tccutil reset ScreenCapture com.targetbridge.sender
nohup ~/bin/tb-approval-watcher >/dev/null 2>&1 &
open -a TargetBridge
open "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
```
Then the user toggles TargetBridge on; the watcher rebuilds the screens.

- [ ] **Step 4: Install the receiver on the 2020 iMac (prebuilt x86_64)**

```bash
IP2020=$(~/bin/tb-resolve nates-imac)
cd /tmp/tb-w1
gh release download v3.4.3-multidisplay.6 --repo natelake/targetBridge -p TargetBridge-Receiver-x86_64.app.zip
scp TargetBridge-Receiver-x86_64.app.zip lake@$IP2020:/tmp/
ssh lake@$IP2020 'cd /tmp && rm -rf rx && mkdir rx && cd rx && unzip -q ../TargetBridge-Receiver-x86_64.app.zip \
  && chmod -R u+w "TargetBridge Receiver.app" && xattr -cr "TargetBridge Receiver.app" \
  && pkill -f TargetBridgeReceiver; sleep 1 \
  && rm -rf "/Applications/TargetBridge Receiver.app" \
  && cp -R "TargetBridge Receiver.app" /Applications/ \
  && open -a "TargetBridge Receiver"'
```
The keeper LaunchAgent `com.natelake.tbreceiver` restarts it if the copy races.

- [ ] **Step 5: Rebuild the receiver on the 2012 iMac (Catalina, from source)**

```bash
IP2012=$(~/bin/tb-resolve nates-imac-2012)
ssh natelake@$IP2012 'cd ~/tbbuild && git -C targetBridge fetch --tags && git -C targetBridge checkout v3.4.3-multidisplay.6 && ./build-receiver.sh'
```
No prebuilt binary runs on 10.15. If the checkout path differs, clone `natelake/targetBridge` there first.

- [ ] **Step 6: Verify end to end**

```bash
rm -f ~/.tb-watchdog-off
~/bin/tb-selftest                      # full run including the motion probe — expect PASS
```
Then, in the Screens bento, press pause on the 2020's tile and check:

```bash
ssh lake@$(~/bin/tb-resolve nates-imac) 'osascript -e "tell application \"System Events\" to get name of first application process whose frontmost is true"'
netstat -an | grep "\.54321" | grep -c ESTABLISHED     # expect 2 — session survives
~/bin/tb-displaynames | grep -c "TB Extend"            # expect 2 — arrangement survives
```
Expected: the iMac's own desktop is frontmost, both streams still ESTABLISHED, both virtual displays still present. Press resume and confirm the picture returns with windows unmoved.
