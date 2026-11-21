import Foundation

public enum UploadPhase: Sendable, Equatable {
    case exporting
    case checkingDuplicate
    case uploading(fraction: Double)
    case verifying
    case finished(ItemResult)
}

public struct UploadEvent: Sendable, Equatable {
    public let localIdentifier: String
    public let index: Int
    public let total: Int
    public let phase: UploadPhase
    /// `.uploading` のときの送信済みバイト数 / 全体のバイト数（分かるときだけ）
    public var bytesSent: Int64? = nil
    public var bytesTotal: Int64? = nil

    public init(localIdentifier: String, index: Int, total: Int, phase: UploadPhase,
                bytesSent: Int64? = nil, bytesTotal: Int64? = nil) {
        self.localIdentifier = localIdentifier; self.index = index; self.total = total; self.phase = phase
        self.bytesSent = bytesSent; self.bytesTotal = bytesTotal
    }
}

public enum ItemStatus: String, Codable, Sendable {
    case sent
    case skippedDuplicate = "skipped_duplicate"
    case skippedIneligible = "skipped_ineligible"
    case failed

    var record: RecordResult {
        switch self {
        case .sent: return .sent
        case .skippedDuplicate: return .skippedDuplicate
        case .skippedIneligible: return .skippedIneligible
        case .failed: return .failed
        }
    }
}

public struct ItemResult: Codable, Sendable, Equatable {
    public var localIdentifier: String
    public var originalFilename: String?
    public var status: ItemStatus
    public var md5: String?
    public var sha256: String?
    public var byteCount: Int64?
    public var dataSource: DataSource?
    public var driveFileId: String?
    public var driveMd5Checksum: String?
    public var verified: Bool
    /// 重複時: 一致した Drive ファイル ID / 同一バッチ内の先行 localIdentifier
    public var duplicateOfFileId: String?
    public var duplicateOfLocalIdentifier: String?
    public var error: String?
    /// md5 / sha256 / byteCount を item-cache.json から取った（原本を書き出していない）
    public var md5FromCache: Bool = false

    /// 中止により処理が打ち切られたアイテム（status は `.failed` のまま）。
    public var wasCancelled: Bool { status == .failed && error == UploadCoordinator.cancelledMessage }
}

public struct RunSummary: Codable, Sendable {
    public var runId: String
    public var folderId: String
    public var remoteFileCount: Int
    public var results: [ItemResult]
    public var cancelled: Bool

    public var sentCount: Int { results.filter { $0.status == .sent }.count }
    public var failedCount: Int { results.filter { $0.status == .failed }.count }
}

public enum UploadCoordinatorError: Error, LocalizedError, Equatable {
    case tooManyItems(selected: Int, max: Int)
    public var errorDescription: String? {
        switch self {
        case .tooManyItems(let s, let m): return "選択が \(s) 件あり、1 回の上限 \(m) 件を超えています"
        }
    }
}

/// 逐次・キャンセル可能なアップロード実行。
public final class UploadCoordinator: @unchecked Sendable {
    public struct Options: Sendable {
        public var verifyAttempts: Int
        public var verifyDelay: TimeInterval
        public init(verifyAttempts: Int = 5, verifyDelay: TimeInterval = 2) {
            self.verifyAttempts = verifyAttempts; self.verifyDelay = verifyDelay
        }
    }

    private let drive: DriveClient
    private let exporter: OriginalExporting
    private let records: RecordStore?
    private let cache: ResultCache?
    private let options: Options
    private let sleep: Sleeper
    private let log: @Sendable (String) -> Void

    public init(drive: DriveClient, exporter: OriginalExporting, records: RecordStore?, cache: ResultCache? = nil,
                options: Options = Options(),
                sleeper: @escaping Sleeper = defaultSleeper, log: @escaping @Sendable (String) -> Void = { _ in }) {
        self.drive = drive
        self.exporter = exporter
        self.records = records
        self.cache = cache
        self.options = options
        self.sleep = sleeper
        self.log = log
    }

