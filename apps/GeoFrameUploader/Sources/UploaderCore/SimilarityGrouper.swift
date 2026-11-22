import Foundation

/// 類似グループ内での 1 枚の評価結果。
public struct RankedMember: Sendable, Equatable {
    public let localIdentifier: String
    public let score: Double
    public let sharpnessRel: Double
    public let exposureRel: Double
    public let contrastRel: Double
    public let rank: Int
    public let isRecommended: Bool
    public let reasons: [String]
    public let issues: [String]
}

/// 同じセクション内で見た目が似ている（または同一バーストの）写真群。
public struct SimilarityCluster: Sendable, Equatable, Identifiable {
    public let id: String
    public let sectionId: String
    /// セクション表示順（撮影日時昇順）のメンバー ID
    public let memberIds: [String]
    public let rankings: [String: RankedMember]
    /// グループ内で推奨と判定された ID（最良 1 枚 ＋ グループ内のお気に入り）
    public let recommendedIds: Set<String>
    /// 推奨順位順に並んだメンバー ID
    public let rankedOrder: [String]
}

public struct SectionGroupingResult: Sendable, Equatable {
    public let clusters: [SimilarityCluster]
    public let clusterByItemId: [String: SimilarityCluster]
    public let standaloneRecommendedIds: Set<String>
    public let standaloneIssues: [String: [String]]

    public init(clusters: [SimilarityCluster], clusterByItemId: [String: SimilarityCluster],
                standaloneRecommendedIds: Set<String>, standaloneIssues: [String: [String]]) {
        self.clusters = clusters
        self.clusterByItemId = clusterByItemId
        self.standaloneRecommendedIds = standaloneRecommendedIds
        self.standaloneIssues = standaloneIssues
    }

    public static let empty = SectionGroupingResult(
        clusters: [], clusterByItemId: [:], standaloneRecommendedIds: [], standaloneIssues: [:]
    )
}

/// `ysogabe/geoframe` の `quality/group.rs` 方式でセクション内類似グルーピング・品質評価・推奨選出を行う。
public enum SimilarityGrouper {
    public static let defaultTimeWindowSeconds: TimeInterval = 180.0
    public static let defaultMaxHammingDistance: Int = 12

    public static func group(
        sectionId: String,
        sectionItems: [PhotoItem],
        metricsById: [String: QualityMetrics],
        timeWindowSeconds: TimeInterval = defaultTimeWindowSeconds,
        maxHammingDistance: Int = defaultMaxHammingDistance
    ) -> SectionGroupingResult {
        let eligible = sectionItems
            .filter { $0.eligibility.isEligible }
            .sorted { a, b in
                let dA = a.creationDate ?? .distantFuture
                let dB = b.creationDate ?? .distantFuture
                if dA != dB { return dA < dB }
                return a.localIdentifier < b.localIdentifier
            }
        guard !eligible.isEmpty else { return .empty }

        var uf = UnionFind(count: eligible.count)

        // 1. PhotoKit バースト ID 一致
        var firstByBurst: [String: Int] = [:]
        for (i, item) in eligible.enumerated() {
            if let b = item.burstIdentifier, !b.isEmpty {
                if let first = firstByBurst[b] {
                    uf.union(first, i)
                } else {
                    firstByBurst[b] = i
                }
            }
        }

        // 2. 180 秒以内かつ pHash ハミング距離 <= 12
        for i in 0..<eligible.count {
            guard let tI = eligible[i].creationDate,
                  let hI = metricsById[eligible[i].localIdentifier]?.pHash else { continue }
            for j in (i + 1)..<eligible.count {
                guard let tJ = eligible[j].creationDate else { continue }
                let dt = tJ.timeIntervalSince(tI)
                if dt > timeWindowSeconds { break }
                guard let hJ = metricsById[eligible[j].localIdentifier]?.pHash else { continue }
                if (hI ^ hJ).nonzeroBitCount <= maxHammingDistance {
                    uf.union(i, j)
                }
            }
        }

        // 連結成分をまとめる
        var components: [Int: [PhotoItem]] = [:]
        var rootOrder: [Int] = []
        for (i, item) in eligible.enumerated() {
            let root = uf.find(i)
            if components[root] == nil { rootOrder.append(root) }
            components[root, default: []].append(item)
        }

        var clusters: [SimilarityCluster] = []
        var clusterByItemId: [String: SimilarityCluster] = [:]
        var standaloneRecommendedIds = Set<String>()
        var standaloneIssues: [String: [String]] = [:]

        for root in rootOrder {
            guard let members = components[root] else { continue }
            if members.count >= 2 {
                let cluster = buildCluster(sectionId: sectionId, members: members, metricsById: metricsById)
                clusters.append(cluster)
                for id in cluster.memberIds { clusterByItemId[id] = cluster }
            } else if let solo = members.first {
                // 未解析の写真・品質下限未満の単独写真は自動推奨に含めない
                guard let m = metricsById[solo.localIdentifier] else { continue }
                let defects = standaloneDefects(for: m)
                if !defects.isEmpty {
                    standaloneIssues[solo.localIdentifier] = defects
                } else {
                    standaloneRecommendedIds.insert(solo.localIdentifier)
                }
            }
        }

        return SectionGroupingResult(
            clusters: clusters,
            clusterByItemId: clusterByItemId,
            standaloneRecommendedIds: standaloneRecommendedIds,
            standaloneIssues: standaloneIssues
        )
    }

