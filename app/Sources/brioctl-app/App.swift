import AppKit
import BrioctlCore
import SwiftUI

@main
struct BrioctlApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra("brioctl", systemImage: "web.camera") {
            RootView(model: AppDelegate.model)
        }
        .menuBarExtraStyle(.window)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    static let model = AppModel()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)  // menu bar only, also when started without the Info.plist
        AppDelegate.model.start()
    }

    /// brioctl:// URLs. Works with no window open, which onOpenURL in the menu content would not.
    func application(_ application: NSApplication, open urls: [URL]) {
        Task { @MainActor in
            for url in urls { await AppDelegate.model.handle(url: url) }
        }
    }
}
