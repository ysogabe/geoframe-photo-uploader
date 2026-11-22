import AppKit
import SwiftUI
import UploaderCore

/// 送信中の大きなパネル（一覧の手前に出すモーダル）。終わったら同じパネルで結果を出す。
struct SendPanelView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(spacing: 14) {
            if model.isSending, let run = model.sendRun {
                ProgressPane(run: run)
            } else {
                SummaryPane()
            }
        }
        .padding(24)
        .frame(width: 620)
        .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.secondary.opacity(0.25)))
        .shadow(color: .black.opacity(0.35), radius: 24, y: 8)
    }
}

// MARK: - 送信中

private struct ProgressPane: View {
    @EnvironmentObject private var model: AppModel
    let run: SendRunState

    private var current: PhotoItem? { run.currentId.flatMap { model.runItem(for: $0) } }

    var body: some View {
        VStack(spacing: 12) {
            Text(run.headline)
                .font(.title2.weight(.semibold))
                .monospacedDigit()

            if let current {
                LargeThumbnail(item: current, thumbnails: model.thumbnails)
                    .frame(maxWidth: 360, minHeight: 120, maxHeight: 270)
                HStack(spacing: 10) {
                    Text(current.driveName).fontWeight(.medium).lineLimit(1).truncationMode(.middle)
                    Text(Self.dateText(current.creationDate)).foregroundStyle(.secondary).monospacedDigit()
                }
                .font(.callout)
            }

            HStack(spacing: 8) {
                if model.isCancelling {
                    ProgressView().controlSize(.small)
                    Text("中止しています…")
                } else {
                    Image(systemName: "play.fill").foregroundStyle(Color.accentColor)
                    Text(UploadPhaseText.label(run.phase))
                        .monospacedDigit()
                }
            }
            .font(.title3.weight(.semibold))

            VStack(spacing: 4) {
                if let f = run.uploadFraction {
                    ProgressView(value: f).progressViewStyle(.linear)
                } else {
                    // 取得中・確認中・照合中は量が分からない
                    ProgressView(value: 0).progressViewStyle(.linear).opacity(run.phase == nil ? 0.3 : 0.6)
                }
                HStack {
                    Spacer()
                    if case .uploading? = run.phase, let s = run.bytesSent, let t = run.bytesTotal, t > 0 {
                        Text(UploadPhaseText.bytes(sent: s, total: t))
                    } else if let f = run.uploadFraction {
                        Text("\(UploadPhaseText.percent(f))%")
                    } else {
                        Text(" ")
                    }
                }
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            }

            HStack(spacing: 8) {
                Text("全体").foregroundStyle(.secondary)
                ProgressView(value: Double(run.finishedCount), total: Double(max(run.total, 1)))
                    .progressViewStyle(.linear)
                Text("\(run.finishedCount) / \(run.total)").monospacedDigit()
            }

            HStack(spacing: 18) {
                Label("送信済み \(run.tally.sent)", systemImage: "checkmark").foregroundStyle(.green)
                Label("重複スキップ \(run.tally.duplicate)", systemImage: "arrow.uturn.backward")
                    .foregroundStyle(.secondary)
                Label("失敗 \(run.tally.failed)", systemImage: "xmark")
                    .foregroundStyle(run.tally.failed > 0 ? .red : .secondary)
            }
            .font(.callout.monospacedDigit())

            let next = run.upcoming(limit: 5)
            if !next.isEmpty {
                HStack(spacing: 6) {
                    Text("次:").foregroundStyle(.secondary)
                    ForEach(next, id: \.self) { id in
                        SmallThumbnail(id: id, thumbnails: model.thumbnails)
                            .frame(width: 44, height: 44)
                            .help(model.displayName(for: id))
                    }
                    if run.remaining > next.count { Text("…").foregroundStyle(.secondary) }
                    Spacer()
                }
                .font(.callout)
            }

            HStack {
                Spacer()
                Button(role: .destructive) {
                    model.cancelRun()
                } label: {
                    Label(model.isCancelling ? "中止しています…" : "中止", systemImage: "stop.fill")
                        .frame(minWidth: 80)
                }
                .controlSize(.large)
                .disabled(model.isCancelling)
                .keyboardShortcut(.cancelAction)
            }
        }
    }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f
    }()

    static func dateText(_ d: Date?) -> String { d.map { dateFormatter.string(from: $0) } ?? "日時不明" }
}

