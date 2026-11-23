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
    public var modificationDate: Date?

    public init(localIdentifier: String, originalFilename: String?, uti: String?, mediaKind: MediaKind,
                creationDate: Date?, location: PhotoLocation? = nil, pixelWidth: Int = 0, pixelHeight: Int = 0,
                burstIdentifier: String? = nil, isFavorite: Bool = false, isLivePhoto: Bool = false,
                hasAdjustments: Bool = false, mediaSubtypesRaw: UInt = 0, eligibility: Eligibility? = nil,
                modificationDate: Date? = nil) {
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
        self.modificationDate = modificationDate
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

    /// 開始日〜終了日の暦日数（同日なら 1）。
    public static func inclusiveDayCount(from: Date, to: Date, calendar: Calendar = .current) -> Int {
        let s = calendar.startOfDay(for: min(from, to))
        let e = calendar.startOfDay(for: max(from, to))
        let days = calendar.dateComponents([.day], from: s, to: e).day ?? 0
        return max(1, days + 1)
    }

    public static func startOfMonth(for date: Date, calendar: Calendar = .current) -> Date {
        let comps = calendar.dateComponents([.year, .month], from: date)
        return calendar.startOfDay(for: calendar.date(from: comps) ?? date)
    }

    public static func addingMonths(_ delta: Int, to monthDate: Date, calendar: Calendar = .current) -> Date {
        let m = startOfMonth(for: monthDate, calendar: calendar)
        return calendar.date(byAdding: .month, value: delta, to: m) ?? m
    }

    /// 2ヶ月見開き・大判レンジカレンダー用の固定 42 マス（6 週 × 日曜始まり 7 列）を生成する。
    public static func monthGrid(forMonth monthDate: Date, calendar: Calendar = .current) -> [CalendarDayCell] {
        let firstOfMonth = startOfMonth(for: monthDate, calendar: calendar)
        let weekday = calendar.component(.weekday, from: firstOfMonth) // 1 = 日曜 ... 7 = 土曜
        let leadingDays = (weekday - 1 + 7) % 7
        let gridStart = calendar.date(byAdding: .day, value: -leadingDays, to: firstOfMonth) ?? firstOfMonth
        var out: [CalendarDayCell] = []
        out.reserveCapacity(42)
        for offset in 0..<42 {
            let raw = calendar.date(byAdding: .day, value: offset, to: gridStart) ?? gridStart
            let day = calendar.startOfDay(for: raw)
            let inMonth = calendar.isDate(day, equalTo: firstOfMonth, toGranularity: .month)
            let dayNum = calendar.component(.day, from: day)
            let wd = calendar.component(.weekday, from: day)
            let comps = calendar.dateComponents([.year, .month, .day], from: day)
            let key = String(format: "%04d-%02d-%02d-%@", comps.year ?? 0, comps.month ?? 0, comps.day ?? 0, inMonth ? "c" : "a")
            out.append(CalendarDayCell(id: key, date: day, dayNumber: dayNum, isCurrentMonth: inMonth, weekday: wd))
        }
        return out
    }
}

/// 大判カレンダーの 1 日分セル。
public struct CalendarDayCell: Identifiable, Equatable, Sendable {
    public let id: String
    public let date: Date
    public let dayNumber: Int
    public let isCurrentMonth: Bool
    /// 1 = 日曜 ... 7 = 土曜
    public let weekday: Int

    public init(id: String, date: Date, dayNumber: Int, isCurrentMonth: Bool, weekday: Int) {
        self.id = id
        self.date = date
        self.dayNumber = dayNumber
        self.isCurrentMonth = isCurrentMonth
        self.weekday = weekday
    }
}

/// よく使う日付範囲のクイックプリセット。
public enum DateRangePreset: String, CaseIterable, Identifiable, Sendable {
    case today
    case yesterday
    case last3Days
    case last7Days
    case last14Days
    case last30Days
    case thisMonth
    case lastMonth

    public var id: Self { self }

    /// 上部ツールバー用の短いラベル。
    public var shortLabel: String {
        switch self {
        case .today: return "今日"
        case .yesterday: return "昨日"
        case .last3Days: return "直近3日"
        case .last7Days: return "直近7日"
        case .last14Days: return "直近14日"
        case .last30Days: return "直近30日"
        case .thisMonth: return "今月"
        case .lastMonth: return "先月"
        }
    }

    /// ポップオーバー左サイド一覧用のラベル。
    public var sidebarLabel: String {
        switch self {
        case .today: return "今日"
        case .yesterday: return "昨日"
        case .last3Days: return "直近 3 日間"
        case .last7Days: return "直近 7 日間"
        case .last14Days: return "直近 14 日間"
        case .last30Days: return "直近 30 日間"
        case .thisMonth: return "今月"
        case .lastMonth: return "先月"
        }
    }

    /// 上部バーに常時並べる主要プリセット。
    public static let toolbarPresets: [DateRangePreset] = [
        .today, .yesterday, .last3Days, .last7Days, .last30Days, .thisMonth,
    ]

    public func dateRange(now: Date = Date(), calendar: Calendar = .current) -> (from: Date, to: Date) {
        let todayStart = calendar.startOfDay(for: now)
        switch self {
        case .today:
            return (todayStart, todayStart)
        case .yesterday:
            let y = calendar.date(byAdding: .day, value: -1, to: todayStart) ?? todayStart
            return (y, y)
        case .last3Days:
            let f = calendar.date(byAdding: .day, value: -2, to: todayStart) ?? todayStart
            return (f, todayStart)
        case .last7Days:
            let f = calendar.date(byAdding: .day, value: -6, to: todayStart) ?? todayStart
            return (f, todayStart)
        case .last14Days:
            let f = calendar.date(byAdding: .day, value: -13, to: todayStart) ?? todayStart
            return (f, todayStart)
        case .last30Days:
            let f = calendar.date(byAdding: .day, value: -29, to: todayStart) ?? todayStart
            return (f, todayStart)
        case .thisMonth:
            let startOfMonth = LocalTime.startOfMonth(for: todayStart, calendar: calendar)
            return (startOfMonth, todayStart)
        case .lastMonth:
            let startOfThisMonth = LocalTime.startOfMonth(for: todayStart, calendar: calendar)
            let startOfLastMonth = calendar.date(byAdding: .month, value: -1, to: startOfThisMonth) ?? startOfThisMonth
            let endOfLastMonth = calendar.date(byAdding: .day, value: -1, to: startOfThisMonth) ?? startOfLastMonth
            return (startOfLastMonth, endOfLastMonth)
        }
    }

    public static func matching(from: Date, to: Date, now: Date = Date(), calendar: Calendar = .current) -> DateRangePreset? {
        let s = min(from, to)
        let e = max(from, to)
        for preset in Self.allCases {
            let r = preset.dateRange(now: now, calendar: calendar)
            if calendar.isDate(s, inSameDayAs: r.from) && calendar.isDate(e, inSameDayAs: r.to) {
                return preset
            }
        }
        return nil
    }
}
