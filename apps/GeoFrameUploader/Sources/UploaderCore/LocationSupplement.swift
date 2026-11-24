import Foundation

/// Drive `properties` や Uploader 側位置補完の出所。
public enum LocationSupplementSource: String, Codable, Sendable, Equatable {
    case photosAsset = "photos_asset"
    case uploaderManual = "uploader_manual"
    case uploaderBorrowed = "uploader_borrowed"

    public var displayLabel: String {
        switch self {
        case .photosAsset: return "写真アプリの位置情報"
        case .uploaderManual: return "手動設定"
        case .uploaderBorrowed: return "近接写真から適用"
        }
    }
}

/// `location-overrides.json` に保存する 1 写真分の補完位置（既存の位置情報を上書きせず、欠落分のみ補完する）。
public struct LocationOverrideEntry: Codable, Sendable, Equatable {
    public var lat: Double
    public var lon: Double
    public var source: LocationSupplementSource
    public var placeName: String?
    public var updatedAt: Date
    public var originalFilename: String?
    public var uti: String?

    public init(lat: Double, lon: Double, source: LocationSupplementSource, placeName: String? = nil,
                updatedAt: Date = Date(), originalFilename: String? = nil, uti: String? = nil) {
        self.lat = lat
        self.lon = lon
        self.source = source
        self.placeName = placeName
        self.updatedAt = updatedAt
        self.originalFilename = originalFilename
        self.uti = uti
    }

    public var location: PhotoLocation { PhotoLocation(lat: lat, lon: lon) }
    public var isValidCoordinate: Bool { PhotoSectioner.isValidCoordinate(location) }

    public func matches(_ item: PhotoItem) -> Bool {
        if originalFilename == nil && uti == nil { return true }
        return originalFilename == item.originalFilename && uti == item.uti
    }
}

/// Uploader 側で設定した補完位置の永続ストア（`location-overrides.json`、0600、アトミック書き込み）。
/// 原則として既存の位置情報（`PhotoItem.location`）を上書きしない。
public final class LocationOverrideStore: @unchecked Sendable {
    public static let currentFormatVersion = 1
    private static let tombstoneRetentionSeconds: TimeInterval = 90 * 86_400

    public let fileURL: URL
    private let lock = NSLock()
    private var entries: [String: LocationOverrideEntry] = [:]
    private var tombstones: [String: Date] = [:]
    private let log: @Sendable (String) -> Void

    private struct FileFormat: Codable {
        var version: Int
        var entries: [String: LocationOverrideEntry]
        var tombstones: [String: Date]?
    }

    public init(fileURL: URL, log: @escaping @Sendable (String) -> Void = { _ in }) {
        self.fileURL = fileURL
        self.log = log
        if FileManager.default.fileExists(atPath: fileURL.path) {
            if let data = try? Data(contentsOf: fileURL),
               let f = try? ResultCache.decoder.decode(FileFormat.self, from: data),
               f.version == Self.currentFormatVersion {
                self.tombstones = f.tombstones ?? [:]
                self.entries = f.entries.filter { id, entry in
                    guard entry.isValidCoordinate else { return false }
                    if let deletedAt = self.tombstones[id], deletedAt >= entry.updatedAt {
                        return false
                    }
                    return true
                }
            } else {
                log("location-overrides.json の形式が異なるか読めないため空で再開します")
            }
        }
    }

    public func refresh() {
        lock.withLock {
            _ = mergeFromDiskLocked()
        }
    }

    public var count: Int {
        lock.withLock { entries.count }
    }

    /// 既存の位置情報（`item.location`）が無い場合だけ、有効な補完エントリを返す。
    public func entry(for item: PhotoItem) -> LocationOverrideEntry? {
        if let loc = item.location, PhotoSectioner.isValidCoordinate(loc) {
            return nil
        }
        return lock.withLock {
            guard let e = entries[item.localIdentifier], e.matches(item), e.isValidCoordinate else {
                return nil
            }
            return e
        }
    }

