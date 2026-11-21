import CryptoKit
import Foundation

/// 前回までの結果（キャッシュ上の状態）。
public enum CachedStatus: String, Codable, Sendable {
    /// 送信して検証まで通った
    case sent
    /// Drive に同じ内容のファイルが既にあった
    case duplicateRemote
    /// 重複確認で Drive に無いと分かった（未送信）
    case checkedNotOnDrive
    /// 送信に失敗した
    case failed
}

/// item-cache.json の 1 エントリ（キーは localIdentifier）。
public struct CacheEntry: Codable, Sendable, Equatable {
    public var originalFilename: String?
    public var uti: String?
    public var md5: String?
    public var sha256: String?
    public var byteCount: Int64?
    public var hashedAt: Date?
    public var lastStatus: CachedStatus?
    /// 送信したファイル、または一致した既存ファイルの Drive ID
    public var driveFileId: String?
    public var statusAt: Date?
    public var folderId: String?

    public init(originalFilename: String?, uti: String?, md5: String? = nil, sha256: String? = nil, byteCount: Int64? = nil,
                hashedAt: Date? = nil, lastStatus: CachedStatus? = nil, driveFileId: String? = nil, statusAt: Date? = nil,
                folderId: String? = nil) {
        self.originalFilename = originalFilename; self.uti = uti; self.md5 = md5; self.sha256 = sha256
        self.byteCount = byteCount; self.hashedAt = hashedAt; self.lastStatus = lastStatus
        self.driveFileId = driveFileId; self.statusAt = statusAt; self.folderId = folderId
    }

    /// 原本ファイル名と UTI が一致するときだけ有効。
    public func matches(_ item: PhotoItem) -> Bool {
        originalFilename == item.originalFilename && uti == item.uti
    }

    /// 最後に更新された日時（ハッシュか状態の新しい方）
    var latest: Date? {
        switch (hashedAt, statusAt) {
        case let (h?, s?): return max(h, s)
        case let (h, s): return h ?? s
        }
    }

    /// 状態が `folderId` のフォルダについてのものか（どちらかが不明なら真）。
    public func statusApplies(toFolder folderId: String?) -> Bool {
        guard let mine = self.folderId, let folderId else { return true }
        return mine == folderId
    }
}

/// 写真ごとの MD5 と前回の結果を覚える永続キャッシュ（`item-cache.json`、0600、アトミック書き込み）。
/// Drive の一覧が重複判定の正であり、ここは「書き出しを省くための MD5」と「前回の結果の表示」にだけ使う。
public final class ResultCache: @unchecked Sendable {
    public let fileURL: URL
    private let lock = NSLock()
    private var entries: [String: CacheEntry] = [:]
    private let log: @Sendable (String) -> Void
    /// 読み込み時に壊れていたファイルの退避先（無ければ nil）
    public private(set) var corruptBackupURL: URL?

    private let records: RecordStore?
    private var watermark: RecordsWatermark?

    /// records.jsonl をどこまで取り込んだか（追記専用なので、バイト位置 + ファイルの同一性 + 直前の末尾の MD5）。
    public struct RecordsWatermark: Codable, Sendable, Equatable {
        public var byteOffset: UInt64
        public var fileNumber: UInt64
        public var deviceNumber: UInt64
        /// `byteOffset` 直前の最大 256 バイトの MD5（同じ inode のまま書き換えられたことの検出用）
        public var tailMD5: String
    }

    private struct FileFormat: Codable {
        var version: Int
        var entries: [String: CacheEntry]
        var recordsImportedThrough: RecordsWatermark?
    }

    /// `fileURL` を読み込み、`records`（records.jsonl）の未取り込み分を取り込む（ファイルが無ければ全件）。
    /// 壊れたファイルは `.corrupt-<timestamp>` に退避し、records.jsonl から作り直す。
    public init(fileURL: URL, records: RecordStore? = nil, log: @escaping @Sendable (String) -> Void = { _ in }) {
        self.fileURL = fileURL
        self.records = records
        self.log = log
        if FileManager.default.fileExists(atPath: fileURL.path) {
            do {
                let f = try Self.decoder.decode(FileFormat.self, from: Data(contentsOf: fileURL))
                entries = f.entries
                watermark = f.recordsImportedThrough
            } catch {
                corruptBackupURL = Self.backupCorrupt(fileURL)
                log("item-cache.json を読めないため作り直します（退避: \(corruptBackupURL?.lastPathComponent ?? "失敗")）")
            }
        }
        if importNewRecordsLocked() { saveLocked() }
    }

