import AppKit
import Foundation

/// Drive クライアントがアクセストークンを得るための抽象。
public protocol AccessTokenProvider: Sendable {
    func accessToken() async throws -> String
    /// 401 を受けた後に呼ぶ。強制的にリフレッシュして新しいトークンを返す。
    func refreshAfterUnauthorized() async throws -> String
}

public enum GoogleAuthError: Error, LocalizedError {
    case notSignedIn
    case noRefreshTokenReturned
    case tokenEndpoint(status: Int, message: String)
    case invalidResponse
    case reauthRequired(String)

    public var errorDescription: String? {
        switch self {
        case .notSignedIn: return "Google にサインインしていません（auth を実行してください）"
        case .noRefreshTokenReturned: return "Google からリフレッシュトークンが返りませんでした"
        case .tokenEndpoint(let s, let m): return "トークン取得に失敗しました（HTTP \(s)）: \(m)"
        case .invalidResponse: return "トークンエンドポイントの応答が不正です"
        case .reauthRequired(let m): return "再サインインが必要です: \(m)"
        }
    }
}

public struct SignInResult: Codable, Sendable {
    public let grantedScopes: [String]
}

/// インストール型アプリ向け OAuth（PKCE + ループバック）。
/// リフレッシュトークンは Keychain のみ、アクセストークンはメモリのみ。
public actor GoogleAuth: AccessTokenProvider {
    /// 要求スコープ（オーケストレーターが変更する場合はここだけ）。
    public static let scopes = ["https://www.googleapis.com/auth/drive"]
    public static let revokeURL = URL(string: "https://oauth2.googleapis.com/revoke")!

    private let client: OAuthClientConfig
    private let store: RefreshTokenStore
    private let session: URLSession
    private let now: @Sendable () -> Date

    private var accessTokenValue: String?
    private var accessTokenExpiry: Date = .distantPast
    private var refreshTask: Task<String, Error>?

    public init(client: OAuthClientConfig, store: RefreshTokenStore = KeychainTokenStore(),
                session: URLSession = .shared, now: @escaping @Sendable () -> Date = { Date() }) {
        self.client = client
        self.store = store
        self.session = session
        self.now = now
    }

    public nonisolated var hasRefreshToken: Bool { store.exists() }

    // MARK: サインイン

    /// ブラウザで認可し、コードをトークンに交換して refresh token を Keychain に保存する。
    public func signIn(timeout: TimeInterval = 300,
                       openURL: @escaping @Sendable (URL) -> Void = { url in
                           DispatchQueue.main.async { NSWorkspace.shared.open(url) }
                       }) async throws -> SignInResult {
        let verifier = PKCE.makeVerifier()
        let state = PKCE.randomState()
        let server = LoopbackServer(expectedState: state)
        let port = try await server.start()
        defer { server.stop() }
        let redirectURI = "http://127.0.0.1:\(port)"
        let url = OAuthURLBuilder.authorizationURL(client: client, redirectURI: redirectURI, scopes: Self.scopes,
                                                   codeChallenge: PKCE.challenge(for: verifier), state: state)
        openURL(url)
        let code = try await server.waitForCode(timeout: timeout)
        server.stop()

        let resp = try await tokenRequest([
            ("code", code),
            ("client_id", client.clientId),
            ("client_secret", client.clientSecret),
            ("code_verifier", verifier),
            ("redirect_uri", redirectURI),
            ("grant_type", "authorization_code"),
        ])
        guard let refresh = resp.refresh_token, !refresh.isEmpty else { throw GoogleAuthError.noRefreshTokenReturned }
        try store.save(refresh)
        apply(resp)
        let granted = resp.scope?.split(separator: " ").map(String.init) ?? []
        return SignInResult(grantedScopes: granted)
    }

    // MARK: AccessTokenProvider

    public func accessToken() async throws -> String {
        if let t = accessTokenValue, now() < accessTokenExpiry.addingTimeInterval(-60) { return t }
        return try await refresh()
    }

    public func refreshAfterUnauthorized() async throws -> String {
        accessTokenValue = nil
        accessTokenExpiry = .distantPast
        return try await refresh()
    }

    private func refresh() async throws -> String {
        if let t = refreshTask { return try await t.value }
        let task = Task { () throws -> String in
            guard let refresh = try self.store.load() else { throw GoogleAuthError.notSignedIn }
            let resp = try await self.tokenRequest([
                ("client_id", self.client.clientId),
                ("client_secret", self.client.clientSecret),
                ("refresh_token", refresh),
                ("grant_type", "refresh_token"),
            ])
            if let newRefresh = resp.refresh_token, !newRefresh.isEmpty, newRefresh != refresh {
                try self.store.save(newRefresh)
            }
            return self.apply(resp)
        }
        refreshTask = task
        defer { refreshTask = nil }
        return try await task.value
    }

    @discardableResult
    private func apply(_ r: TokenResponse) -> String {
        accessTokenValue = r.access_token
        accessTokenExpiry = now().addingTimeInterval(TimeInterval(r.expires_in ?? 3600))
        return r.access_token
    }

    // MARK: サインアウト

    /// Keychain から削除し、ベストエフォートで revoke する。
    public func signOut() async {
        accessTokenValue = nil
        accessTokenExpiry = .distantPast
        await Self.signOut(store: store, session: session)
    }

    public static func signOut(store: RefreshTokenStore = KeychainTokenStore(), session: URLSession = .shared) async {
        let token = try? store.load()
        try? store.delete()
        guard let token else { return }
        var req = URLRequest(url: revokeURL)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = Data(FormEncoding.encode([("token", token)]).utf8)
        req.timeoutInterval = 15
        _ = try? await session.data(for: req)
    }

    // MARK: HTTP

    struct TokenResponse: Decodable {
        let access_token: String
        let expires_in: Int?
        let refresh_token: String?
        let scope: String?
        let token_type: String?
    }

    struct TokenErrorResponse: Decodable {
        let error: String?
        let error_description: String?
    }

    private func tokenRequest(_ params: [(String, String)]) async throws -> TokenResponse {
        var req = URLRequest(url: client.tokenURI)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.httpBody = Data(FormEncoding.encode(params).utf8)
        req.timeoutInterval = 30
        let (data, resp) = try await session.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw GoogleAuthError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            let e = try? JSONDecoder().decode(TokenErrorResponse.self, from: data)
            let msg = Redactor.redact([e?.error, e?.error_description].compactMap { $0 }.joined(separator: ": "))
            if e?.error == "invalid_grant" { throw GoogleAuthError.reauthRequired(msg) }
            throw GoogleAuthError.tokenEndpoint(status: http.statusCode, message: msg)
        }
        do { return try JSONDecoder().decode(TokenResponse.self, from: data) } catch {
            throw GoogleAuthError.invalidResponse
        }
    }
}
