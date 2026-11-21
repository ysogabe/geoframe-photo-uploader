import CryptoKit
import XCTest
@testable import UploaderCore

final class RecordStoreTests: XCTestCase {
    func testWrites0600JSONLines() throws {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("records.jsonl")
        let store = RecordStore(fileURL: url)
        let tz = TimeZone(identifier: "Asia/Tokyo")!
        let created = ISO8601DateFormatter().date(from: "2026-04-19T00:12:03Z")!
        let item = PhotoItem(localIdentifier: "L1/L0/001", originalFilename: "IMG_1.HEIC", uti: "public.heic", mediaKind: .image,
                             creationDate: created, location: PhotoLocation(lat: 35.1, lon: 139.2, altitude: 10, horizontalAccuracy: 5),
                             pixelWidth: 4032, pixelHeight: 3024)
        let exp = ExportedOriginal(fileURL: url, byteCount: 123, md5Hex: "m", sha256Hex: "s", dataSource: .local,
                                   exif: ExifDates(dateTimeOriginal: "2026:04:19 09:12:03", offsetTimeOriginal: "+09:00"))
        try store.append(UploadRecord(runId: "R", item: item, exported: exp, result: .sent, driveFileId: "F", driveMd5Checksum: "m",
                                      verified: true, folderId: "FOLDER", timeZone: tz))
        let noLoc = PhotoItem(localIdentifier: "L2", originalFilename: nil, uti: nil, mediaKind: .video, creationDate: nil)
        try store.append(UploadRecord(runId: "R", item: noLoc, exported: nil, result: .skippedIneligible, error: "動画",
                                      folderId: "FOLDER", timeZone: tz))

        let perms = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        XCTAssertEqual(perms, 0o600)
        let lines = try String(contentsOf: url, encoding: .utf8).split(separator: "\n")
        XCTAssertEqual(lines.count, 2)
        let o1 = try JSONSerialization.jsonObject(with: Data(lines[0].utf8)) as! [String: Any]
        XCTAssertEqual(o1["creationDate"] as? String, "2026-04-19T09:12:03+09:00")
        XCTAssertEqual(o1["creationTimeZone"] as? String, "Asia/Tokyo")
        XCTAssertEqual(o1["result"] as? String, "sent")
        XCTAssertEqual(o1["exifOffsetTimeOriginal"] as? String, "+09:00")
        XCTAssertEqual((o1["location"] as? [String: Any])?["lat"] as? Double, 35.1)
        XCTAssertTrue(o1["burstIdentifier"] is NSNull)
        let o2 = try JSONSerialization.jsonObject(with: Data(lines[1].utf8)) as! [String: Any]
        XCTAssertTrue(o2["location"] is NSNull)
        XCTAssertTrue(o2["md5"] is NSNull)
        XCTAssertEqual(o2["result"] as? String, "skipped_ineligible")
        // キーはソート済み
        XCTAssertTrue(lines[0].hasPrefix("{\"burstIdentifier\""))
        XCTAssertEqual(try store.readAll().count, 2)
    }
}

/// 事前に用意したバイト列を「原本」として返すフェイク。
final class FakeExporter: OriginalExporting, @unchecked Sendable {
    let dir: URL
    let contents: [String: Data]
    private let lock = NSLock()
    private var _calls: [String] = []
    /// export が呼ばれた localIdentifier（順）
    var calls: [String] { lock.withLock { _calls } }
    init(dir: URL, contents: [String: Data]) { self.dir = dir; self.contents = contents }
    private func note(_ id: String) { lock.withLock { _calls.append(id) } }
    func export(localIdentifier: String) async throws -> ExportedOriginal {
        note(localIdentifier)
        guard let d = contents[localIdentifier] else { throw ExportError.assetNotFound(localIdentifier) }
        let u = dir.appendingPathComponent(UUID().uuidString)
        try d.write(to: u)
        let h = try OriginalExporter.hashFile(at: u)
        return ExportedOriginal(fileURL: u, byteCount: h.bytes, md5Hex: h.md5, sha256Hex: h.sha256, dataSource: .local, exif: nil)
    }
}

/// フォルダ一覧 + 単発アップロード + 検証一覧を模す Drive。
final class FakeDrive: @unchecked Sendable {
    var files: [[String: Any]]
    var uploads = 0
    var listingMD5Override: String?
    var hideFromListing = false
    var pendingName = ""
    var pendingMime = ""
    init(files: [[String: Any]]) { self.files = files }

