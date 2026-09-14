import SwiftUI

@main
struct TBDisplaySenderApp: App {
    // `Window` (not `WindowGroup`) is single-instance: SwiftUI cannot open a
    // second one, which is what fixes the stacked-window bug at the root.
    // URL delivery and startup live in the app delegate so neither depends on
    // a window existing — tb-connect launches the sender hidden.
    @NSApplicationDelegateAdaptor(TBDisplaySenderAppDelegate.self) private var appDelegate
    @StateObject private var service = TBDisplaySenderService.shared

    var body: some Scene {
        Window("TargetBridge", id: "main") {
            TBDisplaySenderContentView(service: service)
                .frame(minWidth: 540)
                // SwiftUI's own kAEGetURL registration wins over a handler the
                // delegate installs, so this is the path that actually receives
                // URLs. Safe here in a way it was not under WindowGroup: `Window`
                // is single-instance, so a URL can never mint a second window.
                .onOpenURL { url in
                    TBSenderAutomation.handle(url: url)
                }
        }
        .defaultSize(width: 860, height: 860)

        Settings {
            TBDisplaySenderSettingsView(service: service)
                .frame(minWidth: 760, minHeight: 620)
        }
    }
}
