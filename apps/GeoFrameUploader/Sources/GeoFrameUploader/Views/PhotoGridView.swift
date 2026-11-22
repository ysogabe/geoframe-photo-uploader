import SwiftUI
import UploaderCore

/// サムネイル一覧（フラット表示 / 場所・時間枠セクション表示 / 類似クラスタ枠）。
struct PhotoGridView: View {
    @EnvironmentObject private var model: AppModel

    private let columns = [GridItem(.adaptive(minimum: 140, maximum: 180), spacing: 12, alignment: .top)]

    var body: some View {
        Group {
            if model.items.isEmpty {
                emptyState
            } else if model.visibleItems.isEmpty {
                ContentUnavailableView("すべて非表示です", systemImage: "eye.slash",
                                       description: Text("送信済み・重複の \(model.hiddenCount) 件を隠しています。"))
            } else if model.groupingMode == .sectioned {
                sectionedScrollView
            } else {
                flatScrollView
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - セクション表示

    private var sectionedScrollView: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 14) {
                ForEach(model.sections) { section in
                    let vis = model.visibleItems(in: section)
                    if !vis.isEmpty {
                        SectionBlockView(
                            section: section,
                            visibleItems: vis,
                            grouping: model.grouping(for: section.id),
                            columns: columns
                        )
                    }
                }
            }
            .padding(12)
        }
    }

    // MARK: - フラット表示（クラスタ判定自体はセクション境界を維持して表示だけ平坦化）

    private var flatScrollView: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                ForEach(model.sections) { section in
                    let vis = model.visibleItems(in: section)
                    if !vis.isEmpty {
                        DisplayChunksView(
                            items: vis,
                            grouping: model.grouping(for: section.id),
                            sectionId: section.id,
                            bundleSimilar: model.bundleSimilar,
                            columns: columns
                        )
                    }
                }
            }
            .padding(12)
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        if model.isLoading {
            ProgressView("読み込み中…")
        } else if model.hasLoaded {
            ContentUnavailableView("写真がありません", systemImage: "photo",
                                   description: Text("指定した日付に撮影された写真は見つかりませんでした。"))
        } else {
            ContentUnavailableView("日付を選んで「読み込む」を押してください", systemImage: "calendar",
                                   description: Text("写真アプリの写真を撮影日で一覧にします（Mac のローカル時刻）。"))
        }
    }
}

// MARK: - セクションカード

private struct SectionBlockView: View {
    @EnvironmentObject private var model: AppModel
    let section: PhotoSection
    let visibleItems: [PhotoItem]
    let grouping: SectionGroupingResult
    let columns: [GridItem]

