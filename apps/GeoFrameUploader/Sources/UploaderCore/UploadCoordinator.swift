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
    private let options: Options
    private let sleep: Sleeper
    private let log: @Sendable (String) -> Void

    public init(drive: DriveClient, exporter: OriginalExporting, records: RecordStore?, options: Options = Options(),
                sleeper: @escaping Sleeper = defaultSleeper, log: @escaping @Sendable (String) -> Void = { _ in }) {
        self.drive = drive
        self.exporter = exporter
        self.records = records
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
        // 実行開始時点のフォルダ一覧（新鮮な md5 集合）
        var remote = RemoteIndex(files: try await drive.listFolderFiles(folderId: folderId))
        let remoteCount = remote.count
        log("run \(runId): remote md5 count = \(remoteCount)")
        var inBatch: [String: String] = [:]   // md5 → localIdentifier
        var results: [ItemResult] = []
        var cancelled = false

        for (i, item) in items.enumerated() {
            if Task.isCancelled { cancelled = true; break }
            let emit: @Sendable (UploadPhase) -> Void = { phase in
                onEvent?(UploadEvent(localIdentifier: item.localIdentifier, index: i, total: items.count, phase: phase))
            }
            let (result, exported) = await process(item: item, folderId: folderId, remote: &remote,
                                                   inBatch: &inBatch, emit: emit)
            exported?.remove()
            do {
                try records?.append(UploadRecord(runId: runId, item: item, exported: exported, result: result.status.record,
                                                 driveFileId: result.driveFileId, driveMd5Checksum: result.driveMd5Checksum,
                                                 verified: result.verified, error: result.error, folderId: folderId))
            } catch {
                log("failed to append record: \(error.localizedDescription)")
            }
            results.append(result)
            emit(.finished(result))
            if result.error == Self.cancelledMessage { cancelled = true; break }
        }
        return RunSummary(runId: runId, folderId: folderId, remoteFileCount: remoteCount, results: results, cancelled: cancelled)
    }

    public static let cancelledMessage = "キャンセルされました"

    private func process(item: PhotoItem, folderId: String, remote: inout RemoteIndex,
                         inBatch: inout [String: String], emit: @escaping @Sendable (UploadPhase) -> Void) async -> (ItemResult, ExportedOriginal?) {
        var r = ItemResult(localIdentifier: item.localIdentifier, originalFilename: item.originalFilename, status: .failed,
                           verified: false)
        guard case .eligible = item.eligibility, let mime = item.mimeType else {
            r.status = .skippedIneligible
            r.error = item.eligibility.reason ?? "形式非対応"
            return (r, nil)
        }

        emit(.exporting)
        let exp: ExportedOriginal
        do { exp = try await exporter.export(localIdentifier: item.localIdentifier) } catch {
            r.error = error is CancellationError ? Self.cancelledMessage : "原本の取得に失敗: \(error.localizedDescription)"
            return (r, nil)
        }
        r.md5 = exp.md5Hex; r.sha256 = exp.sha256Hex; r.byteCount = exp.byteCount; r.dataSource = exp.dataSource

        emit(.checkingDuplicate)
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

        emit(.uploading(fraction: 0))
        let uploaded: DriveFile
        do {
            uploaded = try await drive.uploadResumable(
                fileURL: exp.fileURL, name: item.driveName, mimeType: mime, folderId: folderId,
                byteCount: exp.byteCount, expectedMD5: exp.md5Hex,
                progress: { sent, total in emit(.uploading(fraction: total > 0 ? Double(sent) / Double(total) : 1)) })
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

        emit(.verifying)
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
