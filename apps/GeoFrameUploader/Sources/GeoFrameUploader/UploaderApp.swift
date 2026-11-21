import AppKit
import SwiftUI
import UploaderCore

/// SwiftUI アプリ本体（`@main` は Entry.swift）。
struct UploaderApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel()

    var body: some Scene {
        Window("GeoFrame Uploader", id: "main") {
            ContentView()
                .environmentObject(model)
                .frame(minWidth: 900, minHeight: 600)
        }
        .defaultSize(width: 1120, height: 780)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }
    }
}

/// 通常アプリとして起動し、`open` で起動されたときもウィンドウを最前面に出す。
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        // ウィンドウが作られた後に前面化する
        DispatchQueue.main.async {
            NSApp.activate()
            NSApp.windows.first(where: { $0.canBecomeMain })?.makeKeyAndOrderFront(nil)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