    /// 他のプロセス（CLI / 古いビルドのアプリ）が書いた item-cache.json と records.jsonl の追記分を取り込む。
    /// 読み込み直後の表示・重複確認・送信・scan の前に呼ぶ。冪等。
    public func refresh() {
        lock.withLock {
            let merged = mergeFromDiskLocked()
            if importNewRecordsLocked() || merged { saveLocked() }
        }
    }

    /// 取り込み位置（テスト・診断用）
    public var recordsWatermark: RecordsWatermark? { lock.withLock { watermark } }

    // MARK: 参照

    public var count: Int { lock.withLock { entries.count } }

    /// 原本ファイル名と UTI が一致するエントリだけを返す。
    public func entry(for item: PhotoItem) -> CacheEntry? {
        lock.withLock {
            guard let e = entries[item.localIdentifier], e.matches(item) else { return nil }
            return e
        }
    }

    public func entries(for items: [PhotoItem]) -> [String: CacheEntry] {
        lock.withLock {
            var out: [String: CacheEntry] = [:]
            for it in items { if let e = entries[it.localIdentifier], e.matches(it) { out[it.localIdentifier] = e } }
            return out
        }
    }

    /// 有効なキャッシュの MD5（無ければ nil）。
    public func cachedMD5(for item: PhotoItem) -> String? {
        guard let m = entry(for: item)?.md5, !m.isEmpty else { return nil }
        return m.lowercased()
    }

    // MARK: 更新

    /// 書き出して計算したハッシュを記録する。MD5 が変わっていれば状態も消す（別の内容とみなす）。
    public func recordHash(item: PhotoItem, md5: String, sha256: String?, byteCount: Int64?, at date: Date = Date()) {
        lock.withLock {
            var e = validOrFresh(item)
            if let old = e.md5, old.lowercased() != md5.lowercased() {
                e.lastStatus = nil; e.driveFileId = nil; e.statusAt = nil; e.folderId = nil
            }
            e.md5 = md5.lowercased(); e.sha256 = sha256; e.byteCount = byteCount; e.hashedAt = date
            entries[item.localIdentifier] = e
            saveLocked()
        }
    }

    /// 結果を記録する。`md5` を渡すとハッシュも更新する。
    public func recordStatus(item: PhotoItem, status: CachedStatus, driveFileId: String?, folderId: String?,
                             md5: String? = nil, sha256: String? = nil, byteCount: Int64? = nil, at date: Date = Date()) {
        lock.withLock {
            applyStatus(item: item, status: status, driveFileId: driveFileId, folderId: folderId,
                        md5: md5, sha256: sha256, byteCount: byteCount, at: date)
            saveLocked()
        }
    }

    public struct StatusUpdate: Sendable {
        public var item: PhotoItem
        public var status: CachedStatus
        public var driveFileId: String?
        public var folderId: String?
        public init(item: PhotoItem, status: CachedStatus, driveFileId: String?, folderId: String?) {
            self.item = item; self.status = status; self.driveFileId = driveFileId; self.folderId = folderId
        }
    }

    /// まとめて記録して 1 回だけ保存する。
    public func recordStatuses(_ updates: [StatusUpdate], at date: Date = Date()) {
        guard !updates.isEmpty else { return }
        lock.withLock {
            for u in updates {
                applyStatus(item: u.item, status: u.status, driveFileId: u.driveFileId, folderId: u.folderId,
                            md5: nil, sha256: nil, byteCount: nil, at: date)
            }
            saveLocked()
        }
    }

    // MARK: 内部（lock 保持中に呼ぶ）

    private func validOrFresh(_ item: PhotoItem) -> CacheEntry {
        if let e = entries[item.localIdentifier], e.matches(item) { return e }
        return CacheEntry(originalFilename: item.originalFilename, uti: item.uti)
    }

    private func applyStatus(item: PhotoItem, status: CachedStatus, driveFileId: String?, folderId: String?,
                             md5: String?, sha256: String?, byteCount: Int64?, at date: Date) {
        var e = validOrFresh(item)
        let md5Changed = md5.map { m in e.md5.map { $0.lowercased() != m.lowercased() } ?? false } ?? false
        if let md5 {
            e.md5 = md5.lowercased(); e.hashedAt = date
            if let sha256 { e.sha256 = sha256 }
            if let byteCount { e.byteCount = byteCount }
        }
        if !md5Changed, Self.keepsSent(e, incoming: status, driveFileId: driveFileId) {
            entries[item.localIdentifier] = e
            return
        }
        e.lastStatus = status
        e.driveFileId = driveFileId
        e.statusAt = date
        e.folderId = folderId
        entries[item.localIdentifier] = e
    }

