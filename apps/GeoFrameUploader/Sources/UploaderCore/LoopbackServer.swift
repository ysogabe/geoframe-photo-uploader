import Foundation
import Network

public enum LoopbackError: Error, LocalizedError {
    case listenerFailed(String)
    case timeout
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .listenerFailed(let m): return "ローカル受信サーバーを開始できません: \(m)"
        case .timeout: return "ブラウザでの認可が時間内に完了しませんでした"
        case .cancelled: return "認可がキャンセルされました"
        }
    }
}

/// 127.0.0.1 のみで待ち受け、正しい state を持つコールバックを 1 回だけ受け付ける。
final class LoopbackServer: @unchecked Sendable {
    private let queue = DispatchQueue(label: "dev.local.geoframe.uploader.loopback")
    private let lock = NSLock()
    private var listener: NWListener?
    private var continuation: CheckedContinuation<String, Error>?
    private var pendingResult: Result<String, Error>?
    private var done = false
    private let expectedState: String

    init(expectedState: String) { self.expectedState = expectedState }

    /// 待ち受け開始。割り当てられたポートを返す。
    func start() async throws -> UInt16 {
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: NWEndpoint.Host("127.0.0.1"), port: .any)
        params.allowLocalEndpointReuse = false
        let l: NWListener
        do { l = try NWListener(using: params) } catch { throw LoopbackError.listenerFailed("\(error)") }
        setListener(l)
        l.newConnectionHandler = { [weak self] conn in self?.handle(conn) }
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<UInt16, Error>) in
            let once = OnceFlag()
            l.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    if once.fire() {
                        if let p = l.port?.rawValue { cont.resume(returning: p) } else {
                            cont.resume(throwing: LoopbackError.listenerFailed("port unavailable"))
                        }
                    }
                case .failed(let e):
                    if once.fire() { cont.resume(throwing: LoopbackError.listenerFailed("\(e)")) }
                    self?.finish(.failure(LoopbackError.listenerFailed("\(e)")))
                case .cancelled:
                    if once.fire() { cont.resume(throwing: LoopbackError.cancelled) }
                default: break
                }
            }
            l.start(queue: queue)
        }
    }

    /// 有効なコールバックの認可コードを待つ。
    func waitForCode(timeout: TimeInterval) async throws -> String {
        queue.asyncAfter(deadline: .now() + timeout) { [weak self] in self?.finish(.failure(LoopbackError.timeout)) }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<String, Error>) in
                lock.lock()
                if let r = pendingResult {
                    lock.unlock()
                    cont.resume(with: r)
                    return
                }
                continuation = cont
                lock.unlock()
            }
        } onCancel: { [weak self] in
            self?.finish(.failure(LoopbackError.cancelled))
        }
    }

    private func setListener(_ l: NWListener) {
        lock.lock(); listener = l; lock.unlock()
    }

    func stop() {
        lock.lock(); let l = listener; listener = nil; lock.unlock()
        l?.cancel()
    }

    private func finish(_ r: Result<String, Error>) {
        lock.lock()
        if done { lock.unlock(); return }
        done = true
        let c = continuation
        continuation = nil
        if c == nil { pendingResult = r }
        let l = listener
        listener = nil
        lock.unlock()
        l?.cancel()
        c?.resume(with: r)
    }

    private func handle(_ conn: NWConnection) {
        conn.start(queue: queue)
        receive(conn, buffer: Data())
    }

    private func receive(_ conn: NWConnection, buffer: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { conn.cancel(); return }
            var buf = buffer
            if let data { buf.append(data) }
            let headerEnd = buf.range(of: Data("\r\n\r\n".utf8))
            if headerEnd == nil && !isComplete && error == nil && buf.count < 16 * 1024 {
                self.receive(conn, buffer: buf)
                return
            }
            let raw = String(decoding: buf, as: UTF8.self)
            self.respond(conn, raw: raw)
        }
    }

    private func respond(_ conn: NWConnection, raw: String) {
        lock.lock(); let alreadyDone = done; lock.unlock()
        guard let target = OAuthCallback.requestTarget(fromRawRequest: raw) else {
            send(conn, status: "400 Bad Request", body: Self.page(title: "不正なリクエスト", message: ""))
            return
        }
        if alreadyDone {
            send(conn, status: "410 Gone", body: Self.page(title: "処理済み", message: "この認可リクエストは既に処理されました。このタブを閉じてください。"))
            return
        }
        switch OAuthCallback.parse(requestTarget: target, expectedState: expectedState) {
        case .success(let code):
            send(conn, status: "200 OK", body: Self.page(title: "認可が完了しました",
                                                          message: "GeoFrame Uploader に戻ってください。このタブは閉じて構いません。"))
            finish(.success(code))
        case .failure(.notCallback):
            send(conn, status: "404 Not Found", body: Self.page(title: "Not Found", message: ""))
        case .failure(.stateMismatch):
            // 不正なリクエストは無視して待機を続ける
            send(conn, status: "400 Bad Request", body: Self.page(title: "認可に失敗しました", message: "state が一致しません。"))
        case .failure(let e):
            send(conn, status: "400 Bad Request", body: Self.page(title: "認可に失敗しました",
                                                                   message: "アプリに戻ってやり直してください。"))
            finish(.failure(e))
        }
    }

    private func send(_ conn: NWConnection, status: String, body: String) {
        let bodyData = Data(body.utf8)
        let head = "HTTP/1.1 \(status)\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(bodyData.count)\r\nConnection: close\r\nCache-Control: no-store\r\nReferrer-Policy: no-referrer\r\n\r\n"
        var data = Data(head.utf8)
        data.append(bodyData)
        conn.send(content: data, completion: .contentProcessed { _ in conn.cancel() })
    }

    static func page(title: String, message: String) -> String {
        """
        <!doctype html><html lang="ja"><head><meta charset="utf-8"><title>GeoFrame Uploader</title>
        <style>body{font-family:-apple-system,sans-serif;margin:3em;color:#222}</style></head>
        <body><h1>\(title)</h1><p>\(message)</p></body></html>
        """
    }
}
