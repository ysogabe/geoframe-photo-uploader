import CryptoKit
import XCTest
@testable import UploaderCore

final class AutoPrecheckQueueTests: XCTestCase {
    func item(_ id: String, uti: String = "public.heic") -> PhotoItem {
        PhotoItem(localIdentifier: id, originalFilename: "\(id).HEIC", uti: uti, mediaKind: .image, creationDate: nil)
    }

    func testCandidatesOnlyNewEligibleUnsettledInItemOrder() {
        let items = [item("A"), item("B"), item("C", uti: "com.adobe.raw-image"), item("D"), item("E")]
        let c = AutoPrecheckQueue.candidates(items: items, oldSelection: ["A"], newSelection: ["E", "A", "B", "C", "D"],
                                             settled: ["D"])
        XCTAssertEqual(c, ["B", "E"])
        // オンにした直後は今の選択がすべて新しい
        XCTAssertEqual(AutoPrecheckQueue.candidates(items: items, oldSelection: [], newSelection: ["A"], settled: []), ["A"])
        XCTAssertEqual(AutoPrecheckQueue.candidates(items: items, oldSelection: ["A"], newSelection: [], settled: []), [])
    }

    func testSequentialProcessingAndProgress() {
        var q = AutoPrecheckQueue()
        XCTAssertNil(q.progress)
        XCTAssertFalse(q.selectionChanged(selection: ["A", "B"], added: ["A", "B"]))
        XCTAssertEqual(q.next(), "A")
        XCTAssertNil(q.next(), "1 件ずつ")
        XCTAssertEqual(q.progress?.current, 1)
        XCTAssertEqual(q.progress?.total, 2)
        // 処理中に選び足すと同じまとまりに入る
        q.selectionChanged(selection: ["A", "B", "C"], added: ["C"])
        XCTAssertEqual(q.progress?.total, 3)
        XCTAssertFalse(q.finish("A", counted: true))
        XCTAssertEqual(q.progress?.current, 2)
        XCTAssertEqual(q.next(), "B")
        XCTAssertFalse(q.finish("B", counted: true))
        XCTAssertEqual(q.next(), "C")
        XCTAssertTrue(q.finish("C", counted: true), "まとまりの終わり")
        XCTAssertTrue(q.isIdle)
        XCTAssertNil(q.progress)
        XCTAssertEqual(q.done, 0)
        XCTAssertEqual(q.total, 0)
    }

    func testDeselectDropsPendingAndCancelsInFlight() {
        var q = AutoPrecheckQueue()
        q.selectionChanged(selection: ["A", "B", "C"], added: ["A", "B", "C"])
        XCTAssertEqual(q.next(), "A")
        // 待ちの B を外す → 件数から除く。処理中の A は残る
        XCTAssertFalse(q.selectionChanged(selection: ["A", "C"], added: []))
        XCTAssertEqual(q.pending, ["C"])
        XCTAssertEqual(q.total, 2)
        // 処理中の A を外す → 中止を求める
        XCTAssertTrue(q.selectionChanged(selection: ["C"], added: []))
        q.finish("A", counted: false)
        XCTAssertEqual(q.total, 1)
        XCTAssertEqual(q.next(), "C")
        XCTAssertTrue(q.finish("C", counted: true))
    }

    func testRapidToggleCoalescesAndNoDuplicates() {
        var q = AutoPrecheckQueue()
        q.selectionChanged(selection: ["A"], added: ["A"])
        q.selectionChanged(selection: ["A"], added: ["A"])
        XCTAssertEqual(q.pending, ["A"])
        q.selectionChanged(selection: [], added: [])
        XCTAssertTrue(q.isIdle)
        XCTAssertEqual(q.total, 0)
        // 処理中のものは足し直さない
        q.selectionChanged(selection: ["A"], added: ["A"])
        _ = q.next()
        q.selectionChanged(selection: ["A"], added: ["A"])
        XCTAssertEqual(q.pending, [])
        XCTAssertEqual(q.total, 1)
        // 選択に無い id は足さない
        q.selectionChanged(selection: ["A"], added: ["Z"])
        XCTAssertEqual(q.pending, [])
        q.reset()
        XCTAssertTrue(q.isIdle)
        XCTAssertFalse(q.finish("A", counted: true), "reset 後の完了は無視")
    }

    func testSettledAndDeselectDecisions() {
        func pre(_ d: PlanDecision) -> PrecheckResult { PrecheckResult(localIdentifier: "A", decision: d, md5: "m", error: nil) }
        XCTAssertTrue(AutoPrecheckQueue.isSettled(precheck: pre(.toUpload), result: nil))
        XCTAssertTrue(AutoPrecheckQueue.isSettled(precheck: pre(.duplicateRemote(fileId: "F", name: "n")), result: nil))
        XCTAssertFalse(AutoPrecheckQueue.isSettled(precheck: pre(.duplicateInBatch(ofLocalIdentifier: "B")), result: nil))
        XCTAssertFalse(AutoPrecheckQueue.isSettled(precheck: pre(.notHashed), result: nil))
        XCTAssertFalse(AutoPrecheckQueue.isSettled(precheck: nil, result: nil))
        XCTAssertTrue(AutoPrecheckQueue.isSettled(precheck: nil,
                                                  result: ItemResult(localIdentifier: "A", status: .sent, verified: true)))
        XCTAssertFalse(AutoPrecheckQueue.isSettled(precheck: nil,
                                                   result: ItemResult(localIdentifier: "A", status: .failed, verified: false)))
        XCTAssertTrue(AutoPrecheckQueue.shouldDeselect(.duplicateRemote(fileId: "F", name: "n")))
        XCTAssertTrue(AutoPrecheckQueue.shouldDeselect(.duplicateInBatch(ofLocalIdentifier: "B")))
        XCTAssertFalse(AutoPrecheckQueue.shouldDeselect(.toUpload))
        XCTAssertFalse(AutoPrecheckQueue.shouldDeselect(.notHashed))
    }

