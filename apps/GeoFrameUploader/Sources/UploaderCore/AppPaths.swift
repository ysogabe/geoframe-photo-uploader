import Foundation

/// アプリの設定ファイル置き場。既定は `~/Library/Application Support/GeoFrameUploader/`。
/// テストでは任意のディレクトリを注入する。
public struct AppPaths: Sendable {
    public let baseDir: URL

    public init(baseDir: URL? = nil) {
        self.baseDir = baseDir ?? AppPaths.defaultBaseDir
    }

    public static var defaultBaseDir: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return support.appendingPathComponent("GeoFrameUploader", isDirectory: true)
    }

    /// Google Cloud Console からダウンロードした「デスクトップ アプリ」用 OAuth クライアント JSON。
    public var oauthClientFile: URL { baseDir.appendingPathComponent("oauth-client.json") }
    /// `{"folderId": "...", "folderName": "GeoFrame"}`
    public var configFile: URL { baseDir.appendingPathComponent("config.json") }
    /// 送信記録（JSON Lines、0600）
    public var recordsFile: URL { baseDir.appendingPathComponent("records.jsonl") }
    /// 写真ごとの MD5 と前回の結果（JSON、0600）。消すと次回 records.jsonl から作り直す
    public var itemCacheFile: URL { baseDir.appendingPathComponent("item-cache.json") }
    /// 写真ごとの pHash と品質指標（JSON、0600）。item-cache.json とは分離して保持
    public var qualityCacheFile: URL { baseDir.appendingPathComponent("quality-cache.json") }
    /// 逆ジオコーディングの地名キャッシュ（JSON、0600）
    public var placeCacheFile: URL { baseDir.appendingPathComponent("place-cache.json") }

    /// ベースディレクトリを 0700 で作成（既存なら権限を 0700 に揃える）。
    public func ensureBaseDir() throws {
        let fm = FileManager.default
        if !fm.fileExists(atPath: baseDir.path) {
            try fm.createDirectory(at: baseDir, withIntermediateDirectories: true,
                                   attributes: [.posixPermissions: 0o700])
        }
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: baseDir.path)
    }
}

// MARK: - OAuth クライアント設定

public enum ConfigError: Error, LocalizedError, Equatable {
    case oauthClientMissing(path: String)
    case oauthClientInvalid(String)
    case configInvalid(String)

    public var errorDescription: String? {
        switch self {
        case .oauthClientMissing(let p): return "OAuth クライアント JSON が見つかりません: \(p)"
        case .oauthClientInvalid(let m): return "OAuth クライアント JSON が不正です: \(m)"
        case .configInvalid(let m): return "config.json が不正です: \(m)"
        }
    }
}

/// `{"installed": {"client_id", "client_secret", "auth_uri", "token_uri", ...}}`
public struct OAuthClientConfig: Sendable, Equatable {
    public let clientId: String
    public let clientSecret: String
    public let authURI: URL
    public let tokenURI: URL

    public init(clientId: String, clientSecret: String,
                authURI: URL = URL(string: "https://accounts.google.com/o/oauth2/auth")!,
                tokenURI: URL = URL(string: "https://oauth2.googleapis.com/token")!) {
        self.clientId = clientId
        self.clientSecret = clientSecret
        self.authURI = authURI
        self.tokenURI = tokenURI
    }

    private struct File: Decodable {
        struct Installed: Decodable {
            let client_id: String?
            let client_secret: String?
            let auth_uri: String?
            let token_uri: String?
        }
        let installed: Installed?
    }

    public static func parse(_ data: Data) throws -> OAuthClientConfig {
        let file: File
        do { file = try JSONDecoder().decode(File.self, from: data) } catch {
            throw ConfigError.oauthClientInvalid("JSON として読めません")
        }
        guard let inst = file.installed else {
            throw ConfigError.oauthClientInvalid("\"installed\" キーがありません（デスクトップ アプリ用クライアントを使ってください）")
        }
        guard let id = inst.client_id, !id.isEmpty else { throw ConfigError.oauthClientInvalid("client_id がありません") }
        guard let secret = inst.client_secret, !secret.isEmpty else { throw ConfigError.oauthClientInvalid("client_secret がありません") }
        let auth = inst.auth_uri.flatMap(URL.init(string:)) ?? URL(string: "https://accounts.google.com/o/oauth2/auth")!
        let token = inst.token_uri.flatMap(URL.init(string:)) ?? URL(string: "https://oauth2.googleapis.com/token")!
        guard auth.scheme == "https", token.scheme == "https" else {
            throw ConfigError.oauthClientInvalid("auth_uri / token_uri は https である必要があります")
        }
        return OAuthClientConfig(clientId: id, clientSecret: secret, authURI: auth, tokenURI: token)
    }

    public static func load(from url: URL) throws -> OAuthClientConfig {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw ConfigError.oauthClientMissing(path: url.path)
        }
        return try parse(Data(contentsOf: url))
    }
}

// MARK: - config.json

public struct AppConfig: Codable, Sendable, Equatable {
    public var folderId: String?
    public var folderName: String

    public init(folderId: String? = nil, folderName: String = "GeoFrame") {
        self.folderId = folderId
        self.folderName = folderName
    }

    enum CodingKeys: String, CodingKey { case folderId, folderName }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        folderId = try c.decodeIfPresent(String.self, forKey: .folderId)
        if folderId?.isEmpty == true { folderId = nil }
        folderName = try c.decodeIfPresent(String.self, forKey: .folderName) ?? "GeoFrame"
    }

    /// ファイルが無ければ既定値。
    public static func load(from url: URL) throws -> AppConfig {
        guard FileManager.default.fileExists(atPath: url.path) else { return AppConfig() }
        do { return try JSONDecoder().decode(AppConfig.self, from: Data(contentsOf: url)) } catch {
            throw ConfigError.configInvalid(error.localizedDescription)
        }
    }

    public func save(to url: URL) throws {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try enc.encode(self)
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