    func handle(_ r: StubProtocol.Recorded) -> StubProtocol.Reply {
        if r.method == "GET" {
            let q = r.query["q"] ?? ""
            var list = files
            if q.contains("name = '") {
                list = files.filter { q.contains("name = '\($0["name"] as! String)'") }
                if hideFromListing { list = [] }
                if let o = listingMD5Override { list = list.map { var f = $0; f["md5Checksum"] = o; return f } }
            }
            return .http(200, [:], json(["files": list]))
        }
        if r.method == "POST" {
            let meta = try! JSONSerialization.jsonObject(with: r.body) as! [String: Any]
            pendingName = meta["name"] as! String
            pendingMime = meta["mimeType"] as! String
            return .http(200, ["Location": "https://www.googleapis.com/upload/s"], Data())
        }
        // 単一チャンクで完了
        uploads += 1
        let md5 = Insecure.MD5.hash(data: r.body).map { String(format: "%02x", $0) }.joined()
        let f: [String: Any] = ["id": "NEW\(uploads)", "name": pendingName, "md5Checksum": md5]
        files.append(f)
        return .http(200, [:], json(f))
    }
}

final class CoordinatorTests: XCTestCase {
    var dir: URL!
    override func setUp() { dir = makeTempDir() }
    override func tearDown() { try? FileManager.default.removeItem(at: dir) }

    func md5(_ d: Data) -> String { Insecure.MD5.hash(data: d).map { String(format: "%02x", $0) }.joined() }

    func item(_ id: String, uti: String = "public.heic", name: String? = nil) -> PhotoItem {
        PhotoItem(localIdentifier: id, originalFilename: name ?? "\(id).HEIC", uti: uti, mediaKind: .image, creationDate: Date())
    }

    func makeCoordinator(_ fake: FakeDrive, contents: [String: Data], records: RecordStore? = nil) -> UploadCoordinator {
        StubProtocol.setHandler(fake.handle)
        let drive = DriveClient(session: StubProtocol.session(), tokens: FakeTokens(), sleeper: noSleep)
        return UploadCoordinator(drive: drive, exporter: FakeExporter(dir: dir, contents: contents), records: records,
                                 options: .init(verifyAttempts: 3, verifyDelay: 0), sleeper: noSleep)
    }

    func testMixedRun() async throws {
        let existing = Data("existing".utf8), fresh = Data("fresh".utf8)
        let fake = FakeDrive(files: [["id": "OLD", "name": "OLD.HEIC", "md5Checksum": md5(existing)]])
        let records = RecordStore(fileURL: dir.appendingPathComponent("records.jsonl"))
        let c = makeCoordinator(fake, contents: ["A": existing, "B": fresh, "C": fresh], records: records)
        let events = EventBox()
        let items = [item("A"), item("B"), item("C"), item("D", uti: "com.adobe.raw-image", name: "D.DNG")]
        let s = try await c.run(items: items, folderId: "FOLDER", maxItemsPerRun: 4) { events.add($0) }
        XCTAssertEqual(s.results.map(\.status), [.skippedDuplicate, .sent, .skippedDuplicate, .skippedIneligible])
        XCTAssertEqual(s.results[0].duplicateOfFileId, "OLD")
        XCTAssertEqual(s.results[1].driveFileId, "NEW1")
        XCTAssertTrue(s.results[1].verified)
        XCTAssertEqual(s.results[2].duplicateOfLocalIdentifier, "B")
        XCTAssertEqual(fake.uploads, 1)
        XCTAssertEqual(fake.pendingName, "B.HEIC")
        XCTAssertEqual(fake.pendingMime, "image/heic")
        XCTAssertEqual(try records.readAll().map(\.result), [.skippedDuplicate, .sent, .skippedDuplicate, .skippedIneligible])
        XCTAssertTrue(events.phases.contains(.verifying))
        // 一時ファイルは全部消えている
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0 != "records.jsonl" }, [])
    }

    func testVerifyMismatchIsFailureWithFileId() async throws {
        let fake = FakeDrive(files: [])
        fake.listingMD5Override = "0000"
        let c = makeCoordinator(fake, contents: ["A": Data("a".utf8)])
        let s = try await c.run(items: [item("A")], folderId: "FOLDER", maxItemsPerRun: 3)
        XCTAssertEqual(s.results[0].status, .failed)
        XCTAssertFalse(s.results[0].verified)
        XCTAssertEqual(s.results[0].driveFileId, "NEW1")
        XCTAssertTrue(s.results[0].error!.contains("NEW1"))
        XCTAssertEqual(fake.uploads, 1)   // 再送しない
    }

    func testVerifyNotListedIsFailure() async throws {
        let fake = FakeDrive(files: [])
        fake.hideFromListing = true
        let c = makeCoordinator(fake, contents: ["A": Data("a".utf8)])
        let s = try await c.run(items: [item("A")], folderId: "FOLDER", maxItemsPerRun: 3)
        XCTAssertEqual(s.results[0].status, .failed)
        XCTAssertTrue(s.results[0].error!.contains("fileId=NEW1"))
    }

    func testMaxItemsGuard() async throws {
        let fake = FakeDrive(files: [])
        let c = makeCoordinator(fake, contents: [:])
        do {
            _ = try await c.run(items: [item("A"), item("B"), item("C"), item("D")], folderId: "F", maxItemsPerRun: 3)
            XCTFail()
        } catch let e as UploadCoordinatorError {
            XCTAssertEqual(e, .tooManyItems(selected: 4, max: 3))
        }
        XCTAssertTrue(StubProtocol.recorded.isEmpty)   // 何も通信しない
    }
}

