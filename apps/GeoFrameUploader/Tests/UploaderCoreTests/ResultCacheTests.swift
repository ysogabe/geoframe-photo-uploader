import CryptoKit
import XCTest
@testable import UploaderCore

private func md5Hex(_ d: Data) -> String { Insecure.MD5.hash(data: d).map { String(format: "%02x", $0) }.joined() }

private func photo(_ id: String, name: String? = nil, uti: String = "public.heic") -> PhotoItem {
    PhotoItem(localIdentifier: id, originalFilename: name ?? "\(id).HEIC", uti: uti, mediaKind: .image, creationDate: Date())
}

final class ResultCacheTests: XCTestCase {
    var dir: URL!
    override func setUp() { dir = makeTempDir() }
    override func tearDown() { try? FileManager.default.removeItem(at: dir) }

    var cacheURL: URL { dir.appendingPathComponent("item-cache.json") }

    func testRoundTripAndPermissions() throws {
        let c = ResultCache(fileURL: cacheURL)
        XCTAssertEqual(c.count, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: cacheURL.path))
        let a = photo("A/L0/001")
        c.recordHash(item: a, md5: "ABCDEF", sha256: "s1", byteCount: 10)
        c.recordStatus(item: a, status: .sent, driveFileId: "F1", folderId: "FOLDER")