    public func entries(for items: [PhotoItem]) -> [String: LocationOverrideEntry] {
        lock.withLock {
            var out: [String: LocationOverrideEntry] = [:]
            for item in items {
                if let loc = item.location, PhotoSectioner.isValidCoordinate(loc) { continue }
                if let e = entries[item.localIdentifier], e.matches(item), e.isValidCoordinate {
                    out[item.localIdentifier] = e
                }
            }
            return out
        }
    }

    /// 位置情報が未設定のアイテムにのみ補完位置を保存する（既存の位置情報はスキップ）。
    @discardableResult
    public func set(items: [PhotoItem], location: PhotoLocation, source: LocationSupplementSource,
                    placeName: String? = nil, at date: Date = Date()) -> Int {
        guard PhotoSectioner.isValidCoordinate(location), !items.isEmpty else { return 0 }
        return lock.withLock {
            _ = mergeFromDiskLocked()
            var updated = 0
            for item in items {
                if let existing = item.location, PhotoSectioner.isValidCoordinate(existing) {
                    continue
                }
                let id = item.localIdentifier
                entries[id] = LocationOverrideEntry(
                    lat: location.lat,
                    lon: location.lon,
                    source: source,
                    placeName: placeName,
                    updatedAt: date,
                    originalFilename: item.originalFilename,
                    uti: item.uti
                )
                if let deletedAt = tombstones[id], deletedAt <= date {
                    tombstones.removeValue(forKey: id)
                }
                updated += 1
            }
            if updated > 0 {
                saveLocked(referenceDate: date)
            }
            return updated
        }
    }

    public func remove(localIdentifiers: [String], at date: Date = Date()) {
        guard !localIdentifiers.isEmpty else { return }
        lock.withLock {
            _ = mergeFromDiskLocked()
            var changed = false
            for id in localIdentifiers {
                if entries.removeValue(forKey: id) != nil { changed = true }
                let prev = tombstones[id]
                let next = max(prev ?? .distantPast, date)
                if prev != next {
                    tombstones[id] = next
                    changed = true
                }
            }
            if changed {
                saveLocked(referenceDate: date)
            }
        }
    }

    @discardableResult
    private func mergeFromDiskLocked() -> Bool {
        guard let data = try? Data(contentsOf: fileURL),
              let disk = try? ResultCache.decoder.decode(FileFormat.self, from: data),
              disk.version == Self.currentFormatVersion else {
            return false
        }
        var changed = false
        if let diskTombs = disk.tombstones {
            for (id, dDate) in diskTombs {
                if dDate > (tombstones[id] ?? .distantPast) {
                    tombstones[id] = dDate
                    changed = true
                }
            }
        }
        for (id, dEntry) in disk.entries where dEntry.isValidCoordinate {
            if let mEntry = entries[id] {
                if dEntry.updatedAt > mEntry.updatedAt {
                    entries[id] = dEntry
                    changed = true
                }
            } else {
                entries[id] = dEntry
                changed = true
            }
        }
        for (id, deletedAt) in tombstones {
            if let entry = entries[id], deletedAt >= entry.updatedAt {
                entries.removeValue(forKey: id)
                changed = true
            }
        }
        return changed
    }

    private func saveLocked(referenceDate: Date) {
        _ = mergeFromDiskLocked()
        let cutoff = referenceDate.addingTimeInterval(-Self.tombstoneRetentionSeconds)
        let activeTombstones = tombstones.filter { $0.value >= cutoff }
        tombstones = activeTombstones
        let validEntries = entries.filter { $0.value.isValidCoordinate }
        do {
            let payload = FileFormat(
                version: Self.currentFormatVersion,
                entries: validEntries,
                tombstones: activeTombstones.isEmpty ? nil : activeTombstones
            )
            let data = try ResultCache.encoder.encode(payload)
            try ResultCache.atomicWrite0600(data, to: fileURL, label: "location-overrides.json")
        } catch {
            log("location-overrides.json を保存できませんでした: \(error.localizedDescription)")
        }
    }
}

/// アップロード時に Drive `properties` として付与する解決済み位置情報。
public struct ResolvedUploadLocation: Sendable, Equatable {
    public let location: PhotoLocation
    public let source: LocationSupplementSource

