import Foundation

public struct SectionOptions: Sendable, Equatable {
    public var timeGapSeconds: TimeInterval
    public var distanceThresholdMeters: Double
    public var gpsInferenceWindowSeconds: TimeInterval

    public init(timeGapSeconds: TimeInterval = 1800,
                distanceThresholdMeters: Double = 300,
                gpsInferenceWindowSeconds: TimeInterval = 7200) {
        self.timeGapSeconds = timeGapSeconds
        self.distanceThresholdMeters = distanceThresholdMeters
        self.gpsInferenceWindowSeconds = gpsInferenceWindowSeconds
    }
}

/// 場所・時間枠でまとまった写真セクション。
public struct PhotoSection: Sendable, Equatable, Identifiable {
    /// 先頭写真の localIdentifier（日時不明セクションは "undated"）
    public let id: String
    public let startDate: Date?
    public let endDate: Date?
    public let representativeLocation: PhotoLocation?
    public let isLocationBorrowed: Bool
    public let locationKey: String?
    public let items: [PhotoItem]

    public init(id: String, startDate: Date?, endDate: Date?, representativeLocation: PhotoLocation?,
                isLocationBorrowed: Bool, locationKey: String?, items: [PhotoItem]) {
        self.id = id
        self.startDate = startDate
        self.endDate = endDate
        self.representativeLocation = representativeLocation
        self.isLocationBorrowed = isLocationBorrowed
        self.locationKey = locationKey
        self.items = items
    }
}

/// 写真一覧を「場所 × 時間枠」のセクションに分割する純粋関数群。
/// 境界判定は実 GPS 同士のみで比較し、欠落 GPS の借用は表示用代表座標のみに行う。
public enum PhotoSectioner {
    private static let earthRadiusMeters = 6_371_000.0
    private static let posix = Locale(identifier: "en_US_POSIX")

    public static func isValidCoordinate(_ loc: PhotoLocation) -> Bool {
        loc.lat.isFinite && loc.lon.isFinite && abs(loc.lat) <= 90.0 && abs(loc.lon) <= 180.0
    }

    /// 2 点間の Haversine 大圏距離（メートル）。座標が無効なら nil。
    public static func haversineMeters(_ a: PhotoLocation, _ b: PhotoLocation) -> Double? {
        guard isValidCoordinate(a), isValidCoordinate(b) else { return nil }
        let dLat = (b.lat - a.lat) * .pi / 180.0
        let dLon = (b.lon - a.lon) * .pi / 180.0
        let lat1 = a.lat * .pi / 180.0
        let lat2 = b.lat * .pi / 180.0
        let sinHalfLat = sin(dLat / 2.0)
        let sinHalfLon = sin(dLon / 2.0)
        let rawA = sinHalfLat * sinHalfLat + cos(lat1) * cos(lat2) * sinHalfLon * sinHalfLon
        let clampedA = min(1.0, max(0.0, rawA))
        let c = 2.0 * atan2(sqrt(clampedA), sqrt(1.0 - clampedA))
        return earthRadiusMeters * c
    }

    public struct NormalizedCoordinate: Sendable, Equatable {
        public let lat: Double
        public let lon: Double
        public let key: String
    }

    /// 座標を小数点 3 桁（約 100 m 格子）に丸め、`-0.000` / `-180.000` を正規化した座標とキーを返す。
    public static func normalizedCoordinate(_ loc: PhotoLocation, languagePrefix: String = "ja") -> NormalizedCoordinate? {
        guard isValidCoordinate(loc) else { return nil }
        var rLat = (loc.lat * 1000.0).rounded() / 1000.0
        var rLon = (loc.lon * 1000.0).rounded() / 1000.0
        if abs(rLat) < 0.0005 { rLat = 0.0 }
        if abs(rLon) < 0.0005 { rLon = 0.0 }
        if abs(rLon + 180.0) < 0.0005 { rLon = 180.0 }
        let key = String(format: "%@:%.3f,%.3f", locale: posix, languagePrefix, rLat, rLon)
        return NormalizedCoordinate(lat: rLat, lon: rLon, key: key)
    }

