import CoreLocation
import Foundation

public enum GeocodingResult: Sendable, Equatable {
    case resolved(String)
    case notFound
    case failed
    case cancelled
}

public protocol GeocodingBackend: Sendable {
    func reverseGeocode(lat: Double, lon: Double) async -> GeocodingResult
    func cancel() async
}

/// CoreLocation (`CLGeocoder`) を使う本番用バックエンド。1 リクエストずつ直列に呼ぶこと。
public final class CLGeocoderBackend: GeocodingBackend, @unchecked Sendable {
    private let lock = NSLock()
    private let geocoder = CLGeocoder()
    private let locale = Locale(identifier: "ja_JP")

    public init() {}

    public func reverseGeocode(lat: Double, lon: Double) async -> GeocodingResult {
        let loc = CLLocation(latitude: lat, longitude: lon)
        return await withTaskCancellationHandler {
            do {
                let placemarks = try await geocoder.reverseGeocodeLocation(loc, preferredLocale: locale)
                guard let pm = placemarks.first else { return .notFound }
                guard let formatted = Self.format(pm) else { return .notFound }
                return .resolved(formatted)
            } catch {
                if let clErr = error as? CLError {
                    switch clErr.code {
                    case .geocodeFoundNoResult, .geocodeFoundPartialResult:
                        return .notFound
                    case .geocodeCanceled:
                        return .cancelled
                    default:
                        return .failed
                    }
                }
                return Task.isCancelled ? .cancelled : .failed
            }
        } onCancel: {
            lock.withLock { geocoder.cancelGeocode() }
        }
    }

    public func cancel() async {
        lock.withLock { geocoder.cancelGeocode() }
    }

    static func format(_ pm: CLPlacemark) -> String? {
        var parts: [String] = []
        let candidates = [pm.administrativeArea, pm.locality, pm.subLocality]
        for c in candidates {
            guard let s = c?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { continue }
            if !parts.contains(s) && !parts.contains(where: { $0.hasSuffix(s) }) {
                parts.append(s)
            }
        }
        if parts.isEmpty, let name = pm.name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
            parts.append(name)
        }
        return parts.isEmpty ? nil : parts.joined()
    }
}

