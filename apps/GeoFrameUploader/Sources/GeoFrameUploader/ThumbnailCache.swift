import AppKit
import UploaderCore

/// サムネイルのメモリキャッシュ。同じ写真への同時要求は 1 本にまとめる。
/// PhotoKit の要求自体は途中で止められないので、呼び出し側がキャンセルされても結果はキャッシュに入れる
/// （スクロールで戻ったときに取り直さないため）。
@MainActor
final class ThumbnailCache {
    static let pixelSize = CGSize(width: 320, height: 320)

    private let service: UploaderService
    private let cache = NSCache<NSString, NSImage>()
    private var inFlight: [String: Task<CGImage?, Never>] = [:]

    init(service: UploaderService) {
        self.service = service
        cache.countLimit = 1500
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
