import Foundation

/// 送信前の重複確認（原本を書き出して MD5 を計算し、Drive 一覧と照合するだけ。アップロードはしない）。
public struct PrecheckResult: Sendable, Equatable {
    public var localIdentifier: String
    public var decision: PlanDecision
    public var md5: String?
    /// 原本の取得に失敗したときの理由（decision は `.notHashed`）
    public var error: String?
    /// MD5 を item-cache.json から取った（原本を書き出していない）
    public var md5FromCache: Bool

    public init(localIdentifier: String, decision: PlanDecision, md5: String?, error: String?, md5FromCache: Bool = false) {
        self.localIdentifier = localIdentifier; self.decision = decision; self.md5 = md5; self.error = error
        self.md5FromCache = md5FromCache
    }
}

public enum DuplicatePrecheck {
    /// `items` を順に書き出して MD5 を計算し（一時ファイルはすぐ削除）、`UploadPlanner.plan` で判定する。
    /// `cache` に有効な MD5 があるアイテムは書き出さずにその MD5 で照合する。書き出したハッシュはその都度、
    /// 判定結果は最後に `cache` へ書き戻す（`folderId` は状態の記録用）。
    /// `onProgress(done, total)` は各アイテムの処理前と最後に呼ばれる。キャンセルされたら `CancellationError`。
    public static func run(items: [PhotoItem], exporter: OriginalExporting, remote: RemoteIndex,
                           cache: ResultCache? = nil, folderId: String? = nil,
                           onProgress: (@Sendable (Int, Int) -> Void)? = nil) async throws -> [PrecheckResult] {
        var inputs: [PlanInput] = []
        var md5s: [String?] = []
        var errors: [String?] = []
        var fromCache: [Bool] = []
        cache?.refresh()
        for (i, item) in items.enumerated() {
            try Task.checkCancellation()
            onProgress?(i, items.count)
            var md5: String?
            var err: String?
            var hit = false
            if item.eligibility.isEligible {
                if let cached = cache?.cachedMD5(for: item) {
                    md5 = cached
                    hit = true
                } else {
                    do {
                        let e = try await exporter.export(localIdentifier: item.localIdentifier)
                        e.remove()
                        md5 = e.md5Hex
                        // 中止されても計算済みのハッシュは残す
                        cache?.recordHash(item: item, md5: e.md5Hex, sha256: e.sha256Hex, byteCount: e.byteCount)
                    } catch {
                        if error is CancellationError || Task.isCancelled { throw CancellationError() }
                        err = "原本の取得に失敗: \(Redactor.redact(error.localizedDescription))"
                    }
                }
            }
            md5s.append(md5)
            errors.append(err)
            fromCache.append(hit)
            inputs.append(PlanInput(localIdentifier: item.localIdentifier, eligibility: item.eligibility, md5: md5))
        }
        onProgress?(items.count, items.count)
        let decisions = UploadPlanner.plan(inputs, remote: remote)
        if let cache {
            var updates: [ResultCache.StatusUpdate] = []
            for (i, d) in decisions.enumerated() {
                switch d {
                case .duplicateRemote(let fid, _):
                    updates.append(.init(item: items[i], status: .duplicateRemote, driveFileId: fid.isEmpty ? nil : fid,
                                         folderId: folderId))
                case .toUpload, .duplicateInBatch:
                    updates.append(.init(item: items[i], status: .checkedNotOnDrive, driveFileId: nil, folderId: folderId))
                case .ineligible, .notHashed:
                    break
                }
            }
            cache.recordStatuses(updates)
        }
        return items.indices.map { i in
            PrecheckResult(localIdentifier: items[i].localIdentifier, decision: decisions[i], md5: md5s[i], error: errors[i],
                           md5FromCache: fromCache[i])
        }
    }
}
