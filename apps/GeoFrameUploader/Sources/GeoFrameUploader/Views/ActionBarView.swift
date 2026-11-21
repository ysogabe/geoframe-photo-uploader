import SwiftUI

/// 選択操作・重複確認・送信・中止と全体の進捗。
struct ActionBarView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        HStack(spacing: 10) {
            Button("すべて選択") { model.selectAll() }
                .disabled(model.isBusy || model.eligibleCount == 0)
            Button("選択解除") { model.deselectAll() }
                .disabled(model.isBusy || model.selection.isEmpty)
            Text("選択 \(model.selection.count) 件")
                .monospacedDigit()
                .foregroundStyle(.secondary)
            Toggle("送信済み・重複を隠す", isOn: $model.hideDone)
                .toggleStyle(.checkbox)
                .help("前回までに送信済み、または Drive に同じ内容があると分かっている写真を一覧から隠します")

            Spacer()

            if let p = model.progress {
                progressView(p)
            } else if !model.selection.isEmpty, let hint = disabledHint {
                Text(hint).font(.caption).foregroundStyle(.orange)
            }

            if model.isSending || model.isPrechecking {
                Button(role: .destructive) {
                    model.cancelRun()
                } label: {
                    Label(model.isCancelling ? "中止中…" : "中止", systemImage: "stop.fill")
                }
                .disabled(model.isCancelling)
                .keyboardShortcut(.cancelAction)
            }

            Button("重複を確認") { model.precheck() }
                .disabled(!model.canPrecheck)
                .help("選択した写真の原本 MD5 を計算し、Drive フォルダ内のファイルと照合します（送信はしません）")

            Button {
                model.requestSend()
            } label: {
                Label("送信", systemImage: "paperplane.fill")
            }
            .buttonStyle(.borderedProminent)
            .disabled(!model.canSend)
            .help("選択した写真の原本を Google ドライブへ順に送信します")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private var disabledHint: String? {
        guard let s = model.status else { return nil }
        if s.photosAuthorization != .authorized { return "写真ライブラリのフルアクセスが必要です" }
        if !s.oauthClientValid || !s.signedIn { return "Google に接続してください" }
        return nil
    }

    private func progressView(_ p: RunProgress) -> some View {
        let title = p.kind == .upload ? "送信中" : "重複を確認中"
        return HStack(spacing: 8) {
            Text("\(title) \(max(p.current, p.done))/\(p.total)")
                .font(.callout)
                .monospacedDigit()
            ProgressView(value: Double(p.done), total: Double(max(p.total, 1)))
                .progressViewStyle(.linear)
                .frame(width: 160)
        }
    }
}
