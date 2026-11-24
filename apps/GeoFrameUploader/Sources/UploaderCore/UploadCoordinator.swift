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
    /// Drive properties に付与した補完位置の出所（付与した場合のみ）
    public var locationSupplementSource: LocationSupplementSource? = nil

    /// 中止により処理が打ち切られたアイテム（status は `.failed` のまま）。
    public var wasCancelled: Bool { status == .failed && error == UploadCoordinator.cancelledMessage }

    /// アップロードは完了（応答の md5 は一致）したが、中止のため一覧での照合を終えられなかった（status は `.failed`）。
    /// Drive にはファイルがあるので再送しない。次に一覧と照合すれば「Drive に既存」になる。
    public var verificationInterrupted: Bool {
        status == .failed && (error?.hasPrefix(UploadCoordinator.verifyInterruptedMessage) ?? false)
    }
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
        /// アップロード完了後に中止されたとき、一覧での照合を続ける上限（秒。中止された時点から数える）
        public var verifyBudgetAfterCancel: TimeInterval
        public init(verifyAttempts: Int = 5, verifyDelay: TimeInterval = 2, verifyBudgetAfterCancel: TimeInterval = 10) {
            self.verifyAttempts = verifyAttempts; self.verifyDelay = verifyDelay
            self.verifyBudgetAfterCancel = verifyBudgetAfterCancel
        }
    }

    private let drive: DriveClient
    private let exporter: OriginalExporting
    private let records: RecordStore?
    private let cache: ResultCache?
    private let locationOverrides: LocationOverrideStore?
    private let options: Options
    private let sleep: Sleeper
    private let log: @Sendable (String) -> Void

    public init(drive: DriveClient, exporter: OriginalExporting, records: RecordStore?, cache: ResultCache? = nil,
                locationOverrides: LocationOverrideStore? = nil, options: Options = Options(),
                sleeper: @escaping Sleeper = defaultSleeper, log: @escaping @Sendable (String) -> Void = { _ in }) {
        self.drive = drive
        self.exporter = exporter
        self.records = records
        self.cache = cache
        self.locationOverrides = locationOverrides
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
        // 他のプロセスが追記した records.jsonl / item-cache.json / location-overrides.json を先に取り込む
        cache?.refresh()
        locationOverrides?.refresh()
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
            let (result, exported, resolvedLoc) = await process(item: item, folderId: folderId, remote: &remote,
                                                                inBatch: &inBatch, emit: emit)
            exported?.remove()
            var record = UploadRecord(runId: runId, item: item, exported: exported, result: result.status.record,
                                      driveFileId: result.driveFileId, driveMd5Checksum: result.driveMd5Checksum,
                                      verified: result.verified, error: result.error, folderId: folderId,
                                      uploadedLocation: resolvedLoc?.location,
                                      uploadedLocationSource: resolvedLoc?.source)
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
            if result.error == Self.cancelledMessage || result.verificationInterrupted { cancelled = true; break }
        }
        return RunSummary(runId: runId, folderId: folderId, remoteFileCount: remoteCount, results: results, cancelled: cancelled)
    }

    public static let cancelledMessage = "キャンセルされました"
    public static let verifyInterruptedMessage = "アップロード済み（応答の md5 は一致）・中止のため一覧での照合は未完了"

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
        case .failed where r.driveFileId != nil:
            // Drive にファイルがある失敗（未検証・md5 不一致・中止で照合未完了）は、中止中でも状態と md5 を残す。
            // records.jsonl の同じ行を取り込んだ結果（failed + fileId + md5）と一致させる
            cache.recordStatus(item: item, status: .failed, driveFileId: r.driveFileId, folderId: folderId,
                               md5: freshHash, sha256: r.sha256, byteCount: r.byteCount)
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
                         inBatch: inout [String: String], emit: @escaping @Sendable (UploadPhase, (Int64, Int64)?) -> Void) async -> (ItemResult, ExportedOriginal?, ResolvedUploadLocation?) {
        var r = ItemResult(localIdentifier: item.localIdentifier, originalFilename: item.originalFilename, status: .failed,
                           verified: false)
        guard case .eligible = item.eligibility, let mime = item.mimeType else {
            r.status = .skippedIneligible
            r.error = item.eligibility.reason ?? "形式非対応"
            return (r, nil, nil)
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
                return (r, nil, nil)
            }
        }

        emit(.exporting, nil)
        let exp: ExportedOriginal
        do { exp = try await exporter.export(localIdentifier: item.localIdentifier) } catch {
            r.error = error is CancellationError ? Self.cancelledMessage : "原本の取得に失敗: \(error.localizedDescription)"
            return (r, nil, nil)
        }
        r.md5 = exp.md5Hex; r.sha256 = exp.sha256Hex; r.byteCount = exp.byteCount; r.dataSource = exp.dataSource

        emit(.checkingDuplicate, nil)
        // 同一実行内の先行アイテムを優先して報告し、その後に実行開始時点の Drive 一覧と照合
        if let first = inBatch[exp.md5Hex] {
            r.status = .skippedDuplicate
            r.duplicateOfLocalIdentifier = first
            return (r, exp, nil)
        }
        if let f = remote.lookup(exp.md5Hex) {
            r.status = .skippedDuplicate
            r.duplicateOfFileId = f.id
            return (r, exp, nil)
        }
        if Task.isCancelled { r.error = Self.cancelledMessage; return (r, exp, nil) }

        let overrideEntry = locationOverrides?.entry(for: item)
        let resolvedLoc = DriveLocationProperties.resolveForUpload(
            item: item,
            exifGPS: exp.exifGPS,
            override: overrideEntry
        )
        let driveProps = resolvedLoc.flatMap(DriveLocationProperties.makeProperties(for:))
        if driveProps != nil {
            r.locationSupplementSource = resolvedLoc?.source
        }

        emit(.uploading(fraction: 0), (0, exp.byteCount))
        let uploaded: DriveFile
        do {
            uploaded = try await drive.uploadResumable(
                fileURL: exp.fileURL, name: item.driveName, mimeType: mime, folderId: folderId,
                byteCount: exp.byteCount, expectedMD5: exp.md5Hex, properties: driveProps,
                progress: { sent, total in
                    emit(.uploading(fraction: total > 0 ? Double(sent) / Double(total) : 1), (sent, total))
                })
        } catch DriveError.md5Mismatch(let id, let expected, let actual) {
            // Drive にファイルは作成済み。自動で再送・削除はしない。
            r.driveFileId = id
            r.driveMd5Checksum = actual
            r.error = "アップロード済みだが md5 不一致（fileId=\(id), ローカル \(expected), Drive \(actual ?? "なし")）。手動確認が必要です"
            inBatch[exp.md5Hex] = item.localIdentifier
            return (r, exp, driveProps != nil ? resolvedLoc : nil)
        } catch {
            if error is CancellationError || (error as? URLError)?.code == .cancelled {
                r.error = Self.cancelledMessage
            } else {
                r.error = "アップロード失敗: \(Redactor.redact(error.localizedDescription))"
            }
            return (r, exp, nil)
        }
        r.driveFileId = uploaded.id
        r.driveMd5Checksum = uploaded.md5Checksum
        inBatch[exp.md5Hex] = item.localIdentifier

        emit(.verifying, nil)
        // (b) 新しい一覧で fileId と md5 を確認（結果整合性のため数回リトライ）。
        // アップロードは済んでいるので、ここで中止されても照合は続ける（中止から verifyBudgetAfterCancel 秒まで）
        let v = await verifyShielded(name: item.driveName, folderId: folderId, fileId: uploaded.id, md5: exp.md5Hex)
        if v.verified {
            r.verified = true
            r.status = .sent
            remote.insert(DriveFile(id: uploaded.id, name: uploaded.name, md5Checksum: exp.md5Hex))
        } else if v.interrupted {
            r.status = .failed
            r.error = "\(Self.verifyInterruptedMessage)（fileId=\(uploaded.id)）。再送せず、次回の重複確認で Drive 上の有無を確認してください"
        } else {
            r.status = .failed
            r.error = "アップロード済みだが検証に失敗（fileId=\(uploaded.id)）: \(v.lastProblem)。再送せず手動確認してください"
        }
        return (r, exp, driveProps != nil ? resolvedLoc : nil)
    }

    private struct VerifyOutcome: Sendable {
        var verified: Bool
        /// 中止され、上限時間内に照合を終えられなかった
        var interrupted: Bool
        var lastProblem: String
    }

    /// 一覧での照合を、呼び出し元の中止から切り離して実行する。中止されたら `verifyBudgetAfterCancel` 秒後に打ち切る。
    private func verifyShielded(name: String, folderId: String, fileId: String, md5: String) async -> VerifyOutcome {
        let drive = self.drive, sleep = self.sleep, options = self.options
        // Task {} は呼び出し元の中止を引き継がない
        let worker = Task { () -> VerifyOutcome in
            var lastProblem = "一覧に fileId が見つかりません"
            let attempts = max(1, options.verifyAttempts)
            for attempt in 1...attempts {
                if Task.isCancelled { return VerifyOutcome(verified: false, interrupted: true, lastProblem: lastProblem) }
                do {
                    let listed = try await drive.findFiles(named: name, inFolder: folderId)
                    if let f = listed.first(where: { $0.id == fileId }) {
                        if f.md5Checksum?.lowercased() == md5.lowercased() {
                            return VerifyOutcome(verified: true, interrupted: false, lastProblem: "")
                        }
                        lastProblem = "一覧上の md5 が不一致（\(f.md5Checksum ?? "なし")）"
                    }
                } catch {
                    if Task.isCancelled { return VerifyOutcome(verified: false, interrupted: true, lastProblem: lastProblem) }
                    lastProblem = "検証用一覧の取得に失敗: \(Redactor.redact(error.localizedDescription))"
                }
                if attempt < attempts { try? await sleep(options.verifyDelay) }
            }
            return VerifyOutcome(verified: false, interrupted: Task.isCancelled, lastProblem: lastProblem)
        }
        let budget = options.verifyBudgetAfterCancel
        let timer = TimerBox()
        return await withTaskCancellationHandler {
            let out = await worker.value
            timer.cancel()
            return out
        } onCancel: {
            log("cancelled during verification; continuing for up to \(budget)s")
            timer.start(after: budget) { worker.cancel() }
        }
    }
}

/// 中止後の照合の打ち切りタイマー（照合が先に終わったら止める）。
private final class TimerBox: @unchecked Sendable {
    private let lock = NSLock()
    private var task: Task<Void, Never>?
    private var finished = false

    func start(after seconds: TimeInterval, _ fire: @escaping @Sendable () -> Void) {
        lock.withLock {
            guard !finished, task == nil else { return }
            task = Task {
                try? await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
                if !Task.isCancelled { fire() }
            }
        }
    }

    func cancel() {
        lock.withLock {
            finished = true
            task?.cancel()
            task = nil
        }
    }
}