    /// 単独写真の絶対的な品質不良チェック（お気に入りは免除）。
    public static func standaloneDefects(for m: QualityMetrics) -> [String] {
        var issues: [String] = []
        if m.sharpness < 2.5 { issues.append("ぼけ傾向") }
        if m.exposureScore < 35.0 { issues.append("露出要確認") }
        if m.whiteClip > 0.20 { issues.append("白飛び多め") }
        if m.blackClip > 0.30 { issues.append("黒つぶれ多め") }
        return issues
    }

    private static func buildCluster(sectionId: String, members: [PhotoItem],
                                     metricsById: [String: QualityMetrics]) -> SimilarityCluster {
        let analyzed = members.compactMap { metricsById[$0.localIdentifier] }
        let sharpVals = analyzed.map(\.sharpness)
        let expVals = analyzed.map(\.exposureScore)
        let conVals = analyzed.map(\.contrast)

        let sharpRange = (sharpVals.min() ?? 0, sharpVals.max() ?? 0)
        let expRange = (expVals.min() ?? 0, expVals.max() ?? 0)
        let conRange = (conVals.min() ?? 0, conVals.max() ?? 0)

        let sortedSharp = sharpVals.sorted()
        let medSharp = sortedSharp.isEmpty ? 0 : sortedSharp[sortedSharp.count / 2]
        let maxSharp = sharpRange.1

        struct ScoredItem {
            let item: PhotoItem
            let score: Double
            let sharpRel: Double
            let expRel: Double
            let conRel: Double
            let reasons: [String]
            let issues: [String]
        }

        let scored: [ScoredItem] = members.map { item in
            guard let m = metricsById[item.localIdentifier] else {
                return ScoredItem(item: item, score: 0, sharpRel: 0, expRel: 0, conRel: 0,
                                  reasons: [], issues: ["未解析"])
            }
            let sharpRel = normalize(m.sharpness, sharpRange)
            let expRel = 0.55 * (m.exposureScore / 100.0) + 0.45 * normalize(m.exposureScore, expRange)
            let conRel = normalize(m.contrast, conRange)
            let clipPenalty = min((m.blackClip + m.whiteClip) * 0.8, 0.20)
            let raw = min(1.0, max(0.0, 0.62 * sharpRel + 0.25 * expRel + 0.13 * conRel - clipPenalty))
            let score = (raw * 1000.0).rounded(.toNearestOrAwayFromZero) / 10.0

            var reasons: [String] = []
            if item.isFavorite { reasons.append("お気に入り") }
            if maxSharp > 0 && m.sharpness >= maxSharp * 0.98 {
                reasons.append("グループ内で最も鮮明")
            } else if m.sharpness >= medSharp {
                reasons.append("鮮明さ良好")
            }
            if m.exposureScore >= 75.0 { reasons.append("露出良好") }
            if m.blackClip + m.whiteClip < 0.015 { reasons.append("白飛び・黒つぶれ少") }

            var issues: [String] = []
            if medSharp > 0 && m.sharpness < medSharp * 0.82 { issues.append("ぼけ傾向") }
            if m.exposureScore < 45.0 { issues.append("露出要確認") }
            if m.whiteClip > 0.08 { issues.append("白飛び多め") }
            if m.blackClip > 0.15 { issues.append("黒つぶれ多め") }
            if m.contrast < 45.0 { issues.append("低コントラスト") }

            return ScoredItem(item: item, score: score, sharpRel: sharpRel, expRel: expRel,
                              conRel: conRel, reasons: reasons, issues: issues)
        }

        // お気に入り最優先 → score 降順 → 解像度降順 → 撮影日時昇順 → ID 昇順
        let ranked = scored.sorted { a, b in
            if a.item.isFavorite != b.item.isFavorite { return a.item.isFavorite }
            if a.score != b.score { return a.score > b.score }
            let pxA = a.item.pixelWidth * a.item.pixelHeight
            let pxB = b.item.pixelWidth * b.item.pixelHeight
            if pxA != pxB { return pxA > pxB }
            let dA = a.item.creationDate ?? .distantFuture
            let dB = b.item.creationDate ?? .distantFuture
            if dA != dB { return dA < dB }
            return a.item.localIdentifier < b.item.localIdentifier
        }

        // 原則上位 1 枚 ＋ グループ内の他の お気に入り を推奨にする
        var recIds = Set<String>()
        if let first = ranked.first, metricsById[first.item.localIdentifier] != nil || first.item.isFavorite {
            recIds.insert(first.item.localIdentifier)
        }
        for s in ranked where s.item.isFavorite {
            recIds.insert(s.item.localIdentifier)
        }

        var rankings: [String: RankedMember] = [:]
        for (idx, s) in ranked.enumerated() {
            let id = s.item.localIdentifier
            rankings[id] = RankedMember(
                localIdentifier: id,
                score: s.score,
                sharpnessRel: s.sharpRel,
                exposureRel: s.expRel,
                contrastRel: s.conRel,
                rank: idx + 1,
                isRecommended: recIds.contains(id),
                reasons: s.reasons,
                issues: s.issues
            )
        }

        return SimilarityCluster(
            id: "\(sectionId)#\(members[0].localIdentifier)",
            sectionId: sectionId,
            memberIds: members.map(\.localIdentifier),
            rankings: rankings,
            recommendedIds: recIds,
            rankedOrder: ranked.map(\.item.localIdentifier)
        )
    }

