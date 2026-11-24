import Foundation

public struct DriveFile: Codable, Sendable, Equatable {
    public var id: String
    public var name: String
    public var md5Checksum: String?
    public var size: String?
    public var mimeType: String?
    public var createdTime: String?

    public init(id: String, name: String, md5Checksum: String? = nil, size: String? = nil,
                mimeType: String? = nil, createdTime: String? = nil) {
        self.id = id; self.name = name; self.md5Checksum = md5Checksum
        self.size = size; self.mimeType = mimeType; self.createdTime = createdTime
    }
}

public enum DriveError: Error, LocalizedError, Equatable {
    case folderNotFound(name: String)
    case folderAmbiguous(name: String, ids: [String])
    case http(status: Int, message: String)
    case unauthorized
    case invalidResponse(String)
    case missingSessionURI
    case untrustedSessionURI
    case sessionRestartLimit
    case retriesExhausted(String)
    case md5Mismatch(fileId: String, expected: String, actual: String?)
    case fileIO(String)

    public var errorDescription: String? {
        switch self {
        case .folderNotFound(let n): return "マイドライブ直下にフォルダ「\(n)」が見つかりません"
        case .folderAmbiguous(let n, let ids): return "マイドライブ直下にフォルダ「\(n)」が \(ids.count) 個あります。config.json に folderId を指定してください（候補: \(ids.joined(separator: ", "))）"
        case .http(let s, let m): return "Drive API エラー（HTTP \(s)）: \(m)"
        case .unauthorized: return "Drive API の認証に失敗しました（再サインインが必要かもしれません）"
        case .invalidResponse(let m): return "Drive API の応答が不正です: \(m)"
        case .missingSessionURI: return "再開可能アップロードのセッション URI が返りませんでした"
        case .untrustedSessionURI: return "セッション URI が信頼できないホストを指しています（https://www.googleapis.com 以外は拒否します）"
        case .sessionRestartLimit: return "アップロードセッションの再作成回数の上限に達しました"
        case .retriesExhausted(let m): return "再試行の上限に達しました: \(m)"
        case .md5Mismatch(let id, let e, let a): return "アップロードは作成されましたが md5 が一致しません（fileId=\(id), 期待 \(e), Drive \(a ?? "なし")）"
        case .fileIO(let m): return "ファイル読み込みエラー: \(m)"
        }
    }
}

/// Google Drive v3 の最小クライアント。
public final class DriveClient: @unchecked Sendable {
    public static let filesURL = URL(string: "https://www.googleapis.com/drive/v3/files")!
    public static let uploadURL = URL(string: "https://www.googleapis.com/upload/drive/v3/files")!
    public static let listFields = "nextPageToken,files(id,name,md5Checksum,size,mimeType,createdTime)"
    public static let folderMimeType = "application/vnd.google-apps.folder"

    public struct Options: Sendable {
        /// チャンクサイズ（256 KiB の倍数）。既定 8 MiB（進捗はチャンクの途中でもバイト単位で通知する）。
        public var chunkSize: Int
        /// 1 チャンクあたりの最大試行回数。
        public var maxAttemptsPerChunk: Int
        /// セッション 404/410 時の最大再作成回数。
        public var maxSessionRestarts: Int
        public var baseBackoff: TimeInterval
        public var maxBackoff: TimeInterval

        public init(chunkSize: Int = 8 * 1024 * 1024, maxAttemptsPerChunk: Int = 6, maxSessionRestarts: Int = 2,
                    baseBackoff: TimeInterval = 1, maxBackoff: TimeInterval = 32) {
            precondition(chunkSize > 0 && chunkSize % (256 * 1024) == 0, "chunkSize must be a multiple of 256 KiB")
            self.chunkSize = chunkSize; self.maxAttemptsPerChunk = maxAttemptsPerChunk
            self.maxSessionRestarts = maxSessionRestarts; self.baseBackoff = baseBackoff; self.maxBackoff = maxBackoff
        }
    }

    private let session: URLSession
    private let tokens: AccessTokenProvider
    private let options: Options
    private let sleep: Sleeper
    private let log: @Sendable (String) -> Void