    /// 逆ジオコーディングキャッシュ用の正規化キー。
    public static func coordinateKey(_ loc: PhotoLocation, languagePrefix: String = "ja") -> String? {
        normalizedCoordinate(loc, languagePrefix: languagePrefix)?.key
    }

    /// 全 `items`（`hideDone` 適用前）に対して安定ソート＆セクション分割する。
    public static func section(items: [PhotoItem], options: SectionOptions = SectionOptions()) -> [PhotoSection] {
        guard !items.isEmpty else { return [] }

        let timed = items
            .filter { $0.creationDate != nil }
            .sorted { a, b in
                let ta = a.creationDate!
                let tb = b.creationDate!
                if ta != tb { return ta < tb }
                return a.localIdentifier < b.localIdentifier
            }

        let undated = items
            .filter { $0.creationDate == nil }
            .sorted { $0.localIdentifier < $1.localIdentifier }

        // 実 GPS を持つ時刻順アンカー一覧（表示用補完のみに使う）
        let anchors: [(date: Date, loc: PhotoLocation)] = timed.compactMap { it in
            guard let d = it.creationDate, let l = it.location, isValidCoordinate(l) else { return nil }
            return (d, l)
        }

        var buckets: [[PhotoItem]] = []
        var current: [PhotoItem] = []
        var prevDate: Date?
        var lastRealGPS: PhotoLocation?

        for item in timed {
            let d = item.creationDate!
            let realLoc = item.location.flatMap { isValidCoordinate($0) ? $0 : nil }

            var split = false
            if let pd = prevDate, d.timeIntervalSince(pd) > options.timeGapSeconds {
                split = true
            }
            if !split, let prevGPS = lastRealGPS, let curGPS = realLoc,
               let dist = haversineMeters(prevGPS, curGPS) {
                let accA = (prevGPS.horizontalAccuracy ?? 0).isFinite ? max(0, prevGPS.horizontalAccuracy ?? 0) : 0
                let accB = (curGPS.horizontalAccuracy ?? 0).isFinite ? max(0, curGPS.horizontalAccuracy ?? 0) : 0
                let threshold = max(options.distanceThresholdMeters, accA + accB)
                if dist > threshold {
                    split = true
                }
            }

            if split && !current.isEmpty {
                buckets.append(current)
                current = []
                lastRealGPS = nil
            }
            current.append(item)
            prevDate = d
            if let realLoc { lastRealGPS = realLoc }
        }
        if !current.isEmpty { buckets.append(current) }

        var sections: [PhotoSection] = buckets.map { group in
            let start = group.first?.creationDate
            let end = group.last?.creationDate
            let firstReal = group.compactMap { $0.location }.first(where: isValidCoordinate)
            let rep: PhotoLocation?
            let borrowed: Bool
            if let firstReal {
                rep = firstReal
                borrowed = false
            } else if let start, let end {
                let mid = Date(timeIntervalSince1970: (start.timeIntervalSince1970 + end.timeIntervalSince1970) / 2.0)
                rep = nearestAnchor(around: mid, in: anchors, maxWindow: options.gpsInferenceWindowSeconds)
                borrowed = rep != nil
            } else {
                rep = nil
                borrowed = false
            }
            let key = rep.flatMap { coordinateKey($0) }
            return PhotoSection(
                id: group[0].localIdentifier,
                startDate: start,
                endDate: end,
                representativeLocation: rep,
                isLocationBorrowed: borrowed,
                locationKey: key,
                items: group
            )
        }

        if !undated.isEmpty {
            sections.append(PhotoSection(
                id: "undated",
                startDate: nil,
                endDate: nil,
                representativeLocation: nil,
                isLocationBorrowed: false,
                locationKey: nil,
                items: undated
            ))
        }
        return sections
    }

    private static func nearestAnchor(around target: Date, in anchors: [(date: Date, loc: PhotoLocation)],
                                      maxWindow: TimeInterval) -> PhotoLocation? {
        var bestDist = Double.infinity
        var bestLoc: PhotoLocation?
        for a in anchors {
            let dt = abs(a.date.timeIntervalSince(target))
            if dt <= maxWindow && dt < bestDist {
                bestDist = dt
                bestLoc = a.loc
            }
        }
        return bestLoc
    }
}
