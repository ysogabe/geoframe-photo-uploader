import Foundation

/// 「選んだら自動で重複確認」の待ち行列（UI 非依存の純粋な状態）。
/// 1 件ずつ順に確認する。選択から外れた待ちは捨て、処理中のものが外れたら中止を求める。
/// `done` / `total` は 1 回のまとまり（待ちが空になるまで）の進捗で、空になったら 0 に戻す。
public struct AutoPrecheckQueue: Sendable, Equatable {
    public private(set) var pending: [String] = []
    public private(set) var inFlight: String?
    public private(set) var done = 0
    public private(set) var total = 0

    public init() {}

    public var isIdle: Bool { pending.isEmpty && inFlight == nil }

    /// 表示用の進捗（処理中の 1 始まりの番号 / まとまりの件数）。何もしていなければ nil。
    public var progress: (current: Int, total: Int)? {
        isIdle ? nil : (min(done + 1, total), total)
    }

    /// 選択が変わったとき。選択から外れた待ちを捨て、`added`（確認が必要な新しい選択、表示順）を待ちに足す。
    /// 処理中のアイテムが選択から外れたら真（呼び出し側はそれを中止する）。
    @discardableResult
    public mutating func selectionChanged(selection: Set<String>, added: [String]) -> Bool {
        let before = pending.count
        pending.removeAll { !selection.contains($0) }
        total -= before - pending.count
        for id in added where selection.contains(id) && id != inFlight && !pending.contains(id) {
            pending.append(id)
            total += 1
        }
        if let f = inFlight, !selection.contains(f) { return true }
        return false
    }

    /// 次に確認するアイテム（処理中があれば nil）。
    public mutating func next() -> String? {
        guard inFlight == nil, !pending.isEmpty else { return nil }
        let id = pending.removeFirst()
        inFlight = id
        return id
    }

    /// 処理中のアイテムが終わった。`counted` が偽（選択から外れて中止した等）なら件数から除く。
    /// まとまりが終わった（待ちが空になった）ら真。
    @discardableResult
    public mutating func finish(_ id: String, counted: Bool) -> Bool {
        guard inFlight == id else { return false }
        inFlight = nil
        if counted { done += 1 } else { total = max(0, total - 1) }
        if isIdle {
            done = 0
            total = 0
            return true
        }
        return false
    }

    public mutating func reset() { self = AutoPrecheckQueue() }

    /// 新しく選ばれた（`oldSelection` に無く `newSelection` にある）対象の写真のうち、確認が要るもの（`items` の順）。
    /// `settled` はこのセッションで判定済み（もう一度確認しない）のもの。
    public static func candidates(items: [PhotoItem], oldSelection: Set<String>, newSelection: Set<String>,
                                  settled: Set<String>) -> [String] {
        items.compactMap { it in
            let id = it.localIdentifier
            guard newSelection.contains(id), !oldSelection.contains(id), it.eligibility.isEligible,
                  !settled.contains(id) else { return nil }
            return id
        }
    }

    /// このセッションの Drive 一覧で判定済みとみなせるか。送信結果があるか、重複確認で「送信予定」「Drive に既存」と
    /// 分かったもの。選択内の重複・判定できずは、選び直したときにもう一度確認する（MD5 はキャッシュにあるので速い）。
    public static func isSettled(precheck: PrecheckResult?, result: ItemResult?) -> Bool {
        if let r = result, r.status == .sent || r.status == .skippedDuplicate { return true }
        switch precheck?.decision {
        case .toUpload?, .duplicateRemote?: return true
        default: return false
        }
    }

    /// 自動確認の結果、選択から外すべきか（Drive に既存 / 選択内の先行写真と同一）。
    public static func shouldDeselect(_ decision: PlanDecision) -> Bool {
        switch decision {
        case .duplicateRemote, .duplicateInBatch: return true
        case .toUpload, .ineligible, .notHashed: return false
        }
    }
}

/// 自動重複確認の表示文言。
public enum AutoPrecheckText {
    /// 「重複のため選択を外しました: IMG_0001.HEIC（ほか 2 件）」。名前が無ければ nil。
    public static func deselectedBanner(names: [String]) -> String? {
        guard let first = names.first else { return nil }
        let rest = names.count - 1
        return "重複のため選択を外しました: \(first)" + (rest > 0 ? "（ほか \(rest) 件）" : "")
    }

    /// 「重複を確認中 2/5」
    public static func progress(current: Int, total: Int) -> String { "重複を確認中 \(current)/\(total)" }
}

/// セッション内で使い回す Drive フォルダ一覧。
public struct RemoteListingSnapshot: Sendable {
    public static let defaultMaxAge: TimeInterval = 5 * 60

    public var folderId: String
    public var index: RemoteIndex
    public var fetchedAt: Date

    public init(folderId: String, index: RemoteIndex, fetchedAt: Date) {
        self.folderId = folderId; self.index = index; self.fetchedAt = fetchedAt
    }

    /// 同じフォルダで、取得から `maxAge` 秒未満なら使い回せる（時計が戻ったときは使わない）。
    public func isUsable(folderId: String, now: Date, maxAge: TimeInterval = defaultMaxAge) -> Bool {
        guard self.folderId == folderId else { return false }
        let age = now.timeIntervalSince(fetchedAt)
        return age >= 0 && age < maxAge
    }
}
