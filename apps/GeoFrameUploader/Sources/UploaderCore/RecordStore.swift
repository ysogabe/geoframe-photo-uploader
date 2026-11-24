import Foundation

public enum RecordResult: String, Codable, Sendable {
    case sent
    case skippedDuplicate = "skipped_duplicate"
    case skippedIneligible = "skipped_ineligible"
    case failed
}

/// records.jsonl の 1 行。値が無い項目も null として出力する。
public struct UploadRecord: Codable, Sendable, Equatable {
    public var runId: String
    public var recordedAt: String
    public var localIdentifier: String
    public var originalFilename: String?
    public var uti: String?
    public var byteCount: Int64?
    public var md5: String?
    public var sha256: String?
    public var creationDate: String?
    public var creationTimeZone: String
    public var exifDateTimeOriginal: String?
    public var exifOffsetTimeOriginal: String?
    public var location: PhotoLocation?
    public var pixelWidth: Int
    public var pixelHeight: Int
    public var burstIdentifier: String?
    public var isFavorite: Bool
    public var isLivePhoto: Bool
    public var hasAdjustments: Bool
    public var result: RecordResult
    public var driveFileId: String?
    public var driveMd5Checksum: String?
    public var verified: Bool
    public var error: String?
    public var folderId: String
    public var exifHasGPS: Bool?
    public var uploadedLocation: PhotoLocation?
    public var uploadedLocationSource: LocationSupplementSource?

    public init(runId: String, recordedAt: Date = Date(), item: PhotoItem, exported: ExportedOriginal?,
                result: RecordResult, driveFileId: String? = nil, driveMd5Checksum: String? = nil,
                verified: Bool = false, error: String? = nil, folderId: String, timeZone: TimeZone = .current,
                uploadedLocation: PhotoLocation? = nil, uploadedLocationSource: LocationSupplementSource? = nil) {
        self.runId = runId
        self.recordedAt = LocalTime.iso8601(recordedAt, timeZone: timeZone)
        self.localIdentifier = item.localIdentifier
        self.originalFilename = item.originalFilename
        self.uti = item.uti
        self.byteCount = exported?.byteCount
        self.md5 = exported?.md5Hex
        self.sha256 = exported?.sha256Hex
        self.creationDate = item.creationDate.map { LocalTime.iso8601($0, timeZone: timeZone) }
        self.creationTimeZone = timeZone.identifier
        self.exifDateTimeOriginal = exported?.exif?.dateTimeOriginal
        self.exifOffsetTimeOriginal = exported?.exif?.offsetTimeOriginal
        self.location = item.location
        self.pixelWidth = item.pixelWidth
        self.pixelHeight = item.pixelHeight
        self.burstIdentifier = item.burstIdentifier
        self.isFavorite = item.isFavorite
        self.isLivePhoto = item.isLivePhoto
        self.hasAdjustments = item.hasAdjustments
        self.result = result
        self.driveFileId = driveFileId
        self.driveMd5Checksum = driveMd5Checksum
        self.verified = verified
        self.error = error.map(Redactor.redact)
        self.folderId = folderId
        self.exifHasGPS = exported.map { $0.exifGPS != nil }
        self.uploadedLocation = uploadedLocation
        self.uploadedLocationSource = uploadedLocationSource
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        func opt<T: Encodable>(_ v: T?, _ k: CodingKeys) throws {
            if let v { try c.encode(v, forKey: k) } else { try c.encodeNil(forKey: k) }
        }
        try c.encode(runId, forKey: .runId)
        try c.encode(recordedAt, forKey: .recordedAt)
        try c.encode(localIdentifier, forKey: .localIdentifier)
        try opt(originalFilename, .originalFilename)
        try opt(uti, .uti)
        try opt(byteCount, .byteCount)
        try opt(md5, .md5)
        try opt(sha256, .sha256)
        try opt(creationDate, .creationDate)
        try c.encode(creationTimeZone, forKey: .creationTimeZone)
        try opt(exifDateTimeOriginal, .exifDateTimeOriginal)
        try opt(exifOffsetTimeOriginal, .exifOffsetTimeOriginal)
        try opt(location, .location)
        try c.encode(pixelWidth, forKey: .pixelWidth)
        try c.encode(pixelHeight, forKey: .pixelHeight)
        try opt(burstIdentifier, .burstIdentifier)
        try c.encode(isFavorite, forKey: .isFavorite)
        try c.encode(isLivePhoto, forKey: .isLivePhoto)
        try c.encode(hasAdjustments, forKey: .hasAdjustments)
        try c.encode(result, forKey: .result)
        try opt(driveFileId, .driveFileId)
        try opt(driveMd5Checksum, .driveMd5Checksum)
        try c.encode(verified, forKey: .verified)
        try opt(error, .error)
        try c.encode(folderId, forKey: .folderId)
        try opt(exifHasGPS, .exifHasGPS)
        try opt(uploadedLocation, .uploadedLocation)
        try opt(uploadedLocationSource, .uploadedLocationSource)
    }
}

/// JSON Lines 追記（0600）。
public final class RecordStore: @unchecked Sendable {
    public let fileURL: URL
    private let lock = NSLock()

    public init(fileURL: URL) { self.fileURL = fileURL }

    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return e
    }()

    public func append(_ record: UploadRecord) throws {
        var line = try Self.encoder.encode(record)
        line.append(0x0A)
        lock.lock(); defer { lock.unlock() }
        // O_CREAT のモード指定で作成と同時に 0600（作成後に権限を変える隙間を作らない）
        let fd = open(fileURL.path, O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw DriveError.fileIO("records.jsonl: \(String(cString: strerror(errno)))") }
        defer { close(fd) }
        _ = fchmod(fd, 0o600)
        try line.withUnsafeBytes { (buf: UnsafeRawBufferPointer) in
            var off = 0
            while off < buf.count {
                let n = write(fd, buf.baseAddress! + off, buf.count - off)
                if n < 0 {
                    if errno == EINTR { continue }
                    throw DriveError.fileIO("records.jsonl: \(String(cString: strerror(errno)))")
                }
                off += n
            }
        }
    }

    public func readAll() throws -> [UploadRecord] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        let text = try String(contentsOf: fileURL, encoding: .utf8)
        return try text.split(separator: "\n").map { try JSONDecoder().decode(UploadRecord.self, from: Data($0.utf8)) }
    }
}