    public init(location: PhotoLocation, source: LocationSupplementSource) {
        self.location = location
        self.source = source
    }
}

/// Drive カスタム属性 `properties` 契約および座標フォーマット・パースユーティリティ。
public enum DriveLocationProperties {
    public static let latKey = "geoframe.lat"
    public static let lonKey = "geoframe.lon"
    public static let sourceKey = "geoframe.loc_source"
    private static let posix = Locale(identifier: "en_US_POSIX")

    /// 原本 EXIF GPS → `PHAsset.location` → Uploader 補完 の優先順で不足分だけを補う。
    /// 原本 EXIF に既に有効な GPS がある場合は既存位置を尊重し、`nil`（`properties` 付与なし）を返す。
    public static func resolveForUpload(
        item: PhotoItem,
        exifGPS: PhotoLocation?,
        override: LocationOverrideEntry?
    ) -> ResolvedUploadLocation? {
        if let gps = exifGPS, PhotoSectioner.isValidCoordinate(gps) {
            return nil
        }
        if let assetLoc = item.location, PhotoSectioner.isValidCoordinate(assetLoc) {
            return ResolvedUploadLocation(location: assetLoc, source: .photosAsset)
        }
        if let ov = override, ov.matches(item), ov.isValidCoordinate {
            return ResolvedUploadLocation(location: ov.location, source: ov.source)
        }
        return nil
    }

    public static func formatCoordinate(_ value: Double) -> String {
        let s = String(format: "%.6f", locale: posix, value)
        return s == "-0.000000" ? "0.000000" : s
    }

    public static func makeProperties(for resolved: ResolvedUploadLocation) -> [String: String]? {
        guard PhotoSectioner.isValidCoordinate(resolved.location) else { return nil }
        return [
            latKey: formatCoordinate(resolved.location.lat),
            lonKey: formatCoordinate(resolved.location.lon),
            sourceKey: resolved.source.rawValue,
        ]
    }

    /// 緯度・経度テキスト（例 `"35.681236, 139.767125"` / Google マップ `@lat,lon,15z`）をパースする。
    public static func parseCoordinateString(_ raw: String) -> PhotoLocation? {
        let half = (raw.applyingTransform(.fullwidthToHalfwidth, reverse: false) ?? raw)
            .replacingOccurrences(of: "\u{2212}", with: "-")
            .replacingOccurrences(of: "\u{FF0D}", with: "-")
            .replacingOccurrences(of: "、", with: ",")
            .replacingOccurrences(of: "､", with: ",")
            .replacingOccurrences(of: "，", with: ",")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !half.isEmpty else { return nil }

        let tokens: [String]
        if let atIdx = half.firstIndex(of: "@") {
            let afterAt = half[half.index(after: atIdx)...]
            let segment = afterAt.split(whereSeparator: { $0 == "/" || $0 == "?" || $0 == "&" }).first ?? afterAt
            let parts = segment.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            guard parts.count >= 2 else { return nil }
            tokens = [parts[0], parts[1]]
        } else {
            var cleaned = half
                .replacingOccurrences(of: "、", with: ",")
                .replacingOccurrences(of: "，", with: ",")
            if (cleaned.hasPrefix("(") && cleaned.hasSuffix(")"))
                || (cleaned.hasPrefix("[") && cleaned.hasSuffix("]")) {
                cleaned = String(cleaned.dropFirst().dropLast())
            }
            if cleaned.contains(",") {
                tokens = cleaned.split(separator: ",", omittingEmptySubsequences: false)
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            } else {
                tokens = cleaned.components(separatedBy: .whitespacesAndNewlines)
                    .filter { !$0.isEmpty }
            }
            guard tokens.count == 2 else { return nil }
        }

        guard let lat = Double(tokens[0]), let lon = Double(tokens[1]) else { return nil }
        let loc = PhotoLocation(lat: lat, lon: lon)
        return PhotoSectioner.isValidCoordinate(loc) ? loc : nil
    }
}