    public init(session: URLSession = .shared, tokens: AccessTokenProvider, options: Options = Options(),
                sleeper: @escaping Sleeper = defaultSleeper, log: @escaping @Sendable (String) -> Void = { _ in }) {
        self.session = session
        self.tokens = tokens
        self.options = options
        self.sleep = sleeper
        self.log = log
    }

    // MARK: クエリ

    /// Drive クエリの文字列リテラル用エスケープ（`\` と `'`）。
    public static func escapeQueryLiteral(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'")
    }

    public static func folderQuery(name: String) -> String {
        "name = '\(escapeQueryLiteral(name))' and mimeType = '\(folderMimeType)' and 'root' in parents and trashed = false"
    }

    public static func childrenQuery(folderId: String) -> String {
        "'\(escapeQueryLiteral(folderId))' in parents and trashed = false"
    }

    public static func childrenByNameQuery(folderId: String, name: String) -> String {
        "'\(escapeQueryLiteral(folderId))' in parents and name = '\(escapeQueryLiteral(name))' and trashed = false"
    }

    static func listURL(query: String, pageToken: String?) -> URL {
        var params: [(String, String)] = [
            ("q", query),
            ("fields", listFields),
            ("pageSize", "1000"),
            ("spaces", "drive"),
        ]
        if let pageToken { params.append(("pageToken", pageToken)) }
        var c = URLComponents(url: filesURL, resolvingAgainstBaseURL: false)!
        c.percentEncodedQuery = FormEncoding.encode(params)
        return c.url!
    }

    // MARK: 一覧

    private struct ListResponse: Decodable {
        let nextPageToken: String?
        let files: [DriveFile]?
    }

    public func listFiles(query: String) async throws -> [DriveFile] {
        var all: [DriveFile] = []
        var token: String?
        var pages = 0
        repeat {
            var req = URLRequest(url: Self.listURL(query: query, pageToken: token))
            req.httpMethod = "GET"
            req.timeoutInterval = 60
            let (data, http) = try await sendWithRetry(req)
            guard http.statusCode == 200 else { throw Self.httpError(http.statusCode, data) }
            let page: ListResponse
            do { page = try JSONDecoder().decode(ListResponse.self, from: data) } catch {
                throw DriveError.invalidResponse("files.list")
            }
            all.append(contentsOf: page.files ?? [])
            token = (page.nextPageToken?.isEmpty == false) ? page.nextPageToken : nil
            pages += 1
            if pages > 10_000 { throw DriveError.invalidResponse("pagination did not terminate") }
        } while token != nil
        return all
    }

    /// マイドライブ直下の指定名フォルダ。0 件・複数件はエラー（推測しない）。
    public func resolveFolder(name: String) async throws -> String {
        let found = try await listFiles(query: Self.folderQuery(name: name))
        switch found.count {
        case 1: return found[0].id
        case 0: throw DriveError.folderNotFound(name: name)
        default: throw DriveError.folderAmbiguous(name: name, ids: found.map(\.id))
        }
    }

    public func listFolderFiles(folderId: String) async throws -> [DriveFile] {
        try await listFiles(query: Self.childrenQuery(folderId: folderId))
    }

    public func findFiles(named name: String, inFolder folderId: String) async throws -> [DriveFile] {
        try await listFiles(query: Self.childrenByNameQuery(folderId: folderId, name: name))
    }

    // MARK: 再開可能アップロード

    public typealias Progress = @Sendable (_ sent: Int64, _ total: Int64) -> Void