    /// 自分で送ったファイルを後で「Drive に既存」と見つけたときは `sent` のまま残す。
    static func keepsSent(_ e: CacheEntry, incoming: CachedStatus, driveFileId: String?) -> Bool {
        guard e.lastStatus == .sent, incoming == .duplicateRemote else { return false }
        return driveFileId == nil || driveFileId == e.driveFileId
    }

    /// ディスク上の内容とエントリ単位でマージする（新しい方が勝つ。同時刻ならメモリ側）。変化があれば真。
    @discardableResult
    private func mergeFromDiskLocked() -> Bool {
        guard let data = try? Data(contentsOf: fileURL),
              let disk = try? Self.decoder.decode(FileFormat.self, from: data) else { return false }
        var changed = false
        for (id, d) in disk.entries {
            if let m = entries[id] {
                if (d.latest ?? .distantPast) > (m.latest ?? .distantPast) { entries[id] = d; changed = true }
            } else {
                entries[id] = d; changed = true
            }
        }
        // 相手の方が先まで取り込んでいれば（そのエントリはマージ済み）その位置を使う
        if let dw = disk.recordsImportedThrough {
            if let w = watermark {
                if dw.fileNumber == w.fileNumber, dw.deviceNumber == w.deviceNumber, dw.byteOffset > w.byteOffset {
                    watermark = dw
                }
            } else {
                watermark = dw
            }
        }
        if disk.recordsImportedThrough != watermark { changed = true }
        return changed
    }

