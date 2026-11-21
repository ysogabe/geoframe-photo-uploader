import Foundation

public enum PlanDecision: Equatable, Sendable {
    case toUpload
    case duplicateRemote(fileId: String, name: String)
    case duplicateInBatch(ofLocalIdentifier: String)
    case ineligible(reason: String)
    /// 対象だが MD5 未計算（判定不能）
    case notHashed

    public var label: String {
        switch self {
        case .toUpload: return "to_upload"
        case .duplicateRemote: return "duplicate_remote"
        case .duplicateInBatch: return "duplicate_in_batch"
        case .ineligible: return "ineligible"
        case .notHashed: return "not_hashed"
        }
    }
}

extension PlanDecision: Codable {
    private enum K: String, CodingKey { case decision, fileId, name, ofLocalIdentifier, reason }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: K.self)
        try c.encode(label, forKey: .decision)
        switch self {
        case .duplicateRemote(let id, let n): try c.encode(id, forKey: .fileId); try c.encode(n, forKey: .name)
        case .duplicateInBatch(let l): try c.encode(l, forKey: .ofLocalIdentifier)
        case .ineligible(let r): try c.encode(r, forKey: .reason)
        case .toUpload, .notHashed: break
        }
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: K.self)
        switch try c.decode(String.self, forKey: .decision) {
        case "duplicate_remote":
            self = .duplicateRemote(fileId: try c.decode(String.self, forKey: .fileId), name: try c.decode(String.self, forKey: .name))
        case "duplicate_in_batch": self = .duplicateInBatch(ofLocalIdentifier: try c.decode(String.self, forKey: .ofLocalIdentifier))
        case "ineligible": self = .ineligible(reason: try c.decode(String.self, forKey: .reason))
        case "not_hashed": self = .notHashed
        default: self = .toUpload
        }
    }
}

/// Drive フォルダ内の md5 → ファイル。
public struct RemoteIndex: Sendable {
    public private(set) var byMD5: [String: DriveFile] = [:]

    public init(files: [DriveFile] = []) {
        for f in files { if let m = f.md5Checksum?.lowercased(), byMD5[m] == nil { byMD5[m] = f } }
    }

    /// md5 だけ分かっている場合（rclone lsjson 等）
    public init(md5s: [String]) {
        for m in md5s { let k = m.lowercased(); if byMD5[k] == nil { byMD5[k] = DriveFile(id: "", name: "", md5Checksum: k) } }
    }

    public func lookup(_ md5: String) -> DriveFile? { byMD5[md5.lowercased()] }
    public var count: Int { byMD5.count }

    public mutating func insert(_ f: DriveFile) {
        if let m = f.md5Checksum?.lowercased(), byMD5[m] == nil { byMD5[m] = f }
    }
}

public struct PlanInput: Sendable {
    public var localIdentifier: String
    public var eligibility: Eligibility
    public var md5: String?
    public init(localIdentifier: String, eligibility: Eligibility, md5: String?) {
        self.localIdentifier = localIdentifier; self.eligibility = eligibility; self.md5 = md5
    }
}

public enum UploadPlanner {
    /// 入力順に評価する。同じ md5 が複数あれば最初のものだけ `.toUpload`。
    public static func plan(_ inputs: [PlanInput], remote: RemoteIndex) -> [PlanDecision] {
        var firstSeen: [String: String] = [:]
        return inputs.map { item in
            if case .ineligible(let r) = item.eligibility { return .ineligible(reason: r) }
            guard let raw = item.md5, !raw.isEmpty else { return .notHashed }
            let md5 = raw.lowercased()
            if let f = remote.lookup(md5) { return .duplicateRemote(fileId: f.id, name: f.name) }
            if let first = firstSeen[md5] { return .duplicateInBatch(ofLocalIdentifier: first) }
            firstSeen[md5] = item.localIdentifier
            return .toUpload
        }
    }
}

/// `--remote-md5-file` の読み込み: md5 文字列の配列、または rclone lsjson（Hashes.md5）、
/// または Drive files.list 風（md5Checksum）のオブジェクト配列 / `{"files": [...]}`。
public enum RemoteMD5File {
    public static func parse(_ data: Data) throws -> RemoteIndex {
        let obj = try JSONSerialization.jsonObject(with: data)
        var arr: [Any]
        if let a = obj as? [Any] { arr = a }
        else if let d = obj as? [String: Any], let a = d["files"] as? [Any] { arr = a }
        else { throw DriveError.invalidResponse("remote md5 file: 配列ではありません") }
        var files: [DriveFile] = []
        for e in arr {
            if let s = e as? String {
                files.append(DriveFile(id: "", name: "", md5Checksum: s))
            } else if let d = e as? [String: Any] {
                let md5 = ((d["Hashes"] as? [String: Any])?["md5"] as? String)
                    ?? ((d["Hashes"] as? [String: Any])?["MD5"] as? String)
                    ?? (d["md5Checksum"] as? String)
                guard let md5, !md5.isEmpty else { continue }
                let id = (d["ID"] as? String) ?? (d["id"] as? String) ?? ""
                let name = (d["Name"] as? String) ?? (d["name"] as? String) ?? ""
                files.append(DriveFile(id: id, name: name, md5Checksum: md5))
            }
        }
        return RemoteIndex(files: files)
    }
}
