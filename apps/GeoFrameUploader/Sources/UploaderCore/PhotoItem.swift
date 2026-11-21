import Foundation

public struct PhotoLocation: Codable, Sendable, Equatable {
    public var lat: Double
    public var lon: Double
    public var altitude: Double?
    public var horizontalAccuracy: Double?

    public init(lat: Double, lon: Double, altitude: Double? = nil, horizontalAccuracy: Double? = nil) {
        self.lat = lat; self.lon = lon; self.altitude = altitude; self.horizontalAccuracy = horizontalAccuracy
    }
}

/// 写真ライブラリの 1 アセット（PhotoKit 非依存の値型。UI / CLI / 記録で共有）。
public struct PhotoItem: Codable, Sendable, Equatable, Identifiable {
    public var id: String { localIdentifier }

    public var localIdentifier: String
    /// `.photo` リソースの originalFilename（無ければ nil）
    public var originalFilename: String?
    /// `.photo` リソースの UTI（無ければ nil）
    public var uti: String?
    public var mediaKind: MediaKind
    public var creationDate: Date?
    public var location: PhotoLocation?
    public var pixelWidth: Int
    public var pixelHeight: Int
    public var burstIdentifier: String?
    public var isFavorite: Bool
    public var isLivePhoto: Bool
    public var hasAdjustments: Bool
    public var mediaSubtypesRaw: UInt
    public var eligibility: Eligibility

    public init(localIdentifier: String, originalFilename: String?, uti: String?, mediaKind: MediaKind,
                creationDate: Date?, location: PhotoLocation? = nil, pixelWidth: Int = 0, pixelHeight: Int = 0,
                burstIdentifier: String? = nil, isFavorite: Bool = false, isLivePhoto: Bool = false,
                hasAdjustments: Bool = false, mediaSubtypesRaw: UInt = 0, eligibility: Eligibility? = nil) {
        self.localIdentifier = localIdentifier
        self.originalFilename = originalFilename
        self.uti = uti
        self.mediaKind = mediaKind
        self.creationDate = creationDate
        self.location = location
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.burstIdentifier = burstIdentifier
        self.isFavorite = isFavorite
        self.isLivePhoto = isLivePhoto
        self.hasAdjustments = hasAdjustments
        self.mediaSubtypesRaw = mediaSubtypesRaw
        self.eligibility = eligibility ?? EligibilityClassifier.classify(mediaKind: mediaKind, photoResourceUTI: uti)
    }

    /// Drive 上のファイル名（原本ファイル名そのまま）。
    public var driveName: String { originalFilename ?? "\(localIdentifier.replacingOccurrences(of: "/", with: "_"))" }
    public var mimeType: String? { uti.flatMap(EligibilityClassifier.mimeType(forUTI:)) }
}

/// ローカル時刻（Mac の現在のタイムゾーン）でオフセット付き ISO8601 を作る。
public enum LocalTime {
    public static func iso8601(_ date: Date, timeZone: TimeZone = .current) -> String {
        let f = ISO8601DateFormatter()
        f.timeZone = timeZone
        f.formatOptions = [.withInternetDateTime]
        return f.string(from: date)
    }

    /// "YYYY-MM-DD" をローカルの暦日として解釈。
    public static func parseDay(_ s: String, calendar: Calendar = .current) -> DateComponents? {
        let parts = s.split(separator: "-")
        guard parts.count == 3, let y = Int(parts[0]), let m = Int(parts[1]), let d = Int(parts[2]),
              (1...12).contains(m), (1...31).contains(d) else { return nil }
        var dc = DateComponents(year: y, month: m, day: d)
        dc.calendar = calendar
        guard dc.isValidDate(in: calendar) else { return nil }
        return dc
    }

    /// [startOfDay(from), startOfDay(to) + 1 日) を返す（from == to で 1 日分）。
    public static func dayRange(from: Date, to: Date, calendar: Calendar = .current) -> (start: Date, end: Date) {
        let s = calendar.startOfDay(for: min(from, to))
        let lastDay = calendar.startOfDay(for: max(from, to))
        let e = calendar.date(byAdding: .day, value: 1, to: lastDay) ?? lastDay.addingTimeInterval(86400)
        return (s, e)
    }

    public static func dayRange(fromDay: String, toDay: String?, calendar: Calendar = .current) -> (start: Date, end: Date)? {
        guard let f = parseDay(fromDay, calendar: calendar), let fd = calendar.date(from: f) else { return nil }
        var td = fd
        if let toDay {
            guard let t = parseDay(toDay, calendar: calendar), let d = calendar.date(from: t) else { return nil }
            td = d
        }
        return dayRange(from: fd, to: td, calendar: calendar)
    }
}
