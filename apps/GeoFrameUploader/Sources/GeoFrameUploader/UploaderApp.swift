import AppKit
import SwiftUI
import UploaderCore

/// SwiftUI アプリ本体（`@main` は Entry.swift）。
struct UploaderApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Window("GeoFrame Uploader", id: "main") {
            // モデルは AppDelegate が持つ（終了時に送信中かどうかを確かめるため）
            ContentView()
                .environmentObject(appDelegate.model)
                .frame(minWidth: 900, minHeight: 600)
                .modifier(CloseGuard(model: appDelegate.model))
        }
        .defaultSize(width: 1120, height: 780)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }
    }
}

/// 送信中・重複確認中はウィンドウを閉じられないようにする（閉じるボタンと ⌘W。macOS 15 以降）。
/// それ以前の macOS では、閉じると最後のウィンドウとして終了の確認（AppDelegate）に回る。
private struct CloseGuard: ViewModifier {
    @ObservedObject var model: AppModel

    func body(content: Content) -> some View {
        if #available(macOS 15.0, *) {
            content.windowDismissBehavior(model.needsQuitConfirmation ? .disabled : .automatic)
        } else {
            content
        }
    }
}

/// 通常アプリとして起動し、`open` で起動されたときもウィンドウを最前面に出す。
/// 送信中・重複確認中の終了は確認してから、中止して記録と一時ファイルの後始末を待って終了する。
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()
    /// 終了待ち（中止して後始末を待っている）
    private var terminationPending = false

    /// 後始末を待つ上限（秒）
    static let terminationTimeout: TimeInterval = 15

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        // 前回強制終了したときに残った原本の一時ディレクトリを掃除する
        Task.detached(priority: .utility) { TempSweeper.sweepStale() }
        // ウィンドウが作られた後に前面化する
        DispatchQueue.main.async {
            NSApp.activate()
            NSApp.windows.first(where: { $0.canBecomeMain })?.makeKeyAndOrderFront(nil)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if terminationPending { return .terminateCancel }   // 既に終了待ち（そちらの返事で終了する）
        guard model.hasActiveWork else {
            model.cancelBackgroundWorkForImmediateTerminate()
            return .terminateNow
        }
        if model.needsQuitConfirmation {
            guard confirmStopAndQuit() else {
                // 続ける。閉じられてしまったウィンドウがあれば出し直す（最後のウィンドウを閉じて終了に来た場合）
                if !NSApp.windows.contains(where: { $0.isVisible && $0.canBecomeMain }) {
                    NSApp.windows.first(where: { $0.canBecomeMain })?.makeKeyAndOrderFront(nil)
                }
                return .terminateCancel
            }
        }
        // 自動の重複確認だけなら確認せずに中止する（送信はしていない）
        terminationPending = true
        let model = self.model
        Task { @MainActor in
            await model.stopForTermination(timeout: Self.terminationTimeout)
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    /// 「送信中です。中止して終了しますか？」。中止して終了なら真。
    private func confirmStopAndQuit() -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = model.quitConfirmationMessage
        alert.informativeText = "処理中の写真は中止し、ここまでの記録を保存して一時ファイルを消してから終了します。"
            + "送信済みの写真はそのまま Drive に残ります。"
        let quit = alert.addButton(withTitle: "中止して終了")
        quit.hasDestructiveAction = true
        quit.keyEquivalent = ""
        // Return は「続ける」（誤って中止しない）
        let keep = alert.addButton(withTitle: "続ける")
        keep.keyEquivalent = "\r"
        return alert.runModal() == .alertFirstButtonReturn
    }
}
