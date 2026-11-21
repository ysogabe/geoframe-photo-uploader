import CryptoKit
import Foundation
import ImageIO
import Photos

public enum DataSource: String, Codable, Sendable { case local, iCloud }

public struct ExifDates: Codable, Sendable, Equatable {
    public var dateTimeOriginal: String?
    public var offsetTimeOriginal: String?
    public init(dateTimeOriginal: String? = nil, offsetTimeOriginal: String? = nil) {
        self.dateTimeOriginal = dateTimeOriginal; self.offsetTimeOriginal = offsetTimeOriginal
    }
}

/// 一時ファイルに書き出した原本。呼び出し側がアップロード後に `remove()` する。
public struct ExportedOriginal: Sendable {
    public let fileURL: URL
    public let byteCount: Int64
    public let md5Hex: String
    public let sha256Hex: String
    public let dataSource: DataSource
    public let exif: ExifDates?

    public init(fileURL: URL, byteCount: Int64, md5Hex: String, sha256Hex: String, dataSource: DataSource, exif: ExifDates?) {
        self.fileURL = fileURL; self.byteCount = byteCount; self.md5Hex = md5Hex
        self.sha256Hex = sha256Hex; self.dataSource = dataSource; self.exif = exif
    }

    public func remove() { try? FileManager.default.removeItem(at: fileURL) }
}

public enum ExportError: Error, LocalizedError {
    case assetNotFound(String)
    case noPhotoResource(String)
    case timeout(seconds: TimeInterval, network: Bool)
    case photoKit(String)
    case io(String)

    public var errorDescription: String? {
        switch self {
        case .assetNotFound(let id): return "写真が見つかりません: \(id)"
        case .noPhotoResource(let id): return "原本（.photo）リソースがありません: \(id)"
        case .timeout(let s, let n): return "原本の取得がタイムアウトしました（\(Int(s)) 秒, \(n ? "iCloud" : "ローカル")）"
        case .photoKit(let m): return "原本の取得に失敗しました: \(m)"
        case .io(let m): return "一時ファイルの書き込みに失敗しました: \(m)"
        }
    }
}

/// 原本を書き出してハッシュを返す抽象（コーディネーターのテスト用に差し替え可能）。
public protocol OriginalExporting: Sendable {
    func export(localIdentifier: String) async throws -> ExportedOriginal
}

public func hexString<D: Sequence>(_ bytes: D) -> String where D.Element == UInt8 {
    bytes.map { String(format: "%02x", $0) }.joined()
}

/// MD5 と SHA-256 を同時に計算しつつ一時ファイルへ書く。
final class HashingFileSink: @unchecked Sendable {
    private let lock = NSLock()
    private var handle: FileHandle?
    private var md5 = Insecure.MD5()
    private var sha = SHA256()
    private(set) var bytes: Int64 = 0
    private var writeError: Error?
    let url: URL

    init(url: URL) throws {
        self.url = url
        // 0600 で新規作成
        let fd = open(url.path, O_CREAT | O_TRUNC | O_WRONLY, 0o600)
        guard fd >= 0 else { throw ExportError.io(String(cString: strerror(errno))) }
        handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    }

    func append(_ data: Data) {
        lock.lock(); defer { lock.unlock() }
        guard writeError == nil, let handle else { return }
        do { try handle.write(contentsOf: data) } catch { writeError = error; return }
        md5.update(data: data)
        sha.update(data: data)
        bytes += Int64(data.count)
    }

    func finish() throws -> (md5: String, sha256: String, bytes: Int64) {
        lock.lock(); defer { lock.unlock() }
        try? handle?.close()
        handle = nil
        if let e = writeError { throw ExportError.io(e.localizedDescription) }
        return (hexString(md5.finalize()), hexString(sha.finalize()), bytes)
    }

    func discard() {
        lock.lock(); defer { lock.unlock() }
        try? handle?.close()
        handle = nil
        try? FileManager.default.removeItem(at: url)
    }

    static func hashFile(at url: URL) throws -> (md5: String, sha256: String, bytes: Int64) {
        let fh = try FileHandle(forReadingFrom: url)
        defer { try? fh.close() }
        var md5 = Insecure.MD5()
        var sha = SHA256()
        var n: Int64 = 0
        while let chunk = try fh.read(upToCount: 1 << 20), !chunk.isEmpty {
            md5.update(data: chunk); sha.update(data: chunk); n += Int64(chunk.count)
        }
        return (hexString(md5.finalize()), hexString(sha.finalize()), n)
    }
}

/// PhotoKit の `.photo` リソースを一切加工せずに一時ファイルへストリーミングする。
public final class OriginalExporter: OriginalExporting, @unchecked Sendable {
    public let tempDir: URL
    public var localTimeout: TimeInterval = 120
    public var networkTimeout: TimeInterval = 600

