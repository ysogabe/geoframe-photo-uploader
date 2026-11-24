import AppKit
import CoreLocation
import Foundation
import Photos

public enum PhotoAuthState: String, Codable, Sendable {
    case notDetermined, restricted, denied, authorized, limited, unknown

    init(_ s: PHAuthorizationStatus) {
        switch s {
        case .notDetermined: self = .notDetermined
        case .restricted: self = .restricted
        case .denied: self = .denied
        case .authorized: self = .authorized
        case .limited: self = .limited
        @unknown default: self = .unknown
        }
    }
}

public enum PhotoLibraryError: Error, LocalizedError, Equatable {
    case notAuthorized(PhotoAuthState)
    case limitedAccess
    case authorizationTimeout
    case assetNotFound(String)
    case noPhotoResource(String)
    case invalidLocation

    public var errorDescription: String? {
        switch self {
        case .notAuthorized(let s): return "写真ライブラリへのアクセスが許可されていません（状態: \(s.rawValue)）。システム設定 > プライバシーとセキュリティ > 写真 で「フルアクセス」を許可してください。"
        case .limitedAccess: return "写真ライブラリへのアクセスが「選択した写真のみ」に制限されています。フルアクセスを許可してください。"
        case .authorizationTimeout: return "写真ライブラリのアクセス許可ダイアログに応答がありませんでした。"
        case .assetNotFound(let id): return "写真が見つかりません: \(id)"
        case .noPhotoResource(let id): return "原本（.photo）リソースがありません: \(id)"
        case .invalidLocation: return "位置情報の座標が不正です"
        }
    }
}

public struct PhotoLocationWriteSummary: Sendable, Equatable {
    public var updatedIds: [String]
    public var skippedAlreadyHasLocationIds: [String]
    public var skippedNotEditableIds: [String]
    public var missingAssetIds: [String]

    public init(updatedIds: [String] = [], skippedAlreadyHasLocationIds: [String] = [],
                skippedNotEditableIds: [String] = [], missingAssetIds: [String] = []) {
        self.updatedIds = updatedIds
        self.skippedAlreadyHasLocationIds = skippedAlreadyHasLocationIds
        self.skippedNotEditableIds = skippedNotEditableIds
        self.missingAssetIds = missingAssetIds
    }
}

/// PhotoKit ラッパー。位置情報未設定アセットへの明示的補完書き込みのみオプション対応（画像変更・削除・既存位置上書きなし）。
public final class PhotoLibrary: @unchecked Sendable {
    public static let shared = PhotoLibrary()

    private let imageManager = PHCachingImageManager()

    public init() {}

    // MARK: 認可

    /// プロンプトを出さずに現在の状態を返す。
    public static func currentAuthorization() -> PhotoAuthState {
        PhotoAuthState(PHPhotoLibrary.authorizationStatus(for: .readWrite))
    }

    /// 未決定ならダイアログを出して結果を返す。
    public static func requestAuthorization() async -> PhotoAuthState {
        let s = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard s == .notDetermined else { return PhotoAuthState(s) }
        let result = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        return PhotoAuthState(result)
    }

    /// `.authorized` 以外はエラー（`.limited` も不十分として扱う）。
    @discardableResult
    public static func ensureAuthorized() async throws -> PhotoAuthState {
        let s = await requestAuthorization()
        switch s {
        case .authorized: return s
        case .limited: throw PhotoLibraryError.limitedAccess
        default: throw PhotoLibraryError.notAuthorized(s)
        }
    }

    // MARK: 列挙

