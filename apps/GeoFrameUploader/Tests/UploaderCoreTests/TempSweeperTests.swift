import XCTest
@testable import UploaderCore

final class TempSweeperTests: XCTestCase {
    var root: URL!
    var outside: URL!
    override func setUp() { root = makeTempDir(); outside = makeTempDir() }
    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
        try? FileManager.default.removeItem(at: outside)
    }

    let now = Date()

    func makeDir(_ name: String, age: TimeInterval) throws -> URL {
        let u = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: u.appendingPathComponent("IMG.HEIC"))
        // 中身を作った後に更新日時を設定する
        try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-age)], ofItemAtPath: u.path)
        return u
    }

    func exists(_ u: URL) -> Bool { FileManager.default.fileExists(atPath: u.path) }

    func testRemovesOnlyStaleOwnedPrefixedUUIDDirectories() throws {
        let p = OriginalExporter.tempDirPrefix
        let stale = try makeDir("\(p)\(UUID().uuidString)", age: 2 * 3600)
        let fresh = try makeDir("\(p)\(UUID().uuidString)", age: 60)
        let otherPrefix = try makeDir("Other-\(UUID().uuidString)", age: 2 * 3600)
        let notUUID = try makeDir("\(p)keep-me", age: 2 * 3600)
        // 接頭辞 + UUID のファイル（ディレクトリではない）
        let file = root.appendingPathComponent("\(p)\(UUID().uuidString)")
        try Data("f".utf8).write(to: file)
        try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-7200)], ofItemAtPath: file.path)
        // 接頭辞 + UUID のシンボリックリンク → 外の古いディレクトリ（辿らない・消さない）
        let target = outside.appendingPathComponent("target", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try Data("t".utf8).write(to: target.appendingPathComponent("precious"))
        try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-7200)], ofItemAtPath: target.path)
        let link = root.appendingPathComponent("\(p)\(UUID().uuidString)")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        // 古いディレクトリの中にある、外を指すシンボリックリンク（リンクだけ消え、リンク先は残る）
        try FileManager.default.createSymbolicLink(at: stale.appendingPathComponent("link"), withDestinationURL: target)
        try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-7200)], ofItemAtPath: stale.path)

        let removed = TempSweeper.sweepStale(root: root, olderThan: 3600, now: now)

        XCTAssertEqual(removed.map(\.lastPathComponent), [stale.lastPathComponent])
        XCTAssertFalse(exists(stale))
        XCTAssertTrue(exists(fresh))
        XCTAssertTrue(exists(otherPrefix))
        XCTAssertTrue(exists(notUUID))
        XCTAssertTrue(exists(file))
        XCTAssertNotNil(try? FileManager.default.destinationOfSymbolicLink(atPath: link.path))
        XCTAssertTrue(exists(target.appendingPathComponent("precious")))
    }

    func testMissingRootIsNoop() {
        XCTAssertEqual(TempSweeper.sweepStale(root: root.appendingPathComponent("nope"), now: now), [])
    }
}
