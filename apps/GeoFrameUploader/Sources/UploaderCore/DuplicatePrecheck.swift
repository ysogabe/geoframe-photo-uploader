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
            let h = try await hash(item: item, exporter: exporter, cache: cache)
            md5s.append(h.md5)
            errors.append(h.error)
            fromCache.append(h.fromCache)
            inputs.append(PlanInput(localIdentifier: item.localIdentifier, eligibility: item.eligibility, md5: h.md5))
        }
        onProgress?(items.count, items.count)
        let decisions = UploadPlanner.plan(inputs, remote: remote)
        if let cache {
            cache.recordStatuses(items.indices.compactMap { statusUpdate(item: items[$0], decision: decisions[$0], folderId: folderId) })
        }
        return items.indices.map { i in
            PrecheckResult(localIdentifier: items[i].localIdentifier, decision: decisions[i], md5: md5s[i], error: errors[i],
                           md5FromCache: fromCache[i])
        }
    }

    /// 1 枚だけ確認する（選んだら自動で重複確認）。`priorSelected` は既に MD5 が分かっている他の選択中の写真で、
    /// 同じ MD5 があればこの写真を「選択内の先行写真と同一」とする（先に選んだ方を残す）。
    /// 判定結果は `cache` に書き戻す。キャンセルされたら `CancellationError`。
    public static func checkOne(item: PhotoItem, priorSelected: [PlanInput], exporter: OriginalExporting,
                                remote: RemoteIndex, cache: ResultCache? = nil,
                                folderId: String? = nil) async throws -> PrecheckResult {
        try Task.checkCancellation()
        let h = try await hash(item: item, exporter: exporter, cache: cache)
        let prior = priorSelected.filter { $0.localIdentifier != item.localIdentifier }
        let input = PlanInput(localIdentifier: item.localIdentifier, eligibility: item.eligibility, md5: h.md5)
        let decision = UploadPlanner.plan(prior + [input], remote: remote).last ?? .notHashed
        if let cache, let u = statusUpdate(item: item, decision: decision, folderId: folderId) {
            cache.recordStatuses([u])
        }
        return PrecheckResult(localIdentifier: item.localIdentifier, decision: decision, md5: h.md5, error: h.error,
                              md5FromCache: h.fromCache)
    }

    /// 有効なキャッシュの MD5、無ければ原本を書き出して計算する（一時ファイルはすぐ削除し、ハッシュはキャッシュへ）。
    /// 取得の失敗は `error` に入れて返す（キャンセルだけ投げる）。対象外は何もしない。
    static func hash(item: PhotoItem, exporter: OriginalExporting,
                     cache: ResultCache?) async throws -> (md5: String?, error: String?, fromCache: Bool) {
        guard item.eligibility.isEligible else { return (nil, nil, false) }
        if let cached = cache?.cachedMD5(for: item) { return (cached, nil, true) }
        do {
            let e = try await exporter.export(localIdentifier: item.localIdentifier)
            e.remove()
            // 中止されても計算済みのハッシュは残す
            cache?.recordHash(item: item, md5: e.md5Hex, sha256: e.sha256Hex, byteCount: e.byteCount)
            return (e.md5Hex, nil, false)
        } catch {
            if error is CancellationError || Task.isCancelled { throw CancellationError() }
            return (nil, "原本の取得に失敗: \(Redactor.redact(error.localizedDescription))", false)
        }
    }

    static func statusUpdate(item: PhotoItem, decision: PlanDecision, folderId: String?) -> ResultCache.StatusUpdate? {
        switch decision {
        case .duplicateRemote(let fid, _):
            return .init(item: item, status: .duplicateRemote, driveFileId: fid.isEmpty ? nil : fid, folderId: folderId)
        case .toUpload, .duplicateInBatch:
            return .init(item: item, status: .checkedNotOnDrive, driveFileId: nil, folderId: folderId)
        case .ineligible, .notHashed:
            return nil
        }
    }
}
