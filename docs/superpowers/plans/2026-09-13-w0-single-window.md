# W0 Single Window Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the TargetBridge sender open exactly one window, ever, instead of accumulating one per incoming `targetbridge://` URL.

**Architecture:** Replace the `WindowGroup` scene — which SwiftUI grows by one window per unclaimed incoming URL — with a single-instance `Window` scene, and move URL delivery plus process-level startup out of the window's `.task` and into an `NSApplicationDelegateAdaptor`. Nothing about connection, capture, or the protocol changes.

**Tech Stack:** Swift 6 (strict concurrency: minimal), SwiftUI, AppKit, XCTest, xcodegen + xcodebuild on GitHub Actions (`macos-15`).

**Spec:** `docs/superpowers/specs/2026-09-13-pause-split-single-window-design.md` (section "W0 — Single window")

## Global Constraints

- macOS deployment target is **14.0** (`TargetBridge-Sender/project.yml`). `Window` requires macOS 13+, so it is available.
- Swift version **6.0**, `SWIFT_STRICT_CONCURRENCY: minimal`. `TBSenderAutomation` is `@MainActor`; anything calling it must be main-actor isolated.
- **This mini cannot build the project.** It has Command Line Tools only — no Xcode, no `xcodegen`. Every build and test runs in GitHub Actions (`.github/workflows/ci.yml` on push, `release.yml` on tag). Do not add steps that assume a local `xcodebuild`.
- The app is a regular app (no `LSUIElement` in `TargetBridgeSupport/Info.plist`), so it has a Dock icon and a menu bar.
- **Non-regression R7:** `tb-connect` launches the sender hidden with `open -g -j -a TargetBridge` and streaming must work with no window on screen. Status-item activation and launch-argument handling must therefore not depend on a window existing.
- **Non-regression R8:** `targetbridge://connect|disconnect` and `--connect/--disconnect` must keep resolving to the same in-process actions. `TBSenderAutomation.handle`/`run` logic is not to be modified.

---

### Task 1: Extract a pure URL parser and test it

Today `TBSenderAutomation.handle(url:)` parses and dispatches in one step, so there is no way to assert what a URL means without triggering a real connect. Split the parsing out so the delegate path can be tested.

**Files:**
- Modify: `TargetBridge-Sender/TBDisplaySender/TBDisplaySenderAutomation.swift:22-33`
- Test: `TargetBridge-Sender/TBDisplaySenderTests/TBSenderAutomationParsingTests.swift`

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces: `TBSenderAutomation.parseURL(_ url: URL) -> (action: String, params: [String: String])?` — returns `nil` for a non-`targetbridge` scheme; `action` is lowercased `url.host` (empty string when absent); `params` keys are lowercased, values are the raw query values, entries with a `nil` value omitted.

- [ ] **Step 1: Write the failing tests**

Add to `TBSenderAutomationParsingTests.swift`, after the `parsePreset` section:

```swift
    // MARK: - parseURL

    func testParseURLExtractsActionAndLowercasedParams() {
        let url = URL(string: "targetbridge://connect?Receiver=auto&MODE=extended&preset=native5k")!
        let parsed = TBSenderAutomation.parseURL(url)
        XCTAssertEqual(parsed?.action, "connect")
        XCTAssertEqual(parsed?.params["receiver"], "auto")
        XCTAssertEqual(parsed?.params["mode"], "extended")
        XCTAssertEqual(parsed?.params["preset"], "native5k")
    }

    func testParseURLLowercasesTheAction() {
        XCTAssertEqual(TBSenderAutomation.parseURL(URL(string: "targetbridge://DISCONNECT")!)?.action, "disconnect")
    }

    func testParseURLWithNoQueryYieldsEmptyParams() {
        let parsed = TBSenderAutomation.parseURL(URL(string: "targetbridge://disconnect")!)
        XCTAssertEqual(parsed?.action, "disconnect")
        XCTAssertEqual(parsed?.params.isEmpty, true)
    }

    func testParseURLRejectsForeignScheme() {
        XCTAssertNil(TBSenderAutomation.parseURL(URL(string: "https://example.com/connect")!))
    }

    /// The 20-window bug: tb-connect fires several URLs per rebuild. Parsing
    /// must be a pure function of the URL so N URLs can be handled by one
    /// window — or by no window at all.
    func testParseURLIsRepeatableAndIndependentOfCallCount() {
        let url = URL(string: "targetbridge://connect?receiver=169.254.155.234&session=1")!
        let first = TBSenderAutomation.parseURL(url)
        for _ in 0..<20 {
            let again = TBSenderAutomation.parseURL(url)
            XCTAssertEqual(again?.action, first?.action)
            XCTAssertEqual(again?.params, first?.params)
        }
    }
```

