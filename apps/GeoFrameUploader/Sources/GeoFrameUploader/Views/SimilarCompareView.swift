import SwiftUI
import UploaderCore

/// 類似写真グループを見比べて選択するモーダルパネル（最大 6 枚/ページ・キーボード操作対応）。
struct SimilarCompareView: View {
    @EnvironmentObject private var model: AppModel
    let cluster: SimilarityCluster
    let editableIds: [String]

    @State private var stagedSelection: Set<String> = []
    @State private var focusedIndex: Int = 0
    @State private var pageIndex: Int = 0
    @FocusState private var isPanelFocused: Bool

    private let pageSize = 6

    private var orderedIds: [String] {
        let editableSet = Set(editableIds)
        return cluster.rankedOrder.filter { editableSet.contains($0) }
    }
    private var totalPages: Int { max(1, (orderedIds.count + pageSize - 1) / pageSize) }
    private var pageIds: [String] {
        let start = pageIndex * pageSize
        guard start < orderedIds.count else { return [] }
        return Array(orderedIds[start..<min(orderedIds.count, start + pageSize)])
    }
    private var gridColumns: [GridItem] {
        let colCount = min(3, max(1, pageIds.count))
        return Array(repeating: GridItem(.flexible(), spacing: 12, alignment: .top), count: colCount)
    }

    var body: some View {
        VStack(spacing: 14) {
            header
            ScrollView {
                LazyVGrid(columns: gridColumns, alignment: .leading, spacing: 12) {
                    ForEach(Array(pageIds.enumerated()), id: \.element) { localIdx, id in
                        let globalIdx = pageIndex * pageSize + localIdx
                        if let item = model.runItem(for: id) {
                            CompareCard(
                                item: item,
                                ranking: cluster.rankings[id],
                                keyNumber: globalIdx < 9 ? (globalIdx + 1) : nil,
                                isSelected: stagedSelection.contains(id),
                                isFocused: focusedIndex == globalIdx,
                                compact: pageIds.count > 3,
                                thumbnails: model.thumbnails,
                                onToggle: {
                                    focusedIndex = globalIdx
                                    toggleId(id)
                                }
                            )
                        }
                    }
                }
            }
            .frame(maxHeight: 540)
            footer
        }
        .padding(20)
        .frame(minWidth: 680, idealWidth: 840, maxWidth: 850)
        .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.secondary.opacity(0.25)))
        .shadow(color: .black.opacity(0.38), radius: 24, y: 8)
        .focusable()
        .focused($isPanelFocused)
        .onAppear {
            stagedSelection = Set(orderedIds.filter { model.selection.contains($0) })
            focusedIndex = 0
            pageIndex = 0
            isPanelFocused = true
        }
        .onChange(of: model.selection) { oldSelection, newSelection in
            // 自動重複確認等でグローバル選択から実際に外された ID だけをステージから除く
            let removed = oldSelection.subtracting(newSelection)
            stagedSelection.subtract(removed)
        }
        .onKeyPress { press in
            handleKeyPress(press)
        }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("類似グループを見比べて選ぶ（\(orderedIds.count) 枚）")
                    .font(.title3.weight(.semibold))
                Text("512px サムネイルから算出した品質スコア順（お気に入り最優先）で表示しています")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if totalPages > 1 {
                HStack(spacing: 6) {
                    Button {
                        pageIndex = max(0, pageIndex - 1)
                        focusedIndex = pageIndex * pageSize
                    } label: {
                        Image(systemName: "chevron.left")
                    }
                    .disabled(pageIndex == 0)

                    Text("\(pageIndex + 1) / \(totalPages)")
                        .font(.callout.monospacedDigit())

                    Button {
                        pageIndex = min(totalPages - 1, pageIndex + 1)
                        focusedIndex = pageIndex * pageSize
                    } label: {
                        Image(systemName: "chevron.right")
                    }
                    .disabled(pageIndex >= totalPages - 1)
                }
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            let maxKey = min(9, orderedIds.count)
            Text("← / → 移動   Space 選択切替   1〜\(maxKey) 直接切替   Enter 確定   Esc 閉じる")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Button("推奨だけ残す") {
                stagedSelection = Set(orderedIds).intersection(cluster.recommendedIds)
            }
            Button("キャンセル") {
                model.closeComparison()
            }
            .keyboardShortcut(.cancelAction)
            Button("この選択で確定（\(stagedSelection.count) 枚）") {
                model.applyClusterComparison(cluster: cluster, editableIds: orderedIds, selectedIds: stagedSelection)
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
        }
    }

    private func toggleId(_ id: String) {
        if stagedSelection.contains(id) {
            stagedSelection.remove(id)
        } else {
            stagedSelection.insert(id)
        }
    }

    private func handleKeyPress(_ press: KeyPress) -> KeyPress.Result {
        switch press.key {
        case .leftArrow:
            focusedIndex = max(0, focusedIndex - 1)
            pageIndex = focusedIndex / pageSize
            return .handled
        case .rightArrow:
            focusedIndex = min(max(0, orderedIds.count - 1), focusedIndex + 1)
            pageIndex = focusedIndex / pageSize
            return .handled
        case .space:
            if orderedIds.indices.contains(focusedIndex) {
                toggleId(orderedIds[focusedIndex])
            }
            return .handled
        case .return:
            model.applyClusterComparison(cluster: cluster, editableIds: orderedIds, selectedIds: stagedSelection)
            return .handled
        case .escape:
            model.closeComparison()
            return .handled
        default:
            if let ch = press.characters.first, let num = Int(String(ch)),
               (1...min(9, orderedIds.count)).contains(num) {
                let idx = num - 1
                focusedIndex = idx
                pageIndex = idx / pageSize
                toggleId(orderedIds[idx])
                return .handled
            }
            return .ignored
        }
    }
}

