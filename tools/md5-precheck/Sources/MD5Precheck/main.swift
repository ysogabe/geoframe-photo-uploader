// geoframe 写真アップローダー 前提検証:
// PhotoKit から取得した原本リソース（PHAssetResource .photo）のバイト列 MD5 が
// Drive 側カタログの md5Checksum と一致するかを確かめる。読み取り専用。原本バイトは保存しない。
//
// 使い方（.app 経由で起動すること。scripts/run.sh 参照）:
//   MD5Precheck --out <result.json> --mode status
//   MD5Precheck --out <result.json> --mode run --target 'IMG_1254.HEIC|2026-11-01 12:50|ff43...' ...
//   MD5Precheck --out <result.json> --mode selftest --file <path>

import AppKit
import CryptoKit
import Foundation
import Photos

// MARK: - 引数

struct Target {
    let filename: String
    let dateText: String
    let expectedMD5: String
}

var outPath = FileManager.default.currentDirectoryPath + "/md5-precheck-result.json"
var mode = "status"
var targets: [Target] = []
var selftestFile: String?

do {
    var it = CommandLine.arguments.dropFirst().makeIterator()
    while let a = it.next() {
        switch a {
        case "--out": outPath = it.next() ?? outPath
        case "--mode": mode = it.next() ?? mode
        case "--file": selftestFile = it.next()
        case "--target":
            if let spec = it.next() {
                let p = spec.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
                if p.count == 3 { targets.append(Target(filename: p[0], dateText: p[1], expectedMD5: p[2].lowercased())) }
            }
        default: break
        }
    }
}

// MARK: - 出力

var report: [String: Any] = [
    "startedAt": ISO8601DateFormatter().string(from: Date()),
    "mode": mode,
    "processTimeZone": TimeZone.current.identifier,
    "bundleIdentifier": Bundle.main.bundleIdentifier ?? NSNull(),
]

func log(_ s: String) {
    FileHandle.standardError.write((s + "\n").data(using: .utf8)!)
}

func finish(_ code: Int32) -> Never {
    report["finishedAt"] = ISO8601DateFormatter().string(from: Date())
    do {
        let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: URL(fileURLWithPath: outPath))
        log("wrote \(outPath)")
    } catch {
        log("failed to write report: \(error)")
    }
    exit(code)
}

// MARK: - ユーティリティ

func hex(_ d: Insecure.MD5.Digest) -> String { d.map { String(format: "%02x", $0) }.joined() }

func authName(_ s: PHAuthorizationStatus) -> String {
    switch s {
    case .notDetermined: return "notDetermined"
    case .restricted: return "restricted"
    case .denied: return "denied"
    case .authorized: return "authorized"
    case .limited: return "limited"
    @unknown default: return "unknown(\(s.rawValue))"
    }
}

func resourceTypeName(_ t: PHAssetResourceType) -> String {
    switch t {
    case .photo: return "photo"
    case .video: return "video"
    case .audio: return "audio"
    case .alternatePhoto: return "alternatePhoto"
    case .fullSizePhoto: return "fullSizePhoto"
    case .fullSizeVideo: return "fullSizeVideo"
    case .adjustmentData: return "adjustmentData"
    case .adjustmentBasePhoto: return "adjustmentBasePhoto"
    case .pairedVideo: return "pairedVideo"
    case .fullSizePairedVideo: return "fullSizePairedVideo"
    case .adjustmentBasePairedVideo: return "adjustmentBasePairedVideo"
    case .adjustmentBaseVideo: return "adjustmentBaseVideo"
    case .photoProxy: return "photoProxy"
    @unknown default: return "unknown(\(t.rawValue))"
    }
}

let hashableTypes: Set<PHAssetResourceType> = [.photo, .fullSizePhoto, .alternatePhoto, .adjustmentBasePhoto]

struct FetchResult {
    var md5: String?
    var bytes: Int = 0
    var source: String = "unknown"   // "local" / "iCloud"
    var errors: [String] = []
}

/// requestData を1回実行してストリーミングで MD5 を計算する。
func hashResource(_ r: PHAssetResource, network: Bool, timeout: TimeInterval) -> (md5: String?, bytes: Int, error: Error?) {
    let opts = PHAssetResourceRequestOptions()
    opts.isNetworkAccessAllowed = network
    var hasher = Insecure.MD5()
    var bytes = 0
    var err: Error?
    let sem = DispatchSemaphore(value: 0)
    let lock = NSLock()
    PHAssetResourceManager.default().requestData(for: r, options: opts, dataReceivedHandler: { chunk in
        lock.lock(); hasher.update(data: chunk); bytes += chunk.count; lock.unlock()
    }, completionHandler: { e in
        err = e
        sem.signal()
    })
    if sem.wait(timeout: .now() + timeout) == .timedOut {
        return (nil, bytes, NSError(domain: "MD5Precheck", code: -1, userInfo: [NSLocalizedDescriptionKey: "timeout after \(timeout)s"]))
    }
    if let e = err { return (nil, bytes, e) }
    return (hex(hasher.finalize()), bytes, nil)
}

/// まずネットワーク不可で取得 → 失敗したらネットワーク可で再取得。成功した方で local/iCloud を判定。
func fetch(_ r: PHAssetResource) -> FetchResult {
    var out = FetchResult()
    let local = hashResource(r, network: false, timeout: 120)
    if let md5 = local.md5 {
        out.md5 = md5; out.bytes = local.bytes; out.source = "local"
        return out
    }
    if let e = local.error as NSError? { out.errors.append("local-only attempt: \(e.domain) \(e.code) \(e.localizedDescription)") }
    let remote = hashResource(r, network: true, timeout: 600)
    if let md5 = remote.md5 {
        out.md5 = md5; out.bytes = remote.bytes; out.source = "iCloud"
    } else if let e = remote.error as NSError? {
        out.errors.append("network attempt: \(e.domain) \(e.code) \(e.localizedDescription)")
    }
    return out
}