- [ ] **Step 2: Run the tests to verify they fail**

Commit the test alone on a branch and push, then:

Run: `cd ~/targetBridge && git push -u origin w0-single-window && gh run watch`
Expected: CI job "sender" FAILS at `xcodebuild test` with `type 'TBSenderAutomation' has no member 'parseURL'`.

- [ ] **Step 3: Write the minimal implementation**

In `TBDisplaySenderAutomation.swift`, replace the body of `handle(url:)` with a call to a new pure helper:

```swift
    /// Pure URL → (action, params) split. Kept separate from `handle(url:)` so
    /// the delegate path is testable without triggering a real connect.
    static func parseURL(_ url: URL) -> (action: String, params: [String: String])? {
        guard url.scheme?.lowercased() == "targetbridge" else { return nil }
        let action = (url.host ?? "").lowercased()
        var params: [String: String] = [:]
        if let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems {
            for item in items where item.value != nil {
                params[item.name.lowercased()] = item.value
            }
        }
        return (action, params)
    }

    /// Handle a `targetbridge://` URL (from the app delegate).
    static func handle(url: URL) {
        guard let parsed = parseURL(url) else { return }
        run(action: parsed.action, params: parsed.params)
    }
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `cd ~/targetBridge && git push && gh run watch`
Expected: CI job "sender" PASSES.

- [ ] **Step 5: Commit**

```bash
cd ~/targetBridge
git add TargetBridge-Sender/TBDisplaySender/TBDisplaySenderAutomation.swift \
        TargetBridge-Sender/TBDisplaySenderTests/TBSenderAutomationParsingTests.swift
git commit -m "refactor(sender): extract pure parseURL from automation handle"
```

---

### Task 2: Single-instance window and an app delegate

**Files:**
- Create: `TargetBridge-Sender/TBDisplaySender/TBDisplaySenderAppDelegate.swift`
- Modify: `TargetBridge-Sender/TBDisplaySender/TBDisplaySenderApp.swift` (whole file)

**Interfaces:**
- Consumes: `TBSenderAutomation.parseURL` / `handle(url:)` from Task 1; the existing `TBDisplaySenderStatusItemController(service:)` initializer and its `activate()` method; `TBSenderAutomation.handleLaunchArguments(_:)`.
- Produces: `TBDisplaySenderAppDelegate` — a `@MainActor final class` conforming to `NSApplicationDelegate`, installed via `@NSApplicationDelegateAdaptor`. No later task depends on it.

- [ ] **Step 1: Write the app delegate**

Create `TBDisplaySenderAppDelegate.swift`:

```swift
import AppKit
import SwiftUI

/// Process-level lifecycle for the sender.
///
/// Two things used to live inside the window's `.task`, which made both depend
/// on a window existing:
///
///  • `.onOpenURL` — with a `WindowGroup`, SwiftUI opens a NEW window for every
///    incoming URL no existing window claims. `tb-connect` fires several
///    `targetbridge://` URLs per rebuild, so windows piled up (twenty was not
///    unusual). Delivering URLs here means no window is needed to receive one.
///  • Status-item activation and `--connect` launch arguments — `tb-connect`
///    starts the sender hidden (`open -g -j -a TargetBridge`) and streaming
///    must work with no window on screen.
@MainActor
final class TBDisplaySenderAppDelegate: NSObject, NSApplicationDelegate {
    private let statusItemController = TBDisplaySenderStatusItemController(
        service: TBDisplaySenderService.shared
    )

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItemController.activate()
        TBSenderAutomation.handleLaunchArguments(CommandLine.arguments)
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            TBSenderAutomation.handle(url: url)
        }
    }

    /// Clicking the Dock icon raises the existing window instead of minting one.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            sender.windows.first?.makeKeyAndOrderFront(nil)
        }
        return true
    }
}
```

- [ ] **Step 2: Rewrite the app entry point**

Replace the whole of `TBDisplaySenderApp.swift` with:

```swift
import SwiftUI

@main
struct TBDisplaySenderApp: App {
    // `Window` (not `WindowGroup`) is single-instance: SwiftUI cannot open a
    // second one, which is what fixes the stacked-window bug at the root.
    @NSApplicationDelegateAdaptor(TBDisplaySenderAppDelegate.self) private var appDelegate
    @StateObject private var service = TBDisplaySenderService.shared