    /// 常に新規ファイルを作成する（既存ファイルの上書き・更新はしない）。
    /// `expectedMD5` を渡すと、完了レスポンスの md5Checksum と照合し不一致なら `.md5Mismatch` を投げる。
    public func uploadResumable(fileURL: URL, name: String, mimeType: String, folderId: String, byteCount: Int64,
                                expectedMD5: String? = nil, properties: [String: String]? = nil,
                                progress: Progress? = nil) async throws -> DriveFile {
        let fh: FileHandle
        do { fh = try FileHandle(forReadingFrom: fileURL) } catch { throw DriveError.fileIO(error.localizedDescription) }
        defer { try? fh.close() }

        var restarts = 0
        var file: DriveFile?
        while file == nil {
            try Task.checkCancellation()
            let sessionURI = try await startSession(name: name, mimeType: mimeType, folderId: folderId,
                                                    byteCount: byteCount, properties: properties)
            do {
                file = try await runSession(sessionURI, fh: fh, total: byteCount, progress: progress)
            } catch SessionOutcome.gone {
                restarts += 1
                if restarts > options.maxSessionRestarts { throw DriveError.sessionRestartLimit }
                log("upload session expired; restarting from 0 (restart \(restarts))")
            }
        }
        let f = file!
        if let expected = expectedMD5, f.md5Checksum?.lowercased() != expected.lowercased() {
            throw DriveError.md5Mismatch(fileId: f.id, expected: expected, actual: f.md5Checksum)
        }
        return f
    }

    private enum SessionOutcome: Error { case gone }

    private func startSession(name: String, mimeType: String, folderId: String, byteCount: Int64,
                              properties: [String: String]?) async throws -> URL {
        var c = URLComponents(url: Self.uploadURL, resolvingAgainstBaseURL: false)!
        c.percentEncodedQuery = FormEncoding.encode([("uploadType", "resumable"), ("fields", "id,name,md5Checksum,size")])
        var req = URLRequest(url: c.url!)
        req.httpMethod = "POST"
        req.timeoutInterval = 60
        req.setValue("application/json; charset=UTF-8", forHTTPHeaderField: "Content-Type")
        req.setValue(mimeType, forHTTPHeaderField: "X-Upload-Content-Type")
        req.setValue(String(byteCount), forHTTPHeaderField: "X-Upload-Content-Length")
        var meta: [String: Any] = ["name": name, "parents": [folderId], "mimeType": mimeType]
        if let properties, !properties.isEmpty {
            meta["properties"] = properties
        }
        req.httpBody = try JSONSerialization.data(withJSONObject: meta, options: [.sortedKeys])
        let (data, http) = try await sendWithRetry(req)
        guard http.statusCode == 200 else { throw Self.httpError(http.statusCode, data) }
        guard let loc = http.header("Location"), let url = URL(string: loc) else { throw DriveError.missingSessionURI }
        guard url.scheme == "https", url.host?.lowercased() == "www.googleapis.com" else { throw DriveError.untrustedSessionURI }
        return url
    }

    /// `Range: bytes=0-N` → 次のオフセット N+1。無ければ 0。
    public static func nextOffset(fromRangeHeader h: String?) -> Int64 {
        guard let h, let dash = h.lastIndex(of: "-"), let last = Int64(h[h.index(after: dash)...].trimmingCharacters(in: .whitespaces)) else { return 0 }
        return last + 1
    }

    private enum ChunkResult {
        case done(DriveFile)
        case advanced(Int64)
    }

    private func runSession(_ uri: URL, fh: FileHandle, total: Int64, progress: Progress?) async throws -> DriveFile {
        var offset: Int64 = 0
        var attempts = 0
        var lastError = ""
        // セッションごとに作り直す（再作成時だけ 0 に戻る。古いセッションの遅れた通知は新しい方に届かない）
        let gate = ProgressGate(total: total, progress: progress)
        gate.start()
        while true {
            try Task.checkCancellation()
            let len = Int(min(Int64(options.chunkSize), max(0, total - offset)))
            let outcome: Result<ChunkResult, Error>
            let chunkStart = offset
            do {
                outcome = .success(try await putChunk(uri, fh: fh, offset: offset, length: len, total: total,
                                                      onSent: { sent in gate.report(chunkStart + min(sent, Int64(len))) }))
            } catch let e as TransientError {
                outcome = .failure(e)
            }
            switch outcome {
            case .success(.done(let f)):
                gate.report(total)
                return f
            case .success(.advanced(let next)):
                if next > offset {
                    attempts = 0
                } else {
                    // 進捗しない 308 が続く場合の無限ループ防止
                    attempts += 1
                    if attempts >= options.maxAttemptsPerChunk { throw DriveError.retriesExhausted("no progress at offset \(offset)") }
                }
                offset = min(next, total)
                gate.report(offset)
                continue
            case .failure(let e):
                lastError = "\(e)"
            }
            // 一時的エラー: バックオフしつつステータス照会（bytes */total）でオフセットを再同期
            resync: while true {
                attempts += 1
                if attempts >= options.maxAttemptsPerChunk { throw DriveError.retriesExhausted(lastError) }
                try await sleep(backoff(attempts))
                do {
                    switch try await queryStatus(uri, total: total) {
                    case .done(let f):
                        // 照会で完了が判明した場合は再送しない（重複ファイル作成を避ける）
                        gate.report(total)
                        return f
                    case .advanced(let next):
                        // サーバーが受け取れていなかった分は送り直す（表示は戻さない）
                        offset = min(next, total)
                        gate.report(offset)
                    }
                    break resync
                } catch let e as TransientError {
                    lastError = "\(e)"
                }
            }
        }
    }

