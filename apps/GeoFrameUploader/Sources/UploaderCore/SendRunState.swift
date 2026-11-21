import Foundation

/// 結果の件数。
public struct RunTally: Sendable, Equatable {
    public var sent = 0
    public var duplicate = 0
    /// 中止で打ち切られたものは含めない
    public var failed = 0
    public var ineligible = 0
    public var cancelled = 0

    public init() {}

    public init(_ results: [ItemResult]) {
        for r in results { add(r) }
    }

    public mutating func add(_ r: ItemResult) {
        switch r.status {
        case .sent: sent += 1
        case .skippedDuplicate: duplicate += 1
        case .skippedIneligible: ineligible += 1
        case .failed: if r.wasCancelled { cancelled += 1 } else { failed += 1 }
        }
    }

    /// 処理を終えた件数（中止で打ち切られたものを除く）
    public var processed: Int { sent + duplicate + failed + ineligible }
}

/// 送信パネルの状態（UploadEvent を順に適用する純粋な状態）。
/// 送信は 1 件ずつなので、処理中のアイテムは常に「終わった件数」番目（0 始まり）。
public struct SendRunState: Sendable, Equatable {
    /// 送る順の localIdentifier
    public let order: [String]
    public private(set) var finishedCount = 0
    public private(set) var tally = RunTally()
    public private(set) var results: [ItemResult] = []
    /// 処理中のアイテムの段階（`.finished` は入れない。次のアイテムの最初のイベントまでは nil）
    public private(set) var phase: UploadPhase?
    public private(set) var bytesSent: Int64?
    public private(set) var bytesTotal: Int64?

    public init(order: [String]) { self.order = order }

    public var total: Int { order.count }

    /// 処理中（または次に処理する）アイテムの 1 始まりの番号。
    public var position: Int { total == 0 ? 0 : min(finishedCount + 1, total) }

    /// まだ終わっていない件数（処理中のものを除く）。
    public var remaining: Int { max(0, total - finishedCount - 1) }

    public var isComplete: Bool { finishedCount >= total }

    /// 処理中（または次に処理する）アイテム。
    public var currentId: String? { finishedCount < total ? order[finishedCount] : nil }

    /// 処理中の次から `limit` 件。
    public func upcoming(limit: Int = 5) -> [String] {
        let start = finishedCount + 1
        guard start < total, limit > 0 else { return [] }
        return Array(order[start..<min(total, start + limit)])
    }

    /// 「送信中  3 / 12 枚目（残り 9 枚）」
    public var headline: String { "送信中  \(position) / \(total) 枚目（残り \(remaining) 枚）" }

    /// イベントを適用する。表示が変わるとき（送信中の % は整数が変わったとき）だけ真。
    @discardableResult
    public mutating func apply(_ ev: UploadEvent) -> Bool {
        let before = self
        switch ev.phase {
        case .finished(let r):
            results.append(r)
            tally.add(r)
            finishedCount = max(finishedCount, min(ev.index + 1, total))
            phase = nil
            bytesSent = nil
            bytesTotal = nil
        default:
            // 古い（既に終わった）アイテムのイベントは無視する
            guard ev.index >= finishedCount else { return false }
            finishedCount = min(ev.index, total)
            phase = ev.phase
            bytesSent = ev.bytesSent
            bytesTotal = ev.bytesTotal
        }
        return before.displayKey != displayKey
    }

    /// 再描画を抑えるための比較キー（送信中の % は整数、バイト数は 0.1 MB 単位）。
    private var displayKey: [String] {
        let phaseKey: String
        switch phase {
        case nil: phaseKey = "-"
        case .exporting?: phaseKey = "e"
        case .checkingDuplicate?: phaseKey = "c"
        case .uploading(let f)?: phaseKey = "u\(UploadPhaseText.percent(f))"
        case .verifying?: phaseKey = "v"
        case .finished?: phaseKey = "f"
        }
        return ["\(finishedCount)", "\(results.count)", phaseKey,
                bytesSent.map { "\($0 / 100_000)" } ?? "-", bytesTotal.map { "\($0)" } ?? "-"]
    }

    /// 処理中のアイテムの送信の割合（0...1。送信中でなければ nil）。
    public var uploadFraction: Double? {
        guard case .uploading(let f)? = phase else { return nil }
        if let s = bytesSent, let t = bytesTotal, t > 0 { return min(1, max(0, Double(s) / Double(t))) }
        return min(1, max(0, f))
    }
}

/// 送信の段階・バイト数の表示文言。
public enum UploadPhaseText {
    public static func percent(_ fraction: Double) -> Int {
        max(0, min(100, Int((fraction * 100).rounded(.down))))
    }

    /// パネルの大きな文言。`nil` は次のアイテムの準備中。
    public static func label(_ phase: UploadPhase?) -> String {
        switch phase {
        case nil: return "準備中…"
        case .exporting?: return "写真ライブラリ / iCloud から原本を取得中"
        case .checkingDuplicate?: return "重複を確認中"
        case .uploading(let f)?: return "Google ドライブへ送信中 \(percent(f))%"
        case .verifying?: return "Drive で md5 を照合中"
        case .finished?: return "完了"
        }
    }

    /// 「5.1 / 8.0 MB」（1 MB 未満なら KB）。
    public static func bytes(sent: Int64, total: Int64) -> String {
        let s = max(0, min(sent, total))
        if total < 1_000_000 {
            return "\(s / 1_000) / \(total / 1_000) KB"
        }
        return String(format: "%.1f / %.1f MB", Double(s) / 1_000_000, Double(total) / 1_000_000)
    }
}
