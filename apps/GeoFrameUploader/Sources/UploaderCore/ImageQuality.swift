import CoreGraphics
import Foundation

/// サムネイルから計算した知覚ハッシュと画質指標。
public struct QualityMetrics: Codable, Sendable, Equatable {
    /// 64-bit pHash の 16 進文字列（16 文字）。平坦画像などで算出不能な場合は nil。
    public var pHashHex: String?
    public var sharpness: Double
    public var exposureScore: Double
    public var contrast: Double
    public var luminance: Double
    public var blackClip: Double
    public var whiteClip: Double

    public init(pHash: UInt64?, sharpness: Double, exposureScore: Double, contrast: Double,
                luminance: Double, blackClip: Double, whiteClip: Double) {
        self.pHashHex = pHash.map { String(format: "%016llx", $0) }
        self.sharpness = sharpness
        self.exposureScore = exposureScore
        self.contrast = contrast
        self.luminance = luminance
        self.blackClip = blackClip
        self.whiteClip = whiteClip
    }

    public var pHash: UInt64? {
        guard let pHashHex, !pHashHex.isEmpty else { return nil }
        return UInt64(pHashHex, radix: 16)
    }

    /// JSON エンコード時（NaN / Inf 拒否）に備えて全浮動小数が有限か確認する。
    public var isValid: Bool {
        sharpness.isFinite && exposureScore.isFinite && contrast.isFinite
            && luminance.isFinite && blackClip.isFinite && whiteClip.isFinite
    }
}

/// `ysogabe/geoframe` の `rust-phash-v1:t3:h12` および `image_metrics` を Swift へ移植した解析器。
/// 入力がサムネイルであるためサーバー側の原本計算結果とは数ビットの差が出得る（ローカル比較専用）。
public enum ImageQualityAnalyzer {
    public static let algorithmVersion = "swift-phash-v1:t3:h12:m512"
    public static let metricMaxPx = 512
    public static let pHashSize = 32
    public static let pHashLow = 8

    // 32x8 の正規化なし Type-II DCT 用 cos テーブル
    private static let dctCosTable: [[Double]] = {
        (0..<pHashLow).map { u in
            (0..<pHashSize).map { x in
                cos((Double(2 * x + 1) * Double(u) * .pi) / (2.0 * Double(pHashSize)))
            }
        }
    }()

    /// 任意の `CGImage` から pHash と画質指標を計算する。不正画像または非有限値を含む場合は `nil`。
    public static func analyze(_ image: CGImage) -> QualityMetrics? {
        guard image.width > 0, image.height > 0 else { return nil }

        // 1. 品質指標用（長辺が 512 超なら縮小、512 以下はそのまま）
        let longEdge = max(image.width, image.height)
        let targetW: Int
        let targetH: Int
        if longEdge > metricMaxPx {
            let scale = Double(metricMaxPx) / Double(longEdge)
            targetW = max(1, Int((Double(image.width) * scale).rounded()))
            targetH = max(1, Int((Double(image.height) * scale).rounded()))
        } else {
            targetW = image.width
            targetH = image.height
        }

        guard let metricPixels = renderGamma22Gray(image, width: targetW, height: targetH) else {
            return nil
        }
        let m = computeMetrics(pixels: metricPixels, width: targetW, height: targetH)

        // 2. pHash 用（中央正方形クロップ → 32x32 縮小 → 8x8 DCT）
        let pHash = computePHash(from: image)

        let out = QualityMetrics(
            pHash: pHash,
            sharpness: m.sharpness,
            exposureScore: m.exposureScore,
            contrast: m.contrast,
            luminance: m.luminance,
            blackClip: m.blackClip,
            whiteClip: m.whiteClip
        )
        return out.isValid ? out : nil
    }

    // MARK: - pHash

    public static func computePHash(from image: CGImage) -> UInt64? {
        let w = image.width
        let h = image.height
        let side = min(w, h)
        guard side > 0 else { return nil }
        let cropRect = CGRect(x: (w - side) / 2, y: (h - side) / 2, width: side, height: side)
        guard let cropped = image.cropping(to: cropRect),
              let gray = renderGamma22Gray(cropped, width: pHashSize, height: pHashSize) else {
            return nil
        }
        return pHashFrom32x32Gray(gray)
    }