    /// creationDate ∈ [start, end) の画像アセットを撮影日時順に返す。
    public func fetchItems(start: Date, end: Date) -> [PhotoItem] {
        let opts = PHFetchOptions()
        opts.predicate = NSPredicate(format: "creationDate >= %@ AND creationDate < %@", start as NSDate, end as NSDate)
        opts.includeHiddenAssets = false
        opts.includeAllBurstAssets = true
        opts.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]
        // 動画等も列挙して「対象外」として見せる（UI で理由を表示できるように）。
        let result = PHAsset.fetchAssets(with: opts)
        var items: [PhotoItem] = []
        items.reserveCapacity(result.count)
        result.enumerateObjects { asset, _, _ in
            items.append(Self.makeItem(asset))
        }
        return items
    }

    public func fetchItems(fromDay: String, toDay: String?) -> [PhotoItem]? {
        guard let r = LocalTime.dayRange(fromDay: fromDay, toDay: toDay) else { return nil }
        return fetchItems(start: r.start, end: r.end)
    }

    public func asset(for localIdentifier: String) -> PHAsset? {
        let opts = PHFetchOptions()
        opts.includeHiddenAssets = false
        opts.includeAllBurstAssets = true
        return PHAsset.fetchAssets(withLocalIdentifiers: [localIdentifier], options: opts).firstObject
    }

    /// 原本 `.photo` リソース（編集済みでも `.fullSizePhoto` ではなく `.photo`、Live Photo でも静止画のみ）。
    public static func photoResource(for asset: PHAsset) -> PHAssetResource? {
        PHAssetResource.assetResources(for: asset).first { $0.type == .photo }
    }

    static func makeItem(_ asset: PHAsset) -> PhotoItem {
        let resources = PHAssetResource.assetResources(for: asset)
        let photo = resources.first { $0.type == .photo }
        let kind: MediaKind
        switch asset.mediaType {
        case .image: kind = .image
        case .video: kind = .video
        case .audio: kind = .audio
        default: kind = .unknown
        }
        var loc: PhotoLocation?
        if let l = asset.location {
            loc = PhotoLocation(lat: l.coordinate.latitude, lon: l.coordinate.longitude,
                                altitude: l.verticalAccuracy >= 0 ? l.altitude : nil,
                                horizontalAccuracy: l.horizontalAccuracy >= 0 ? l.horizontalAccuracy : nil)
        }
        let adjusted = asset.hasAdjustments
            || resources.contains { [.adjustmentData, .fullSizePhoto, .adjustmentBasePhoto].contains($0.type) }
        return PhotoItem(
            localIdentifier: asset.localIdentifier,
            originalFilename: photo?.originalFilename,
            uti: photo?.uniformTypeIdentifier,
            mediaKind: kind,
            creationDate: asset.creationDate,
            location: loc,
            pixelWidth: asset.pixelWidth,
            pixelHeight: asset.pixelHeight,
            burstIdentifier: asset.burstIdentifier,
            isFavorite: asset.isFavorite,
            isLivePhoto: asset.mediaSubtypes.contains(.photoLive),
            hasAdjustments: adjusted,
            mediaSubtypesRaw: asset.mediaSubtypes.rawValue,
            modificationDate: asset.modificationDate
        )
    }

    // MARK: サムネイル（UI 用）

    /// サムネイルを非同期に取得（iCloud からの取得も許可）。見つからなければ nil。
    public func thumbnail(for localIdentifier: String, size: CGSize) async -> NSImage? {
        await requestImage(for: localIdentifier, size: size, contentMode: .aspectFill, resizeMode: .fast)
    }

    public func thumbnailCGImage(for localIdentifier: String, size: CGSize) async -> CGImage? {
        guard let img = await thumbnail(for: localIdentifier, size: size) else { return nil }
        var rect = CGRect(origin: .zero, size: img.size)
        return img.cgImage(forProposedRect: &rect, context: nil, hints: nil)
    }

    /// 品質解析・pHash 用にアスペクト比を維持したまま長辺 `maxDimension` 相当の画像を取得する。
    /// キャンセル時は `PHImageManager` のリクエストを中止する。
    public func analysisCGImage(for localIdentifier: String, maxDimension: Int = 512) async -> CGImage? {
        let size = CGSize(width: maxDimension, height: maxDimension)
        guard let img = await requestImage(for: localIdentifier, size: size, contentMode: .aspectFit, resizeMode: .exact) else {
            return nil
        }
        var rect = CGRect(origin: .zero, size: img.size)
        return img.cgImage(forProposedRect: &rect, context: nil, hints: nil)
    }

    private func requestImage(for localIdentifier: String, size: CGSize,
                              contentMode: PHImageContentMode, resizeMode: PHImageRequestOptionsResizeMode) async -> NSImage? {
        guard let asset = asset(for: localIdentifier) else { return nil }
        let opts = PHImageRequestOptions()
        opts.deliveryMode = .highQualityFormat
        opts.resizeMode = resizeMode
        opts.isNetworkAccessAllowed = true
        opts.isSynchronous = false
        let reqHolder = RequestIDHolder()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (cont: CheckedContinuation<NSImage?, Never>) in
                let once = OnceFlag()
                let rid = imageManager.requestImage(for: asset, targetSize: size, contentMode: contentMode, options: opts) { image, info in
                    let degraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
                    if degraded && image != nil { return }
                    if once.fire() { cont.resume(returning: image) }
                }
                reqHolder.set(rid, manager: imageManager)
            }
        } onCancel: {
            reqHolder.cancel()
        }
    }

    public func startCaching(localIdentifiers: [String], size: CGSize) {
        let assets = PHAsset.fetchAssets(withLocalIdentifiers: localIdentifiers, options: nil)
        var arr: [PHAsset] = []
        assets.enumerateObjects { a, _, _ in arr.append(a) }
        imageManager.startCachingImages(for: arr, targetSize: size, contentMode: .aspectFill, options: nil)
    }

    public func stopCachingAll() { imageManager.stopCachingImagesForAllAssets() }

    /// `.authorized` のときだけダイアログを出さずに撮影日時を取得する（履歴キャッシュ補完用）。
    public func creationDates(for localIdentifiers: [String]) -> [String: Date] {
        guard !localIdentifiers.isEmpty, Self.currentAuthorization() == .authorized else { return [:] }
        let opts = PHFetchOptions()
        opts.includeHiddenAssets = false
        opts.includeAllBurstAssets = true
        let assets = PHAsset.fetchAssets(withLocalIdentifiers: localIdentifiers, options: opts)
        var out: [String: Date] = [:]
        out.reserveCapacity(assets.count)
        assets.enumerateObjects { asset, _, _ in
            if let d = asset.creationDate {
                out[asset.localIdentifier] = d
            }
        }
        return out
    }

    public func fetchItems(localIdentifiers: [String]) -> [PhotoItem] {
        guard !localIdentifiers.isEmpty else { return [] }
        let opts = PHFetchOptions()
        opts.includeHiddenAssets = false
        opts.includeAllBurstAssets = true
        let result = PHAsset.fetchAssets(withLocalIdentifiers: localIdentifiers, options: opts)
        var byId: [String: PhotoItem] = [:]
        result.enumerateObjects { asset, _, _ in
            byId[asset.localIdentifier] = Self.makeItem(asset)
        }
        var seen = Set<String>()
        return localIdentifiers.filter { seen.insert($0).inserted }.compactMap { byId[$0] }
    }

    /// `asset.location == nil` の写真に対してのみ位置情報を書き込む（既存の位置情報は絶対に上書きしない）。
    public func assignLocationIfMissing(localIdentifiers: [String], location: PhotoLocation) async throws -> PhotoLocationWriteSummary {
        guard PhotoSectioner.isValidCoordinate(location) else { throw PhotoLibraryError.invalidLocation }
        try await Self.ensureAuthorized()
        var seen = Set<String>()
        let uniqueIds = localIdentifiers.filter { seen.insert($0).inserted }
        guard !uniqueIds.isEmpty else { return PhotoLocationWriteSummary() }

        let opts = PHFetchOptions()
        opts.includeHiddenAssets = false
        opts.includeAllBurstAssets = true
        let fetched = PHAsset.fetchAssets(withLocalIdentifiers: uniqueIds, options: opts)
        var byId: [String: PHAsset] = [:]
        fetched.enumerateObjects { asset, _, _ in
            byId[asset.localIdentifier] = asset
        }

        var missingIds: [String] = []
        var alreadyHasLocIds: [String] = []
        var notEditableIds: [String] = []
        var candidates: [PHAsset] = []

        for id in uniqueIds {
            guard let asset = byId[id] else {
                missingIds.append(id)
                continue
            }
            if asset.location != nil {
                alreadyHasLocIds.append(id)
                continue
            }
            if !asset.canPerform(.properties) {
                notEditableIds.append(id)
                continue
            }
            candidates.append(asset)
        }

        guard !candidates.isEmpty else {
            return PhotoLocationWriteSummary(
                updatedIds: [],
                skippedAlreadyHasLocationIds: alreadyHasLocIds,
                skippedNotEditableIds: notEditableIds,
                missingAssetIds: missingIds
            )
        }

        let targetLoc = CLLocation(latitude: location.lat, longitude: location.lon)
        let box = WriteTrackingBox()
        let assetsToWrite = candidates
        try await PHPhotoLibrary.shared().performChanges {
            var written: [String] = []
            var skippedInBlock: [String] = []
            for asset in assetsToWrite {
                // performChanges 内でも直前に location 未設定を再検証し、既存位置を上書きしない
                guard asset.location == nil else {
                    skippedInBlock.append(asset.localIdentifier)
                    continue
                }
                let req = PHAssetChangeRequest(for: asset)
                req.location = targetLoc
                written.append(asset.localIdentifier)
            }
            box.record(written: written, skipped: skippedInBlock)
        }

        let (writtenIds, skippedInBlock) = box.snapshot()
        return PhotoLocationWriteSummary(
            updatedIds: writtenIds,
            skippedAlreadyHasLocationIds: alreadyHasLocIds + skippedInBlock,
            skippedNotEditableIds: notEditableIds,
            missingAssetIds: missingIds
        )
    }
}