        let perms = try FileManager.default.attributesOfItem(atPath: cacheURL.path)[.posixPermissions] as? Int
        XCTAssertEqual(perms, 0o600)
        // 一時ファイルは残らない
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path), ["item-cache.json"])

        let c2 = ResultCache(fileURL: cacheURL)
        XCTAssertEqual(c2.count, 1)
        let e = try XCTUnwrap(c2.entry(for: a))
        XCTAssertEqual(e.md5, "abcdef")
        XCTAssertEqual(c2.cachedMD5(for: a), "abcdef")
        XCTAssertEqual(e.sha256, "s1")
        XCTAssertEqual(e.byteCount, 10)
        XCTAssertEqual(e.lastStatus, .sent)
        XCTAssertEqual(e.driveFileId, "F1")
        XCTAssertEqual(e.folderId, "FOLDER")
        XCTAssertNotNil(e.hashedAt)
        XCTAssertNotNil(e.statusAt)
        XCTAssertTrue(e.statusApplies(toFolder: "FOLDER"))
        XCTAssertFalse(e.statusApplies(toFolder: "OTHER"))
        XCTAssertTrue(e.statusApplies(toFolder: nil))
    }

    func testMismatchInvalidatesAndOverwrites() throws {
        let c = ResultCache(fileURL: cacheURL)
        c.recordStatus(item: photo("A"), status: .sent, driveFileId: "F1", folderId: "FOLDER", md5: "aaa")
        let renamed = photo("A", name: "IMG_9.HEIC")
        let otherUTI = photo("A", uti: "public.jpeg")
        XCTAssertNil(c.entry(for: renamed))
        XCTAssertNil(c.cachedMD5(for: otherUTI))
        XCTAssertTrue(c.entries(for: [renamed, otherUTI]).isEmpty)
        XCTAssertEqual(c.entries(for: [photo("A")]).count, 1)

        // 一致しない古いエントリは引き継がずに上書きする
        c.recordHash(item: renamed, md5: "bbb", sha256: nil, byteCount: nil)
        let e = try XCTUnwrap(c.entry(for: renamed))
        XCTAssertEqual(e.md5, "bbb")
        XCTAssertNil(e.lastStatus)
        XCTAssertNil(e.driveFileId)
        XCTAssertNil(c.entry(for: photo("A")))
    }

    func testChangedMD5ClearsStatus() throws {
        let c = ResultCache(fileURL: cacheURL)
        let a = photo("A")
        c.recordStatus(item: a, status: .sent, driveFileId: "F1", folderId: "FOLDER", md5: "aaa")
        c.recordHash(item: a, md5: "aaa", sha256: "s", byteCount: 1)
        XCTAssertEqual(c.entry(for: a)?.lastStatus, .sent)
        c.recordHash(item: a, md5: "ccc", sha256: "s", byteCount: 1)
        XCTAssertNil(c.entry(for: a)?.lastStatus)
        XCTAssertNil(c.entry(for: a)?.driveFileId)
    }

    func testOwnSentFileFoundOnDriveStaysSent() throws {
        let c = ResultCache(fileURL: cacheURL)
        let a = photo("A")
        c.recordStatus(item: a, status: .sent, driveFileId: "F1", folderId: "FOLDER", md5: "aaa")
        c.recordStatus(item: a, status: .duplicateRemote, driveFileId: "F1", folderId: "FOLDER", md5: "aaa")
        XCTAssertEqual(c.entry(for: a)?.lastStatus, .sent)
        c.recordStatuses([.init(item: a, status: .duplicateRemote, driveFileId: nil, folderId: "FOLDER")])
        XCTAssertEqual(c.entry(for: a)?.lastStatus, .sent)
        // 別のファイルと一致したなら重複として記録する
        c.recordStatus(item: a, status: .duplicateRemote, driveFileId: "OTHER", folderId: "FOLDER")
        XCTAssertEqual(c.entry(for: a)?.lastStatus, .duplicateRemote)
        XCTAssertEqual(c.entry(for: a)?.driveFileId, "OTHER")
    }

    func testCorruptFileIsBackedUpAndRebuiltFromRecords() throws {
        try Data("{not json".utf8).write(to: cacheURL)
        let records = RecordStore(fileURL: dir.appendingPathComponent("records.jsonl"))
        try records.append(UploadRecord(runId: "R", item: photo("A"), exported: nil, result: .skippedDuplicate,
                                        folderId: "F"))
        let c = ResultCache(fileURL: cacheURL, records: records)
        XCTAssertEqual(c.count, 1)   // 退避後、records.jsonl から作り直す
        XCTAssertEqual(c.entry(for: photo("A"))?.lastStatus, .duplicateRemote)
        let backup = try XCTUnwrap(c.corruptBackupURL)
        XCTAssertTrue(backup.lastPathComponent.hasPrefix("item-cache.json.corrupt-"))
        XCTAssertEqual(try String(contentsOf: backup, encoding: .utf8), "{not json")
        // 以後は普通に使える
        c.recordHash(item: photo("B"), md5: "bbb", sha256: nil, byteCount: nil)
        XCTAssertEqual(ResultCache(fileURL: cacheURL).count, 2)
    }

    func testConcurrentUpdates() async throws {
        let c = ResultCache(fileURL: cacheURL)
        await withTaskGroup(of: Void.self) { g in
            for i in 0..<50 {
                g.addTask { c.recordHash(item: photo("P\(i)"), md5: "m\(i)", sha256: nil, byteCount: Int64(i)) }
            }
        }
        XCTAssertEqual(c.count, 50)
        XCTAssertEqual(ResultCache(fileURL: cacheURL).count, 50)
    }

    // MARK: records.jsonl からの初期化

    func exported(_ md5: String, sha: String = "sha") -> ExportedOriginal {
        ExportedOriginal(fileURL: dir.appendingPathComponent("x"), byteCount: 42, md5Hex: md5, sha256Hex: sha,
                         dataSource: .local, exif: nil)
    }

    func testSeedingFromRecords() throws {
        let recURL = dir.appendingPathComponent("records.jsonl")
        let records = RecordStore(fileURL: recURL)
        let a = photo("A"), b = photo("B"), c = photo("C"), d = photo("D"), e = photo("E"), f = photo("F")
        try records.append(UploadRecord(runId: "R1", item: a, exported: exported("AAA"), result: .sent, driveFileId: "FA",
                                        driveMd5Checksum: "aaa", verified: true, folderId: "FOLDER"))
        try records.append(UploadRecord(runId: "R1", item: b, exported: exported("bbb"), result: .skippedDuplicate,
                                        folderId: "FOLDER"))
        try records.append(UploadRecord(runId: "R1", item: c, exported: exported("ccc"), result: .failed,
                                        error: "アップロード失敗: x", folderId: "FOLDER"))
        try records.append(UploadRecord(runId: "R1", item: d, exported: nil, result: .failed, error: "原本の取得に失敗",
                                        folderId: "FOLDER"))
        // E: 先に失敗、後で送信済み（後が優先）
        try records.append(UploadRecord(runId: "R1", item: e, exported: exported("eee"), result: .failed, error: "x",
                                        folderId: "FOLDER"))
        try records.append(UploadRecord(runId: "R2", item: e, exported: exported("eee"), result: .sent, driveFileId: "FE",
                                        verified: true, folderId: "FOLDER"))
        // F: md5 付きの送信済みの後、md5 の無い中止記録（md5 も状態も消さない）
        try records.append(UploadRecord(runId: "R1", item: f, exported: exported("fff"), result: .sent, driveFileId: "FF",
                                        verified: true, folderId: "FOLDER"))
        try records.append(UploadRecord(runId: "R2", item: f, exported: nil, result: .failed,
                                        error: UploadCoordinator.cancelledMessage, folderId: "FOLDER"))
        // A: 送信済みの後の重複スキップ（自分の送ったファイル）は sent のまま
        try records.append(UploadRecord(runId: "R2", item: a, exported: exported("aaa"), result: .skippedDuplicate,
                                        folderId: "FOLDER"))
        // 壊れた行は飛ばす
        let h = try FileHandle(forWritingTo: recURL)
        try h.seekToEnd(); try h.write(contentsOf: Data("garbage line\n".utf8)); try h.close()
        try records.append(UploadRecord(runId: "R3", item: photo("G", uti: "com.adobe.raw-image"), exported: nil,
                                        result: .skippedIneligible, error: "DNG", folderId: "FOLDER"))

        let cache = ResultCache(fileURL: cacheURL, records: records)
        XCTAssertEqual(cache.entry(for: a)?.lastStatus, .sent)
        XCTAssertEqual(cache.entry(for: a)?.driveFileId, "FA")
        XCTAssertEqual(cache.entry(for: a)?.md5, "aaa")
        XCTAssertEqual(cache.entry(for: a)?.byteCount, 42)
        XCTAssertEqual(cache.entry(for: a)?.folderId, "FOLDER")
        XCTAssertEqual(cache.entry(for: b)?.lastStatus, .duplicateRemote)
        XCTAssertNil(cache.entry(for: b)?.driveFileId)
        XCTAssertEqual(cache.entry(for: b)?.md5, "bbb")
        XCTAssertEqual(cache.entry(for: c)?.lastStatus, .failed)
        XCTAssertEqual(cache.entry(for: c)?.md5, "ccc")
        XCTAssertNil(cache.entry(for: d))   // md5 の無い失敗は残さない
        XCTAssertEqual(cache.entry(for: e)?.lastStatus, .sent)
        XCTAssertEqual(cache.entry(for: e)?.driveFileId, "FE")
        XCTAssertEqual(cache.entry(for: f)?.lastStatus, .sent)
        XCTAssertEqual(cache.entry(for: f)?.md5, "fff")
        XCTAssertNil(cache.entry(for: photo("G", uti: "com.adobe.raw-image")))
        XCTAssertEqual(cache.count, 5)

        // 作成時に保存される
        XCTAssertTrue(FileManager.default.fileExists(atPath: cacheURL.path))
        let size = try FileManager.default.attributesOfItem(atPath: recURL.path)[.size] as? NSNumber
        XCTAssertEqual(cache.recordsWatermark?.byteOffset, size?.uint64Value)
    }

    // MARK: records.jsonl の差分取り込み

    var recURL: URL { dir.appendingPathComponent("records.jsonl") }

    func rec(_ item: PhotoItem, _ result: RecordResult, md5: String?, fileId: String? = nil, at: Date,
             error: String? = nil) -> UploadRecord {
        UploadRecord(runId: "R", recordedAt: at, item: item, exported: md5.map { exported($0) }, result: result,
                     driveFileId: fileId, verified: result == .sent, error: error, folderId: "FOLDER")
    }

    let t0 = Date(timeIntervalSince1970: 1_790_000_000)

    func testIncrementalImportPicksUpAppendedLines() throws {
        let records = RecordStore(fileURL: recURL)
        try records.append(rec(photo("A"), .sent, md5: "aaa", fileId: "FA", at: t0))
        let c = ResultCache(fileURL: cacheURL, records: records)
        XCTAssertEqual(c.count, 1)

        // 別のプロセス（古いビルドのアプリ）が追記
        try records.append(rec(photo("B"), .skippedDuplicate, md5: "bbb", at: t0 + 10))
        try records.append(rec(photo("A"), .skippedDuplicate, md5: "aaa", at: t0 + 10))   // 自分の送ったファイル
        // 書き込み途中の行は取り込まない
        let h = try FileHandle(forWritingTo: recURL)
        try h.seekToEnd(); try h.write(contentsOf: Data("{\"partial\":".utf8)); try h.close()

        c.refresh()
        XCTAssertEqual(c.count, 2)
        XCTAssertEqual(c.entry(for: photo("B"))?.lastStatus, .duplicateRemote)
        XCTAssertEqual(c.entry(for: photo("A"))?.lastStatus, .sent)
        let offset = try XCTUnwrap(c.recordsWatermark?.byteOffset)
        let size = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: recURL.path)[.size] as? NSNumber).uint64Value
        XCTAssertEqual(offset, size - UInt64("{\"partial\":".utf8.count))

        // 新しいインスタンスも保存済みの位置から続ける
        let c2 = ResultCache(fileURL: cacheURL, records: records)
        XCTAssertEqual(c2.count, 2)
        XCTAssertEqual(c2.recordsWatermark, c.recordsWatermark)
    }

    func testReimportIsIdempotentWithDirectWrites() throws {
        let records = RecordStore(fileURL: recURL)
        let a = photo("A"), b = photo("B")
        let c = ResultCache(fileURL: cacheURL, records: records)
        // このプロセスの送信: 記録を書いてから直接キャッシュへ（コーディネーターと同じ順）
        try records.append(rec(a, .sent, md5: "aaa", fileId: "FA", at: t0))
        c.recordStatus(item: a, status: .sent, driveFileId: "FA", folderId: "FOLDER", md5: "aaa", at: t0 + 0.5)
        // 同一実行内の重複: 記録には fileId が無いが、キャッシュには先行写真の fileId を入れる
        try records.append(rec(b, .skippedDuplicate, md5: "aaa", at: t0))
        c.recordStatus(item: b, status: .duplicateRemote, driveFileId: "FA", folderId: "FOLDER", md5: "aaa", at: t0 + 0.5)
        let snapshot = c.entries(for: [a, b])

        c.refresh()
        XCTAssertEqual(c.entries(for: [a, b]), snapshot)
        c.refresh()
        XCTAssertEqual(c.entries(for: [a, b]), snapshot)
        // 保存して読み直し（日時は秒に丸まる）ても、取り込み直しで結果は変わらない
        let reloaded = ResultCache(fileURL: cacheURL, records: records)
        XCTAssertEqual(reloaded.entry(for: b)?.driveFileId, "FA")
        XCTAssertEqual(reloaded.entry(for: a)?.lastStatus, .sent)
        let before = reloaded.entries(for: [a, b])
        reloaded.refresh()
        XCTAssertEqual(reloaded.entries(for: [a, b]), before)
    }

    func testTruncatedOrReplacedRecordsTriggerFullReimport() throws {
        let records = RecordStore(fileURL: recURL)
        try records.append(rec(photo("A"), .sent, md5: "aaa", fileId: "FA", at: t0))
        try records.append(rec(photo("B"), .sent, md5: "bbb", fileId: "FB", at: t0))
        let c = ResultCache(fileURL: cacheURL, records: records)
        XCTAssertEqual(c.count, 2)

        // 縮んだ（別の内容で作り直された）
        try FileManager.default.removeItem(at: recURL)
        try records.append(rec(photo("C"), .skippedDuplicate, md5: "ccc", at: t0 + 20))
        c.refresh()
        XCTAssertEqual(c.entry(for: photo("C"))?.lastStatus, .duplicateRemote)
        XCTAssertEqual(c.count, 3)   // 既存のエントリは残す

        // 同じ大きさ以上で置き換わった（別 inode）
        let replacement = dir.appendingPathComponent("replacement.jsonl")
        let other = RecordStore(fileURL: replacement)
        try other.append(rec(photo("D"), .sent, md5: "ddd", fileId: "FD", at: t0 + 30))
        try other.append(rec(photo("E"), .sent, md5: "eee", fileId: "FE", at: t0 + 30))
        _ = try FileManager.default.replaceItemAt(recURL, withItemAt: replacement)
        c.refresh()
        XCTAssertEqual(c.entry(for: photo("D"))?.driveFileId, "FD")
        XCTAssertEqual(c.entry(for: photo("E"))?.driveFileId, "FE")
    }

    func testRewrittenInPlaceIsDetectedByTailHash() throws {
        let records = RecordStore(fileURL: recURL)
        try records.append(rec(photo("A"), .sent, md5: "aaa", fileId: "FA", at: t0))
        let c = ResultCache(fileURL: cacheURL, records: records)
        // 同じ inode のまま中身を書き換えて伸ばす
        var line = try Self.encodeLine(rec(photo("Z"), .sent, md5: "zzz", fileId: "FZ", at: t0 + 40))
        line.append(try Self.encodeLine(rec(photo("Y"), .sent, md5: "yyy", fileId: "FY", at: t0 + 40)))
        let h = try FileHandle(forWritingTo: recURL)
        try h.truncate(atOffset: 0); try h.write(contentsOf: line); try h.close()
        c.refresh()
        XCTAssertEqual(c.entry(for: photo("Z"))?.driveFileId, "FZ")
        XCTAssertEqual(c.entry(for: photo("Y"))?.driveFileId, "FY")
    }

    static func encodeLine(_ r: UploadRecord) throws -> Data {
        var d = try RecordStore.encoder.encode(r); d.append(0x0A); return d
    }

    func testOlderRecordDoesNotOverrideNewerDirectWrite() throws {
        let records = RecordStore(fileURL: recURL)
        let a = photo("A")
        let c = ResultCache(fileURL: cacheURL, records: records)
        c.recordStatus(item: a, status: .checkedNotOnDrive, driveFileId: nil, folderId: "FOLDER", md5: "aaa", at: t0 + 100)
        try records.append(rec(a, .failed, md5: "aaa", at: t0, error: "x"))   // 古い記録が後から届いた
        c.refresh()
        XCTAssertEqual(c.entry(for: a)?.lastStatus, .checkedNotOnDrive)
    }

    func testMergeOnSaveKeepsEntriesFromAnotherInstance() throws {
        let gui = ResultCache(fileURL: cacheURL)
        let cli = ResultCache(fileURL: cacheURL)
        let a = photo("A"), b = photo("B")
        gui.recordStatus(item: a, status: .sent, driveFileId: "FA", folderId: "FOLDER", md5: "aaa", at: t0)
        cli.recordStatus(item: b, status: .duplicateRemote, driveFileId: "FB", folderId: "FOLDER", md5: "bbb", at: t0)
        // CLI の保存で GUI の A が消えない
        let disk = ResultCache(fileURL: cacheURL)
        XCTAssertEqual(disk.entry(for: a)?.driveFileId, "FA")
        XCTAssertEqual(disk.entry(for: b)?.driveFileId, "FB")
        // 新しい方が勝つ
        gui.recordStatus(item: b, status: .failed, driveFileId: nil, folderId: "FOLDER", at: t0 - 50)
        XCTAssertEqual(ResultCache(fileURL: cacheURL).entry(for: b)?.lastStatus, .duplicateRemote)
        XCTAssertEqual(gui.entry(for: b)?.lastStatus, .duplicateRemote)
        cli.recordStatus(item: a, status: .failed, driveFileId: nil, folderId: "FOLDER", at: t0 + 50)
        gui.refresh()
        XCTAssertEqual(gui.entry(for: a)?.lastStatus, .failed)
    }
}