    /// 32x32 グレースケール配列から 64-bit pHash を算出する（平坦画像なら nil）。
    static func pHashFrom32x32Gray(_ pixels: [UInt8]) -> UInt64? {
        guard pixels.count == pHashSize * pHashSize else { return nil }

        // 横方向 1D DCT（32 行 × 8 低周波）
        var tmp = [Double](repeating: 0, count: pHashSize * pHashLow)
        for y in 0..<pHashSize {
            let rowBase = y * pHashSize
            for u in 0..<pHashLow {
                let cosRow = dctCosTable[u]
                var sum = 0.0
                for x in 0..<pHashSize {
                    sum += Double(pixels[rowBase + x]) * cosRow[x]
                }
                tmp[y * pHashLow + u] = sum
            }
        }

        // 縦方向 1D DCT（8 × 8）
        var coeffs = [Double](repeating: 0, count: pHashLow * pHashLow)
        for v in 0..<pHashLow {
            let cosCol = dctCosTable[v]
            for u in 0..<pHashLow {
                var sum = 0.0
                for y in 0..<pHashSize {
                    sum += tmp[y * pHashLow + u] * cosCol[y]
                }
                coeffs[v * pHashLow + u] = sum
            }
        }

        // 平坦・単色画像では AC 係数が丸め誤差レベルになるため偽一致防止で nil を返す
        let ac = Array(coeffs[1..<64])
        let maxAC = ac.map { abs($0) }.max() ?? 0
        guard maxAC.isFinite, maxAC >= 1e-3 else { return nil }

        let sortedAC = ac.sorted()
        let median = sortedAC[31]

        var hash: UInt64 = 0
        for i in 0..<64 {
            if coeffs[i] > median {
                hash |= UInt64(1) << (63 - i)
            }
        }
        return hash
    }

    // MARK: - 画質指標

    struct RawMetrics {
        let sharpness: Double
        let exposureScore: Double
        let contrast: Double
        let luminance: Double
        let blackClip: Double
        let whiteClip: Double
    }

    static func computeMetrics(pixels: [UInt8], width: Int, height: Int) -> RawMetrics {
        let totalCount = width * height
        guard totalCount > 0 else {
            return RawMetrics(sharpness: 0, exposureScore: 0, contrast: 0, luminance: 0, blackClip: 0, whiteClip: 0)
        }

        var hist = [Int](repeating: 0, count: 256)
        for p in pixels { hist[Int(p)] += 1 }

        let total = Double(totalCount)
        var sumLuma = 0.0
        for i in 0..<256 { sumLuma += Double(i) * Double(hist[i]) }
        let luminance = sumLuma / total

        let blackCount = hist[0..<8].reduce(0, +)
        let whiteCount = hist[248..<256].reduce(0, +)
        let blackClip = Double(blackCount) / total
        let whiteClip = Double(whiteCount) / total
        let contrast = percentile(hist: hist, p: 0.95, total: totalCount)
            - percentile(hist: hist, p: 0.05, total: totalCount)

        let edges = findEdges(pixels: pixels, width: width, height: height)
        let margin = (width > 8 && height > 8) ? 4 : 0
        var sum = 0.0
        var sum2 = 0.0
        var edgeCount = 0
        for y in margin..<(height - margin) {
            let row = y * width
            for x in margin..<(width - margin) {
                let v = Double(edges[row + x])
                sum += v
                sum2 += v * v
                edgeCount += 1
            }
        }
        let variance: Double
        if edgeCount > 0 {
            let n = Double(edgeCount)
            variance = max(0.0, (sum2 - (sum * sum) / n) / n)
        } else {
            variance = 0.0
        }
        let sharpness = log1p(variance)

        let centerScore = 100.0 * exp(-pow((luminance - 128.0) / 100.0, 2.0))
        let clipPenalty = min((blackClip + whiteClip) * 260.0, 55.0)
        let lowContrastPenalty = max(45.0 - contrast, 0.0) * 0.45
        let exposureScore = min(100.0, max(0.0, centerScore - clipPenalty - lowContrastPenalty))

        return RawMetrics(
            sharpness: sharpness,
            exposureScore: exposureScore,
            contrast: contrast,
            luminance: luminance,
            blackClip: blackClip,
            whiteClip: whiteClip
        )
    }

    private static func percentile(hist: [Int], p: Double, total: Int) -> Double {
        let target = Int((Double(total) * p).rounded(.up))
        var cum = 0
        for i in 0..<256 {
            cum += hist[i]
            if cum >= target { return Double(i) }
        }
        return 255.0
    }

    private static func findEdges(pixels: [UInt8], width: Int, height: Int) -> [UInt8] {
        guard width >= 3 && height >= 3 else { return pixels }
        var out = pixels
        for y in 1..<(height - 1) {
            let row = y * width
            for x in 1..<(width - 1) {
                let idx = row + x
                let center = Int(pixels[idx])
                let nSum = Int(pixels[idx - width - 1]) + Int(pixels[idx - width]) + Int(pixels[idx - width + 1])
                    + Int(pixels[idx - 1]) + Int(pixels[idx + 1])
                    + Int(pixels[idx + width - 1]) + Int(pixels[idx + width]) + Int(pixels[idx + width + 1])
                let v = max(0, min(255, 8 * center - nSum))
                out[idx] = UInt8(v)
            }
        }
        return out
    }