private final class WriteTrackingBox: @unchecked Sendable {
    private let lock = NSLock()
    private var written: [String] = []
    private var skipped: [String] = []

    func record(written: [String], skipped: [String]) {
        lock.withLock {
            self.written = written
            self.skipped = skipped
        }
    }

    func snapshot() -> ([String], [String]) {
        lock.withLock { (written, skipped) }
    }
}

/// 一度だけ true を返すフラグ（continuation の二重 resume 防止）。
final class OnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var fired = false
    func fire() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if fired { return false }
        fired = true
        return true
    }
}

/// `PHImageManager` のリクエスト ID を保持し、キャンセル時に取り消す。
final class RequestIDHolder: @unchecked Sendable {
    private let lock = NSLock()
    private var id: PHImageRequestID = PHInvalidImageRequestID
    private weak var manager: PHImageManager?
    private var cancelled = false

    func set(_ id: PHImageRequestID, manager: PHImageManager) {
        lock.lock()
        self.id = id
        self.manager = manager
        let shouldCancel = cancelled
        lock.unlock()
        if shouldCancel && id != PHInvalidImageRequestID {
            manager.cancelImageRequest(id)
        }
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let id = self.id
        let manager = self.manager
        lock.unlock()
        if id != PHInvalidImageRequestID {
            manager?.cancelImageRequest(id)
        }
    }
}