// MARK: - 結果

private struct SummaryPane: View {
    @EnvironmentObject private var model: AppModel

    private var results: [ItemResult] { model.lastSummary?.results ?? model.sendRun?.results ?? [] }
    private var tally: RunTally { RunTally(results) }
    private var cancelled: Bool { model.runWasCancelled || (model.lastSummary?.cancelled ?? false) }
    private var failures: [ItemResult] { results.filter { $0.status == .failed && !$0.wasCancelled } }
    private var notProcessed: Int { max(0, model.lastRunItems.count - tally.processed) }

    private var title: String {
        if cancelled { return "送信を中止しました" }
        return model.lastSummary == nil ? "送信できませんでした" : "送信が完了しました"
    }

    var body: some View {
        VStack(spacing: 14) {
            Text(title).font(.title2.weight(.semibold))
            if let err = model.runError, !cancelled {
                Text(err)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 28) {
                bigCount("送信済み", tally.sent, .green)
                bigCount("重複スキップ", tally.duplicate, .secondary)
                bigCount("失敗", tally.failed, tally.failed > 0 ? .red : .secondary)
                if cancelled || notProcessed > 0 { bigCount("未処理", notProcessed, .orange) }
                if tally.ineligible > 0 { bigCount("対象外", tally.ineligible, .secondary) }
            }

            if !failures.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("失敗した写真（再送せず内容を確認してください）").font(.callout.weight(.semibold))
                    ScrollView {
                        VStack(alignment: .leading, spacing: 6) {
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
                    .frame(maxHeight: 180)
                }
            }

            HStack {
                if model.recordsFile != nil {
                    Button("records.jsonl を Finder で表示") { model.revealRecords() }
                }
                Spacer()
                Button("閉じる") { model.closeSendPanel() }
                    .keyboardShortcut(.defaultAction)
                    .controlSize(.large)
            }
        }
    }

    private func bigCount(_ label: String, _ n: Int, _ color: Color) -> some View {
        VStack(spacing: 2) {
            Text("\(n)").font(.system(size: 34, weight: .bold)).monospacedDigit().foregroundStyle(color)
            Text(label).font(.callout).foregroundStyle(.secondary)
        }
    }
}

// MARK: - サムネイル

/// 処理中の写真（大きめのサムネイルを取り直す。届くまでは一覧用の小さい方を出す）。
struct LargeThumbnail: View {
    let item: PhotoItem
    let thumbnails: ThumbnailCache
    @State private var image: NSImage?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .quaternaryLabelColor))
            if let image {
                Image(nsImage: image).resizable().scaledToFit()
            } else {
                Image(systemName: "photo").font(.largeTitle).foregroundStyle(.secondary)
            }
        }
        .aspectRatio(4.0 / 3.0, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .task(id: item.id) {
            image = thumbnails.cachedLarge(item.id) ?? thumbnails.cached(item.id)
            if let big = await thumbnails.largeImage(for: item.id), !Task.isCancelled { image = big }
        }
    }
}

private struct SmallThumbnail: View {
    let id: String
    let thumbnails: ThumbnailCache
    @State private var image: NSImage?

    var body: some View {
        Color(nsColor: .quaternaryLabelColor)
            .overlay {
                if let image { Image(nsImage: image).resizable().scaledToFill() }
            }
            .clipShape(RoundedRectangle(cornerRadius: 5))
            .task(id: id) {
                if let hit = thumbnails.cached(id) { image = hit; return }
                let img = await thumbnails.image(for: id)
                if !Task.isCancelled { image = img }
            }
    }
}
