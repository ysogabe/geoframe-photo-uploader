import Foundation
import XCTest
@testable import UploaderCore

/// URLProtocol スタブ。テストは逐次実行（XCTest 既定）前提で静的ハンドラを差し替える。
final class StubProtocol: URLProtocol {
    struct Recorded {
        let request: URLRequest
        let body: Data
        var method: String { request.httpMethod ?? "GET" }
        var url: URL { request.url! }
        func header(_ n: String) -> String? { request.value(forHTTPHeaderField: n) }
        var query: [String: String] { FormEncoding.parseQuery(url.query ?? "") }
    }

    enum Reply {
        case http(Int, [String: String], Data)
        case failure(URLError.Code)
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var _handler: ((Recorded) -> Reply)?
    nonisolated(unsafe) private static var _recorded: [Recorded] = []

    static func setHandler(_ h: @escaping (Recorded) -> Reply) {
        lock.lock(); _handler = h; _recorded = []; lock.unlock()
    }

    static var recorded: [Recorded] { lock.lock(); defer { lock.unlock() }; return _recorded }

    static func session() -> URLSession {
        let c = URLSessionConfiguration.ephemeral
        c.protocolClasses = [StubProtocol.self]
        return URLSession(configuration: c)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let body = Self.readBody(request)
        let rec = Recorded(request: request, body: body)
        Self.lock.lock()
        Self._recorded.append(rec)
        let h = Self._handler
        Self.lock.unlock()
        let reply = h?(rec) ?? .http(500, [:], Data())
        switch reply {
        case .http(let status, let headers, let data):
            let resp = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
            client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        case .failure(let code):
            client?.urlProtocol(self, didFailWithError: URLError(code))
        }
    }

    override func stopLoading() {}

    static func readBody(_ r: URLRequest) -> Data {
        if let b = r.httpBody { return b }
        guard let s = r.httpBodyStream else { return Data() }
        s.open(); defer { s.close() }
        var out = Data()
        var buf = [UInt8](repeating: 0, count: 64 * 1024)
        while s.hasBytesAvailable {
            let n = s.read(&buf, maxLength: buf.count)
            if n <= 0 { break }
            out.append(buf, count: n)
        }
        return out
    }
}

final class FakeTokens: AccessTokenProvider, @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    private var refreshes = 0
    var refreshCount: Int { lock.withLock { refreshes } }
    private func current() -> String { lock.withLock { "tok\(n)" } }
    private func bump() -> String { lock.withLock { n += 1; refreshes += 1; return "tok\(n)" } }
    func accessToken() async throws -> String { current() }
    func refreshAfterUnauthorized() async throws -> String { bump() }
}

func json(_ o: Any) -> Data { try! JSONSerialization.data(withJSONObject: o) }

func makeTempDir() -> URL {
    let d = FileManager.default.temporaryDirectory.appendingPathComponent("UploaderCoreTests-\(UUID().uuidString)")
    try! FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    return d
}

func makeFile(bytes: Int, in dir: URL) -> (URL, Data) {
    var d = Data(count: bytes)
    for i in 0..<bytes { d[i] = UInt8(truncatingIfNeeded: i &* 31 &+ 7) }
    let u = dir.appendingPathComponent("f-\(UUID().uuidString).bin")
    try! d.write(to: u)
    return (u, d)
}

let noSleep: Sleeper = { _ in }
