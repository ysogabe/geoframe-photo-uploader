import CryptoKit
import XCTest
@testable import UploaderCore

final class SendRunStateTests: XCTestCase {
    func ev(_ i: Int, _ phase: UploadPhase, total: Int = 3, sent: Int64? = nil, of: Int64? = nil) -> UploadEvent {
        UploadEvent(localIdentifier: ["A", "B", "C", "D"][i], index: i, total: total, phase: phase, bytesSent: sent, bytesTotal: of)
    }

    func res(_ id: String, _ status: ItemStatus, error: String? = nil) -> ItemResult {
        var r = ItemResult(localIdentifier: id, status: status, verified: status == .sent)
        r.error = error
        return r
    }

    func testPositionAndRemaining() {
        var s = SendRunState(order: ["A", "B", "C"])
        XCTAssertEqual(s.position, 1)
        XCTAssertEqual(s.remaining, 2)
        XCTAssertEqual(s.headline, "送信中  1 / 3 枚目（残り 2 枚）")
        XCTAssertEqual(s.currentId, "A")
        XCTAssertEqual(s.upcoming(), ["B", "C"])

        XCTAssertTrue(s.apply(ev(0, .exporting)))
        XCTAssertEqual(s.phase, .exporting)
        s.apply(ev(0, .finished(res("A", .sent))))
        // 次のアイテムの最初のイベントまでの間も次を処理中として数える
        XCTAssertNil(s.phase)
        XCTAssertEqual(s.position, 2)
        XCTAssertEqual(s.remaining, 1)
        XCTAssertEqual(s.currentId, "B")
        XCTAssertEqual(s.upcoming(), ["C"])

        // 対象外は .finished だけが来る
        s.apply(ev(1, .finished(res("B", .skippedIneligible))))
        XCTAssertEqual(s.headline, "送信中  3 / 3 枚目（残り 0 枚）")
        XCTAssertEqual(s.upcoming(), [])
        s.apply(ev(2, .finished(res("C", .failed, error: "x"))))
        XCTAssertTrue(s.isComplete)
        XCTAssertNil(s.currentId)
        XCTAssertEqual(s.position, 3)
        XCTAssertEqual(s.remaining, 0)
        XCTAssertEqual(s.tally.sent, 1)
        XCTAssertEqual(s.tally.ineligible, 1)
        XCTAssertEqual(s.tally.failed, 1)
        XCTAssertEqual(s.results.map(\.localIdentifier), ["A", "B", "C"])
    }

    func testExampleFromSpec() {
        let order = (0..<12).map { "I\($0)" }
        var s = SendRunState(order: order)
        for i in 0..<2 {
            s.apply(UploadEvent(localIdentifier: order[i], index: i, total: 12, phase: .finished(res(order[i], .sent))))
        }
        s.apply(UploadEvent(localIdentifier: order[2], index: 2, total: 12, phase: .uploading(fraction: 0.64)))
        XCTAssertEqual(s.headline, "送信中  3 / 12 枚目（残り 9 枚）")
        XCTAssertEqual(s.upcoming(limit: 5), ["I3", "I4", "I5", "I6", "I7"])
    }

    func testUploadingThrottleAndBytes() {
        var s = SendRunState(order: ["A", "B", "C"])
        XCTAssertTrue(s.apply(ev(0, .uploading(fraction: 0), sent: 0, of: 8_000_000)))
        XCTAssertEqual(s.uploadFraction, 0)
        XCTAssertFalse(s.apply(ev(0, .uploading(fraction: 0.001), sent: 8_000, of: 8_000_000)), "表示が変わらない")
        XCTAssertTrue(s.apply(ev(0, .uploading(fraction: 0.6375), sent: 5_100_000, of: 8_000_000)))
        XCTAssertEqual(s.bytesSent, 5_100_000)
        XCTAssertEqual(s.uploadFraction!, 0.6375, accuracy: 1e-9)
        XCTAssertTrue(s.apply(ev(0, .verifying)))
        XCTAssertNil(s.uploadFraction)
        XCTAssertNil(s.bytesSent)
        // 終わったアイテムの遅れたイベントは無視
        s.apply(ev(0, .finished(res("A", .sent))))
        XCTAssertFalse(s.apply(ev(0, .verifying)))
        XCTAssertNil(s.phase)
    }