    private var isCollapsed: Bool { model.collapsedSectionIds.contains(section.id) }
    private var selectedCount: Int { model.selectedCount(in: section) }
    private var eligibleCount: Int { visibleItems.filter { $0.eligibility.isEligible }.count }
    private var recIds: Set<String> { model.recommendedIds(in: section) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if !isCollapsed {
                Divider()
                DisplayChunksView(
                    items: visibleItems,
                    grouping: grouping,
                    sectionId: section.id,
                    bundleSimilar: model.bundleSimilar,
                    columns: columns
                )
                .padding(10)
            }
        }
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.45), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.secondary.opacity(0.22)))
    }

    private var header: some View {
        HStack(spacing: 8) {
            Button {
                model.toggleSectionCollapsed(section.id)
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(Self.timeRangeText(start: section.startDate, end: section.endDate,
                                            includeDate: model.dateMode == .range || Self.spansMultipleDays(section.startDate, section.endDate)))
                        .font(.callout.monospacedDigit().weight(.semibold))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(Color.accentColor.opacity(0.14), in: RoundedRectangle(cornerRadius: 5))
                    locationLabel
                    Text("対象 \(eligibleCount) 枚")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if !grouping.clusters.isEmpty {
                        Text("類似 \(grouping.clusters.count) グループ")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if selectedCount > 0 {
                        Text("選択 \(selectedCount) 件")
                            .font(.caption.weight(.semibold).monospacedDigit())
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .foregroundStyle(.white)
                            .background(Color.accentColor, in: Capsule())
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Spacer()

            Button {
                model.selectRecommended(in: section)
            } label: {
                Label(model.isAnalysisComplete ? "推奨を選択 (\(recIds.count))" : "推奨を選択", systemImage: "sparkles")
            }
            .controlSize(.small)
            .disabled(model.isBusy || !model.isAnalysisComplete || recIds.isEmpty)

            Button("枠内をすべて選択") { model.selectAll(in: section) }
                .controlSize(.small)
                .disabled(model.isBusy || eligibleCount == 0)

            Button("解除") { model.deselectAll(in: section) }
                .controlSize(.small)
                .disabled(model.isBusy || selectedCount == 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(Color(nsColor: .windowBackgroundColor).opacity(0.5))
    }

    @ViewBuilder
    private var locationLabel: some View {
        if let loc = section.representativeLocation {
            HStack(spacing: 4) {
                Image(systemName: "mappin.and.ellipse").foregroundStyle(.red)
                if model.geocodeEnabled, let key = section.locationKey, let name = model.placeNames[key] {
                    Text(name + (section.isLocationBorrowed ? "（推定）" : ""))
                        .font(.callout.weight(.medium))
                } else {
                    Text(String(format: "%.3f, %.3f", loc.lat, loc.lon) + (section.isLocationBorrowed ? "（推定）" : ""))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
        } else if section.id == "undated" {
            Text("日時不明").font(.callout.weight(.medium)).foregroundStyle(.secondary)
        } else {
            Text("位置情報なし").font(.caption).foregroundStyle(.secondary)
        }
    }

    private static let timeFmt: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "HH:mm"
        return f
    }()

    private static let dateTimeFmt: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "MM/dd HH:mm"
        return f
    }()

    static func spansMultipleDays(_ a: Date?, _ b: Date?) -> Bool {
        guard let a, let b else { return false }
        return !Calendar.current.isDate(a, inSameDayAs: b)
    }

    static func timeRangeText(start: Date?, end: Date?, includeDate: Bool) -> String {
        guard let start else { return "--:--" }
        let fmt = includeDate ? dateTimeFmt : timeFmt
        let s = fmt.string(from: start)
        guard let end, end > start else { return s }
        let e = timeFmt.string(from: end)
        return "\(s) – \(e)"
    }
}

// MARK: - 表示チャンク（共通の SelectionPlanner.displayChunks を使用）

private struct DisplayChunksView: View {
    @EnvironmentObject private var model: AppModel
    let items: [PhotoItem]
    let grouping: SectionGroupingResult
    let sectionId: String
    let bundleSimilar: Bool
    let columns: [GridItem]

    private var chunks: [DisplayChunk] {
        SelectionPlanner.displayChunks(items: items, grouping: grouping, bundleSimilar: bundleSimilar)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(chunks) { chunk in
                switch chunk {
                case .cluster(let cluster, let members):
                    ClusterBoxView(cluster: cluster, members: members, sectionId: sectionId, columns: columns)
                case .grid(_, let gridItems):
                    LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
                        ForEach(gridItems) { item in
                            cell(for: item)
                        }
                    }
                }
            }
        }
    }

    private func cell(for item: PhotoItem) -> some View {
        PhotoCell(
            item: item,
            isSelected: model.selection.contains(item.id),
            isSelectable: model.isSelectable(item),
            live: model.livePhases[item.id] ?? (model.autoCheckingId == item.id ? .checkingDuplicate : nil),
            result: model.results[item.id],
            precheck: model.prechecks[item.id],
            cached: model.cachedStatus(for: item),
            cacheWarning: model.cacheWarning(for: item),
            duplicateNote: Self.duplicateNote(for: item, model: model),
            ranking: model.ranking(for: item.id, in: sectionId),
            standaloneIssues: model.standaloneIssues(for: item.id, in: sectionId),
            thumbnails: model.thumbnails,
            onToggle: { shift in model.toggle(item, shiftPressed: shift) }
        )
    }

    static func duplicateNote(for item: PhotoItem, model: AppModel) -> String? {
        if let r = model.results[item.id], r.status == .skippedDuplicate {
            if let fid = r.duplicateOfFileId, !fid.isEmpty { return "Drive の既存ファイルと同一（fileId: \(fid)）" }
            if let lid = r.duplicateOfLocalIdentifier { return "この実行内の先行写真と同一: \(model.displayName(for: lid))" }
            return "既存ファイルと同一"
        }
        if let p = model.prechecks[item.id] {
            switch p.decision {
            case .duplicateRemote(let fid, let name):
                return "Drive の既存ファイルと同一の見込み: \(name.isEmpty ? "" : name + " ")（fileId: \(fid)）"
            case .duplicateInBatch(let lid):
                return "選択内の先行写真と同一の見込み: \(model.displayName(for: lid))"
            default: return nil
            }
        }
        return nil
    }
}

private struct ClusterBoxView: View {
    @EnvironmentObject private var model: AppModel
    let cluster: SimilarityCluster
    let members: [PhotoItem]
    let sectionId: String
    let columns: [GridItem]

    private var selectedInCluster: Int {
        members.reduce(0) { $0 + (model.selection.contains($1.id) ? 1 : 0) }
    }

    private var editableIds: [String] {
        model.editableIds(for: cluster, visibleMembers: members)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Label("類似 \(members.count) 枚", systemImage: "square.stack.3d.up")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tint)
                if selectedInCluster > 0 {
                    Text("選択 \(selectedInCluster) 枚")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("見比べて選ぶ") {
                    model.openComparison(cluster: cluster, editableIds: editableIds)
                }
                .controlSize(.small)
                .disabled(model.isBusy || editableIds.isEmpty)
            }
            LazyVGrid(columns: columns, alignment: .leading, spacing: 10) {
                ForEach(members) { item in
                    PhotoCell(
                        item: item,
                        isSelected: model.selection.contains(item.id),
                        isSelectable: model.isSelectable(item),
                        live: model.livePhases[item.id] ?? (model.autoCheckingId == item.id ? .checkingDuplicate : nil),
                        result: model.results[item.id],
                        precheck: model.prechecks[item.id],
                        cached: model.cachedStatus(for: item),
                        cacheWarning: model.cacheWarning(for: item),
                        duplicateNote: DisplayChunksView.duplicateNote(for: item, model: model),
                        ranking: model.ranking(for: item.id, in: sectionId),
                        standaloneIssues: nil,
                        thumbnails: model.thumbnails,
                        onToggle: { shift in model.toggle(item, shiftPressed: shift) }
                    )
                }
            }
        }
        .padding(10)
        .background(Color.accentColor.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(style: StrokeStyle(lineWidth: 1.2, dash: [5, 3]))
                .foregroundStyle(Color.accentColor.opacity(0.45))
        )
    }
}
