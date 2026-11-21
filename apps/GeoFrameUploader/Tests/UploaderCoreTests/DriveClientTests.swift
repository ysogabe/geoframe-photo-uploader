import CryptoKit
import XCTest
@testable import UploaderCore

final class DriveQueryTests: XCTestCase {
    func testEscaping() {
        XCTAssertEqual(DriveClient.escapeQueryLiteral(#"it's a \ test"#), #"it\'s a \\ test"#)
        XCTAssertEqual(DriveClient.folderQuery(name: "GeoFrame"),
                       "name = 'GeoFrame' and mimeType = 'application/vnd.google-apps.folder' and 'root' in parents and trashed = false")
        XCTAssertEqual(DriveClient.childrenByNameQuery(folderId: "F", name: "O'Neil.jpg"),
                       #"'F' in parents and name = 'O\'Neil.jpg' and trashed = false"#)
    }

    func testListURLEncodesPlusAndQuotes() {
        let u = DriveClient.listURL(query: "name = 'a+b c'", pageToken: "T+1")
        let q = u.query(percentEncoded: true)!
        XCTAssertTrue(q.contains("a%2Bb%20c"), q)
        XCTAssertTrue(q.contains("pageToken=T%2B1"), q)
        let parsed = FormEncoding.parseQuery(q)
        XCTAssertEqual(parsed["q"], "name = 'a+b c'")
        XCTAssertEqual(parsed["pageSize"], "1000")
        XCTAssertEqual(parsed["spaces"], "drive")
        XCTAssertEqual(parsed["fields"], DriveClient.listFields)
    }

    func testPagination() async throws {
        StubProtocol.setHandler { r in
            XCTAssertEqual(r.header("Authorization"), "Bearer tok0")
            switch r.query["pageToken"] {
            case nil: return .http(200, [:], json(["nextPageToken": "p2", "files": [["id": "1", "name": "a", "md5Checksum": "m1"]]]))
            case "p2": return .http(200, [:], json(["nextPageToken": "p3", "files": [["id": "2", "name": "b"]]]))
            default: return .http(200, [:], json(["files": [["id": "3", "name": "c", "md5Checksum": "m3"]]]))
            }
        }
        let drive = DriveClient(session: StubProtocol.session(), tokens: FakeTokens(), sleeper: noSleep)
        let files = try await drive.listFolderFiles(folderId: "FOLDER")
        XCTAssertEqual(files.map(\.id), ["1", "2", "3"])
        XCTAssertEqual(StubProtocol.recorded.count, 3)
        XCTAssertEqual(StubProtocol.recorded[0].query["q"], "'FOLDER' in parents and trashed = false")
    }

    func testResolveFolderCounts() async throws {
        let drive = DriveClient(session: StubProtocol.session(), tokens: FakeTokens(), sleeper: noSleep)
        StubProtocol.setHandler { _ in .http(200, [:], json(["files": [["id": "G1", "name": "GeoFrame"]]])) }
        let id = try await drive.resolveFolder(name: "GeoFrame")
        XCTAssertEqual(id, "G1")
        StubProtocol.setHandler { _ in .http(200, [:], json(["files": []])) }
        do { _ = try await drive.resolveFolder(name: "GeoFrame"); XCTFail() } catch let e as DriveError {
            XCTAssertEqual(e, .folderNotFound(name: "GeoFrame"))
        }
        StubProtocol.setHandler { _ in .http(200, [:], json(["files": [["id": "A", "name": "GeoFrame"], ["id": "B", "name": "GeoFrame"]]])) }
        do { _ = try await drive.resolveFolder(name: "GeoFrame"); XCTFail() } catch let e as DriveError {
            XCTAssertEqual(e, .folderAmbiguous(name: "GeoFrame", ids: ["A", "B"]))
        }
    }

    func testListRetriesOn503AndRefreshesOn401() async throws {
        var calls = 0
        StubProtocol.setHandler { r in
            calls += 1
            switch calls {
            case 1: return .http(503, [:], Data())
            case 2: return .http(401, [:], Data())
            default:
                XCTAssertEqual(r.header("Authorization"), "Bearer tok1")
                return .http(200, [:], json(["files": []]))
            }
        }
        let tokens = FakeTokens()
        let drive = DriveClient(session: StubProtocol.session(), tokens: tokens, sleeper: noSleep)
        _ = try await drive.listFolderFiles(folderId: "F")
        XCTAssertEqual(tokens.refreshCount, 1)
        XCTAssertEqual(calls, 3)
    }
}

/// 再開可能アップロードの疑似サーバー。受け取ったバイトを保持し、Content-Range を検証する。
final class FakeResumableServer: @unchecked Sendable {
    let total: Int
    var received = Data()
    var sessions = 0
    var contentRanges: [String] = []
    var chunkSizes: [Int] = []
    var md5Override: String?
    /// 各 PUT の前に呼ばれる。nil 以外を返すとその応答で割り込む（Content-Range, 現在の受信数）。
    var intercept: ((String, Int) -> StubProtocol.Reply?)?
    /// 受理するバイト数を制限（部分受理の 308 を再現）
    var acceptLimit: ((Int) -> Int)?

    init(total: Int) { self.total = total }

    func handle(_ r: StubProtocol.Recorded) -> StubProtocol.Reply {
        if r.method == "POST" {
            XCTAssertEqual(r.query["uploadType"], "resumable")
            XCTAssertEqual(r.header("X-Upload-Content-Length"), String(total))
            XCTAssertEqual(r.header("X-Upload-Content-Type"), "image/heic")
            let meta = try! JSONSerialization.jsonObject(with: r.body) as! [String: Any]
            XCTAssertEqual(meta["name"] as? String, "IMG_1.HEIC")
            XCTAssertEqual(meta["parents"] as? [String], ["FOLDER"])
            sessions += 1
            received = Data()
            return .http(200, ["Location": "https://www.googleapis.com/upload/session\(sessions)?upload_id=X\(sessions)"], Data())
        }
        let cr = r.header("Content-Range") ?? ""
        contentRanges.append(cr)
        if let i = intercept, let reply = i(cr, received.count) { return reply }
        if cr == "bytes */\(total)" {
            return statusReply()
        }
        // bytes a-b/total
        let spec = cr.replacingOccurrences(of: "bytes ", with: "").split(separator: "/")[0].split(separator: "-")
        let a = Int(spec[0])!, b = Int(spec[1])!
        XCTAssertEqual(a, received.count, "chunk must start at server offset")
        XCTAssertEqual(r.body.count, b - a + 1)
        chunkSizes.append(r.body.count)
        let accept = acceptLimit?(r.body.count) ?? r.body.count
        received.append(r.body.prefix(accept))
        return statusReply()
    }

    func statusReply() -> StubProtocol.Reply {
        if received.count == total {
            let md5 = md5Override ?? Insecure.MD5.hash(data: received).map { String(format: "%02x", $0) }.joined()
            return .http(200, [:], json(["id": "NEWID", "name": "IMG_1.HEIC", "md5Checksum": md5, "size": String(total)]))
        }
        let headers = received.isEmpty ? [:] : ["Range": "bytes=0-\(received.count - 1)"]
        return .http(308, headers, Data())
    }
}

final class ResumableUploadTests: XCTestCase {
    let chunk = 256 * 1024
    var dir: URL!

    override func setUp() { dir = makeTempDir() }
    override func tearDown() { try? FileManager.default.removeItem(at: dir) }

    func makeDrive(_ tokens: FakeTokens = FakeTokens()) -> DriveClient {
        DriveClient(session: StubProtocol.session(), tokens: tokens,
                    options: .init(chunkSize: chunk, maxAttemptsPerChunk: 6, maxSessionRestarts: 2), sleeper: noSleep)
    }

    func md5(_ d: Data) -> String { Insecure.MD5.hash(data: d).map { String(format: "%02x", $0) }.joined() }

    func upload(_ drive: DriveClient, _ url: URL, _ n: Int, expected: String?) async throws -> DriveFile {
        try await drive.uploadResumable(fileURL: url, name: "IMG_1.HEIC", mimeType: "image/heic", folderId: "FOLDER",
                                        byteCount: Int64(n), expectedMD5: expected)
    }

    func testHappyPathMultiChunk() async throws {
        let n = chunk * 2 + 1000
        let (url, data) = makeFile(bytes: n, in: dir)
        let server = FakeResumableServer(total: n)
        StubProtocol.setHandler(server.handle)
        let progress = ProgressBox()
        let f = try await makeDrive().uploadResumable(fileURL: url, name: "IMG_1.HEIC", mimeType: "image/heic", folderId: "FOLDER",
                                                      byteCount: Int64(n), expectedMD5: md5(data),
                                                      progress: { s, t in progress.add(s, t) })
        XCTAssertEqual(f.id, "NEWID")
        XCTAssertEqual(server.received, data)
        XCTAssertEqual(server.contentRanges, [
            "bytes 0-\(chunk - 1)/\(n)",
            "bytes \(chunk)-\(2 * chunk - 1)/\(n)",
            "bytes \(2 * chunk)-\(n - 1)/\(n)",
        ])
        XCTAssertEqual(server.chunkSizes, [chunk, chunk, 1000])
        for s in server.chunkSizes.dropLast() { XCTAssertEqual(s % (256 * 1024), 0) }
        XCTAssertEqual(progress.last?.0, Int64(n))
        // セッション URI への PUT 以外の URL は upload エンドポイント
        let post = StubProtocol.recorded.first { $0.method == "POST" }!
        XCTAssertEqual(post.url.host, "www.googleapis.com")
        XCTAssertEqual(post.url.path, "/upload/drive/v3/files")
        XCTAssertEqual(post.query["fields"], "id,name,md5Checksum,size")
    }

    func testUntrustedSessionURIRejectedAndNoPUT() async throws {
        let n = chunk
        let (url, _) = makeFile(bytes: n, in: dir)
        StubProtocol.setHandler { r in
            .http(200, ["Location": "https://evil.example.com/upload?upload_id=X"], Data())
        }
        do {
            _ = try await upload(makeDrive(), url, n, expected: nil)
            XCTFail("expected throw")
        } catch let e as DriveError {
            XCTAssertEqual(e, .untrustedSessionURI)
        }
        XCTAssertTrue(StubProtocol.recorded.allSatisfy { $0.method != "PUT" })
    }

    func test308PartialRangeResumes() async throws {
        let n = chunk * 2
        let (url, data) = makeFile(bytes: n, in: dir)
        let server = FakeResumableServer(total: n)
        var first = true
        server.acceptLimit = { count in
            if first { first = false; return count / 2 }   // 1 回目は半分だけ受理
            return count
        }
        StubProtocol.setHandler(server.handle)
        let f = try await upload(makeDrive(), url, n, expected: md5(data))
        XCTAssertEqual(f.id, "NEWID")
        XCTAssertEqual(server.received, data)
        XCTAssertEqual(server.contentRanges[1], "bytes \(chunk / 2)-\(chunk / 2 + chunk - 1)/\(n)")
    }

    func testTransient503ThenStatusQueryThenResume() async throws {
        let n = chunk * 2 + 10
        let (url, data) = makeFile(bytes: n, in: dir)
        let server = FakeResumableServer(total: n)
        var failed = false
        server.intercept = { cr, received in
            // 2 チャンク目で 1 回だけ 503（サーバーは受理しない）
            if !failed && cr.hasPrefix("bytes \(self.chunk)-") { failed = true; return .http(503, [:], Data()) }
            return nil
        }
        StubProtocol.setHandler(server.handle)
        let f = try await upload(makeDrive(), url, n, expected: md5(data))
        XCTAssertEqual(f.id, "NEWID")
        XCTAssertEqual(server.received, data)
        XCTAssertEqual(server.contentRanges, [
            "bytes 0-\(chunk - 1)/\(n)",
            "bytes \(chunk)-\(2 * chunk - 1)/\(n)",   // 503
            "bytes */\(n)",                            // ステータス照会
            "bytes \(chunk)-\(2 * chunk - 1)/\(n)",   // 再送
            "bytes \(2 * chunk)-\(n - 1)/\(n)",
        ])
    }

    func testNetworkErrorThenStatusQueryReportsComplete() async throws {
        // 最終チャンクは実際には届いたが応答が失われた → 照会で 200 を得たら再送しない
        let n = chunk + 10
        let (url, data) = makeFile(bytes: n, in: dir)
        let server = FakeResumableServer(total: n)
        server.intercept = { cr, _ in
            if cr == "bytes \(self.chunk)-\(n - 1)/\(n)" {
                server.received = data          // 受理はした
                return .failure(.networkConnectionLost)
            }
            return nil
        }
        StubProtocol.setHandler(server.handle)
        let f = try await upload(makeDrive(), url, n, expected: md5(data))
        XCTAssertEqual(f.id, "NEWID")
        XCTAssertEqual(server.contentRanges.last, "bytes */\(n)")
        XCTAssertEqual(server.sessions, 1)
    }

    func test404SessionRestartsFromZero() async throws {
        let n = chunk * 2
        let (url, data) = makeFile(bytes: n, in: dir)
        let server = FakeResumableServer(total: n)
        var gone = false
        server.intercept = { cr, _ in
            if !gone && cr.hasPrefix("bytes \(self.chunk)-") { gone = true; return .http(404, [:], Data()) }
            return nil
        }
        StubProtocol.setHandler(server.handle)
        let f = try await upload(makeDrive(), url, n, expected: md5(data))
        XCTAssertEqual(f.id, "NEWID")
        XCTAssertEqual(server.sessions, 2)
        XCTAssertEqual(server.received, data)
        XCTAssertEqual(server.contentRanges.filter { $0.hasPrefix("bytes 0-") }.count, 2)
    }

    func testSessionRestartLimit() async throws {
        let n = chunk
        let (url, _) = makeFile(bytes: n, in: dir)
        let server = FakeResumableServer(total: n)
        server.intercept = { _, _ in .http(410, [:], Data()) }
        StubProtocol.setHandler(server.handle)
        do { _ = try await upload(makeDrive(), url, n, expected: nil); XCTFail() } catch let e as DriveError {
            XCTAssertEqual(e, .sessionRestartLimit)
        }
        XCTAssertEqual(server.sessions, 3)   // 初回 + 再作成 2 回
    }

    func testFinalMD5MismatchThrowsWithFileId() async throws {
        let n = 1000
        let (url, data) = makeFile(bytes: n, in: dir)
        let server = FakeResumableServer(total: n)
        server.md5Override = "deadbeef"
        StubProtocol.setHandler(server.handle)
        do { _ = try await upload(makeDrive(), url, n, expected: md5(data)); XCTFail() } catch let e as DriveError {
            XCTAssertEqual(e, .md5Mismatch(fileId: "NEWID", expected: md5(data), actual: "deadbeef"))
        }
    }

    func testPersistent503ExhaustsRetries() async throws {
        let n = 1000
        let (url, _) = makeFile(bytes: n, in: dir)
        let server = FakeResumableServer(total: n)
        server.intercept = { _, _ in .http(503, [:], Data()) }
        StubProtocol.setHandler(server.handle)
        do { _ = try await upload(makeDrive(), url, n, expected: nil); XCTFail() } catch let e as DriveError {
            guard case .retriesExhausted = e else { return XCTFail("\(e)") }
        }
        XCTAssertEqual(server.contentRanges.count, 6)
    }

    func test401RefreshesOnceThenRetries() async throws {
        let n = 1000
        let (url, data) = makeFile(bytes: n, in: dir)
        let server = FakeResumableServer(total: n)
        var unauthorized = false
        server.intercept = { _, _ in
            if !unauthorized { unauthorized = true; return .http(401, [:], Data()) }
            return nil
        }
        StubProtocol.setHandler(server.handle)
        let tokens = FakeTokens()
        let f = try await upload(makeDrive(tokens), url, n, expected: md5(data))
        XCTAssertEqual(f.id, "NEWID")
        XCTAssertEqual(tokens.refreshCount, 1)
    }

    func testClient4xxFailsWithMessage() async throws {
        let n = 1000
        let (url, _) = makeFile(bytes: n, in: dir)
        let server = FakeResumableServer(total: n)
        server.intercept = { _, _ in .http(403, [:], json(["error": ["message": "storageQuotaExceeded"]])) }
        StubProtocol.setHandler(server.handle)
        do { _ = try await upload(makeDrive(), url, n, expected: nil); XCTFail() } catch let e as DriveError {
            XCTAssertEqual(e, .http(status: 403, message: "storageQuotaExceeded"))
        }
    }

    func testRangeHeaderParsing() {
        XCTAssertEqual(DriveClient.nextOffset(fromRangeHeader: nil), 0)
        XCTAssertEqual(DriveClient.nextOffset(fromRangeHeader: "bytes=0-524287"), 524288)
        XCTAssertEqual(DriveClient.nextOffset(fromRangeHeader: "garbage"), 0)
    }
}

final class ProgressBox: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [(Int64, Int64)] = []
    func add(_ s: Int64, _ t: Int64) { lock.lock(); values.append((s, t)); lock.unlock() }
    var last: (Int64, Int64)? { lock.lock(); defer { lock.unlock() }; return values.last }
}
