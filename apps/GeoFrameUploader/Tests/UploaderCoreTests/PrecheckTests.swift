import CryptoKit
import XCTest
@testable import UploaderCore

final class PrecheckTests: XCTestCase {
    var dir: URL!
    override func setUp() { dir = makeTempDir() }
    override func tearDown() { try? FileManager.default.removeItem(at: dir) }

    func md5(_ d: Data) -> String { Insecure.MD5.hash(data: d).map { String(format: "%02x", $0) }.joined() }

    func item(_ id: String, uti: String = "public.heic") -> PhotoItem {
        PhotoItem(localIdentifier: id, originalFilename: "\(id).HEIC", uti: uti, mediaKind: .image, creationDate: Date())
    }

    func testDecisionsAndTempCleanup() async throws {
        let existing = Data("existing".utf8), fresh = Data("fresh".utf8)
        let remote = RemoteIndex(files: [DriveFile(id: "OLD", name: "OLD.HEIC", md5Checksum: md5(existing))])
        let exporter = FakeExporter(dir: dir, contents: ["A": existing, "B": fresh, "C": fresh])
        let items = [item("A"), item("B"), item("C"), item("D", uti: "com.adobe.raw-image"), item("E")]
        let progress = PrecheckProgressBox()
        let r = try await DuplicatePrecheck.run(items: items, exporter: exporter, remote: remote) { progress.add($0, $1) }

        XCTAssertEqual(r.map(\.localIdentifier), ["A", "B", "C", "D", "E"])
        XCTAssertEqual(r[0].decision, .duplicateRemote(fileId: "OLD", name: "OLD.HEIC"))
        XCTAssertEqual(r[1].decision, .toUpload)
        XCTAssertEqual(r[1].md5, md5(fresh))
        XCTAssertEqual(r[2].decision, .duplicateInBatch(ofLocalIdentifier: "B"))
        XCTAssertEqual(r[3].decision, .ineligible(reason: "DNG（geoframe 非対応）"))
        XCTAssertNil(r[3].md5)
        XCTAssertEqual(r[4].decision, .notHashed)
        XCTAssertNotNil(r[4].error)
        XCTAssertEqual(progress.values.last?.0, 5)
        XCTAssertEqual(progress.values.count, 6)
        // 書き出した一時ファイルは残さない
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path), [])
    }

    func testCancellationThrows() async throws {
        let exporter = FakeExporter(dir: dir, contents: ["A": Data("a".utf8)])
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await DuplicatePrecheck.run(items: [item("A")], exporter: exporter, remote: RemoteIndex())
        }
        do {
            _ = try await task.value
            XCTFail("expected cancellation")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
    }

    func testCancelledResultFlag() {
        var r = ItemResult(localIdentifier: "A", status: .failed, verified: false)
        r.error = UploadCoordinator.cancelledMessage
        XCTAssertTrue(r.wasCancelled)
        r.error = "アップロード失敗: x"
        XCTAssertFalse(r.wasCancelled)
    }
}

final class PrecheckProgressBox: @unchecked Sendable {
    private let lock = NSLock()
    private var v: [(Int, Int)] = []
    func add(_ a: Int, _ b: Int) { lock.lock(); v.append((a, b)); lock.unlock() }
    var values: [(Int, Int)] { lock.lock(); defer { lock.unlock() }; return v }
}
