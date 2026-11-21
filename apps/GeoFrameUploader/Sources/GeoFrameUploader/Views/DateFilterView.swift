import SwiftUI

/// 単日 / 期間の日付指定と読み込み。
struct DateFilterView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
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
                     + (model.hiddenCount > 0 ? "（\(model.hiddenCount) 件を非表示）" : ""))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .onChange(of: model.fromDate) { _, newValue in
            if model.toDate < newValue { model.toDate = newValue }
        }
    }
}