/// 逆ジオコーディングの直列キューと `place-cache.json` 永続化を管理する。
/// ・丸め済み座標（約 100 m 精度）だけをバックエンドに送信する
/// ・キューが一度空になっても前回リクエストからの最小間隔（既定 300 ms）を跨いで保持する
/// ・キャンセル後の遅延応答はキャッシュ・公開しない
public actor PlaceNameResolver {
    public let fileURL: URL?
    private let backend: GeocodingBackend
    private let spacingNanoseconds: UInt64
    private let log: @Sendable (String) -> Void

    private var diskCache: [String: String] = [:]
    private var emptyKeys = Set<String>()
    private var dirtyCount = 0

    private struct RequestItem {
        let id: UUID
        let norm: PhotoSectioner.NormalizedCoordinate
        let generation: Int
        var continuation: CheckedContinuation<GeocodingResult, Never>
    }

    private var generation = 0
    private var queue: [RequestItem] = []
    private var inFlightId: UUID?
    private var inFlightGeneration: Int = 0
    private var cancelledInFlightIds = Set<UUID>()
    private var inFlightContinuation: CheckedContinuation<GeocodingResult, Never>?
    private var workerTask: Task<Void, Never>?
    private var lastBackendQueryAt: ContinuousClock.Instant?

    private struct FileFormat: Codable {
        var version: Int
        var entries: [String: String]
    }

    public init(fileURL: URL?, backend: GeocodingBackend = CLGeocoderBackend(),
                spacingNanoseconds: UInt64 = 300_000_000,
                log: @escaping @Sendable (String) -> Void = { _ in }) {
        self.fileURL = fileURL
        self.backend = backend
        self.spacingNanoseconds = spacingNanoseconds
        self.log = log
        if let fileURL, FileManager.default.fileExists(atPath: fileURL.path),
           let data = try? Data(contentsOf: fileURL),
           let f = try? ResultCache.decoder.decode(FileFormat.self, from: data) {
            self.diskCache = f.entries
        }
    }

    public func cachedName(for location: PhotoLocation) -> String? {
        guard let norm = PhotoSectioner.normalizedCoordinate(location) else { return nil }
        return diskCache[norm.key]
    }

    public func resolve(location: PhotoLocation) async -> String? {
        switch await resolveOutcome(location: location) {
        case .resolved(let name): return name
        case .notFound, .failed, .cancelled: return nil
        }
    }

    /// 指定座標の地名を解決し、失敗理由を含む結果を返す。
    public func resolveOutcome(location: PhotoLocation) async -> GeocodingResult {
        guard let norm = PhotoSectioner.normalizedCoordinate(location) else { return .notFound }
        if let hit = diskCache[norm.key] { return .resolved(hit) }
        if emptyKeys.contains(norm.key) { return .notFound }

        let reqId = UUID()
        let reqGen = generation
        return await withTaskCancellationHandler {
            await withCheckedContinuation { cont in
                if Task.isCancelled {
                    cont.resume(returning: .cancelled)
                    return
                }
                queue.append(RequestItem(id: reqId, norm: norm, generation: reqGen, continuation: cont))
                if workerTask == nil {
                    workerTask = Task { await self.processQueue() }
                }
            }
        } onCancel: {
            Task { await self.cancelRequest(id: reqId) }
        }
    }

    /// 保留中の全問い合わせを中止し、ここまでの解決済みキャッシュを保存する。
    /// 単一ワーカーの所有権は進行中のリクエストが抜けるまで維持する。
    public func cancelAll() async {
        generation &+= 1
        let pending = queue
        queue.removeAll()
        for item in pending {
            item.continuation.resume(returning: .cancelled)
        }
        if let id = inFlightId {
            cancelledInFlightIds.insert(id)
            if let cont = inFlightContinuation {
                inFlightContinuation = nil
                cont.resume(returning: .cancelled)
            }
            await backend.cancel()
        }
        saveIfNeeded()
    }

    private func cancelRequest(id: UUID) async {
        if let idx = queue.firstIndex(where: { $0.id == id }) {
            let item = queue.remove(at: idx)
            item.continuation.resume(returning: .cancelled)
            return
        }
        if inFlightId == id {
            cancelledInFlightIds.insert(id)
            if let cont = inFlightContinuation {
                inFlightContinuation = nil
                cont.resume(returning: .cancelled)
            }
            await backend.cancel()
        }
    }

    private func processQueue() async {
        defer {
            saveIfNeeded()
            workerTask = nil
        }

        while !queue.isEmpty {
            let req = queue.removeFirst()
            if req.generation != generation {
                req.continuation.resume(returning: .cancelled)
                continue
            }
            if let hit = diskCache[req.norm.key] {
                req.continuation.resume(returning: .resolved(hit))
                continue
            }
            if emptyKeys.contains(req.norm.key) {
                req.continuation.resume(returning: .notFound)
                continue
            }

            if spacingNanoseconds > 0, let last = lastBackendQueryAt {
                let elapsed = last.duration(to: .now)
                let required = Duration.nanoseconds(Int64(min(spacingNanoseconds, UInt64(Int64.max))))
                if elapsed < required {
                    let waitDur = required - elapsed
                    try? await Task.sleep(for: waitDur)
                }
            }

            if req.generation != generation || cancelledInFlightIds.contains(req.id) {
                cancelledInFlightIds.remove(req.id)
                req.continuation.resume(returning: .cancelled)
                continue
            }

            inFlightId = req.id
            inFlightGeneration = req.generation
            inFlightContinuation = req.continuation
            lastBackendQueryAt = .now

            // 必ず約 100 m 粒度に丸めた正規化座標を送信する
            let result = await backend.reverseGeocode(lat: req.norm.lat, lon: req.norm.lon)

            let wasCancelled = (req.generation != generation) || cancelledInFlightIds.remove(req.id) != nil
            let cont = inFlightContinuation
            inFlightId = nil
            inFlightContinuation = nil

            if wasCancelled || result == .cancelled {
                cont?.resume(returning: .cancelled)
                continue
            }

            switch result {
            case .resolved(let name):
                diskCache[req.norm.key] = name
                dirtyCount += 1
                cont?.resume(returning: .resolved(name))
                if dirtyCount >= 5 { saveIfNeeded() }
            case .notFound:
                emptyKeys.insert(req.norm.key)
                cont?.resume(returning: .notFound)
            case .failed:
                // レート制限やオフライン時は永続キャッシュせず、同世代の残りキューを打ち切る
                cont?.resume(returning: .failed)
                let failedGen = req.generation
                var remaining: [RequestItem] = []
                for queued in queue {
                    if queued.generation == failedGen {
                        queued.continuation.resume(returning: .failed)
                    } else {
                        remaining.append(queued)
                    }
                }
                queue = remaining
            case .cancelled:
                cont?.resume(returning: .cancelled)
            }
        }
    }

    private func saveIfNeeded() {
        guard dirtyCount > 0, let fileURL else { return }
        do {
            let data = try ResultCache.encoder.encode(FileFormat(version: 1, entries: diskCache))
            try ResultCache.atomicWrite0600(data, to: fileURL, label: "place-cache.json")
            dirtyCount = 0
        } catch {
            log("place-cache.json を保存できませんでした: \(error.localizedDescription)")
        }
    }
}