    private struct TransientError: Error, CustomStringConvertible {
        let description: String
    }

    func backoff(_ attempt: Int) -> TimeInterval {
        let exp = min(options.maxBackoff, options.baseBackoff * pow(2, Double(max(0, attempt - 1))))
        return exp * Double.random(in: 0.5...1.0)
    }

    private func putChunk(_ uri: URL, fh: FileHandle, offset: Int64, length: Int, total: Int64,
                          onSent: @escaping @Sendable (Int64) -> Void) async throws -> ChunkResult {
        let data: Data
        do {
            try fh.seek(toOffset: UInt64(offset))
            data = try fh.read(upToCount: length) ?? Data()
        } catch { throw DriveError.fileIO(error.localizedDescription) }
        guard data.count == length else { throw DriveError.fileIO("short read at \(offset)") }
        var req = URLRequest(url: uri)
        req.httpMethod = "PUT"
        req.timeoutInterval = 300
        if length > 0 {
            req.setValue("bytes \(offset)-\(offset + Int64(length) - 1)/\(total)", forHTTPHeaderField: "Content-Range")
        } else {
            req.setValue("bytes */\(total)", forHTTPHeaderField: "Content-Range")
        }
        req.setValue(String(length), forHTTPHeaderField: "Content-Length")
        guard length > 0 else {
            req.httpBody = Data()
            return try await interpretSessionResponse(req)
        }
        // 本文は upload タスクで送り、送信済みバイト数をチャンクの途中でも通知する
        return try await interpretSessionResponse(req, upload: UploadBody(data: data, onSent: onSent))
    }

    private func queryStatus(_ uri: URL, total: Int64) async throws -> ChunkResult {
        var req = URLRequest(url: uri)
        req.httpMethod = "PUT"
        req.timeoutInterval = 60
        req.setValue("bytes */\(total)", forHTTPHeaderField: "Content-Range")
        req.setValue("0", forHTTPHeaderField: "Content-Length")
        req.httpBody = Data()
        return try await interpretSessionResponse(req)
    }

    private func interpretSessionResponse(_ req: URLRequest, upload: UploadBody? = nil) async throws -> ChunkResult {
        let data: Data, http: HTTPURLResponse
        do {
            (data, http) = try await sendAuthorized(req, upload: upload)
        } catch let e as URLError where e.code != .cancelled {
            throw TransientError(description: "network: \(e.code.rawValue)")
        }
        switch http.statusCode {
        case 200, 201:
            do { return .done(try JSONDecoder().decode(DriveFile.self, from: data)) } catch {
                throw DriveError.invalidResponse("upload completion body")
            }
        case 308:
            return .advanced(Self.nextOffset(fromRangeHeader: http.header("Range")))
        case 404, 410:
            throw SessionOutcome.gone
        case 429, 500...599:
            throw TransientError(description: "HTTP \(http.statusCode)")
        default:
            throw Self.httpError(http.statusCode, data)
        }
    }

    // MARK: 送信共通

