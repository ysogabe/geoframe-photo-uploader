import Foundation
import UploaderCore

/// CLI モード。結果 JSON は必ず `--out` に書き、ログは stderr。
struct CLI {
    let arguments: [String]
    private var report: [String: Any] = [:]

    init(arguments: [String]) { self.arguments = arguments }

    // MARK: 引数

    private func value(_ flag: String) -> String? {
        guard let i = arguments.firstIndex(of: flag), i + 1 < arguments.count else { return nil }
        let v = arguments[i + 1]
        return v.hasPrefix("--") ? nil : v
    }

    private func has(_ flag: String) -> Bool { arguments.contains(flag) }

    private var subcommand: String? { value("--cli") }

    private var outPath: String {
        value("--out") ?? FileManager.default.currentDirectoryPath + "/geoframe-uploader-\(subcommand ?? "cli").json"
    }

    // MARK: 実行

    mutating func run() async -> Int32 {
        report["startedAt"] = LocalTime.iso8601(Date())
        report["subcommand"] = subcommand ?? NSNull()
        report["bundleIdentifier"] = Bundle.main.bundleIdentifier ?? NSNull()
        report["processTimeZone"] = TimeZone.current.identifier
        let service = UploaderService(log: { CLI.log($0) })
        var code: Int32 = 0
        do {
            switch subcommand {
            case "status": try await status(service)
            case "scan": try await scan(service)
            case "auth": try await auth(service)
            case "upload": code = try await upload(service)
            case "signout": await service.signOut(); report["signedOut"] = true
            default:
                report["error"] = "unknown subcommand: \(subcommand ?? "(none)")（status|scan|auth|upload|signout）"
                code = 2
            }
        } catch {
            report["error"] = Redactor.redact(error.localizedDescription)
            report["errorType"] = String(describing: type(of: error))
            code = 1
        }
        report["exitCode"] = Int(code)
        finish()
        return code
    }

    static func log(_ s: String) {
        FileHandle.standardError.write(Data((Redactor.redact(s) + "\n").utf8))
    }

    private func finish() {
        var r = report
        r["finishedAt"] = LocalTime.iso8601(Date())
        do {
            let data = try JSONSerialization.data(withJSONObject: r, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
            try data.write(to: URL(fileURLWithPath: outPath), options: .atomic)
            // GPS 位置情報を含むため所有者のみ読み書き可にする
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: outPath)
            CLI.log("wrote \(outPath)")
        } catch {
            CLI.log("failed to write report: \(error)")
        }
    }

