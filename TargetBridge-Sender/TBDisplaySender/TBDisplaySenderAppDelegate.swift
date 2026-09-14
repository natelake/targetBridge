import AppKit
import SwiftUI

/// Process-level lifecycle for the sender.
///
/// Three things must hold, and each one was broken at some point by moving the
/// scene from `WindowGroup` to a single-instance `Window`:
///
///  • **URLs must arrive with or without a window.** `tb-connect` drives every
///    connect through `targetbridge://` URLs. With `WindowGroup` + `.onOpenURL`
///    SwiftUI opened a NEW window per URL (up to twenty piled up). Dropping
///    `.onOpenURL` stopped the pile-up but also stopped delivery outright:
///    SwiftUI registers its own `kAEGetURL` Apple Event handler and swallows
///    the event when no `.onOpenURL` exists, and `application(_:open:)` never
///    fires. Registering our own handler in `applicationWillFinishLaunching`
///    takes that registration back, and works with no window at all.
///
///  • **The process must outlive its window.** Streaming needs the process, not
///    a window — `tb-connect` starts the sender hidden with `open -g -j`, and
///    closing the window must not kill the screens.
///
///  • **Startup must not depend on a window either**, so the status item and
///    `--connect` launch arguments are handled here rather than in a view.
@MainActor
final class TBDisplaySenderAppDelegate: NSObject, NSApplicationDelegate {
    private let statusItemController = TBDisplaySenderStatusItemController(
        service: TBDisplaySenderService.shared
    )

    /// Must be `willFinish`, not `didFinish`: the URL that launched the app is
    /// delivered during launch, and a handler registered later misses it.
    func applicationWillFinishLaunching(_ notification: Notification) {
        NSAppleEventManager.shared().setEventHandler(
            self,
            andSelector: #selector(handleGetURLEvent(_:withReplyEvent:)),
            forEventClass: AEEventClass(kInternetEventClass),
            andEventID: AEEventID(kAEGetURL)
        )
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItemController.activate()
        TBSenderAutomation.handleLaunchArguments(CommandLine.arguments)
    }

    @objc
    private func handleGetURLEvent(_ event: NSAppleEventDescriptor,
                                   withReplyEvent reply: NSAppleEventDescriptor) {
        guard let string = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue,
              let url = URL(string: string)
        else { return }
        TBSenderAutomation.handle(url: url)
    }

    /// Kept as a second path: some launch routes deliver through the delegate
    /// rather than the Apple Event. `TBSenderAutomation.run` is idempotent per
    /// action, so a URL arriving twice is harmless.
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            TBSenderAutomation.handle(url: url)
        }
    }

    /// The sender streams from its process, not from a window. Closing the
    /// window must leave the screens up.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    /// Clicking the Dock icon raises the existing window instead of minting one.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            sender.windows.first?.makeKeyAndOrderFront(nil)
        }
        return true
    }
}