    /// Authorization を付けて送信。401 なら 1 回だけリフレッシュして再送。
    private func sendAuthorized(_ request: URLRequest, upload: UploadBody? = nil) async throws -> (Data, HTTPURLResponse) {
        var req = request
        req.setValue("Bearer \(try await tokens.accessToken())", forHTTPHeaderField: "Authorization")
        var (data, http) = try await perform(req, upload: upload)
        if http.statusCode == 401 {
            log("401 from Drive; refreshing access token once")
            req.setValue("Bearer \(try await tokens.refreshAfterUnauthorized())", forHTTPHeaderField: "Authorization")
            (data, http) = try await perform(req, upload: upload)
            if http.statusCode == 401 { throw DriveError.unauthorized }
        }
        return (data, http)
    }

    /// upload タスクで送る本文と、送信済みバイト数（この本文の中での位置）の通知先。
    struct UploadBody: Sendable {
        let data: Data
        let onSent: @Sendable (Int64) -> Void
    }

    private func perform(_ req: URLRequest, upload: UploadBody? = nil) async throws -> (Data, HTTPURLResponse) {
        let data: Data, resp: URLResponse
        if let upload {
            var r = req
            r.httpBody = nil   // 本文は from: で渡す（両方あると upload タスクは失敗する）
            (data, resp) = try await session.upload(for: r, from: upload.data,
                                                    delegate: UploadProgressDelegate(onSent: upload.onSent))
        } else {
            (data, resp) = try await session.data(for: req)
        }
        guard let http = resp as? HTTPURLResponse else { throw DriveError.invalidResponse("non-HTTP response") }
        return (data, http)
    }

    /// 冪等なリクエスト（一覧、セッション開始）用: ネットワークエラー / 5xx / 429 をバックオフ再試行。
    private func sendWithRetry(_ req: URLRequest) async throws -> (Data, HTTPURLResponse) {
        var attempt = 0
        while true {
            attempt += 1
            do {
                let (data, http) = try await sendAuthorized(req)
                if (http.statusCode == 429 || (500...599).contains(http.statusCode)) && attempt < options.maxAttemptsPerChunk {
                    try await sleep(backoff(attempt))
                    continue
                }
                return (data, http)
            } catch let e as URLError where e.code != .cancelled && attempt < options.maxAttemptsPerChunk {
                log("network error \(e.code.rawValue); retrying")
                try await sleep(backoff(attempt))
            }
        }
    }

    static func httpError(_ status: Int, _ data: Data) -> DriveError {
        struct Body: Decodable { struct E: Decodable { let message: String? }; let error: E? }
        let msg = (try? JSONDecoder().decode(Body.self, from: data))?.error?.message
            ?? String(decoding: data.prefix(500), as: UTF8.self)
        if status == 401 { return .unauthorized }
        return .http(status: status, message: Redactor.redact(msg))
    }
}

/// 1 回のアップロードセッションの進捗通知。値は戻さない（再同期でサーバーの位置が手前でも表示は据え置く）。
final class ProgressGate: @unchecked Sendable {
    private let lock = NSLock()
    private let total: Int64
    private let progress: DriveClient.Progress?
    private var high: Int64 = -1

    init(total: Int64, progress: DriveClient.Progress?) { self.total = total; self.progress = progress }

    /// セッション開始（0 を通知する）。
    func start() {
        lock.withLock {
            high = 0
            progress?(0, total)
        }
    }

    /// `sent`（0...total に丸める）が今までの最大を超えたときだけ通知する。
    /// 通知もロック内で行う（別スレッドからの通知が前後して値が戻って見えないように）。
    func report(_ sent: Int64) {
        let v = max(0, min(sent, total))
        lock.withLock {
            guard v > high else { return }
            high = v
            progress?(v, total)
        }
    }

    var reported: Int64 { lock.withLock { max(0, high) } }
}

/// チャンクの PUT 1 回分のタスクデリゲート。送信済みバイト数（本文の中での位置）を通知する。
/// URLProtocol のスタブなど、通知が来ない経路ではチャンク単位の通知だけになる。
final class UploadProgressDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let onSent: @Sendable (Int64) -> Void

    init(onSent: @escaping @Sendable (Int64) -> Void) { self.onSent = onSent }

    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64,
                    totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        onSent(max(0, totalBytesSent))
    }
}