/// 一覧での照合の途中で中止されたとき。
final class CancelDuringVerifyTests: XCTestCase {
    var dir: URL!
    override func setUp() { dir = makeTempDir() }
    override func tearDown() { try? FileManager.default.removeItem(at: dir) }

    func md5(_ d: Data) -> String { Insecure.MD5.hash(data: d).map { String(format: "%02x", $0) }.joined() }

    func item(_ id: String) -> PhotoItem {
        PhotoItem(localIdentifier: id, originalFilename: "\(id).HEIC", uti: "public.heic", mediaKind: .image, creationDate: Date())
    }

    func makeCoordinator(_ fake: FakeDrive, exporter: FakeExporter, records: RecordStore?, cache: ResultCache?,
                         options: UploadCoordinator.Options, sleeper: @escaping Sleeper) -> UploadCoordinator {
        StubProtocol.setHandler(fake.handle)
        let drive = DriveClient(session: StubProtocol.session(), tokens: FakeTokens(), sleeper: noSleep)
        return UploadCoordinator(drive: drive, exporter: exporter, records: records, cache: cache,
                                 options: options, sleeper: sleeper)
    }

    /// `.verifying` を受け取った時点で実行中のタスク自身を中止する（onEvent は実行中のタスクから同期で呼ばれる）。
    static let cancelAtVerify: @Sendable (UploadEvent) -> Void = { ev in
        if ev.phase == .verifying { withUnsafeCurrentTask { $0?.cancel() } }
    }

    func testCancelDuringVerifyStillVerifiesAndReportsSent() async throws {
        let bytes = Data("photo".utf8)
        let fake = FakeDrive(files: [])
        let records = RecordStore(fileURL: dir.appendingPathComponent("records.jsonl"))
        let cache = ResultCache(fileURL: dir.appendingPathComponent("item-cache.json"))
        let a = item("A")
        let c = makeCoordinator(fake, exporter: FakeExporter(dir: dir, contents: ["A": bytes]), records: records, cache: cache,
                                options: .init(verifyAttempts: 3, verifyDelay: 0, verifyBudgetAfterCancel: 5),
                                sleeper: defaultSleeper)
        // 中止するのは送信用のタスクだけ（テスト自身のタスクは中止しない）
        let s = try await Task { try await c.run(items: [a, self.item("B")], folderId: "FOLDER", maxItemsPerRun: 2,
                                                 onEvent: Self.cancelAtVerify) }.value
        XCTAssertEqual(s.results.count, 1)   // B は始めない
        XCTAssertTrue(s.cancelled)
        XCTAssertEqual(s.results[0].status, .sent)
        XCTAssertTrue(s.results[0].verified)
        XCTAssertNil(s.results[0].error)
        XCTAssertEqual(fake.uploads, 1)
        XCTAssertEqual(try records.readAll().map(\.result), [.sent])
        XCTAssertEqual(cache.entry(for: a)?.lastStatus, .sent)
        XCTAssertEqual(cache.entry(for: a)?.driveFileId, "NEW1")
    }