    /// プライベートな一時ディレクトリ（0700）を作る。
    public init(tempRoot: URL? = nil) throws {
        let root = tempRoot ?? FileManager.default.temporaryDirectory
        let dir = root.appendingPathComponent("GeoFrameUploader-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        tempDir = dir
    }

    /// 一時ディレクトリごと削除。
    public func cleanup() { try? FileManager.default.removeItem(at: tempDir) }

    public func export(localIdentifier: String) async throws -> ExportedOriginal {
        let opts = PHFetchOptions()
        opts.includeAllBurstAssets = true
        opts.includeHiddenAssets = false
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [localIdentifier], options: opts).firstObject else {
            throw ExportError.assetNotFound(localIdentifier)
        }
        guard let res = PhotoLibrary.photoResource(for: asset) else { throw ExportError.noPhotoResource(localIdentifier) }
        return try await export(resource: res)
    }

    /// まずネットワーク不可で取得し、失敗したらネットワーク可（iCloud）で取り直す。
    public func export(resource: PHAssetResource) async throws -> ExportedOriginal {
        let ext = (resource.originalFilename as NSString).pathExtension
        let name = UUID().uuidString + (ext.isEmpty ? "" : ".\(ext)")
        let url = tempDir.appendingPathComponent(name)
        var firstError: Error?
        for network in [false, true] {
            // 試行ごとにファイルとハッシュをリセット（失敗した試行の部分書き込みを持ち越さない）
            let sink = try HashingFileSink(url: url)
            do {
                try await request(resource, network: network, sink: sink)
                let r = try sink.finish()
                return ExportedOriginal(fileURL: url, byteCount: r.bytes, md5Hex: r.md5, sha256Hex: r.sha256,
                                        dataSource: network ? .iCloud : .local, exif: Self.readExifDates(url: url))
            } catch {
                sink.discard()
                if error is CancellationError { throw error }
                if firstError == nil { firstError = error }
                if network { throw error }
            }
        }
        throw firstError ?? ExportError.photoKit("unknown")
    }

    private func request(_ resource: PHAssetResource, network: Bool, sink: HashingFileSink) async throws {
        let opts = PHAssetResourceRequestOptions()
        opts.isNetworkAccessAllowed = network
        let timeout = network ? networkTimeout : localTimeout
        let manager = PHAssetResourceManager.default()
        let once = OnceFlag()
        let idBox = RequestIDBox()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                let rid = manager.requestData(for: resource, options: opts, dataReceivedHandler: { chunk in
                    sink.append(chunk)
                }, completionHandler: { error in
                    guard once.fire() else { return }
                    if let e = error as NSError? {
                        cont.resume(throwing: ExportError.photoKit("\(e.domain) \(e.code) \(e.localizedDescription)"))
                    } else {
                        cont.resume()
                    }
                })
                idBox.set(rid)
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                    guard once.fire() else { return }
                    manager.cancelDataRequest(rid)
                    cont.resume(throwing: ExportError.timeout(seconds: timeout, network: network))
                }
                idBox.setResumer {
                    guard once.fire() else { return }
                    manager.cancelDataRequest(rid)
                    cont.resume(throwing: CancellationError())
                }
            }
        } onCancel: {
            idBox.cancel()
        }
    }

    /// EXIF DateTimeOriginal / OffsetTimeOriginal を読む（ベストエフォート）。
    public static func readExifDates(url: URL) -> ExifDates? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any] else { return nil }
        let dto = exif[kCGImagePropertyExifDateTimeOriginal] as? String
        let off = exif[kCGImagePropertyExifOffsetTimeOriginal] as? String
        if dto == nil && off == nil { return nil }
        return ExifDates(dateTimeOriginal: dto, offsetTimeOriginal: off)
    }

    public static func hashFile(at url: URL) throws -> (md5: String, sha256: String, bytes: Int64) {
        try HashingFileSink.hashFile(at: url)
    }
}

/// キャンセルハンドラとリクエスト ID の受け渡し（キャンセルが先に来た場合も扱う）。
private final class RequestIDBox: @unchecked Sendable {
    private let lock = NSLock()
    private var rid: PHAssetResourceDataRequestID?
    private var resumer: (() -> Void)?
    private var cancelled = false

    func set(_ id: PHAssetResourceDataRequestID) { lock.lock(); rid = id; lock.unlock() }

    func setResumer(_ r: @escaping () -> Void) {
        lock.lock()
        if cancelled { lock.unlock(); r(); return }
        resumer = r
        lock.unlock()
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let r = resumer
        lock.unlock()
        r?()
    }
}