    static func normalize(_ v: Double, _ range: (Double, Double)) -> Double {
        let (lo, hi) = range
        let tol = 1e-9 * max(1.0, abs(lo), abs(hi))
        if abs(hi - lo) <= tol { return 0.5 }
        return min(1.0, max(0.0, (v - lo) / (hi - lo)))
    }
}

private struct UnionFind {
    private var parent: [Int]
    init(count: Int) { parent = Array(0..<count) }
    mutating func find(_ x: Int) -> Int {
        var root = x
        while parent[root] != root { root = parent[root] }
        var cur = x
        while parent[cur] != root {
            let next = parent[cur]
            parent[cur] = root
            cur = next
        }
        return root
    }
    mutating func union(_ a: Int, _ b: Int) {
        let ra = find(a)
        let rb = find(b)
        if ra != rb { parent[rb] = ra }
    }
}

// MARK: - 表示順・選択計算（純粋関数）

/// グリッドの描画チャンク（類似クラスタ枠と通常グリッドを混在させても時系列を保つ）。
public enum DisplayChunk: Sendable, Equatable, Identifiable {
    case cluster(SimilarityCluster, [PhotoItem])
    case grid(String, [PhotoItem])

    public var id: String {
        switch self {
        case .cluster(let c, _): return "c:\(c.id)"
        case .grid(let k, _): return "g:\(k)"
        }
    }

