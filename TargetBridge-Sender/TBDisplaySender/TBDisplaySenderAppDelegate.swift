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
///    must keep working with no window on screen.
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
