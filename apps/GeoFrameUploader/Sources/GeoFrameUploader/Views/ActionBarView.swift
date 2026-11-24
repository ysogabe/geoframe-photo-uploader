import SwiftUI
import UploaderCore

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
                .help("Shift+クリックで表示中の写真を範囲選択できます")
            Toggle("送信済み・重複を隠す", isOn: $model.hideDone)
                .toggleStyle(.checkbox)
                .fixedSize()
                .help("前回までに送信済み、または Drive に同じ内容があると分かっている写真を一覧から隠します")
            Toggle("選んだら自動で重複確認", isOn: $model.autoPrecheckEnabled)
                .toggleStyle(.checkbox)
                .fixedSize()
                .disabled(!model.canAutoPrecheck)
                .help(model.canAutoPrecheck
                      ? "写真を選ぶたびに、新しく選んだ写真だけを Drive と照合し、重複なら選択から外します（送信はしません）"
                      : "Google に接続し、写真ライブラリのフルアクセスを許可すると使えます")

            Spacer()

            if let p = model.progress {
                progressView(p)
            } else if let a = model.autoProgress {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text(AutoPrecheckText.progress(current: a.current, total: a.total))
                        .font(.callout)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            } else if !model.selection.isEmpty, let hint = disabledHint {
                Text(hint).font(.caption).foregroundStyle(.orange)
            }

            // 送信中の「中止」は送信パネルにある
            if model.isPrechecking {
                Button(role: .destructive) {
                    model.cancelRun()
                } label: {
                    Label(model.isCancelling ? "中止中…" : "中止", systemImage: "stop.fill")
                }
                .disabled(model.isCancelling)
                .keyboardShortcut(.cancelAction)
            }

            Button {
                model.openLocationPickerForSelection()
            } label: {
                Label("位置を設定…", systemImage: "mappin.and.ellipse")
            }
            .disabled(model.isBusy || model.selectedAssignableLocationItems.isEmpty)
            .help("選択中の写真のうち、位置情報がない写真にのみ位置を補完します（既存の位置情報は上書きしません）")

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
                .frame(minWidth: 60, idealWidth: 160, maxWidth: 160)
        }
    }
}
