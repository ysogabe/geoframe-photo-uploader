import CryptoKit
import Foundation
import Security

/// RFC 7636 PKCE。
public enum PKCE {
    /// 43〜128 文字の code_verifier（SecRandomCopyBytes 由来、base64url）。
    public static func makeVerifier(byteCount: Int = 64) -> String {
        base64URL(randomBytes(max(32, min(96, byteCount))))
    }

    /// S256 チャレンジ。
    public static func challenge(for verifier: String) -> String {
        base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
    }

    public static func randomState() -> String { base64URL(randomBytes(32)) }

    static func randomBytes(_ n: Int) -> Data {
        var bytes = [UInt8](repeating: 0, count: n)
        let rc = SecRandomCopyBytes(kSecRandomDefault, n, &bytes)
        precondition(rc == errSecSuccess, "SecRandomCopyBytes failed")
        return Data(bytes)
    }

    public static func base64URL(_ d: Data) -> String {
        d.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

public enum OAuthURLBuilder {
    public static func authorizationURL(client: OAuthClientConfig, redirectURI: String, scopes: [String],
                                        codeChallenge: String, state: String) -> URL {
        var c = URLComponents(url: client.authURI, resolvingAgainstBaseURL: false)!
        let params: [(String, String)] = [
            ("client_id", client.clientId),
            ("redirect_uri", redirectURI),
            ("response_type", "code"),
            ("scope", scopes.joined(separator: " ")),
            ("access_type", "offline"),
            ("prompt", "consent"),
            ("code_challenge", codeChallenge),
            ("code_challenge_method", "S256"),
            ("state", state),
        ]
        c.percentEncodedQuery = FormEncoding.encode(params)
        return c.url!
    }
}

public enum OAuthCallbackError: Error, Equatable, LocalizedError {
    case notCallback          // favicon 等、無関係なリクエスト
    case stateMismatch
    case missingCode
    case authorizationDenied(String)

    public var errorDescription: String? {
        switch self {
        case .notCallback: return "OAuth コールバックではありません"
        case .stateMismatch: return "state が一致しません（不正なコールバックの可能性）"
        case .missingCode: return "認可コードがありません"
        case .authorizationDenied(let e): return "Google 側で認可が拒否されました: \(e)"
        }
    }
}

public enum OAuthCallback {
    /// HTTP リクエスト行のターゲット（例 `/?state=..&code=..`）を検証して認可コードを返す。
    public static func parse(requestTarget: String, expectedState: String) -> Result<String, OAuthCallbackError> {
        let parts = requestTarget.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
        let path = String(parts[0])
        guard path == "/" || path.isEmpty, parts.count == 2 else { return .failure(.notCallback) }
        let q = FormEncoding.parseQuery(String(parts[1]))
        guard let state = q["state"], constantTimeEquals(state, expectedState) else { return .failure(.stateMismatch) }
        if let err = q["error"] { return .failure(.authorizationDenied(err)) }
        guard let code = q["code"], !code.isEmpty else { return .failure(.missingCode) }
        return .success(code)
    }

    static func constantTimeEquals(_ a: String, _ b: String) -> Bool {
        let x = Array(a.utf8), y = Array(b.utf8)
        guard x.count == y.count else { return false }
        var diff: UInt8 = 0
        for i in 0..<x.count { diff |= x[i] ^ y[i] }
        return diff == 0
    }

    /// 生の HTTP リクエストから最初の行のターゲットを取り出す（GET のみ）。
    public static func requestTarget(fromRawRequest raw: String) -> String? {
        guard let line = raw.split(separator: "\r\n", maxSplits: 1).first ?? raw.split(separator: "\n").first else { return nil }
        let p = line.split(separator: " ")
        guard p.count >= 3, p[0] == "GET", p[2].hasPrefix("HTTP/") else { return nil }
        return String(p[1])
    }
}

// MARK: - リフレッシュトークン保管

public protocol RefreshTokenStore: Sendable {
    func load() throws -> String?
    func save(_ token: String) throws
    func delete() throws
    /// データを読まずに存在だけ確認（プロンプトを出さない）。
    func exists() -> Bool
}

public enum KeychainError: Error, LocalizedError {
    case status(OSStatus, String)
    public var errorDescription: String? {
        switch self {
        case .status(let s, let op):
            let msg = (SecCopyErrorMessageString(s, nil) as String?) ?? ""
            return "Keychain \(op) 失敗 (\(s)) \(msg)"
        }
    }
}

/// Keychain（generic password）。
public struct KeychainTokenStore: RefreshTokenStore {
    public let service: String
    public let account: String

    public init(service: String = "dev.local.geoframe.uploader", account: String = "google-refresh-token") {
        self.service = service; self.account = account
    }

    private var baseQuery: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    public func load() throws -> String? {
        var q = baseQuery
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        let s = SecItemCopyMatching(q as CFDictionary, &out)
        if s == errSecItemNotFound { return nil }
        guard s == errSecSuccess, let d = out as? Data else { throw KeychainError.status(s, "読み取り") }
        return String(data: d, encoding: .utf8)
    }

    public func save(_ token: String) throws {
        let data = Data(token.utf8)
        let upd: [String: Any] = [kSecValueData as String: data,
                                  kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        let s = SecItemUpdate(baseQuery as CFDictionary, upd as CFDictionary)
        if s == errSecSuccess { return }
        guard s == errSecItemNotFound else { throw KeychainError.status(s, "更新") }
        var add = baseQuery
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        add[kSecAttrLabel as String] = "GeoFrame Uploader Google refresh token"
        let a = SecItemAdd(add as CFDictionary, nil)
        guard a == errSecSuccess else { throw KeychainError.status(a, "保存") }
    }

    public func delete() throws {
        let s = SecItemDelete(baseQuery as CFDictionary)
        guard s == errSecSuccess || s == errSecItemNotFound else { throw KeychainError.status(s, "削除") }
    }

    public func exists() -> Bool {
        var q = baseQuery
        q[kSecReturnAttributes as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        return SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess
    }
}

/// テスト用。
public final class InMemoryTokenStore: RefreshTokenStore, @unchecked Sendable {
    private let lock = NSLock()
    private var token: String?
    public init(token: String? = nil) { self.token = token }
    public func load() throws -> String? { lock.lock(); defer { lock.unlock() }; return token }
    public func save(_ t: String) throws { lock.lock(); token = t; lock.unlock() }
    public func delete() throws { lock.lock(); token = nil; lock.unlock() }
    public func exists() -> Bool { lock.lock(); defer { lock.unlock() }; return token != nil }
}
