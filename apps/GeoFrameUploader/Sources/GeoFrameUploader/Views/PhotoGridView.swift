import SwiftUI
import UploaderCore

/// サムネイル一覧。セルには値だけを渡し、モデル全体を監視させない。
struct PhotoGridView: View {
    @EnvironmentObject private var model: AppModel

    private let columns = [GridItem(.adaptive(minimum: 140, maximum: 180), spacing: 12, alignment: .top)]

    var body: some View {
        Group {
            if model.items.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, alignment: .leading, spacing: 14) {
                        ForEach(model.items) { item in
                            PhotoCell(
                                item: item,
                                isSelected: model.selection.contains(item.id),
                                isSelectable: model.isSelectable(item),
                                live: model.livePhases[item.id],
                                result: model.results[item.id],
                                precheck: model.prechecks[item.id],
                                duplicateNote: duplicateNote(for: item),
                                thumbnails: model.thumbnails,
                                onToggle: { model.toggle(item) }
                            )
                        }
                    }
                    .padding(12)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var emptyState: some View {
        if model.isLoading {
            ProgressView("読み込み中…")
        } else if model.hasLoaded {
            ContentUnavailableView("写真がありません", systemImage: "photo",
                                   description: Text("指定した日付に撮影された写真は見つかりませんでした。"))
        } else {
            ContentUnavailableView("日付を選んで「読み込む」を押してください", systemImage: "calendar",
                                   description: Text("写真アプリの写真を撮影日で一覧にします（Mac のローカル時刻）。"))
        }
    }

    /// 重複のツールチップ（送信結果を優先、無ければ事前確認の結果）。
    private func duplicateNote(for item: PhotoItem) -> String? {
        if let r = model.results[item.id], r.status == .skippedDuplicate {
            if let fid = r.duplicateOfFileId, !fid.isEmpty { return "Drive の既存ファイルと同一（fileId: \(fid)）" }
            if let lid = r.duplicateOfLocalIdentifier { return "この実行内の先行写真と同一: \(model.displayName(for: lid))" }
            return "既存ファイルと同一"
        }
        if let p = model.prechecks[item.id] {
            switch p.decision {
            case .duplicateRemote(let fid, let name):
                return "Drive の既存ファイルと同一の見込み: \(name.isEmpty ? "" : name + " ")（fileId: \(fid)）"
            case .duplicateInBatch(let lid):
                return "選択内の先行写真と同一の見込み: \(model.displayName(for: lid))"
            default: return nil
            }
        }
        return nil
    }
}
