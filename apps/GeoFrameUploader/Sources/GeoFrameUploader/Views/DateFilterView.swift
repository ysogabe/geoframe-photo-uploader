import SwiftUI

/// 単日 / 期間の日付指定・読み込み、および表示・グルーピング・推奨選択バー。
struct DateFilterView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 12) {
                Picker("", selection: $model.dateMode) {
                    ForEach(DateMode.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 140)

                DatePicker(model.dateMode == .single ? "日付" : "開始", selection: $model.fromDate,
                           displayedComponents: .date)
                    .fixedSize()
                if model.dateMode == .range {
                    DatePicker("終了", selection: $model.toDate, in: model.fromDate..., displayedComponents: .date)
                        .fixedSize()
                }

                Button {
                    model.load()
                } label: {
                    if model.isLoading {
                        HStack(spacing: 6) { ProgressView().controlSize(.small); Text("読み込み中…") }
                    } else {
                        Label("読み込む", systemImage: "arrow.down.circle")
                    }
                }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(model.isBusy)

                Spacer()

                if model.hasLoaded {
                    Text("全 \(model.items.count) 件 / 対象 \(model.eligibleCount) 件 / 対象外 \(model.ineligibleCount) 件"
                         + " / 前回送信済み \(model.previouslySentCount) 件"
                         + (model.similarClusterCount > 0 ? " / 類似 \(model.similarClusterCount) グループ" : "")
                         + (model.hiddenCount > 0 ? "（\(model.hiddenCount) 件を非表示）" : ""))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }

            if model.hasLoaded {
                HStack(spacing: 10) {
                    Picker("", selection: $model.groupingMode) {
                        ForEach(GroupingMode.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 196)

                    if model.groupingMode == .sectioned {
                        Menu {
                            ForEach([15, 30, 60], id: \.self) { m in
                                Button { model.timeGapMinutes = m } label: {
                                    HStack {
                                        Text("\(m) 分以上空いたら分割")
                                        if model.timeGapMinutes == m { Image(systemName: "checkmark") }
                                    }
                                }
                            }
                            Divider()
                            ForEach([100, 300, 1000], id: \.self) { d in
                                Button { model.distanceThresholdMeters = d } label: {
                                    HStack {
                                        Text(d >= 1000 ? "\(d / 1000) km 以上移動で分割" : "\(d) m 以上移動で分割")
                                        if model.distanceThresholdMeters == d { Image(systemName: "checkmark") }
                                    }
                                }
                            }
                        } label: {
                            Label("\(model.timeGapMinutes)分 / \(model.distanceThresholdMeters >= 1000 ? "1km" : "\(model.distanceThresholdMeters)m")",
                                  systemImage: "slider.horizontal.3")
                        }
                        .controlSize(.small)
                        .help("場所・時間枠を区切る時間差と移動距離のしきい値")

                        Toggle("地名を表示", isOn: $model.geocodeEnabled)
                            .toggleStyle(.checkbox)
                            .fixedSize()
                            .help("セクションの代表座標（約100m単位）を Apple のジオコーディングで地名に変換します")
                    }

                    Toggle("似た写真を束ねる", isOn: $model.bundleSimilar)
                        .toggleStyle(.checkbox)
                        .fixedSize()
                        .help("同じバーストや 3 分以内・pHash 距離 12 以下の似た写真をまとめて表示します")

                    Spacer()

                    if let ap = model.analysisProgress {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text("品質解析中 \(ap.done)/\(ap.total)")
                                .font(.caption)
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                    }

                    Button {
                        model.selectFavorites()
                    } label: {
                        Label("お気に入りのみ", systemImage: "star")
                    }
                    .controlSize(.small)
                    .disabled(model.isBusy || model.eligibleCount == 0)

                    Button {
                        model.selectRecommendedAll()
                    } label: {
                        let count = model.recommendedAllIds.count
                        Label(model.isAnalysisComplete ? "推奨を自動選択 (\(count))" : "推奨を自動選択",
                              systemImage: "sparkles")
                    }
                    .controlSize(.small)
                    .buttonStyle(.borderedProminent)
                    .tint(.orange)
                    .disabled(model.isBusy || !model.isAnalysisComplete || model.recommendedAllIds.isEmpty)
                    .help(model.isAnalysisComplete
                          ? "各類似グループの最良（お気に入り最優先・鮮明度/露出スコア順）1枚と単独写真をまとめて選択します（手動選択は置き換えます）"
                          : "品質解析の完了後に使えます")
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .onChange(of: model.fromDate) { _, newValue in
            if model.toDate < newValue { model.toDate = newValue }
        }
    }
}