    /// `items` を順に処理する。`items.count > maxItemsPerRun` なら何もせずエラー。
    public func run(items: [PhotoItem], folderId: String, maxItemsPerRun: Int,
                    onEvent: (@Sendable (UploadEvent) -> Void)? = nil) async throws -> RunSummary {
        guard items.count <= maxItemsPerRun else {
            throw UploadCoordinatorError.tooManyItems(selected: items.count, max: maxItemsPerRun)
        }
        let runId = UUID().uuidString
        // 他のプロセスが追記した records.jsonl / item-cache.json を先に取り込む
        cache?.refresh()
        // 実行開始時点のフォルダ一覧（新鮮な md5 集合）
        var remote = RemoteIndex(files: try await drive.listFolderFiles(folderId: folderId))
        let remoteCount = remote.count
        log("run \(runId): remote md5 count = \(remoteCount)")
        var inBatch: [String: String] = [:]   // md5 → localIdentifier
        var results: [ItemResult] = []
        var cancelled = false

        for (i, item) in items.enumerated() {
            if Task.isCancelled { cancelled = true; break }
            let emit: @Sendable (UploadPhase, (Int64, Int64)?) -> Void = { phase, bytes in
                onEvent?(UploadEvent(localIdentifier: item.localIdentifier, index: i, total: items.count, phase: phase,
                                     bytesSent: bytes?.0, bytesTotal: bytes?.1))
            }
            let (result, exported) = await process(item: item, folderId: folderId, remote: &remote,
                                                   inBatch: &inBatch, emit: emit)
            exported?.remove()
            var record = UploadRecord(runId: runId, item: item, exported: exported, result: result.status.record,
                                      driveFileId: result.driveFileId, driveMd5Checksum: result.driveMd5Checksum,
                                      verified: result.verified, error: result.error, folderId: folderId)
            if exported == nil && result.md5FromCache {
                record.md5 = result.md5; record.sha256 = result.sha256; record.byteCount = result.byteCount
            }
            do {
                try records?.append(record)
            } catch {
                log("failed to append record: \(error.localizedDescription)")
            }
            updateCache(item: item, result: result, remote: remote, folderId: folderId)
            results.append(result)
            emit(.finished(result), nil)
            if result.error == Self.cancelledMessage { cancelled = true; break }
        }
        return RunSummary(runId: runId, folderId: folderId, remoteFileCount: remoteCount, results: results, cancelled: cancelled)
    }

    public static let cancelledMessage = "キャンセルされました"

    /// 1 件の結果を item-cache.json に反映する（中止は失敗として残さない）。
    private func updateCache(item: PhotoItem, result r: ItemResult, remote: RemoteIndex, folderId: String) {
        guard let cache, r.status != .skippedIneligible else { return }
        let freshHash = r.md5FromCache ? nil : r.md5
        switch r.status {
        case .sent where r.verified:
            cache.recordStatus(item: item, status: .sent, driveFileId: r.driveFileId, folderId: folderId,
                               md5: freshHash, sha256: r.sha256, byteCount: r.byteCount)
        case .skippedDuplicate:
            // 同一実行内の先行写真との重複は、先行写真が Drive に載った（一覧に入った）ときだけ「Drive に既存」
            let fid = r.duplicateOfFileId ?? r.md5.flatMap { remote.lookup($0)?.id }
            if r.duplicateOfFileId != nil || fid != nil {
                cache.recordStatus(item: item, status: .duplicateRemote, driveFileId: (fid?.isEmpty ?? true) ? nil : fid,
                                   folderId: folderId, md5: freshHash, sha256: r.sha256, byteCount: r.byteCount)
            } else if let m = freshHash {
                cache.recordHash(item: item, md5: m, sha256: r.sha256, byteCount: r.byteCount)
            }
        case .sent, .failed:
            if r.wasCancelled || Task.isCancelled {
                if let m = freshHash { cache.recordHash(item: item, md5: m, sha256: r.sha256, byteCount: r.byteCount) }
            } else {
                cache.recordStatus(item: item, status: .failed, driveFileId: r.driveFileId, folderId: folderId,
                                   md5: freshHash, sha256: r.sha256, byteCount: r.byteCount)
            }
        case .skippedIneligible:
            break
        }
    }