    // MARK: JSON 変換

    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        e.dateEncodingStrategy = .custom { date, enc in
            var c = enc.singleValueContainer()
            try c.encode(LocalTime.iso8601(date))
        }
        return e
    }()

    static func json<T: Encodable>(_ v: T) -> Any {
        guard let d = try? encoder.encode(v), let o = try? JSONSerialization.jsonObject(with: d, options: [.fragmentsAllowed]) else {
            return NSNull()
        }
        return o
    }

    // MARK: サブコマンド

    private mutating func status(_ service: UploaderService) async throws {
        let s = await service.status()
        report["status"] = CLI.json(s)
    }

    private mutating func auth(_ service: UploaderService) async throws {
        CLI.log("opening browser for Google sign-in (waiting up to 5 minutes)...")
        let r = try await service.signIn()
        report["signedIn"] = true
        report["grantedScopes"] = r.grantedScopes
        report["requestedScopes"] = GoogleAuth.scopes
    }

    private func dateArgs() throws -> (from: String, to: String?) {
        guard let from = value("--from") else { throw CLIError.usage("--from YYYY-MM-DD が必要です") }
        let to = value("--to")
        guard LocalTime.dayRange(fromDay: from, toDay: to) != nil else { throw CLIError.usage("日付は YYYY-MM-DD で指定してください") }
        return (from, to)
    }

    private mutating func scan(_ service: UploaderService) async throws {
        let (from, to) = try dateArgs()
        report["from"] = from; report["to"] = to ?? from
        let items = try await service.loadItems(fromDay: from, toDay: to)
        CLI.log("found \(items.count) assets")
        report["itemCount"] = items.count
        report["eligibleCount"] = items.filter { $0.eligibility.isEligible }.count

        var entries: [[String: Any]] = items.map { ["item": CLI.json($0)] }
        guard has("--hash") else {
            report["items"] = entries
            return
        }

        // 遠隔 md5 集合（ファイル指定 → Drive 認証済みなら Drive → 無し）
        var remote: RemoteIndex?
        if let p = value("--remote-md5-file") {
            remote = try RemoteMD5File.parse(Data(contentsOf: URL(fileURLWithPath: p)))
            report["remoteSource"] = "file"
        } else {
            let st = await service.status()
            if st.oauthClientValid && st.signedIn {
                do {
                    remote = try await service.remoteIndex()
                    report["remoteSource"] = "drive"
                } catch {
                    report["remoteError"] = Redactor.redact(error.localizedDescription)
                }
            }
        }
        report["remoteSource"] = report["remoteSource"] ?? "none"
        report["remoteMd5Count"] = remote?.count ?? NSNull()

        let exporter = try OriginalExporter()
        defer { exporter.cleanup() }
        var inputs: [PlanInput] = []
        for (i, item) in items.enumerated() {
            var md5: String?
            if item.eligibility.isEligible {
                CLI.log("[\(i + 1)/\(items.count)] hashing \(item.originalFilename ?? item.localIdentifier)")
                do {
                    let e = try await exporter.export(localIdentifier: item.localIdentifier)
                    e.remove()
                    md5 = e.md5Hex
                    entries[i]["md5"] = e.md5Hex
                    entries[i]["sha256"] = e.sha256Hex
                    entries[i]["byteCount"] = e.byteCount
                    entries[i]["dataSource"] = e.dataSource.rawValue
                    entries[i]["exif"] = CLI.json(e.exif)
                } catch {
                    entries[i]["hashError"] = Redactor.redact(error.localizedDescription)
                }
            }
            inputs.append(PlanInput(localIdentifier: item.localIdentifier, eligibility: item.eligibility, md5: md5))
        }
        if let remote {
            let decisions = UploadPlanner.plan(inputs, remote: remote)
            var counts: [String: Int] = [:]
            for (i, d) in decisions.enumerated() {
                entries[i]["plan"] = CLI.json(d)
                counts[d.label, default: 0] += 1
            }
            report["planCounts"] = counts
        }
        report["items"] = entries
    }

    private mutating func upload(_ service: UploaderService) async throws -> Int32 {
        let (from, to) = try dateArgs()
        let max = Int(value("--max") ?? "3") ?? 3
        let ids = value("--ids")?.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let limit = value("--limit").flatMap(Int.init)
        guard (ids != nil) != (limit != nil) else { throw CLIError.usage("--ids か --limit のどちらか一方を指定してください") }

        let items = try await service.loadItems(fromDay: from, toDay: to)
        var selected: [PhotoItem]
        if let ids {
            let byId = Dictionary(items.map { ($0.localIdentifier, $0) }, uniquingKeysWith: { a, _ in a })
            let missing = ids.filter { byId[$0] == nil }
            guard missing.isEmpty else { throw CLIError.usage("指定期間に存在しない ID: \(missing.joined(separator: ", "))") }
            var seen = Set<String>()
            selected = ids.filter { seen.insert($0).inserted }.compactMap { byId[$0] }
        } else {
            selected = Array(items.filter { $0.eligibility.isEligible }.prefix(Swift.max(0, limit ?? 0)))
        }
        report["from"] = from; report["to"] = to ?? from
        report["selectedCount"] = selected.count
        report["maxItemsPerRun"] = max
        guard !selected.isEmpty else { throw CLIError.usage("送信対象がありません") }

        let summary = try await service.upload(items: selected, maxItemsPerRun: max) { ev in
            switch ev.phase {
            case .exporting: CLI.log("[\(ev.index + 1)/\(ev.total)] exporting \(ev.localIdentifier)")
            case .checkingDuplicate: CLI.log("[\(ev.index + 1)/\(ev.total)] checking duplicate")
            case .uploading(let f): if f == 0 || f == 1 { CLI.log("[\(ev.index + 1)/\(ev.total)] uploading \(Int(f * 100))%") }
            case .verifying: CLI.log("[\(ev.index + 1)/\(ev.total)] verifying")
            case .finished(let r): CLI.log("[\(ev.index + 1)/\(ev.total)] \(r.status.rawValue) \(r.error ?? "")")
            }
        }
        report["summary"] = CLI.json(summary)
        report["sentCount"] = summary.sentCount
        report["failedCount"] = summary.failedCount
        return summary.failedCount > 0 ? 5 : 0
    }
}

enum CLIError: Error, LocalizedError {
    case usage(String)
    var errorDescription: String? {
        switch self { case .usage(let m): return "使い方エラー: \(m)" }
    }
}