func parseLocalDate(_ s: String) -> Date? {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.timeZone = TimeZone.current
    f.dateFormat = "yyyy-MM-dd HH:mm"
    return f.date(from: s)
}

let isoLocal: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.timeZone = TimeZone.current
    f.formatOptions = [.withInternetDateTime]
    return f
}()

// MARK: - モード

func runSelftest() -> Never {
    guard let path = selftestFile, let fh = FileHandle(forReadingAtPath: path) else {
        report["error"] = "selftest: --file missing or unreadable"; finish(2)
    }
    var hasher = Insecure.MD5()
    var bytes = 0
    while true {
        let chunk = fh.readData(ofLength: 1 << 20)
        if chunk.isEmpty { break }
        hasher.update(data: chunk); bytes += chunk.count
    }
    report["selftest"] = ["file": path, "md5": hex(hasher.finalize()), "bytes": bytes]
    finish(0)
}

func ensureAuthorized() -> Bool {
    let before = PHPhotoLibrary.authorizationStatus(for: .readWrite)
    report["authorizationBefore"] = authName(before)
    if mode == "status" { finish(0) }
    var status = before
    if before == .notDetermined {
        log("requesting Photos authorization (waiting up to 90s for user response)...")
        let sem = DispatchSemaphore(value: 0)
        PHPhotoLibrary.requestAuthorization(for: .readWrite) { s in status = s; sem.signal() }
        if sem.wait(timeout: .now() + 90) == .timedOut {
            report["authorizationAfter"] = "timeout(no response within 90s)"
            return false
        }
    }
    report["authorizationAfter"] = authName(status)
    return status == .authorized
}

func runVerify() -> Never {
    guard ensureAuthorized() else {
        report["stopped"] = "Photos full access not granted"
        finish(3)
    }
    var results: [[String: Any]] = []
    for t in targets {
        var entry: [String: Any] = ["filename": t.filename, "catalogDate": t.dateText, "expectedMD5": t.expectedMD5]
        guard let center = parseLocalDate(t.dateText) else {
            entry["error"] = "bad date"; results.append(entry); continue
        }
        let opts = PHFetchOptions()
        opts.predicate = NSPredicate(format: "creationDate >= %@ AND creationDate <= %@",
                                     center.addingTimeInterval(-86400) as NSDate,
                                     center.addingTimeInterval(86400) as NSDate)
        opts.includeHiddenAssets = true
        opts.includeAllBurstAssets = true
        let fetched = PHAsset.fetchAssets(with: opts)
        entry["assetsInWindow"] = fetched.count
        var candidates: [[String: Any]] = []
        fetched.enumerateObjects { asset, _, _ in
            let resources = PHAssetResource.assetResources(for: asset)
            guard resources.contains(where: { $0.originalFilename.caseInsensitiveCompare(t.filename) == .orderedSame }) else { return }
            var c: [String: Any] = [
                "localIdentifier": asset.localIdentifier,
                "creationDate": asset.creationDate.map { isoLocal.string(from: $0) } ?? NSNull(),
                "modificationDate": asset.modificationDate.map { isoLocal.string(from: $0) } ?? NSNull(),
                "minutesFromCatalogDate": asset.creationDate.map { ($0.timeIntervalSince(center) / 60).rounded() } ?? NSNull(),
                "hasLocation": asset.location != nil,
                "pixelWidth": asset.pixelWidth,
                "pixelHeight": asset.pixelHeight,
                "mediaSubtypesRaw": asset.mediaSubtypes.rawValue,
                "isLivePhoto": asset.mediaSubtypes.contains(.photoLive),
                "hasAdjustmentResources": resources.contains { [.adjustmentData, .fullSizePhoto, .adjustmentBasePhoto].contains($0.type) },
                "isHidden": asset.isHidden,
            ]
            if let loc = asset.location {
                c["location"] = ["lat": loc.coordinate.latitude, "lon": loc.coordinate.longitude]
            }
            var rs: [[String: Any]] = []
            for r in resources {
                var rd: [String: Any] = [
                    "type": resourceTypeName(r.type),
                    "originalFilename": r.originalFilename,
                    "uti": r.uniformTypeIdentifier,
                ]
                if hashableTypes.contains(r.type) {
                    log("fetching \(t.filename) / \(resourceTypeName(r.type)) / \(r.originalFilename) ...")
                    let f = fetch(r)
                    rd["md5"] = f.md5 ?? NSNull()
                    rd["bytes"] = f.bytes
                    rd["dataSource"] = f.source
                    if !f.errors.isEmpty { rd["fetchErrors"] = f.errors }
                    rd["matchesCatalog"] = (f.md5 == t.expectedMD5)
                }
                rs.append(rd)
            }
            c["resources"] = rs
            let photo = rs.first { ($0["type"] as? String) == "photo" }
            c["photoResourceMatchesCatalog"] = (photo?["matchesCatalog"] as? Bool) ?? false
            candidates.append(c)
        }
        entry["candidates"] = candidates
        entry["candidateCount"] = candidates.count
        results.append(entry)
    }
    report["results"] = results
    let found = results.allSatisfy { ($0["candidateCount"] as? Int ?? 0) > 0 }
    report["allTargetsFound"] = found
    finish(found ? 0 : 4)
}

// MARK: - 起動

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
DispatchQueue.global(qos: .userInitiated).async {
    switch mode {
    case "selftest": runSelftest()
    case "status", "run": runVerify()
    default:
        report["error"] = "unknown mode \(mode)"; finish(2)
    }
}
app.run()
