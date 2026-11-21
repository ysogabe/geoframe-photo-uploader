import Foundation

/// ログ・エラーメッセージからトークン類を除去する。
public enum Redactor {
    private static let patterns: [(NSRegularExpression, String)] = {
        let specs: [(String, String)] = [
            (#"ya29\.[A-Za-z0-9._\-]+"#, "ya29.<redacted>"),
            (#"1//[A-Za-z0-9._\-]+"#, "1//<redacted>"),
            (#"(?i)("(?:access_token|refresh_token|id_token|client_secret|code|code_verifier)"\s*:\s*")[^"]*(")"#, "$1<redacted>$2"),
            (#"(?i)((?:access_token|refresh_token|client_secret|code|code_verifier|upload_id|token)=)[^&\s"']+"#, "$1<redacted>"),
            (#"(?i)(Bearer\s+)[A-Za-z0-9._\-]+"#, "$1<redacted>"),
        ]
        return specs.compactMap { p, t in (try? NSRegularExpression(pattern: p)).map { ($0, t) } }
    }()

    public static func redact(_ s: String) -> String {
        var out = s
        for (re, tmpl) in patterns {
            out = re.stringByReplacingMatches(in: out, range: NSRange(out.startIndex..., in: out), withTemplate: tmpl)
        }
        return out
    }
}

/// `application/x-www-form-urlencoded` 用の厳格なエンコード。
public enum FormEncoding {
    static let unreserved: CharacterSet = {
        var s = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
        s.insert(charactersIn: "-._~")
        return s
    }()

    public static func escape(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: unreserved) ?? s
    }

    public static func encode(_ pairs: [(String, String)]) -> String {
        pairs.map { "\(escape($0.0))=\(escape($0.1))" }.joined(separator: "&")
    }

    /// クエリ文字列を辞書に（重複キーは最初の値）。
    public static func parseQuery(_ q: String) -> [String: String] {
        var out: [String: String] = [:]
        for part in q.split(separator: "&", omittingEmptySubsequences: true) {
            let kv = part.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            let rawK = String(kv[0]).replacingOccurrences(of: "+", with: " ")
            let rawV = kv.count > 1 ? String(kv[1]).replacingOccurrences(of: "+", with: " ") : ""
            let k = rawK.removingPercentEncoding ?? rawK
            let v = rawV.removingPercentEncoding ?? rawV
            if out[k] == nil { out[k] = v }
        }
        return out
    }
}

/// 非同期 sleep の差し替え口（テストでは待たない）。
public typealias Sleeper = @Sendable (TimeInterval) async throws -> Void

public let defaultSleeper: Sleeper = { seconds in
    try await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
}

extension HTTPURLResponse {
    func header(_ name: String) -> String? { value(forHTTPHeaderField: name) }
}