    var body: some Scene {
        Window("TargetBridge", id: "main") {
            TBDisplaySenderContentView(service: service)
                .frame(minWidth: 540)
        }
        .defaultSize(width: 860, height: 860)

        Settings {
            TBDisplaySenderSettingsView(service: service)
                .frame(minWidth: 760, minHeight: 620)
        }
    }
}
```

- [ ] **Step 3: Push and verify CI builds and tests pass**

Run: `cd ~/targetBridge && git add -A && git commit -m "fix(sender): single window scene + app delegate for URLs and startup" && git push && gh run watch`
Expected: CI jobs "sender" and both receiver arches PASS. The sender job compiles the new file and re-runs the Task 1 tests.

- [ ] **Step 4: Commit**

Already committed in Step 3. Confirm with:

```bash
cd ~/targetBridge && git log --oneline -2
```

---

### Task 3: Release, install, and verify on the real desk

**Files:** none — this task tags, downloads, installs, and verifies.

**Interfaces:**
- Consumes: a green CI run on `w0-single-window`.
- Produces: an installed `/Applications/TargetBridge.app` exhibiting single-window behavior.

- [ ] **Step 1: Merge to `multi-display` and tag a release**

```bash
cd ~/targetBridge
git checkout multi-display && git merge --no-ff w0-single-window -m "Merge W0: single window"
git tag v3.4.3-multidisplay.5
git push origin multi-display --tags
gh run watch
```
Expected: `release.yml` produces `TargetBridge-arm64.app.zip` plus both receiver zips on a draft release.

- [ ] **Step 2: Download and stage the new sender**

```bash
cd /tmp && rm -rf tb-w0 && mkdir tb-w0 && cd tb-w0
gh release download v3.4.3-multidisplay.5 --repo natelake/targetBridge -p TargetBridge-arm64.app.zip
unzip -q TargetBridge-arm64.app.zip
chmod -R u+w TargetBridge.app && xattr -cr TargetBridge.app
```
The `chmod -R u+w` and `xattr -cr` are required: the CI zip unpacks without owner write permission and carries a quarantine attribute.

- [ ] **Step 3: Pause the watchdog before swapping the app**

```bash
touch ~/.tb-watchdog-off
```
Without this, `tb-watchdog` sees the sender disappear and starts a repair mid-install.

- [ ] **Step 4: Swap the app in**

```bash
killall TargetBridge 2>/dev/null
rm -rf "/Applications/TargetBridge.app"
cp -R /tmp/tb-w0/TargetBridge.app /Applications/
```

- [ ] **Step 5: Re-grant Screen Recording**

Replacing the ad-hoc-signed sender invalidates its TCC grant, and the screens stay black until it is re-approved. This step needs a human at the keyboard.

```bash
tccutil reset ScreenCapture com.targetbridge.sender
open -a TargetBridge
```
Then in System Settings → Privacy & Security → Screen Recording, enable TargetBridge. The prompt may demand the account password, which cannot be automated.

- [ ] **Step 6: Rebuild the screens and confirm nothing regressed**

```bash
rm -f ~/.tb-watchdog-off
~/bin/tb-connect --fast
~/bin/tb-selftest          # full run, including the motion probe
```
Expected: `tb-selftest` reports PASS on all four checks — both virtual displays present, one ESTABLISHED stream each, no mirroring.

- [ ] **Step 7: Verify the bug is actually fixed**

```bash
for i in $(seq 1 20); do open -g "targetbridge://connect?receiver=auto&session=1"; done
sleep 3
osascript -e 'tell application "System Events" to count windows of process "TargetBridge"'
```
Expected: `1` (or `0` if the window was never shown). Before this change the same loop produced twenty.

- [ ] **Step 8: Verify the hidden-launch path still works (R7)**

```bash
killall TargetBridge; sleep 1
open -g -j -a TargetBridge; sleep 2
pgrep -x TargetBridge >/dev/null && echo "process up"
~/bin/tb-selftest --fast
```
Expected: "process up" and a PASS — the sender streams with no visible window, and the status item is present.

---

## Follow-on plans (not in this plan)

- **W1 — pause/resume.** Its own plan. Adds protocol `0x38`, touches the receiver, and therefore requires rebuilding the receiver on both iMacs (the 2012 through `~/tbbuild/build-receiver.sh` on Catalina).
- **W2 — split screen.** Its own plan, and gated on two prerequisites from the spec: reconstructing `~/bin/tb-arrange` from source into `cli/`, and measuring HiDPI backing availability at split widths.