    /// records.jsonl の未取り込み分を取り込む。位置が使えない（縮んだ・置き換わった）ときは先頭から取り込み直す。
    /// 変化があれば真。
    private func importNewRecordsLocked() -> Bool {
        guard let records else { return false }
        let url = records.fileURL
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let fh = try? FileHandle(forReadingFrom: url) else {
            return false
        }
        defer { try? fh.close() }
        let size = (attrs[.size] as? NSNumber)?.uint64Value ?? 0
        let ino = (attrs[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
        let dev = (attrs[.systemNumber] as? NSNumber)?.uint64Value ?? 0

        var start: UInt64 = 0
        if let w = watermark, w.fileNumber == ino, w.deviceNumber == dev, w.byteOffset <= size,
           Self.tailMD5(fh, end: w.byteOffset) == w.tailMD5 {
            start = w.byteOffset
        } else if watermark != nil {
            log("records.jsonl が置き換わったか縮んだため、先頭から取り込み直します")
        }
        if start == size, watermark != nil, watermark?.byteOffset == start { return false }

        let data: Data
        do {
            try fh.seek(toOffset: start)
            data = try fh.readToEnd() ?? Data()
        } catch {
            log("records.jsonl を読めませんでした: \(error.localizedDescription)")
            return false
        }
        // 改行で終わる行だけを取り込む（書き込み途中の行は次回）
        guard let lastNL = data.lastIndex(of: 0x0A) else {
            let w = RecordsWatermark(byteOffset: start, fileNumber: ino, deviceNumber: dev, tailMD5: Self.tailMD5(fh, end: start))
            defer { watermark = w }
            return watermark != w
        }
        let complete = data[data.startIndex...lastNL]
        let before = entries
        var touched = Set<String>()
        let dec = JSONDecoder()
        let iso = ISO8601DateFormatter()
        for line in complete.split(separator: 0x0A) {
            guard let r = try? dec.decode(UploadRecord.self, from: Data(line)) else { continue }
            Self.apply(r, to: &entries, touched: &touched, iso: iso)
        }
        let end = start + UInt64(complete.count)
        let w = RecordsWatermark(byteOffset: end, fileNumber: ino, deviceNumber: dev, tailMD5: Self.tailMD5(fh, end: end))
        let changed = entries != before || watermark != w
        watermark = w
        return changed
    }

    static func tailMD5(_ fh: FileHandle, end: UInt64) -> String {
        let begin = end > 256 ? end - 256 : 0
        guard (try? fh.seek(toOffset: begin)) != nil,
              let d = try? fh.read(upToCount: Int(end - begin)) ?? Data() else { return "" }
        return hexString(Insecure.MD5.hash(data: d))
    }

    private func saveLocked() {
        // 他のインスタンスが書いた分を失わないよう、保存直前にディスクの内容とマージする
        mergeFromDiskLocked()
        do {
            let data = try Self.encoder.encode(FileFormat(version: 1, entries: entries, recordsImportedThrough: watermark))
            try Self.atomicWrite0600(data, to: fileURL)
        } catch {
            log("item-cache.json を保存できませんでした: \(error.localizedDescription)")
        }
    }

    // MARK: 保存・退避

    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    /// 同じディレクトリに 0600 で一時ファイルを作り、rename で置き換える。
    static func atomicWrite0600(_ data: Data, to url: URL) throws {
        let dir = url.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: dir.path) {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
        }
        let tmp = dir.appendingPathComponent(".\(url.lastPathComponent).tmp-\(UUID().uuidString)")
        let fd = open(tmp.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw DriveError.fileIO("item-cache.json: \(String(cString: strerror(errno)))") }
        var ok = false
        defer { if !ok { unlink(tmp.path) } }
        do {
            defer { close(fd) }
            _ = fchmod(fd, 0o600)
            try data.withUnsafeBytes { (buf: UnsafeRawBufferPointer) in
                var off = 0
                while off < buf.count {
                    let n = write(fd, buf.baseAddress! + off, buf.count - off)
                    if n < 0 {
                        if errno == EINTR { continue }
                        throw DriveError.fileIO("item-cache.json: \(String(cString: strerror(errno)))")
                    }
                    off += n
                }
            }
            _ = fsync(fd)
        }
        guard rename(tmp.path, url.path) == 0 else {
            throw DriveError.fileIO("item-cache.json: \(String(cString: strerror(errno)))")
        }
        ok = true
    }

    private static func backupCorrupt(_ url: URL) -> URL? {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd'T'HHmmss"
        var dest = url.deletingLastPathComponent().appendingPathComponent("\(url.lastPathComponent).corrupt-\(f.string(from: Date()))")
        if FileManager.default.fileExists(atPath: dest.path) {
            dest = dest.deletingLastPathComponent().appendingPathComponent("\(dest.lastPathComponent)-\(UUID().uuidString.prefix(8))")
        }
        return rename(url.path, dest.path) == 0 ? dest : nil
    }

    // MARK: records.jsonl の取り込み

    /// 記録 1 行を適用する。エントリより新しい記録だけが勝つ（同じ取り込み中に触れたエントリは同時刻も可）ので、
    /// このプロセスが直接反映済みの記録を取り込み直しても結果は変わらない。md5 の無い記録で md5 を消さない。
    static func apply(_ r: UploadRecord, to out: inout [String: CacheEntry], touched: inout Set<String>,
                      iso: ISO8601DateFormatter) {
        let date = iso.date(from: r.recordedAt) ?? .distantPast
        let id = r.localIdentifier
        let inPass = touched.contains(id)
        func newer(_ t: Date?) -> Bool {
            guard let t else { return true }
            return inPass ? date >= t : date > t
        }
        let fresh = CacheEntry(originalFilename: r.originalFilename, uti: r.uti)
        var e = out[id] ?? fresh
        if e.originalFilename != r.originalFilename || e.uti != r.uti {
            guard newer(e.latest) else { return }
            e = fresh
        }
        let md5 = r.md5.flatMap { $0.isEmpty ? nil : $0.lowercased() }
        if let md5 {
            if let old = e.md5, old != md5 {
                guard newer(e.latest) else { return }   // 古い記録は別の内容についてのもの
                e.lastStatus = nil; e.driveFileId = nil; e.statusAt = nil; e.folderId = nil
                e.md5 = md5; e.sha256 = r.sha256; e.byteCount = r.byteCount; e.hashedAt = date
            } else if e.md5 == nil || newer(e.hashedAt) {
                e.md5 = md5
                e.sha256 = r.sha256 ?? e.sha256
                e.byteCount = r.byteCount ?? e.byteCount
                e.hashedAt = date
            }
        }
        let status: CachedStatus?
        var fileId: String?
        switch r.result {
        case .sent:
            status = r.verified ? .sent : .failed; fileId = r.driveFileId
        case .skippedDuplicate:
            status = .duplicateRemote; fileId = r.driveFileId
        case .failed:
            // 中止は失敗として扱わない。md5 の無い失敗は状態を残さない
            status = (r.error == UploadCoordinator.cancelledMessage || md5 == nil) ? nil : .failed
            fileId = r.driveFileId
        case .skippedIneligible:
            status = nil
        }
        if let status, newer(e.statusAt), !keepsSent(e, incoming: status, driveFileId: fileId) {
            if status == .duplicateRemote, fileId == nil, e.lastStatus == .duplicateRemote { fileId = e.driveFileId }
            e.lastStatus = status; e.driveFileId = fileId; e.statusAt = date; e.folderId = r.folderId
        }
        if e.md5 != nil || e.lastStatus != nil, out[id] != e {
            out[id] = e
            touched.insert(id)
        }
    }
}