    func testTexts() {
        XCTAssertNil(AutoPrecheckText.deselectedBanner(names: []))
        XCTAssertEqual(AutoPrecheckText.deselectedBanner(names: ["IMG_1.HEIC"]), "重複のため選択を外しました: IMG_1.HEIC")
        XCTAssertEqual(AutoPrecheckText.deselectedBanner(names: ["IMG_1.HEIC", "IMG_2.HEIC", "IMG_3.HEIC"]),
                       "重複のため選択を外しました: IMG_1.HEIC（ほか 2 件）")
        XCTAssertEqual(AutoPrecheckText.progress(current: 2, total: 5), "重複を確認中 2/5")
    }

    func testListingSnapshotFreshness() {
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        let s = RemoteListingSnapshot(folderId: "F", index: RemoteIndex(), fetchedAt: t0)
        XCTAssertTrue(s.isUsable(folderId: "F", now: t0))
        XCTAssertTrue(s.isUsable(folderId: "F", now: t0.addingTimeInterval(299)))
        XCTAssertFalse(s.isUsable(folderId: "F", now: t0.addingTimeInterval(300)))
        XCTAssertFalse(s.isUsable(folderId: "G", now: t0), "別フォルダ")
        XCTAssertFalse(s.isUsable(folderId: "F", now: t0.addingTimeInterval(-1)), "時計が戻った")
    }
}

final class AutoPrecheckCheckOneTests: XCTestCase {
    var dir: URL!
    override func setUp() { dir = makeTempDir() }
    override func tearDown() { try? FileManager.default.removeItem(at: dir) }

    func md5(_ d: Data) -> String { Insecure.MD5.hash(data: d).map { String(format: "%02x", $0) }.joined() }

    func item(_ id: String) -> PhotoItem {
        PhotoItem(localIdentifier: id, originalFilename: "\(id).HEIC", uti: "public.heic", mediaKind: .image, creationDate: nil)
    }

    func testRemoteDuplicateAndCacheWrite() async throws {
        let existing = Data("existing".utf8)
        let cache = ResultCache(fileURL: dir.appendingPathComponent("item-cache.json"))
        let exporter = FakeExporter(dir: dir, contents: ["A": existing])
        let remote = RemoteIndex(files: [DriveFile(id: "OLD", name: "OLD.HEIC", md5Checksum: md5(existing))])
        let r = try await DuplicatePrecheck.checkOne(item: item("A"), priorSelected: [], exporter: exporter, remote: remote,
                                                     cache: cache, folderId: "F")
        XCTAssertEqual(r.decision, .duplicateRemote(fileId: "OLD", name: "OLD.HEIC"))
        XCTAssertFalse(r.md5FromCache)
        XCTAssertEqual(cache.entry(for: item("A"))?.lastStatus, .duplicateRemote)
        XCTAssertEqual(cache.entry(for: item("A"))?.md5, md5(existing))

        // 2 回目はキャッシュの MD5 を使い、書き出さない
        let again = try await DuplicatePrecheck.checkOne(item: item("A"), priorSelected: [], exporter: exporter,
                                                         remote: remote, cache: cache, folderId: "F")
        XCTAssertTrue(again.md5FromCache)
        XCTAssertEqual(exporter.calls, ["A"])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path), ["item-cache.json"])
    }

    func testInBatchDuplicateAgainstPriorSelected() async throws {
        let same = Data("same".utf8)
        let cache = ResultCache(fileURL: dir.appendingPathComponent("item-cache.json"))
        let exporter = FakeExporter(dir: dir, contents: ["B": same])
        let prior = [PlanInput(localIdentifier: "A", eligibility: .eligible, md5: md5(same).uppercased()),
                     PlanInput(localIdentifier: "B", eligibility: .eligible, md5: "ignored-self")]
        let r = try await DuplicatePrecheck.checkOne(item: item("B"), priorSelected: prior, exporter: exporter,
                                                     remote: RemoteIndex(), cache: cache, folderId: "F")
        XCTAssertEqual(r.decision, .duplicateInBatch(ofLocalIdentifier: "A"))
        XCTAssertEqual(cache.entry(for: item("B"))?.lastStatus, .checkedNotOnDrive)

        let fresh = try await DuplicatePrecheck.checkOne(item: item("B"), priorSelected: [], exporter: exporter,
                                                         remote: RemoteIndex(), cache: cache, folderId: "F")
        XCTAssertEqual(fresh.decision, .toUpload)
    }

    func testExportFailureIsNotHashed() async throws {
        let r = try await DuplicatePrecheck.checkOne(item: item("X"), priorSelected: [],
                                                     exporter: FakeExporter(dir: dir, contents: [:]), remote: RemoteIndex())
        XCTAssertEqual(r.decision, .notHashed)
        XCTAssertNotNil(r.error)
    }

    func testCancellationThrows() async throws {
        let exporter = FakeExporter(dir: dir, contents: ["A": Data("a".utf8)])
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await DuplicatePrecheck.checkOne(item: self.item("A"), priorSelected: [], exporter: exporter,
                                                        remote: RemoteIndex())
        }
        do {
            _ = try await task.value
            XCTFail("expected cancellation")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertEqual(exporter.calls, [])
    }
}