    func testTallyCancelled() {
        var cancelled = res("C", .failed)
        cancelled.error = UploadCoordinator.cancelledMessage
        let t = RunTally([res("A", .sent), res("B", .skippedDuplicate), cancelled, res("D", .failed, error: "e")])
        XCTAssertEqual(t.sent, 1)
        XCTAssertEqual(t.duplicate, 1)
        XCTAssertEqual(t.failed, 1)
        XCTAssertEqual(t.cancelled, 1)
        XCTAssertEqual(t.processed, 3)
    }

    func testEmptyRun() {
        let s = SendRunState(order: [])
        XCTAssertEqual(s.position, 0)
        XCTAssertEqual(s.remaining, 0)
        XCTAssertNil(s.currentId)
        XCTAssertTrue(s.isComplete)
    }

    func testTexts() {
        XCTAssertEqual(UploadPhaseText.bytes(sent: 5_100_000, total: 8_000_000), "5.1 / 8.0 MB")
        XCTAssertEqual(UploadPhaseText.bytes(sent: 9_000_000, total: 8_000_000), "8.0 / 8.0 MB")
        XCTAssertEqual(UploadPhaseText.bytes(sent: 250_000, total: 600_000), "250 / 600 KB")
        XCTAssertEqual(UploadPhaseText.label(.uploading(fraction: 0.649)), "Google ドライブへ送信中 64%")
        XCTAssertEqual(UploadPhaseText.label(.verifying), "Drive で md5 を照合中")
        XCTAssertEqual(UploadPhaseText.label(.checkingDuplicate), "重複を確認中")
        XCTAssertEqual(UploadPhaseText.label(nil), "準備中…")
        XCTAssertEqual(UploadPhaseText.percent(1.5), 100)
        XCTAssertEqual(UploadPhaseText.percent(-1), 0)
    }
}

/// 送信中のイベントにバイト数が載ること（UploadCoordinator 経由）。
final class UploadEventBytesTests: XCTestCase {
    var dir: URL!
    override func setUp() { dir = makeTempDir() }
    override func tearDown() { try? FileManager.default.removeItem(at: dir) }

    func testUploadingEventsCarryBytes() async throws {
        let fake = FakeDrive(files: [])
        StubProtocol.setHandler(fake.handle)
        let drive = DriveClient(session: StubProtocol.session(), tokens: FakeTokens(), sleeper: noSleep)
        let data = Data("hello world".utf8)
        let c = UploadCoordinator(drive: drive, exporter: FakeExporter(dir: dir, contents: ["A": data]), records: nil,
                                  options: .init(verifyAttempts: 1, verifyDelay: 0), sleeper: noSleep)
        let events = EventBox()
        let item = PhotoItem(localIdentifier: "A", originalFilename: "A.HEIC", uti: "public.heic", mediaKind: .image,
                             creationDate: nil)
        let s = try await c.run(items: [item], folderId: "FOLDER", maxItemsPerRun: 1) { events.add($0) }
        XCTAssertEqual(s.results.first?.status, .sent)
        let uploading = events.all.filter { if case .uploading = $0.phase { return true } else { return false } }
        XCTAssertFalse(uploading.isEmpty)
        XCTAssertTrue(uploading.allSatisfy { $0.bytesTotal == Int64(data.count) })
        XCTAssertEqual(uploading.first?.bytesSent, 0)
        XCTAssertEqual(uploading.last?.bytesSent, Int64(data.count))
        // 他の段階にはバイト数を載せない
        XCTAssertTrue(events.all.filter { $0.phase == .verifying }.allSatisfy { $0.bytesSent == nil })
    }
}