    public var orderedItems: [PhotoItem] {
        switch self {
        case .cluster(_, let members): return members
        case .grid(_, let gridItems): return gridItems
        }
    }
}

public enum SelectionPlanner {
    /// グリッド描画用のチャンク列を構築する（UI の表示順と Shift+クリック範囲選択の順序を一致させる）。
    public static func displayChunks(
        items: [PhotoItem],
        grouping: SectionGroupingResult,
        bundleSimilar: Bool
    ) -> [DisplayChunk] {
        guard bundleSimilar, !grouping.clusters.isEmpty else {
            return items.isEmpty ? [] : [.grid(items[0].id, items)]
        }
        var result: [DisplayChunk] = []
        var gridBuf: [PhotoItem] = []
        var emittedClusterIds = Set<String>()

        func flushGrid() {
            if !gridBuf.isEmpty {
                result.append(.grid(gridBuf[0].id, gridBuf))
                gridBuf = []
            }
        }

        let byId = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
        for item in items {
            if let cluster = grouping.clusterByItemId[item.id] {
                guard !emittedClusterIds.contains(cluster.id) else { continue }
                emittedClusterIds.insert(cluster.id)
                let visibleMembers = cluster.memberIds.compactMap { byId[$0] }
                if visibleMembers.count >= 2 {
                    flushGrid()
                    result.append(.cluster(cluster, visibleMembers))
                } else {
                    gridBuf.append(contentsOf: visibleMembers)
                }
            } else {
                gridBuf.append(item)
            }
        }
        flushGrid()
        return result
    }

    /// チャンク列から実際の画面並び順と一致する対象 ID リストを取り出す。
    public static func orderedSelectableIds(
        from chunks: [DisplayChunk],
        isSelectable: (PhotoItem) -> Bool
    ) -> [String] {
        chunks.flatMap { chunk in
            chunk.orderedItems.filter(isSelectable).map(\.localIdentifier)
        }
    }

    /// クラスタ内の推奨写真が既に `isDone` なら、そのクラスタからは 2 番手を繰り上げて選ばない。
    public static func recommendedToSelect(
        items: [PhotoItem],
        grouping: SectionGroupingResult,
        isDone: (PhotoItem) -> Bool
    ) -> Set<String> {
        let byId = Dictionary(uniqueKeysWithValues: items.map { ($0.localIdentifier, $0) })
        var out = Set<String>()

        for cluster in grouping.clusters {
            let recItems = cluster.recommendedIds.compactMap { byId[$0] }
            if recItems.contains(where: isDone) {
                continue
            }
            for item in recItems where item.eligibility.isEligible && !isDone(item) {
                out.insert(item.localIdentifier)
            }
        }

        for id in grouping.standaloneRecommendedIds {
            if let item = byId[id], item.eligibility.isEligible, !isDone(item) {
                out.insert(id)
            }
        }
        return out
    }

    /// 表示中（折りたたみ除外・対象のみ）の順序付き ID リストに対して Shift+クリック範囲選択を適用する。
    /// `targetId` が表示順リストに含まれない場合は `currentSelection` を変更しない。
    public static func shiftRange(
        orderedSelectableIds: [String],
        anchorId: String?,
        targetId: String,
        anchorTargetState: Bool,
        currentSelection: Set<String>
    ) -> Set<String> {
        guard let tIdx = orderedSelectableIds.firstIndex(of: targetId) else {
            return currentSelection
        }
        var next = currentSelection
        guard let anchorId,
              let aIdx = orderedSelectableIds.firstIndex(of: anchorId) else {
            if next.contains(targetId) { next.remove(targetId) } else { next.insert(targetId) }
            return next
        }
        let low = min(aIdx, tIdx)
        let high = max(aIdx, tIdx)
        for idx in low...high {
            let id = orderedSelectableIds[idx]
            if anchorTargetState { next.insert(id) } else { next.remove(id) }
        }
        return next
    }
}