// MARK: - コーディネーター / 重複確認とキャッシュ

final class CachedCoordinatorTests: XCTestCase {
    var dir: URL!
    var cacheDir: URL!
    override func setUp() { dir = makeTempDir(); cacheDir = makeTempDir() }
    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
        try? FileManager.default.removeItem(at: cacheDir)
    }

    func makeCache() -> ResultCache { ResultCache(fileURL: cacheDir.appendingPathComponent("item-cache.json")) }

    func makeCoordinator(_ fake: FakeDrive, exporter: FakeExporter, records: RecordStore? = nil,
                         cache: ResultCache) -> UploadCoordinator {
        StubProtocol.setHandler(fake.handle)
        let drive = DriveClient(session: StubProtocol.session(), tokens: FakeTokens(), sleeper: noSleep)
        return UploadCoordinator(drive: drive, exporter: exporter, records: records, cache: cache,
                                 options: .init(verifyAttempts: 3, verifyDelay: 0), sleeper: noSleep)
    }

    func testSkipsWithoutExportWhenCachedMD5IsOnDrive() async throws {
        let existing = Data("existing".utf8)
        let fake = FakeDrive(files: [["id": "OLD", "name": "OLD.HEIC", "md5Checksum": md5Hex(existing)]])
        let exporter = FakeExporter(dir: dir, contents: ["A": existing])
        let cache = makeCache()
        let a = photo("A")
        cache.recordHash(item: a, md5: md5Hex(existing), sha256: "sha-a", byteCount: 8)
        let records = RecordStore(fileURL: cacheDir.appendingPathComponent("records.jsonl"))
        let c = makeCoordinator(fake, exporter: exporter, records: records, cache: cache)
        let events = EventBox()
        let s = try await c.run(items: [a], folderId: "FOLDER", maxItemsPerRun: 1) { events.add($0) }

        XCTAssertEqual(exporter.calls, [])   // 書き出していない
        XCTAssertEqual(s.results[0].status, .skippedDuplicate)
        XCTAssertEqual(s.results[0].duplicateOfFileId, "OLD")
        XCTAssertTrue(s.results[0].md5FromCache)
        XCTAssertEqual(fake.uploads, 0)
        XCTAssertFalse(events.phases.contains(.exporting))
        let rec = try XCTUnwrap(try records.readAll().first)
        XCTAssertEqual(rec.result, .skippedDuplicate)
        XCTAssertEqual(rec.md5, md5Hex(existing))
        XCTAssertEqual(rec.sha256, "sha-a")
        XCTAssertEqual(rec.byteCount, 8)
        XCTAssertEqual(cache.entry(for: a)?.lastStatus, .duplicateRemote)
        XCTAssertEqual(cache.entry(for: a)?.driveFileId, "OLD")
        XCTAssertEqual(cache.entry(for: a)?.folderId, "FOLDER")
    }

    func testExportsWhenCachedMD5NotOnDriveAndUpdatesCacheAfterVerifiedSend() async throws {
        let bytes = Data("fresh".utf8)
        let fake = FakeDrive(files: [])
        let exporter = FakeExporter(dir: dir, contents: ["A": bytes])
        let cache = makeCache()
        let a = photo("A")
        // 前回送信済みだが Drive に見当たらない（消された）
        cache.recordStatus(item: a, status: .sent, driveFileId: "GONE", folderId: "FOLDER", md5: md5Hex(bytes))
        let c = makeCoordinator(fake, exporter: exporter, cache: cache)
        let s = try await c.run(items: [a], folderId: "FOLDER", maxItemsPerRun: 1)

        XCTAssertEqual(exporter.calls, ["A"])
        XCTAssertEqual(s.results[0].status, .sent)
        XCTAssertTrue(s.results[0].verified)
        XCTAssertFalse(s.results[0].md5FromCache)
        XCTAssertEqual(fake.uploads, 1)
        let e = try XCTUnwrap(cache.entry(for: a))
        XCTAssertEqual(e.lastStatus, .sent)
        XCTAssertEqual(e.driveFileId, "NEW1")
        XCTAssertEqual(e.md5, md5Hex(bytes))
        XCTAssertNotNil(e.sha256)
        // 保存もされている
        XCTAssertEqual(ResultCache(fileURL: cache.fileURL).entry(for: a)?.driveFileId, "NEW1")
    }

    func testStaleCachedMD5IsOverwrittenByExport() async throws {
        let bytes = Data("actual".utf8)
        let fake = FakeDrive(files: [])
        let exporter = FakeExporter(dir: dir, contents: ["A": bytes])
        let cache = makeCache()
        let a = photo("A")
        cache.recordHash(item: a, md5: "00000000000000000000000000000000", sha256: nil, byteCount: nil)
        let c = makeCoordinator(fake, exporter: exporter, cache: cache)
        let s = try await c.run(items: [a], folderId: "FOLDER", maxItemsPerRun: 1)
        XCTAssertEqual(exporter.calls, ["A"])
        XCTAssertEqual(s.results[0].status, .sent)
        XCTAssertEqual(cache.entry(for: a)?.md5, md5Hex(bytes))
    }

    func testInBatchDuplicateFromCacheSkipsExport() async throws {
        let bytes = Data("same".utf8)
        let fake = FakeDrive(files: [])
        let exporter = FakeExporter(dir: dir, contents: ["A": bytes, "B": bytes])
        let cache = makeCache()
        let b = photo("B")
        cache.recordHash(item: b, md5: md5Hex(bytes), sha256: nil, byteCount: nil)
        let c = makeCoordinator(fake, exporter: exporter, cache: cache)
        let s = try await c.run(items: [photo("A"), b], folderId: "FOLDER", maxItemsPerRun: 2)
        XCTAssertEqual(exporter.calls, ["A"])
        XCTAssertEqual(s.results.map(\.status), [.sent, .skippedDuplicate])
        XCTAssertEqual(s.results[1].duplicateOfLocalIdentifier, "A")
        // 先行写真が Drive に載ったので「Drive に既存」として覚える
        XCTAssertEqual(cache.entry(for: b)?.lastStatus, .duplicateRemote)
        XCTAssertEqual(cache.entry(for: b)?.driveFileId, "NEW1")
    }

    func testVerifyFailureIsCached() async throws {
        let fake = FakeDrive(files: [])
        fake.listingMD5Override = "0000"
        let exporter = FakeExporter(dir: dir, contents: ["A": Data("a".utf8)])
        let cache = makeCache()
        let c = makeCoordinator(fake, exporter: exporter, cache: cache)
        let s = try await c.run(items: [photo("A")], folderId: "FOLDER", maxItemsPerRun: 1)
        XCTAssertEqual(s.results[0].status, .failed)
        XCTAssertEqual(cache.entry(for: photo("A"))?.lastStatus, .failed)
        XCTAssertEqual(cache.entry(for: photo("A"))?.driveFileId, "NEW1")
    }

    func testPrecheckUsesCacheWithoutExport() async throws {
        let existing = Data("existing".utf8), fresh = Data("fresh".utf8)
        let remote = RemoteIndex(files: [DriveFile(id: "OLD", name: "OLD.HEIC", md5Checksum: md5Hex(existing))])
        let exporter = FakeExporter(dir: dir, contents: ["A": existing, "B": fresh, "C": Data("c".utf8)])
        let cache = makeCache()
        let a = photo("A"), b = photo("B"), c = photo("C")
        cache.recordHash(item: a, md5: md5Hex(existing), sha256: nil, byteCount: nil)
        cache.recordStatus(item: b, status: .sent, driveFileId: "GONE", folderId: "FOLDER", md5: md5Hex(fresh))
        let progress = PrecheckProgressBox()
        let r = try await DuplicatePrecheck.run(items: [a, b, c], exporter: exporter, remote: remote, cache: cache,
                                                folderId: "FOLDER") { progress.add($0, $1) }

        XCTAssertEqual(exporter.calls, ["C"])   // キャッシュの無い C だけ書き出す
        XCTAssertEqual(r[0].decision, .duplicateRemote(fileId: "OLD", name: "OLD.HEIC"))
        XCTAssertTrue(r[0].md5FromCache)
        XCTAssertEqual(r[1].decision, .toUpload)
        XCTAssertTrue(r[1].md5FromCache)
        XCTAssertEqual(r[2].decision, .toUpload)
        XCTAssertFalse(r[2].md5FromCache)
        XCTAssertEqual(progress.values.count, 4)
        XCTAssertEqual(cache.entry(for: a)?.lastStatus, .duplicateRemote)
        XCTAssertEqual(cache.entry(for: a)?.driveFileId, "OLD")
        // Drive が正: 前回送信済みでも一覧に無ければ「確認済み・未送信」
        XCTAssertEqual(cache.entry(for: b)?.lastStatus, .checkedNotOnDrive)
        XCTAssertEqual(cache.entry(for: c)?.lastStatus, .checkedNotOnDrive)
        XCTAssertEqual(cache.entry(for: c)?.md5, md5Hex(Data("c".utf8)))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path), [])
    }
}