    func testCancelDuringVerifyWhenListingUnavailableRecordsInterruptedFailure() async throws {
        let bytes = Data("photo".utf8)
        let fake = FakeDrive(files: [])
        fake.hideFromListing = true   // 照合の一覧に出てこない（結果整合性の遅れ）
        let recURL = dir.appendingPathComponent("records.jsonl")
        let records = RecordStore(fileURL: recURL)
        let cacheURL = dir.appendingPathComponent("item-cache.json")
        let cache = ResultCache(fileURL: cacheURL, records: records)
        let exporter = FakeExporter(dir: dir, contents: ["A": bytes])
        let a = item("A")
        let realSleep: Sleeper = { _ in try await Task.sleep(nanoseconds: 20_000_000) }
        let c = makeCoordinator(fake, exporter: exporter, records: records, cache: cache,
                                options: .init(verifyAttempts: 10_000, verifyDelay: 0.02, verifyBudgetAfterCancel: 0.2),
                                sleeper: realSleep)
        let started = Date()
        let s = try await Task { try await c.run(items: [a], folderId: "FOLDER", maxItemsPerRun: 1,
                                                 onEvent: Self.cancelAtVerify) }.value
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)   // 上限で打ち切る
        XCTAssertTrue(s.cancelled)
        let r = s.results[0]
        XCTAssertEqual(r.status, .failed)
        XCTAssertFalse(r.verified)
        XCTAssertFalse(r.wasCancelled)
        XCTAssertTrue(r.verificationInterrupted)
        XCTAssertTrue(r.error!.hasPrefix("アップロード済み（応答の md5 は一致）・中止のため一覧での照合は未完了"), r.error!)
        XCTAssertTrue(r.error!.contains("fileId=NEW1"))
        XCTAssertEqual(r.driveFileId, "NEW1")
        XCTAssertEqual(r.md5, md5(bytes))
        XCTAssertEqual(fake.uploads, 1)

        // 記録とキャッシュ（直接の書き込みと records.jsonl からの取り込み）が一致する
        let rec = try XCTUnwrap(try records.readAll().first)
        XCTAssertEqual(rec.result, .failed)
        XCTAssertEqual(rec.driveFileId, "NEW1")
        XCTAssertEqual(rec.md5, md5(bytes))
        XCTAssertEqual(cache.entry(for: a)?.lastStatus, .failed)
        XCTAssertEqual(cache.entry(for: a)?.driveFileId, "NEW1")
        XCTAssertEqual(cache.entry(for: a)?.md5, md5(bytes))
        let imported = ResultCache(fileURL: dir.appendingPathComponent("other-cache.json"), records: RecordStore(fileURL: recURL))
        XCTAssertEqual(imported.entry(for: a)?.lastStatus, .failed)
        XCTAssertEqual(imported.entry(for: a)?.driveFileId, "NEW1")
        XCTAssertEqual(imported.entry(for: a)?.md5, md5(bytes))

        // 次の送信では、キャッシュの md5 が Drive 一覧にあるので書き出さずに「重複」（再送しない）
        fake.hideFromListing = false
        let c2 = makeCoordinator(fake, exporter: exporter, records: records, cache: cache,
                                 options: .init(verifyAttempts: 3, verifyDelay: 0), sleeper: noSleep)
        let s2 = try await c2.run(items: [a], folderId: "FOLDER", maxItemsPerRun: 1)
        XCTAssertEqual(s2.results[0].status, .skippedDuplicate)
        XCTAssertEqual(s2.results[0].duplicateOfFileId, "NEW1")
        XCTAssertEqual(exporter.calls, ["A"])
        XCTAssertEqual(fake.uploads, 1)
        XCTAssertEqual(cache.entry(for: a)?.lastStatus, .duplicateRemote)
    }
}

final class EventBox: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [UploadEvent] = []
    func add(_ e: UploadEvent) { lock.lock(); events.append(e); lock.unlock() }
    var phases: [UploadPhase] { lock.lock(); defer { lock.unlock() }; return events.map(\.phase) }
    var all: [UploadEvent] { lock.lock(); defer { lock.unlock() }; return events }
}
