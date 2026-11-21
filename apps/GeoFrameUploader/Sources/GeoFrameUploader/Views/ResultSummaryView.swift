import SwiftUI
import UploaderCore

/// 実行後の結果まとめ。
struct ResultSummaryView: View {
    @EnvironmentObject private var model: AppModel
    let summary: RunSummary

    private var sent: Int { summary.results.filter { $0.status == .sent }.count }
    private var duplicates: Int { summary.results.filter { $0.status == .skippedDuplicate }.count }
    private var ineligible: Int { summary.results.filter { $0.status == .skippedIneligible }.count }
    private var failures: [ItemResult] { summary.results.filter { $0.status == .failed && !$0.wasCancelled } }
    private var notProcessed: Int {
        let processed = summary.results.filter { !$0.wasCancelled }.count
        return max(0, model.lastRunItems.count - processed)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 16) {
                Text(summary.cancelled ? "結果（中止）" : "結果").font(.headline)
                count("送信済み", sent, .green)
                count("重複スキップ", duplicates, .secondary)
                if ineligible > 0 { count("対象外", ineligible, .secondary) }
                count("失敗", failures.count, failures.isEmpty ? .secondary : .red)
                if notProcessed > 0 { count("未処理", notProcessed, .orange) }
                Spacer()
                Button {
                    model.dismissSummary()
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.borderless)
                .help("閉じる")
            }

            if !failures.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(failures, id: \.localIdentifier) { r in
                            HStack(alignment: .firstTextBaseline, spacing: 6) {
                                Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
                                Text(r.originalFilename ?? model.displayName(for: r.localIdentifier))
                                    .fontWeight(.semibold)
                                Text(r.error ?? "不明なエラー")
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .font(.caption)
                            .textSelection(.enabled)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 110)
            }

            if let path = model.recordsFile {
                HStack(spacing: 6) {
                    Text("記録:").foregroundStyle(.secondary)
                    Text(path)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Button("Finder で表示") { model.revealRecords() }
                        .controlSize(.small)
                }
                .font(.caption)
            }
        }
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private func count(_ label: String, _ n: Int, _ color: Color) -> some View {
        HStack(spacing: 4) {
            Text(label).foregroundStyle(.secondary)
            Text("\(n)").fontWeight(.semibold).foregroundStyle(color).monospacedDigit()
        }
    }
}
