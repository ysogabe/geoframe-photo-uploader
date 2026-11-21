import AppKit
import UploaderCore

/// サムネイルのメモリキャッシュ。同じ写真への同時要求は 1 本にまとめる。
/// PhotoKit の要求自体は途中で止められないので、呼び出し側がキャンセルされても結果はキャッシュに入れる
/// （スクロールで戻ったときに取り直さないため）。
@MainActor
final class ThumbnailCache {
    static let pixelSize = CGSize(width: 320, height: 320)
    /// 送信パネルの大きな表示用
    static let largePixelSize = CGSize(width: 720, height: 720)

    private let service: UploaderService
    private let cache = NSCache<NSString, NSImage>()
    private let largeCache = NSCache<NSString, NSImage>()
    private var inFlight: [String: Task<CGImage?, Never>] = [:]

    init(service: UploaderService) {
        self.service = service
        cache.countLimit = 1500
        largeCache.countLimit = 24
    }

    func cachedLarge(_ id: String) -> NSImage? { largeCache.object(forKey: id as NSString) }

    /// 大きなサムネイル（送信パネル用。数枚だけ覚える）。
    func largeImage(for id: String) async -> NSImage? {
        if let hit = cachedLarge(id) { return hit }
        guard let cg = await service.thumbnail(localIdentifier: id, size: Self.largePixelSize) else { return nil }
        let img = NSImage(cgImage: cg, size: .zero)
        largeCache.setObject(img, forKey: id as NSString)
        return img
    }

    func cached(_ id: String) -> NSImage? { cache.object(forKey: id as NSString) }

    func image(for id: String) async -> NSImage? {
        if let hit = cached(id) { return hit }
        let task: Task<CGImage?, Never>
        if let t = inFlight[id] {
            task = t
        } else {
            let svc = service
            task = Task { await svc.thumbnail(localIdentifier: id, size: Self.pixelSize) }
            inFlight[id] = task
            Task { [weak self] in
                let cg = await task.value
                guard let self else { return }
                self.inFlight[id] = nil
                if let cg { self.cache.setObject(NSImage(cgImage: cg, size: .zero), forKey: id as NSString) }
            }
        }
        guard let cg = await task.value, !Task.isCancelled else { return cached(id) }
        return cached(id) ?? NSImage(cgImage: cg, size: .zero)
    }
}
