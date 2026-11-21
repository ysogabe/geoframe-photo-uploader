import Foundation
import UniformTypeIdentifiers

/// PhotoKit の mediaType を PhotoKit 非依存で表したもの（分類器をテスト可能にするため）。
public enum MediaKind: String, Codable, Sendable {
    case image, video, audio, unknown
}

public enum Eligibility: Equatable, Sendable {
    case eligible
    case ineligible(reason: String)

    public var isEligible: Bool { if case .eligible = self { return true } else { return false } }
    public var reason: String? { if case .ineligible(let r) = self { return r } else { return nil } }
}

extension Eligibility: Codable {
    private enum CodingKeys: String, CodingKey { case eligible, reason }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if try c.decode(Bool.self, forKey: .eligible) { self = .eligible } else {
            self = .ineligible(reason: try c.decodeIfPresent(String.self, forKey: .reason) ?? "")
        }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(isEligible, forKey: .eligible)
        if let r = reason { try c.encode(r, forKey: .reason) } else { try c.encodeNil(forKey: .reason) }
    }
}

/// geoframe に送れる形式の判定（純粋関数）。
public enum EligibilityClassifier {
    /// 受け入れる UTI と Drive に渡す MIME。heic は heif より先に評価する。
    public static let accepted: [(uti: String, mime: String)] = [
        ("public.jpeg", "image/jpeg"),
        ("public.png", "image/png"),
        ("public.heic", "image/heic"),
        ("public.heif", "image/heif"),
        ("public.tiff", "image/tiff"),
    ]

    /// 明示的に拒否する RAW 系（DNG は TIFF 準拠なので受け入れ判定より先に弾く）。
    public static let rejectedRawUTIs = ["com.adobe.raw-image", "public.camera-raw-image"]

    public static func classify(mediaKind: MediaKind, photoResourceUTI: String?) -> Eligibility {
        switch mediaKind {
        case .image: break
        case .video: return .ineligible(reason: "動画")
        case .audio: return .ineligible(reason: "音声")
        case .unknown: return .ineligible(reason: "不明なメディア種別")
        }
        guard let uti = photoResourceUTI, !uti.isEmpty else {
            return .ineligible(reason: "原本（.photo）リソースがありません")
        }
        if isRaw(uti) {
            return uti == "com.adobe.raw-image" ? .ineligible(reason: "DNG（geoframe 非対応）")
                                                  : .ineligible(reason: "RAW 形式 \(uti)（geoframe 非対応）")
        }
        if mimeType(forUTI: uti) != nil { return .eligible }
        return .ineligible(reason: "形式 \(uti) 非対応")
    }

    static func isRaw(_ uti: String) -> Bool {
        if rejectedRawUTIs.contains(uti) { return true }
        guard let t = UTType(uti) else { return false }
        return rejectedRawUTIs.contains { raw in UTType(raw).map { t.conforms(to: $0) } ?? false }
    }

    /// 受け入れ対象なら Drive に渡す MIME、そうでなければ nil。RAW は常に nil。
    public static func mimeType(forUTI uti: String) -> String? {
        if isRaw(uti) { return nil }
        if let hit = accepted.first(where: { $0.uti == uti }) { return hit.mime }
        guard let t = UTType(uti) else { return nil }
        for a in accepted {
            if let base = UTType(a.uti), t.conforms(to: base) { return a.mime }
        }
        return nil
    }
}
