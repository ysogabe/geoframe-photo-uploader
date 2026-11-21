import Foundation

/// 送信前の重複確認（原本を書き出して MD5 を計算し、Drive 一覧と照合するだけ。アップロードはしない）。
public struct PrecheckResult: Sendable, Equatable {
    public var localIdentifier: String
    public var decision: PlanDecision
    public var md5: String?
    /// 原本の取得に失敗したときの理由（decision は `.notHashed`）
    public var error: String?

    public init(localIdentifier: String, decision: PlanDecision, md5: String?, error: String?) {
        self.localIdentifier = localIdentifier; self.decision = decision; self.md5 = md5; self.error = error
    }
}

public enum DuplicatePrecheck {
    /// `items` を順に書き出して MD5 を計算し（一時ファイルはすぐ削除）、`UploadPlanner.plan` で判定する。
    /// `onProgress(done, total)` は各アイテムの処理前と最後に呼ばれる。キャンセルされたら `CancellationError`。
    public static func run(items: [PhotoItem], exporter: OriginalExporting, remote: RemoteIndex,
                           onProgress: (@Sendable (Int, Int) -> Void)? = nil) async throws -> [PrecheckResult] {
        var inputs: [PlanInput] = []
        var md5s: [String?] = []
        var errors: [String?] = []
        for (i, item) in items.enumerated() {
            try Task.checkCancellation()
            onProgress?(i, items.count)
            var md5: String?
            var err: String?
            if item.eligibility.isEligible {
                do {
                    let e = try await exporter.export(localIdentifier: item.localIdentifier)
                    e.remove()
                    md5 = e.md5Hex
                } catch {
                    if error is CancellationError || Task.isCancelled { throw CancellationError() }
                    err = "原本の取得に失敗: \(Redactor.redact(error.localizedDescription))"
                }
            }
            md5s.append(md5)
            errors.append(err)
            inputs.append(PlanInput(localIdentifier: item.localIdentifier, eligibility: item.eligibility, md5: md5))
        }
        onProgress?(items.count, items.count)
        let decisions = UploadPlanner.plan(inputs, remote: remote)
        return items.indices.map { i in
            PrecheckResult(localIdentifier: items[i].localIdentifier, decision: decisions[i], md5: md5s[i], error: errors[i])
        }
    }
}