private struct CompareCard: View {
    let item: PhotoItem
    let ranking: RankedMember?
    let keyNumber: Int?
    let isSelected: Bool
    let isFocused: Bool
    let compact: Bool
    let thumbnails: ThumbnailCache
    let onToggle: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                if let keyNumber {
                    Text("\(keyNumber)")
                        .font(.caption.monospaced().weight(.bold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.secondary.opacity(0.25), in: RoundedRectangle(cornerRadius: 4))
                }
                if let ranking {
                    if ranking.isRecommended {
                        Text("★ 推奨")
                            .font(.caption.weight(.bold))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 2)
                            .foregroundStyle(.white)
                            .background(Color.orange, in: Capsule())
                    } else {
                        Text("候補 \(ranking.rank) 位")
                            .font(.caption.weight(.medium))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 2)
                            .background(Color.secondary.opacity(0.2), in: Capsule())
                    }
                    Spacer()
                    Text(String(format: "%.1f", ranking.score))
                        .font(.callout.monospacedDigit().weight(.bold))
                        .foregroundStyle(ranking.isRecommended ? .orange : .primary)
                }
            }

            LargeThumbnail(item: item, thumbnails: thumbnails)
                .frame(height: compact ? 140 : 185)
                .overlay(alignment: .topLeading) {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.title2)
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(isSelected ? Color.white : Color.white.opacity(0.9),
                                         isSelected ? Color.accentColor : Color.black.opacity(0.4))
                        .padding(8)
                }

            HStack {
                Text(item.originalFilename ?? item.localIdentifier)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                if item.isFavorite {
                    Image(systemName: "star.fill").foregroundStyle(.yellow).font(.caption)
                }
                Text("\(item.pixelWidth)×\(item.pixelHeight)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            if let r = ranking {
                VStack(spacing: 4) {
                    metricBar("鮮明度 (0.62)", r.sharpnessRel, r.isRecommended ? .green : .accentColor)
                    metricBar("露出 (0.25)", r.exposureRel, r.isRecommended ? .green : .accentColor)
                    metricBar("ｺﾝﾄﾗｽﾄ (0.13)", r.contrastRel, r.isRecommended ? .green : .accentColor)
                }
                HStack(spacing: 4) {
                    ForEach(r.reasons, id: \.self) { reason in
                        Text(reason)
                            .font(.system(size: 10, weight: .medium))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(Color.green.opacity(0.16), in: RoundedRectangle(cornerRadius: 4))
                            .foregroundStyle(.green)
                    }
                    ForEach(r.issues, id: \.self) { issue in
                        Text("⚠ \(issue)")
                            .font(.system(size: 10, weight: .medium))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(Color.orange.opacity(0.18), in: RoundedRectangle(cornerRadius: 4))
                            .foregroundStyle(.orange)
                    }
                }
                .lineLimit(1)
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(isSelected ? Color.accentColor.opacity(0.12) : Color(nsColor: .controlBackgroundColor).opacity(0.5))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(
                    isSelected ? Color.accentColor : (isFocused ? Color.secondary : Color.secondary.opacity(0.25)),
                    lineWidth: isSelected || isFocused ? 2 : 1
                )
        )
        .contentShape(Rectangle())
        .onTapGesture(perform: onToggle)
    }

    private func metricBar(_ title: String, _ value: Double, _ color: Color) -> some View {
        HStack(spacing: 6) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .frame(width: 82, alignment: .leading)
            ProgressView(value: min(1.0, max(0.0, value)))
                .tint(color)
            Text("\(Int((value * 100).rounded()))")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 24, alignment: .trailing)
        }
    }
}
