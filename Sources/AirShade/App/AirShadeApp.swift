import AppKit
import SwiftUI

@main @MainActor struct AirShadeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    private var model: AppModel { delegate.model }
    var body: some Scene {
        MenuBarExtra("AirShade", systemImage: model.isEnabled ? "eye.slash.fill" : "eye") {
            Text(model.stateTitle)
            Button(model.isEnabled ? "Pause protection" : "Enable protection", action: model.toggle)
            Button("Recenter / Resume", action: model.recenter).disabled(!model.isEnabled || !model.hasFreshMotion)
            Divider()
            Button("Settings & Setup…") { delegate.showSetup(model: model) }
            Divider()
            Button("Quit AirShade") { model.shutdown(); NSApp.terminate(nil) }
        }
        .menuBarExtraStyle(.menu)
        Settings { SetupView(model: model) }
    }
    @MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
        let model = AppModel(simulation: ProcessInfo.processInfo.arguments.contains("--simulate"))
        private var setup: NSWindow?
        func applicationDidFinishLaunching(_ notification: Notification) {
            NSApp.setActivationPolicy(.accessory)
            if !UserDefaults.standard.bool(forKey: "hasOpenedSetup") || ProcessInfo.processInfo.arguments.contains("--show-setup") {
                showSetup(model: model)
            }
        }
        func applicationWillTerminate(_ notification: Notification) { model.shutdown() }
        func showSetup(model: AppModel) {
            if setup == nil {
                let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 580, height: 740),
                                      styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
                window.title = "AirShade — Settings & Setup"
                window.contentView = NSHostingView(rootView: SetupView(model: model))
                window.isReleasedWhenClosed = false; window.center()
                setup = window
            }
            UserDefaults.standard.set(true, forKey: "hasOpenedSetup")
            NSApp.activate(ignoringOtherApps: true); setup?.makeKeyAndOrderFront(nil)
        }
    }
}