    /// ガンマ 2.2 の 8-bit グレースケール空間へ描画（黒背景で透過を潰す）。
    static func renderGamma22Gray(_ image: CGImage, width: Int, height: Int) -> [UInt8]? {
        guard width > 0, height > 0,
              let space = CGColorSpace(name: CGColorSpace.genericGrayGamma2_2) else { return nil }
        var buffer = [UInt8](repeating: 0, count: width * height)
        let ok = buffer.withUnsafeMutableBytes { raw -> Bool in
            guard let base = raw.baseAddress,
                  let ctx = CGContext(
                      data: base,
                      width: width,
                      height: height,
                      bitsPerComponent: 8,
                      bytesPerRow: width,
                      space: space,
                      bitmapInfo: CGImageAlphaInfo.none.rawValue
                  ) else { return false }
            ctx.interpolationQuality = .high
            ctx.setFillColor(gray: 0.0, alpha: 1.0)
            ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return ok ? buffer : nil
    }
}

// MARK: - quality-cache.json

public struct QualityCacheEntry: Codable, Sendable, Equatable {
    public var originalFilename: String?
    public var uti: String?
    public var pixelWidth: Int
    public var pixelHeight: Int
    public var modificationTimestamp: Double?
    public var algorithmVersion: String
    public var metrics: QualityMetrics
    public var analyzedAt: Date

    public init(item: PhotoItem, metrics: QualityMetrics, analyzedAt: Date = Date(),
                algorithmVersion: String = ImageQualityAnalyzer.algorithmVersion) {
        self.originalFilename = item.originalFilename
        self.uti = item.uti
        self.pixelWidth = item.pixelWidth
        self.pixelHeight = item.pixelHeight
        self.modificationTimestamp = item.modificationDate?.timeIntervalSince1970
        self.algorithmVersion = algorithmVersion
        self.metrics = metrics
        self.analyzedAt = analyzedAt
    }

    public func matches(_ item: PhotoItem, algorithmVersion: String = ImageQualityAnalyzer.algorithmVersion) -> Bool {
        guard self.algorithmVersion == algorithmVersion,
              originalFilename == item.originalFilename,
              uti == item.uti,
              pixelWidth == item.pixelWidth,
              pixelHeight == item.pixelHeight,
              metrics.isValid else { return false }
        switch (modificationTimestamp, item.modificationDate?.timeIntervalSince1970) {
        case (nil, nil): return true
        case let (a?, b?): return abs(a - b) < 1e-6
        default: return false
        }
    }
}

/// 品質指標と pHash の永続キャッシュ（`quality-cache.json`、0600、アトミック書き込み）。
/// 送信結果キャッシュ（`item-cache.json`）とはファイルを分離し、相互の保存遅延や障害波及を防ぐ。
public final class QualityCache: @unchecked Sendable {
    public static let currentFormatVersion = 2

    public let fileURL: URL
    private let lock = NSLock()
    private var entries: [String: QualityCacheEntry] = [:]
    private let log: @Sendable (String) -> Void

    private struct FileFormat: Codable {
        var version: Int
        var entries: [String: QualityCacheEntry]
    }

    public init(fileURL: URL, log: @escaping @Sendable (String) -> Void = { _ in }) {
        self.fileURL = fileURL
        self.log = log
        if FileManager.default.fileExists(atPath: fileURL.path) {
            if let data = try? Data(contentsOf: fileURL),
               let f = try? ResultCache.decoder.decode(FileFormat.self, from: data),
               f.version == Self.currentFormatVersion {
                entries = f.entries.filter { $0.value.metrics.isValid }
            } else {
                log("quality-cache.json の形式が異なるか読めないため空で再開します")
            }
        }
    }

    public func metrics(for items: [PhotoItem]) -> [String: QualityMetrics] {
        lock.withLock {
            var out: [String: QualityMetrics] = [:]
            for it in items {
                if let e = entries[it.localIdentifier], e.matches(it) {
                    out[it.localIdentifier] = e.metrics
                }
            }
            return out
        }
    }

    public func recordBatch(_ pairs: [(item: PhotoItem, metrics: QualityMetrics)], at date: Date = Date()) {
        let valid = pairs.filter { $0.metrics.isValid }
        guard !valid.isEmpty else { return }
        lock.withLock {
            mergeFromDiskLocked()
            for (item, metrics) in valid {
                entries[item.localIdentifier] = QualityCacheEntry(item: item, metrics: metrics, analyzedAt: date)
            }
            saveLocked()
        }
    }

    private func mergeFromDiskLocked() {
        guard let data = try? Data(contentsOf: fileURL),
              let disk = try? ResultCache.decoder.decode(FileFormat.self, from: data),
              disk.version == Self.currentFormatVersion else { return }
        for (id, d) in disk.entries where d.metrics.isValid {
            if let m = entries[id] {
                if d.analyzedAt > m.analyzedAt { entries[id] = d }
            } else {
                entries[id] = d
            }
        }
    }

    private func saveLocked() {
        do {
            let safe = entries.filter { $0.value.metrics.isValid }
            let data = try ResultCache.encoder.encode(FileFormat(version: Self.currentFormatVersion, entries: safe))
            try ResultCache.atomicWrite0600(data, to: fileURL, label: "quality-cache.json")
        } catch {
            log("quality-cache.json を保存できませんでした: \(error.localizedDescription)")
        }
    }
}
