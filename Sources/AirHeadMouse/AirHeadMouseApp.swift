import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    let controller = AppController()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory) // 只顯示菜單欄圖標，不佔 Dock
        controller.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        controller.stop()
    }
}

@main
struct AirHeadMouseApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra {
            MenuContentView(app: delegate.controller)
        } label: {
            MenuBarLabel(app: delegate.controller)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView(app: delegate.controller)
        }
    }
}

private struct MenuBarLabel: View {
    @ObservedObject var app: AppController
    var body: some View { Image(systemName: app.statusSymbol) }
}