    private func process(item: PhotoItem, folderId: String, remote: inout RemoteIndex,
                         inBatch: inout [String: String], emit: @escaping @Sendable (UploadPhase, (Int64, Int64)?) -> Void) async -> (ItemResult, ExportedOriginal?) {
        var r = ItemResult(localIdentifier: item.localIdentifier, originalFilename: item.originalFilename, status: .failed,
                           verified: false)
        guard case .eligible = item.eligibility, let mime = item.mimeType else {
            r.status = .skippedIneligible
            r.error = item.eligibility.reason ?? "形式非対応"
            return (r, nil)
        }

        // キャッシュの MD5 が実行開始時点の Drive 一覧（または同一実行内の先行写真）にあれば、書き出さずに重複とする。
        // 無ければ通常どおり書き出す（送るにはバイト列が要る）。
        if let cached = cache?.entry(for: item), let cmd5 = cached.md5?.lowercased(), !cmd5.isEmpty {
            let first = inBatch[cmd5]
            let hit = remote.lookup(cmd5)
            if first != nil || hit != nil {
                emit(.checkingDuplicate, nil)
                r.md5 = cmd5; r.sha256 = cached.sha256; r.byteCount = cached.byteCount; r.md5FromCache = true
                r.status = .skippedDuplicate
                if let first { r.duplicateOfLocalIdentifier = first } else { r.duplicateOfFileId = hit?.id }
                return (r, nil)
            }
        }

        emit(.exporting, nil)
        let exp: ExportedOriginal
        do { exp = try await exporter.export(localIdentifier: item.localIdentifier) } catch {
            r.error = error is CancellationError ? Self.cancelledMessage : "原本の取得に失敗: \(error.localizedDescription)"
            return (r, nil)
        }
        r.md5 = exp.md5Hex; r.sha256 = exp.sha256Hex; r.byteCount = exp.byteCount; r.dataSource = exp.dataSource

        emit(.checkingDuplicate, nil)
        // 同一実行内の先行アイテムを優先して報告し、その後に実行開始時点の Drive 一覧と照合
        if let first = inBatch[exp.md5Hex] {
            r.status = .skippedDuplicate
            r.duplicateOfLocalIdentifier = first
            return (r, exp)
        }
        if let f = remote.lookup(exp.md5Hex) {
            r.status = .skippedDuplicate
            r.duplicateOfFileId = f.id
            return (r, exp)
        }
        if Task.isCancelled { r.error = Self.cancelledMessage; return (r, exp) }

        emit(.uploading(fraction: 0), (0, exp.byteCount))
        let uploaded: DriveFile
        do {
            uploaded = try await drive.uploadResumable(
                fileURL: exp.fileURL, name: item.driveName, mimeType: mime, folderId: folderId,
                byteCount: exp.byteCount, expectedMD5: exp.md5Hex,
                progress: { sent, total in
                    emit(.uploading(fraction: total > 0 ? Double(sent) / Double(total) : 1), (sent, total))
                })
        } catch DriveError.md5Mismatch(let id, let expected, let actual) {
            // Drive にファイルは作成済み。自動で再送・削除はしない。
            r.driveFileId = id
            r.driveMd5Checksum = actual
            r.error = "アップロード済みだが md5 不一致（fileId=\(id), ローカル \(expected), Drive \(actual ?? "なし")）。手動確認が必要です"
            inBatch[exp.md5Hex] = item.localIdentifier
            return (r, exp)
        } catch {
            if error is CancellationError || (error as? URLError)?.code == .cancelled {
                r.error = Self.cancelledMessage
            } else {
                r.error = "アップロード失敗: \(Redactor.redact(error.localizedDescription))"
            }
            return (r, exp)
        }
        r.driveFileId = uploaded.id
        r.driveMd5Checksum = uploaded.md5Checksum
        inBatch[exp.md5Hex] = item.localIdentifier

        emit(.verifying, nil)
        // (b) 新しい一覧で fileId と md5 を確認（結果整合性のため数回リトライ）
        var lastProblem = "一覧に fileId が見つかりません"
        for attempt in 1...max(1, options.verifyAttempts) {
            do {
                let listed = try await drive.findFiles(named: item.driveName, inFolder: folderId)
                if let f = listed.first(where: { $0.id == uploaded.id }) {
                    if f.md5Checksum?.lowercased() == exp.md5Hex.lowercased() {
                        r.verified = true
                        break
                    }
                    lastProblem = "一覧上の md5 が不一致（\(f.md5Checksum ?? "なし")）"
                }
            } catch {
                lastProblem = "検証用一覧の取得に失敗: \(Redactor.redact(error.localizedDescription))"
            }
            if attempt < options.verifyAttempts { try? await sleep(options.verifyDelay) }
        }
        if r.verified {
            r.status = .sent
            remote.insert(DriveFile(id: uploaded.id, name: uploaded.name, md5Checksum: exp.md5Hex))
        } else {
            r.status = .failed
            r.error = "アップロード済みだが検証に失敗（fileId=\(uploaded.id)）: \(lastProblem)。再送せず手動確認してください"
        }
        return (r, exp)
    }
}
